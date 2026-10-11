# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Server-Sent Events framing for Streamable HTTP.
##
## powpow has no SSE helper: `res.send` writes a `Content-Length`-framed body,
## and powpow's own roadmap lists an SSE helper as not started. SSE is also
## unusable with `Content-Length`, since the response length is unknown when the
## head is written. So this module writes the HTTP response head and the event
## stream straight to the connection via `res.getConn()`, and calls
## `res.markSent()` so the HTTP dispatcher does not append its own response.
##
## The alternative, returning a plain JSON body, is what ordinary tool calls do;
## SSE is only used for the streaming half of the binding.

import std/strutils
import powpow
export powpow
import std/httpcore
import openparser/json

type
  SseStream* = ref object
    ## An open SSE response. Writes directly to the underlying connection.
    ##
    ## Reference-typed because closures capture it.
    res*: HttpResponse
    sent*: bool
    closed*: bool
    id*: int

proc headFor*(statusCode: HttpCode; headers: openArray[(string, string)]): string =
  ## An HTTP/1.1 response head for a stream of unknown length.
  ##
  ## `Transfer-Encoding: chunked` is mandatory here: without a `Content-Length`
  ## the client needs framing to know where the body ends.
  # `$Http200` renders as "200 OK", so it supplies both code and reason.
  result = "HTTP/1.1 " & $statusCode & "\r\n"
  for h in headers:
    result.add(h[0] & ": " & h[1] & "\r\n")
  result.add("Transfer-Encoding: chunked\r\n")
  result.add("Connection: keep-alive\r\n")
  result.add("\r\n")

proc chunk*(payload: string): string =
  ## Wrap `payload` in one HTTP chunk.
  ##
  ## Chunk sizes are hexadecimal and a zero-length chunk terminates the body.
  # toHex already emits lowercase; chunk sizes are case-insensitive per RFC.
  result = toHex(payload.len, 4) & "\r\n" & payload & "\r\n"

proc lastChunk*(): string =
  ## The terminating zero-length chunk.
  "0\r\n\r\n"

proc writeRaw*(st: SseStream; bytes: string) =
  ## Write bytes straight to the connection.
  if st.isNil or st.closed:
    return
  discard st.res.getConn().send(bytes)

proc startSse*(res: HttpResponse; id = 0): SseStream =
  ## Open an SSE response: `200 OK`, the required headers, and the chunked head.
  ##
  ## `markSent` is essential: without it powpow's dispatcher writes a second
  ## response after the handler returns and corrupts the stream.
  result = SseStream(res: res, id: id)
  res.status(Http200)
  res.markSent()
  result.writeRaw(headFor(Http200, [
    ("Content-Type", "text/event-stream; charset=utf-8"),
    ("Cache-Control", "no-cache, no-store"),
    # Defeats proxy buffering, which would otherwise defeat streaming entirely.
    ("X-Accel-Buffering", "no"),
  ]))
  result.sent = true

proc sseFrame*(event, data: string; eventId: int = -1): string =
  ## Build one SSE frame.
  ##
  ## Multi-line data is split across `data:` fields as the format requires, and
  ## a bare CR or LF inside the payload cannot break the frame because each line
  ## is re-prefixed.
  result = ""
  if eventId >= 0:
    result.add("id: " & $eventId & "\n")
  if event.len > 0:
    result.add("event: " & event & "\n")
  for line in data.splitLines():
    result.add("data: " & line & "\n")
  result.add("\n")

proc writeSse*(st: SseStream; event, data: string; eventId: int = -1) =
  ## Write one SSE event as a single HTTP chunk.
  if st.isNil or st.closed:
    return
  st.writeRaw(chunk(sseFrame(event, data, eventId)))

proc writeJson*(st: SseStream; event: string; node: JsonNode) =
  ## Write a JSON-RPC message as an SSE event.
  if st.isNil or st.closed:
    return
  st.writeSse(event, $node)

proc writeComment*(st: SseStream; text: string) =
  ## Write an SSE comment, usable as a keep-alive.
  if st.isNil or st.closed:
    return
  st.writeRaw(chunk(": " & text & "\n\n"))

proc closeSse*(st: SseStream) =
  ## Terminate the body with the final chunk and close. Idempotent.
  if st.isNil or st.closed:
    return
  st.closed = true
  st.writeRaw(lastChunk())