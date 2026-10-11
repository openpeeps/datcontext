# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Stream-oriented client transports.
##
## One implementation covers all three byte-stream transports, because the
## specification says a custom transport over a reliable bidirectional stream
## SHOULD reuse the stdio framing. Differences are confined to how the socket is
## opened:
##
## * stdio against a spawned subprocess
## * a Unix domain socket
## * TCP
##
## Every transport sends newline-delimited JSON and matches replies by JSON-RPC
## `id`, so concurrent requests cannot consume each other's responses.

import std/[locks, osproc, tables]
import powpow
import openparser/json
import ../protocol/[errors, framing, meta]
import ./core

type
  StreamClient* = ref object
    ## Shared state for the byte-stream transports.
    loop*: Loop
    conn*: Connection
    fb*: FrameBuffer
    pending*: Table[string, JsonNode]
    ## Replies keyed by request id, waiting to be collected.
    gotReply*: bool
    replyLock: Lock
    writeLock: Lock
    child*: Process
    ## The spawned child, when this is a subprocess transport.
    stderrData*: string
    ## Captured child stderr, for diagnostics.
    stderrFd*: int
    exited*: bool
    exitCode*: int
    errorMsg*: string

proc idOf*(msg: JsonNode): string =
  ## A stable string key for a JSON-RPC id.
  if msg.isNil:
    return ""
  let id = msg{"id"}
  if id.isNil:
    return ""
  $id

proc deliver*(st: StreamClient; msg: JsonNode) =
  ## Route a decoded reply to the request waiting on it.
  if msg.isNil:
    return
  let key = idOf(msg)
  withLock st.replyLock:
    if key.len > 0:
      st.pending[key] = msg
    st.gotReply = true

proc onStreamData(st: StreamClient; data: openArray[byte]) =
  ## Reassemble lines and dispatch each decoded message.
  try:
    for line in st.fb.feed(data):
      var msg: JsonNode
      try:
        msg = parseJson(line)
      except CatchableError:
        continue
      st.deliver(msg)
  except McpError:
    st.errorMsg = "frame buffer overflowed"
    st.loop.stop()
  except CatchableError:
    discard

proc onStreamClose(st: StreamClient) =
  ## The peer went away.
  withLock st.replyLock:
    st.gotReply = true
  st.loop.stop()

proc sendOnStream(st: StreamClient; msg: JsonNode): JsonNode =
  ## Write one message and wait for the matching reply.
  if st.conn.isNil:
    raise newMcpError(ecInternalError, "not connected")
  if st.exited:
    raise newMcpError(ecInternalError,
      "server process exited" &
      (if st.exitCode != 0: " with code " & $st.exitCode else: ""))

  let line = encodeLine(msg) & "\n"
  withLock st.writeLock:
    let n = st.conn.send(line)
    if n < 0:
      raise newMcpError(ecInternalError, "write failed: peer closed")

  let key = idOf(msg)
  if key.len == 0:
    # A notification: no reply is expected.
    return nil

  # Wait for the matching reply, bounded so a wedged server cannot hang forever.
  let deadline = monoMs() + 30_000
  while true:
    withLock st.replyLock:
      if st.pending.hasKey(key):
        result = st.pending[key]
        st.pending.del(key)
        return
      let done = st.gotReply
      if done and not st.pending.hasKey(key):
        # EOF with no reply pending for this id.
        if st.exited or st.conn == nil:
          raise newMcpError(ecInternalError,
            "connection closed before a reply arrived")
    if monoMs() > deadline:
      raise newMcpError(ecInternalError,
        "timed out waiting for a reply to " & key)
    if st.loop.isRunning:
      st.loop.poll(1)
    else:
      st.loop.poll(1)

proc newStreamTransport*(kind: string; st: StreamClient): ClientTransport =
  ## Wrap a stream client as a client transport.
  ClientTransport(kind: kind, send: proc(msg: JsonNode): JsonNode =
    st.sendOnStream(msg))

# ── Unix domain socket ───────────────────────────────────────────────────────

proc connectUnixClient*(path: string; loop: Loop = nil): McpClient =
  ## Connect to an MCP server on a Unix domain socket.
  let lp = if loop.isNil: newLoop() else: loop
  var st = StreamClient(loop: lp, fb: initFrameBuffer(), stderrFd: -1)
  initLock(st.replyLock)
  initLock(st.writeLock)

  var connected = false
  var failed = false
  # powpow's `connectUnix` returns void: the connection arrives through the
  # onConnect callback, so `st.conn` is filled in as a side effect.
  connectUnix(lp, path,
    (proc(c: Connection) {.closure.} =
      st.conn = c
      connected = true),
    (proc(c: Connection, d: openArray[byte]) {.closure.} = onStreamData(st, d)),
    (proc(c: Connection) {.closure.} =
      failed = true
      onStreamClose(st)))

  # Drive the loop until the handshake completes or a short deadline passes.
  let deadline = monoMs() + 3000
  while not connected and not failed and st.conn == nil and monoMs() < deadline:
    lp.poll(1)
  if not connected or st.conn == nil:
    raise newMcpError(ecInternalError,
      "could not connect to unix://" & path)

  result = newClient(newStreamTransport("unix", st))

# ── TCP ──────────────────────────────────────────────────────────────────────

proc connectTcpClient*(host: string; port: int; loop: Loop = nil): McpClient =
  ## Connect to an MCP server over TCP.
  let lp = if loop.isNil: newLoop() else: loop
  var st = StreamClient(loop: lp, fb: initFrameBuffer(), stderrFd: -1)
  initLock(st.replyLock)
  initLock(st.writeLock)

  var connected = false
  var failed = ""
  connect(lp, host, port,
    (proc(c: Connection) {.closure.} =
      st.conn = c
      connected = true),
    (proc(c: Connection, d: openArray[byte]) {.closure.} = onStreamData(st, d)),
    (proc(c: Connection) {.closure.} = onStreamClose(st)),
    (proc(err: string) {.closure.} = failed = err))

  let deadline = monoMs() + 5000
  while not connected and failed.len == 0 and monoMs() < deadline:
    lp.poll(1)
  if failed.len > 0:
    raise newMcpError(ecInternalError, failed)
  if not connected or st.conn == nil:
    raise newMcpError(ecInternalError,
      "could not connect to tcp://" & host & ":" & $port)

  result = newClient(newStreamTransport("tcp", st))

proc closeStreamClient*(st: StreamClient) =
  ## Release the connection, child process, and loop.
  if st.conn != nil and st.conn.state != Closed:
    st.conn.close()
  if st.child != nil:
    if st.child.running:
      st.child.terminate()
    close(st.child)
    st.child = nil
  if st.loop != nil and st.loop.isRunning:
    st.loop.stop()
  if st.loop != nil:
    st.loop.close()
