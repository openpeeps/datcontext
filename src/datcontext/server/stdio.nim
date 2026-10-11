# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## stdio transport.
##
## The client launches the server as a subprocess; the server reads JSON-RPC from
## stdin and writes to stdout, one message per line. powpow's `openStream` drives
## both file descriptors from the event loop, so the server stays responsive to
## signals while a peer is connected.
##
## Two rules from the specification shape this module:
##
## * The server MUST NOT write anything to stdout that is not a valid MCP
##   message. All diagnostics therefore go to stderr.
## * The server SHOULD exit promptly when stdin closes or reads return EOF. That
##   is the primary portable graceful-shutdown signal, since a client that has
##   closed the stream cannot then ask for termination.

import std/os
import powpow
import openparser/json
import ../protocol/errors
import ../subscriptions
import ../protocol/framing
import ./core
import ./signals

type
  StdioServer* = ref object
    ## A server bound to a process's standard streams.
    ##
    ## Reference-typed because the `openStream` callbacks close over it; a stack
    ## or value object would be captured unsafely.
    srv*: McpServer
    loop*: Loop
    input*: IoStream
    output*: IoStream
    fb*: FrameBuffer
    stopOnClose*: bool
    ## Stop the loop when stdin reaches EOF.

proc shutdown*(st: StdioServer) =
  ## Release the streams and stop the loop.
  if st.input != nil and st.input.state == StreamOpen:
    st.input.close()
  if st.output != nil and st.output.state == StreamOpen:
    st.output.close()
  st.loop.stop()

proc newStdioServer*(srv: McpServer; loop: Loop; inFd, outFd: int;
                     stopOnClose = true): StdioServer =
  ## Create the server object without binding any descriptors yet.
  ##
  ## Split from binding so the callbacks can close over a fully-initialized
  ## `ref` object.
  StdioServer(srv: srv, loop: loop, fb: initFrameBuffer(),
              stopOnClose: stopOnClose)

proc writeStdio*(st: StdioServer; node: JsonNode) =
  ## Write one JSON-RPC message as a single NDJSON frame.
  discard st.output.write(encodeLine(node) & "\n")

proc handleStdioLine*(st: StdioServer; line: string): string =
  ## Dispatch one line and render the reply.
  ##
  ## A `subscriptions/listen` request is answered by opening a stream on the same
  ## channel: the acknowledgment is written immediately, and the subscription's
  ## `emit` appends notifications to the shared stream thereafter. On stdio the
  ## client correlates them by the subscription id in `_meta`.
  var msg: JsonNode
  try:
    msg = parseJson(line)
  except CatchableError as e:
    return $newErrorResponse(nil, ecParseError, "Parse error: " & e.msg)

  let d = st.srv.dispatch(msg)
  if d.stream != nil:
    # Write the acknowledgment before emit is wired, so it is provably first.
    st.writeStdio(d.ack)
    d.stream.emit = proc(msg: JsonNode) = st.writeStdio(msg)
    return ""
  if d.reply.isNil:
    ""
  else:
    # The newline terminates the NDJSON frame; without it two replies would
    # concatenate into one unreadable line.
    encodeLine(d.reply) & "\n"

proc bindStdio*(st: StdioServer; inFd = 0; outFd = 1): StdioServer =
  ## Bind the standard streams and begin serving.
  st.input = openStream(st.loop, inFd,
    onData = proc(s: IoStream, data: openArray[byte]) =
      try:
        for line in st.fb.feed(data):
          let rendered = handleStdioLine(st, line)
          if rendered.len > 0:
            # Write to the output stream, not `s`: `s` is the read end, and
            # writing to it would send the reply back down the input pipe.
            discard st.output.write(rendered)
      except McpError as e:
        # A framing violation is the peer's problem; report and drop the
        # connection rather than growing memory.
        stderrLog("datcontext: " & e.msg)
        st.shutdown()
      except CatchableError as e:
        stderrLog("datcontext: read error: " & e.msg)
    ,
    onClose = proc(s: IoStream) =
      # EOF on stdin is the client's shutdown signal.
      if st.stopOnClose:
        st.loop.stop()
  )

  st.output = openStream(st.loop, outFd,
    onData = proc(s: IoStream, data: openArray[byte]) =
      discard
  )
  st

proc serveStdio*(srv: McpServer; loop: Loop; inFd = 0; outFd = 1;
                 stopOnClose = true): StdioServer =
  ## Bind `srv` to a pair of file descriptors.
  ##
  ## The caller must run `loop.run()` afterwards to drive it.
  result = newStdioServer(srv, loop, inFd, outFd, stopOnClose).bindStdio(inFd, outFd)

proc runStdio*(srv: McpServer; loop: Loop; shutdownSignals = true): void =
  ## Serve on this process's stdio until stdin closes or a signal arrives.
  discard serveStdio(srv, loop, 0, 1)
  if shutdownSignals:
    installSignalShutdown(loop)
  loop.run()
  loop.close()

proc runStdio*(srv: McpServer): void =
  ## Convenience overload using a fresh loop.
  srv.runStdio(newLoop())