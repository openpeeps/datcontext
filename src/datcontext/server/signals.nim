# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Server-side signal handling.
##
## powpow's `SignalRelay` delivers SIGINT and SIGTERM through the event loop
## rather than a global handler, so shutdown happens on the loop thread with no
## races. Kept in its own module because every transport wants it and none should
## have to import another transport to get it.

import std/os
import powpow

proc stderrLog*(msg: string) =
  ## Write a diagnostic to stderr.
  ##
  ## Never stdout: the stdio binding forbids the server from writing anything but
  ## MCP messages there, and a stray byte corrupts the stream.
  try:
    var f = stderr
    if f.isNil: return
    f.writeLine(msg)
    f.flushFile()
  except CatchableError:
    discard


proc installSignalShutdown*(loop: Loop): void =
  ## Stop `loop` on SIGINT or SIGTERM.
  ##
  ## The specification's stdio shutdown rule is that the server exits when stdin
  ## closes, since a client that has closed the stream cannot then ask for
  ## termination. Signals cover the case where the process is supervised.
  let relay = newOsSignalRelay(loop)
  discard relay.listen(SignalInt) do (): loop.stop()
  discard relay.listen(SignalTerm) do (): loop.stop()
  relay.watchOsSignals([SignalInt, SignalTerm])