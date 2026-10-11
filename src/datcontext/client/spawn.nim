# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## stdio client transport over a spawned subprocess.
##
## The client owns the child process and speaks newline-delimited JSON-RPC
## across pipes it creates itself, which is the deployment the stdio binding
## describes: a host launches a server and exchanges messages over the child's
## standard streams.
##
## Nim's `osproc.startProcess` inherits the parent's descriptors rather than
## returning pipe ends, so the pipes are created here and wired to the child
## with `fork` + `dup2` + `execv`. This has to be `fork` rather than `dup2` in
## the parent: redirecting fd 0/1/2 before spawning would repoint the *client's*
## own streams, which is exactly the bug that makes a parent-based approach
## unusable. Only the child ever sees the redirects, and it execs immediately.
##
## The child's stderr is drained continuously. The specification lets a server
## log freely there, and a client that ignores it can deadlock a server that
## logs enough to fill the pipe buffer.

import std/[hashes, locks, os, posix, strutils, tables]
import powpow
import openparser/json
import ../protocol/[errors, framing, meta]
import ./core

type
  SubprocessTransport* = ref object
    ## A spawned MCP server plus the pipes connecting to it.
    pid*: Pid
    loop*: Loop
    toChild*: IoStream
    ## The client's write end of the child's stdin.
    fromChild*: IoStream
    ## The client's read end of the child's stdout.
    errStream*: IoStream
    ## The client's read end of the child's stderr.
    fb*: FrameBuffer
    pending*: Table[string, JsonNode]
    gotReply*: bool
    replyLock: Lock
    writeLock: Lock
    stderrBuf*: string
    stderrOnLine*: proc(line: string)
    ## Called for each complete line the child writes to stderr.
    exited*: bool
    exitCode*: int

var spawnedTransport: seq[(McpClient, SubprocessTransport)]
  ## Spawned servers keyed by owning client. A seq rather than a Table because
  ## `McpClient` is a ref to an object with no hash or equality, and the number
  ## of live clients is small.

proc idKey*(msg: JsonNode): string =
  ## The map key for a message's JSON-RPC id, or `""` when absent.
  ##
  ## Uses `idToString` rather than `$` so the key is the id's plain value, not
  ## its JSON rendering: `"abc"` and `abc` must not be different keys.
  if msg.isNil or not msg.hasKey("id"):
    return ""
  idToString(msg["id"])

proc deliver*(st: SubprocessTransport; msg: JsonNode) =
  ## Route a decoded reply to whoever is waiting on its id.
  if msg.isNil:
    return
  withLock st.replyLock:
    let key = idKey(msg)
    if key.len > 0:
      st.pending[key] = msg
    st.gotReply = true

proc onChildStdout(st: SubprocessTransport; data: openArray[byte]) =
  ## Reassemble NDJSON from the child's stdout.
  try:
    for line in st.fb.feed(data):
      var msg: JsonNode
      try:
        msg = parseJson(line)
      except CatchableError:
        continue
      st.deliver(msg)
  except McpError:
    st.loop.stop()

proc onChildStderr(st: SubprocessTransport; data: openArray[byte]) =
  ## Forward whole stderr lines to `stderrOnLine`, accumulating the remainder.
  if st.stderrOnLine == nil:
    return
  var chunk = newString(data.len)
  for i, b in data:
    chunk[i] = char(b)
  st.stderrBuf.add(chunk)
  var nl = st.stderrBuf.find('\n')
  while nl >= 0:
    let line = st.stderrBuf[0 ..< nl]
    st.stderrBuf = if nl + 1 <= st.stderrBuf.high:
                      st.stderrBuf[(nl + 1) .. ^1]
                    else: ""
    if line.len > 0:
      st.stderrOnLine(line)
    nl = st.stderrBuf.find('\n')

proc checkExit(st: SubprocessTransport) =
  ## Notice when the child has exited.
  if st.exited:
    return
  var status: cint = 0
  if posix.waitpid(st.pid, status, WNOHANG) == st.pid:
    st.exited = true
    st.exitCode = (int(status shr 8)) and 0xFF

proc sendOnSubprocess(st: SubprocessTransport; msg: JsonNode): JsonNode =
  ## Write one message and await the matching reply.
  checkExit(st)
  if st.exited:
    raise newMcpError(ecInternalError,
      "server process exited" &
      (if st.exitCode != 0: " with code " & $st.exitCode else: ""))

  let line = encodeLine(msg) & "\n"
  withLock st.writeLock:
    if st.toChild.write(line) < 0:
      raise newMcpError(ecInternalError, "write failed: child closed its stdin")

  let key = idKey(msg)
  if key.len == 0:
    # A notification: no reply is expected.
    return nil

  let deadline = monoMs() + 60_000
  while true:
    withLock st.replyLock:
      if st.pending.hasKey(key):
        result = st.pending[key]
        st.pending.del(key)
        return
    checkExit(st)
    if st.exited:
      raise newMcpError(ecInternalError,
        "server exited before replying to " & key)
    if monoMs() > deadline:
      raise newMcpError(ecInternalError,
        "timed out waiting for a reply to " & key)
    st.loop.poll(1)

proc spawnServer*(command: string; args: openArray[string] = @[];
                  workingDir = ""; loop: Loop = nil;
                  stderrOnLine: proc(line: string) = nil): McpClient =
  ## Launch `command` and speak MCP over its standard streams.
  ##
  ## The client takes ownership of the child: closing it terminates the process.
  ## Raises `McpError` when the child cannot be started.
  let lp = if loop.isNil: newLoop() else: loop
  let st = SubprocessTransport(loop: lp, fb: initFrameBuffer(), stderrBuf: "")
  initLock(st.replyLock)
  initLock(st.writeLock)
  st.stderrOnLine = stderrOnLine

  var inPipe, outPipe, errPipe: array[2, cint]
  if posix.pipe(inPipe) != 0:
    raise newMcpError(ecInternalError, "pipe() failed for the child's stdin")
  if posix.pipe(outPipe) != 0:
    for fd in [inPipe[0], inPipe[1]]: discard posix.close(fd)
    raise newMcpError(ecInternalError, "pipe() failed for the child's stdout")
  if posix.pipe(errPipe) != 0:
    for fd in [inPipe[0], inPipe[1], outPipe[0], outPipe[1]]:
      discard posix.close(fd)
    raise newMcpError(ecInternalError, "pipe() failed for the child's stderr")

  # argv and envp are NULL-terminated cstring arrays, so they must be built as
  # pointer arrays rather than seq[string].
  var argv = newSeq[cstring](args.len + 2)
  # execvp takes a NUL-terminated cstringArray.
  argv[0] = command.cstring
  for i, a in args:
    argv[i + 1] = a.cstring
  argv[args.len + 1] = nil



  var cwd: cstring = nil
  if workingDir.len > 0:
    cwd = workingDir.cstring

  let pid = posix.fork()
  if pid < 0:
    for fd in [inPipe[0], inPipe[1], outPipe[0], outPipe[1],
               errPipe[0], errPipe[1]]:
      discard posix.close(fd)
    raise newMcpError(ecInternalError, "fork() failed")

  if pid == 0:
    # Child. Only the redirects happen here; the parent's streams are untouched
    # because the file descriptors were duplicated in the forked child.
    discard posix.dup2(inPipe[0], 0)   # read the pipe the client writes
    discard posix.dup2(outPipe[1], 1)  # write to the pipe the client reads
    discard posix.dup2(errPipe[1], 2)
    for fd in [inPipe[0], inPipe[1], outPipe[0], outPipe[1],
               errPipe[0], errPipe[1]]:
      discard posix.close(fd)
    if cwd != nil:
      discard posix.chdir(cwd)
    # execvp searches PATH and inherits the environment, which is what a host
    # launching a server by name expects. It only returns on failure.
    discard posix.execvp(command.cstring, cast[cstringArray](argv[0].addr))
    # Only reached when exec failed; 127 is the conventional "not found".
    quit(127)

  st.pid = pid
  # Close the child's ends in the parent.
  for fd in [inPipe[0], outPipe[1], errPipe[1]]:
    discard posix.close(fd)

  st.toChild = openStream(lp, inPipe[1].int,
    onData = proc(s: IoStream, d: openArray[byte]) = discard)
  st.fromChild = openStream(lp, outPipe[0].int,
    onData = proc(s: IoStream, d: openArray[byte]) = onChildStdout(st, d))
  st.errStream = openStream(lp, errPipe[0].int,
    onData = proc(s: IoStream, d: openArray[byte]) = onChildStderr(st, d))

  result = newClient(ClientTransport(
    kind: "stdio",
    send: proc(msg: JsonNode): JsonNode = sendOnSubprocess(st, msg)))
  # The transport owns the child and its pipes; the closure keeps it alive, but
  # hold an explicit reference too so the caller can shut it down.
  spawnedTransport.add((result, st))

proc closeSubprocess*(st: SubprocessTransport) =
  ## Close the pipes, terminate the child, and stop the loop.
  if st.toChild != nil and st.toChild.state == StreamOpen: st.toChild.close()
  if st.fromChild != nil and st.fromChild.state == StreamOpen:
    st.fromChild.close()
  if st.errStream != nil and st.errStream.state == StreamOpen:
    st.errStream.close()
  checkExit(st)
  if not st.exited:
    # Escalate from the spec's graceful step: closing the child's stdin has
    # already happened above, so terminate if it did not exit.
    discard posix.kill(st.pid, SIGTERM)
    var status: cint = 0
    if posix.waitpid(st.pid, status, 1000) != st.pid:
      discard posix.kill(st.pid, SIGKILL)
      discard posix.waitpid(st.pid, status, 0)
  if st.loop != nil and st.loop.isRunning:
    st.loop.stop()

proc closeClient*(c: McpClient) =
  ## Close the client, terminating a spawned server if it owns one.
  var keep: seq[(McpClient, SubprocessTransport)]
  for entry in spawnedTransport:
    if cast[pointer](entry[0]) == cast[pointer](c):
      closeSubprocess(entry[1])
    else:
      keep.add(entry)
  spawnedTransport = keep