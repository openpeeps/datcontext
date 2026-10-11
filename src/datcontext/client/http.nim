# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Streamable HTTP client transport.
##
## Every message is a POST to a single endpoint. The reply is either a JSON
## object or, when the request asked for it, a request-scoped SSE stream, which
## is parsed here since powpow has no SSE reader.
##
## Two protocol details from the 2026-07-28 revision shape this module:
##
## * `MCP-Protocol-Version` mirrors `_meta.protocolVersion`. The body is the
##   source of truth, and a disagreement surfaces as `HeaderMismatch`.
## * Sessions are gone, so there is no `Mcp-Session-Id` to carry between calls
##   and no session state to thread through.

import std/[sequtils, strutils]
import powpow
import openparser/json
import ../protocol/[errors, meta, types, version]
import ./core

const
  McpEndpoint* = "/mcp"
  McpProtocolVersionHeader* = "MCP-Protocol-Version"

type
  HttpClientTransport* = ref object
    baseUrl*: string
    endpoint*: string
    host*: string
    port*: int
    tls*: bool
    unixSocket*: string
    extraHeaders*: seq[(string, string)]

proc newHttpTransport*(url: string;
                       extraHeaders: seq[(string, string)] = @[]): HttpClientTransport =
  ## Build a transport for a Streamable HTTP endpoint.
  ##
  ## `url` may omit the path or include `/mcp`; both resolve to the same
  ## endpoint, so `http://host:9000` and `http://host:9000/mcp` both work.
  result = HttpClientTransport(extraHeaders: extraHeaders)
  var u = url
  if not u.contains("://"):
    u = "http://" & u
  let schemeEnd = u.find("://")
  let scheme = u[0 ..< schemeEnd]
  var rest = u[schemeEnd + 3 .. ^1]
  result.tls = scheme == "https"

  var path = ""
  let slash = rest.find('/')
  if slash >= 0:
    path = rest[slash .. ^1]
    rest = rest[0 ..< slash]

  # Strip any userinfo, then split host and port.
  let at = rest.rfind('@')
  if at >= 0:
    rest = rest[(at + 1) .. ^1]
  let colon = rest.rfind(':')
  if colon >= 0 and rest[(colon + 1) .. ^1].allIt(it in {'0'..'9'}):
    result.host = rest[0 ..< colon]
    result.port = parseInt(rest[(colon + 1) .. ^1])
  else:
    result.host = rest
    result.port = if result.tls: 443 else: 80

  result.baseUrl = (if result.tls: "https://" else: "http://") &
                   result.host & ":" & $result.port
  result.endpoint = if path.len == 0 or path == "/": McpEndpoint else: path

proc parseSse*(body: string): JsonNode =
  ## Extract the JSON payload from an SSE body.
  ##
  ## Each `data:` line is concatenated per the SSE format, then parsed. Returns
  ## nil when the body carries no data field.
  var payload = ""
  var sawData = false
  for line in body.splitLines():
    if line.startsWith("data:"):
      let chunk = line["data:".len .. ^1].strip()
      payload.add(chunk)
      sawData = true
    elif line.startsWith("event:") and sawData:
      # A complete event: stop before the next one.
      break
  if not sawData:
    return nil
  try:
    parseJson(payload)
  except CatchableError:
    nil

proc postMessage*(t: HttpClientTransport; msg: JsonNode;
                  wantSse = false): JsonNode =
  ## POST one message and decode the reply.
  ##
  ## Synchronous: creates a client per request, which sidesteps powpow's
  ## single-in-flight restriction on `AsyncHttpClient`. Requests here are short,
  ## so the extra handshake is not worth a pool.
  let client = newHttpClient(keepAlive = false, timeoutMs = 60_000)
  defer: client.close()

  var headers = @[
    ("Content-Type", "application/json"),
    ("Accept", if wantSse: "text/event-stream" else: "application/json"),
  ]
  let params = msg{"params"}
  let declared = declaredVersion(params)
  if declared.len > 0:
    headers.add((McpProtocolVersionHeader, declared))
  for h in t.extraHeaders:
    headers.add(h)

  let res = client.post(t.baseUrl & t.endpoint, $msg, headers,
                        unixSocket = t.unixSocket)
  let status = res.getStatusCode().int
  let body = res.getBodyString()

  if status == 202:
    # Notification accepted, no body.
    return nil

  if body.len == 0:
    raise newMcpError(ecInternalError,
      "empty response body (status " & $status & ")")

  let contentType = res.parser.getHeaderValue("content-type")
  let isJson = contentType.contains("application/json")
  var decoded: JsonNode
  if isJson:
    try:
      decoded = parseJson(body)
    except CatchableError as e:
      raise newMcpError(ecParseError, "could not parse response: " & e.msg)
  else:
    decoded = parseSse(body)
    if decoded.isNil:
      # Some servers answer an error as a plain-text body.
      if status >= 400:
        raise newMcpError(ecInternalError,
          "HTTP " & $status & ": " & body[0 ..< min(body.len, 200)])
      raise newMcpError(ecParseError, "no JSON-RPC payload in the SSE response")

  if decoded.isNil:
    raise newMcpError(ecInternalError, "no usable response")
  decoded

proc connectHttp*(url: string; name = "datcontext-client";
                  version = "0.1.0";
                  extraHeaders: seq[(string, string)] = @[]): McpClient =
  ## Build a client that talks Streamable HTTP.
  let t = newHttpTransport(url, extraHeaders)
  let transport = ClientTransport(
    kind: "http",
    send: proc(msg: JsonNode): JsonNode = t.postMessage(msg))
  result = newClient(transport, name, version)