# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Unix domain socket and raw TCP transports.
##
## The specification says custom transports over a reliable bidirectional byte
## stream SHOULD reuse the stdio framing, because stdio is just newline-delimited
## JSON-RPC over such a stream and only the process-lifecycle rules are specific
## to standard streams. So both transports here reuse `FrameBuffer` and
## `McpServer.handleLine` verbatim; the only difference from stdio is which
## socket type carries the bytes.

import std/[os, strutils, tables]
import powpow
import openparser/json
import ../protocol/errors
import ../protocol/framing
import ../subscriptions
import ./core
import ./signals

type
  StreamServer* = ref object
    ## A server bound to a listening socket, shared by the UDS and TCP variants.
    srv*: McpServer
    loop*: Loop
    server*: TcpServer
    ## Per-connection frame buffers, keyed by connection identity.
    buffers*: Table[int, FrameBuffer]

proc newStreamServer*(srv: McpServer; loop: Loop): StreamServer =
  ## Wrap `srv` for a socket transport on `loop`.
  StreamServer(srv: srv, loop: loop,
               buffers: initTable[int, FrameBuffer]())

proc onConnData*(st: StreamServer; conn: Connection; data: openArray[byte]) =
  ## Feed a connection's bytes through the shared NDJSON framing.
  ##
  ## One buffer per connection, created lazily: a read can end mid-line, so
  ## reassembly has to persist across reads.
  if not st.buffers.hasKey(conn.fd.int):
    st.buffers[conn.fd.int] = initFrameBuffer()
  try:
    let lines = st.buffers[conn.fd.int].feed(data)
    for line in lines:
      var msg: JsonNode
      try:
        msg = parseJson(line)
      except CatchableError as e:
        discard conn.send($newErrorResponse(nil, ecParseError,
          "Parse error: " & e.msg) & "\n")
        continue
      let d = st.srv.dispatch(msg)
      if d.stream != nil:
        # Write the acknowledgment before wiring emit, so it is provably first.
        discard conn.send(encodeLine(d.ack) & "\n")
        d.stream.emit = proc(msg: JsonNode) =
          discard conn.send(encodeLine(msg) & "\n")
        continue
      if not d.reply.isNil:
        discard conn.send(encodeLine(d.reply) & "\n")
  except McpError as e:
    # A framing violation means the peer is not speaking the protocol; drop the
    # connection rather than growing the buffer.
    stderrLog("datcontext: " & e.msg & "; dropping connection")
    conn.close()
  except CatchableError as e:
    stderrLog("datcontext: connection error: " & e.msg)
    conn.close()

proc runUnix*(srv: McpServer; path: string; loop: Loop = nil): void =
  ## Serve over a Unix domain socket at `path`. Blocking.
  ##
  ## A stale socket file from a previous run is removed first, otherwise bind
  ## fails with EADDRINUSE even though no server is listening.
  let lp = if loop.isNil: newLoop() else: loop
  if fileExists(path) or symlinkExists(path):
    removeFile(path)

  let st = newStreamServer(srv, lp)
  let tcp = newTcpServer(lp,
    onData = proc(conn: Connection, data: openArray[byte]) =
      st.onConnData(conn, data),
    onAccept = proc(conn: Connection) =
      discard
    ,
    onClose = proc(conn: Connection) =
      st.buffers.del(conn.fd.int)
  )

  installSignalShutdown(lp)
  stderrLog("datcontext: MCP on unix://" & path)
  tcp.listenUnix(path)
  lp.run()
  tcp.close()
  if fileExists(path):
    removeFile(path)
  lp.close()

proc runTcp*(srv: McpServer; port: int; address = "127.0.0.1";
             loop: Loop = nil): void =
  ## Serve over TCP. Blocking.
  let lp = if loop.isNil: newLoop() else: loop
  let st = newStreamServer(srv, lp)
  let tcp = newTcpServer(lp,
    onData = proc(conn: Connection, data: openArray[byte]) =
      st.onConnData(conn, data),
    onAccept = proc(conn: Connection) =
      discard
    ,
    onClose = proc(conn: Connection) =
      st.buffers.del(conn.fd.int)
  )

  installSignalShutdown(lp)
  stderrLog("datcontext: MCP on tcp://" & address & ":" & $port)
  tcp.listen(address, port)
  lp.run()
  tcp.close()
  lp.close()

