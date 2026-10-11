# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Newline-delimited JSON framing.
##
## The stdio binding is one JSON-RPC message per line over a reliable
## bidirectional byte stream, with no embedded newlines. The specification
## requires custom transports over such streams to reuse this framing, so the
## same codec drives stdio, Unix domain sockets, and raw TCP.
##
## powpow delivers reads in small pooled chunks, so a single read can end
## mid-line and one line can span several reads. `FrameBuffer` reassembles.

import std/strutils
import openparser/json
import ./errors

const
  DefaultMaxLineLen* = 64 * 1024 * 1024
  ## Upper bound on a single JSON-RPC line. Bounds memory against a peer that
  ## never sends a newline.

type
  FrameBuffer* = ref object
    ## Accumulates bytes and yields whole lines.
    ##
    ## Reference-typed on purpose: transports hold one buffer per connection and
    ## mutate it in place. With value semantics every `feed` would operate on a
    ## copy and bytes buffered mid-line would be silently dropped.
    buf*: string
    maxLineLen*: int
    overflowed*: bool
    ## Set once a line exceeded `maxLineLen`. The buffer refuses further input
    ## until `reset` so a hostile peer cannot grow it without bound.

proc initFrameBuffer*(maxLineLen: int = DefaultMaxLineLen): FrameBuffer =
  FrameBuffer(buf: newStringOfCap(4096), maxLineLen: maxLineLen)

proc reset*(fb: FrameBuffer) =
  ## Drop buffered bytes and clear the overflow latch.
  fb.buf.setLen(0)
  fb.overflowed = false

proc buffered*(fb: FrameBuffer): int {.inline.} =
  ## Number of bytes held pending a newline.
  fb.buf.len

proc feed*(fb: FrameBuffer; chunk: string): seq[string] =
  ## Append `chunk` and return every complete line it completed.
  ##
  ## Handles both `\n` and `\r\n`. Empty lines are skipped, since a client may
  ## pad its output. Raises on overflow to stop unbounded growth.
  if fb.overflowed:
    raise newMcpError(ecInvalidRequest,
      "frame buffer overflowed; refusing further input")
  if chunk.len == 0:
    return @[]
  result = @[]
  fb.buf.add(chunk)
  if fb.buf.len > fb.maxLineLen:
    fb.overflowed = true
    fb.buf.setLen(0)
    raise newMcpError(ecParseError,
      "JSON-RPC line exceeded " & $fb.maxLineLen & " bytes")
  var start = 0
  while true:
    let nl = fb.buf.find('\n', start)
    if nl < 0: break
    var line = fb.buf[start ..< nl]
    if line.len > 0 and line[^1] == '\r':
      line.setLen(line.len - 1)
    if line.len > 0:
      result.add(line)
    start = nl + 1
  if start > 0:
    fb.buf = fb.buf[start .. ^1]
  if fb.buf.len == 0:
    fb.buf = ""

proc feed*(fb: FrameBuffer; chunk: openArray[byte]): seq[string] =
  ## Byte-chunk overload of `feed`, matching powpow's `onData` callback shape.
  if chunk.len == 0:
    return @[]
  # Materialise an owning copy: an `openArray[byte]` is a view that the caller
  # may reuse the moment this returns, and `cast[string]` over it would alias
  # that buffer.
  var s = newString(chunk.len)
  for i, b in chunk:
    s[i] = char(b)
  fb.feed(s)

proc encodeLine*(node: JsonNode): string =
  ## Render `node` as a single NDJSON frame, with any newlines in string
  ## content escaped so the result never spans lines.
  result = $node
  # `$` already escapes control characters inside strings, but be defensive:
  # a raw newline would break framing, so strip any that slipped through.
  if '\n' in result:
    result = result.replace("\n", "\\n")