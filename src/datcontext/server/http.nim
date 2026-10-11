# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Streamable HTTP transport.
##
## Every message is an HTTP POST to a single endpoint. The reply is either a
## JSON object or, when the client accepts `text/event-stream`, a request-scoped
## SSE stream. A bare `GET` opens a server-to-client notification stream.
##
## This module follows the 2026-07-28 revision, which removed protocol-level
## sessions and the `Mcp-Session-Id` header. Concretely, that means:
##
## * List endpoints are not connection-scoped and take no session identifier.
## * The `MCP-Protocol-Version` header mirrors `_meta.protocolVersion`. The body
##   remains the source of truth, and a disagreement is rejected with
##   `HeaderMismatch` (-32020) rather than being silently resolved.
## * A request missing the required metadata is rejected with `400 Bad Request`
##   before any dispatch happens.

import std/httpcore
import std/strutils
import powpow
export powpow
import openparser/json
import ../protocol/[errors, meta, version]
import ../subscriptions
import ./core
import ./sse
import ./signals

const
  McpEndpoint* = "/mcp"
  McpProtocolVersionHeader* = "MCP-Protocol-Version"

type
  HttpServerConfig* = object
    ## Transport tuning.
    maxBodySize*: int64
    ## Reject bodies larger than this. Tool inputs can carry whole documents, so
    ## the default is generous but still bounded.
    allowGetStream*: bool
    ## Whether to answer `GET` with an SSE stream.

proc defaultHttpConfig*(): HttpServerConfig =
  HttpServerConfig(maxBodySize: 64 * 1024 * 1024, allowGetStream: true)

proc isModernRequest(msg: JsonNode): bool =
  ## True when the request carries modern per-request metadata.
  let m = metaOf(msg{"params"})
  if m.isNil:
    return false
  m.hasKey(MetaProtocolVersion) or m.hasKey(MetaClientCapabilities)

proc handleHttp*(srv: McpServer; req: HttpRequest; res: HttpResponse;
                 config = defaultHttpConfig()) =
  ## Handle one HTTP request against the MCP endpoint.
  ##
  ## Registered directly as powpow's `OnRequestCallback`, which is `gcsafe`.
  {.cast(gcsafe).}:
    let path = req.getPath()

    if path != McpEndpoint and not path.startsWith(McpEndpoint & "/"):
      res.sendError(Http404, "Unknown endpoint: " & path)
      return

    let meth = req.getMethod()
    case meth
    of HttpOptions:
      # Advertise the methods this endpoint accepts.
      res.status(Http200)
        .header("Allow", "POST, GET, DELETE, OPTIONS")
        .send("")
      return
    of HttpDelete:
      # Sessions no longer exist in this revision, so there is nothing to
      # delete. Answering 204 keeps older clients' teardown happy.
      res.status(Http204).send("")
      return
    of HttpGet:
      if not config.allowGetStream:
        res.sendError(Http405, "Server-initiated streams are disabled")
        return
      let accepts = req.getHeaderValue("Accept")
      if accepts.len == 0 or not accepts.contains("text/event-stream"):
        res.sendError(Http405,
          "GET requires Accept: text/event-stream")
        return
      # Nothing is pushed in this implementation: the server emits no
      # unsolicited notifications, and all tool results ride the POST that
      # requested them. Open a stream so the client can detect liveness.
      let st = res.startSse()
      st.writeJson("endpoint", %*{"status": "ready",
                                  "protocolVersion": ProtocolVersion})
      st.closeSse()
      return
    of HttpPost:
      discard
    else:
      res.sendError(Http405, "Method not allowed: " & $meth)
      return

    # ── POST ──
    let body = req.getBodyString()
    if body.strip.len == 0:
      res.status(Http400)
        .header("Content-Type", "application/json")
        .send($newErrorResponse(nil, ecInvalidRequest, "empty request body"))
      return

    var msg: JsonNode
    try:
      msg = parseJson(body)
    except CatchableError as e:
      res.status(Http400)
        .header("Content-Type", "application/json")
        .send($newErrorResponse(nil, ecParseError, "Parse error: " & e.msg))
      return

    # Header/body metadata agreement. The body is authoritative, so a mismatch
    # is an error rather than a precedence rule.
    let headerVersion = req.getHeaderValue(McpProtocolVersionHeader)
    let bodyVersion = declaredVersion(msg{"params"})
    if headerVersion.len > 0 and bodyVersion.len > 0 and
        headerVersion != bodyVersion:
      res.status(Http400)
        .header("Content-Type", "application/json")
        .send($srv.toErrorResponse(msg{"id"},
          newMcpError(ecHeaderMismatch,
            "Header and body metadata mismatch",
            headerMismatchData(bodyVersion, headerVersion))))
      return

    # A modern POST must carry the required metadata. On HTTP the rejection is
    # a 400, which is how a legacy client detects it must fall back.
    if isModernRequest(msg):
      try:
        validateModern(msg{"params"})
      except McpError as e:
        res.status(HttpCode(defaultHttpStatus(e.code)))
          .header("Content-Type", "application/json")
          .send($srv.toErrorResponse(msg{"id"}, e))
        return
    elif headerVersion.len > 0:
      # A header without modern body metadata is the mismatch case the spec
      # describes for a legacy client probing a modern server.
      res.status(Http400)
        .header("Content-Type", "application/json")
        .send($newErrorResponse(msg{"id"}, ecInvalidParams,
          "Missing required request metadata; the " &
          McpProtocolVersionHeader &
          " header requires _meta." & MetaProtocolVersion &
          " and _meta." & MetaClientCapabilities & " in the body"))
      return

    let d = srv.dispatch(msg)

    # `subscriptions/listen`: the response is a stream, not a payload. Send the
    # acknowledgment first, and only then wire up emit, so no notification can
    # precede it as the spec requires.
    if d.stream != nil:
      let st = res.startSse()
      st.writeJson("message", d.ack)
      d.stream.emit = proc(msg: JsonNode) = st.writeJson("message", msg)
      # Keep the loop alive for the life of the stream rather than returning a
      # completed response: the connection stays open until the client
      # disconnects, at which point powpow closes the fd and the loop stops.
      discard srv
      return

    let reply = d.reply

    # Notifications get no response body at all.
    if reply.isNil:
      res.status(Http202).send("")
      return

    let accepts = req.getHeaderValue("Accept")
    if accepts.contains("text/event-stream"):
      let st = res.startSse()
      st.writeJson("message", reply)
      st.closeSse()
      return

    res.status(HttpCode(srv.httpStatusFor(reply)))
      .header("Content-Type", "application/json")
      .send($reply)

proc runHttp*(srv: McpServer; port = 9000; address = "127.0.0.1";
              config = defaultHttpConfig()): void =
  ## Serve Streamable HTTP until signalled. Blocking.
  let loop = newLoop()
  let server = newHttpServer(loop)
  server.maxBodySize = config.maxBodySize
  server.handler = proc(req: HttpRequest, res: HttpResponse) {.gcsafe.} =
    srv.handleHttp(req, res, config)

  installSignalShutdown(loop)

  stderrLog("datcontext: Streamable HTTP on http://" & address & ":" &
            $port & McpEndpoint)
  server.listen(address, port)
  loop.run()
  server.close()
  loop.close()

proc httpServer*(srv: McpServer; loop: Loop; port: int;
                 address = "127.0.0.1";
                 config = defaultHttpConfig()): HttpServer =
  ## Build and start an HTTP server on an existing loop, without blocking.
  ##
  ## The caller drives `loop.run()`. Used by the tests to host a server on a
  ## client's loop so both run in one thread.
  result = newHttpServer(loop)
  result.maxBodySize = config.maxBodySize
  result.handler = proc(req: HttpRequest, res: HttpResponse) {.gcsafe.} =
    srv.handleHttp(req, res, config)
  result.listen(address, port)