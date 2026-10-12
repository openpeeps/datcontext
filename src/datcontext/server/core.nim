# datcontext — generic MCP building blocks over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## The MCP server core.
##
## `McpServer` is transport-agnostic: it turns a decoded JSON-RPC message into a
## reply message, with no socket or loop involved. Every transport is then a thin
## adapter that moves bytes and calls `handleMessage`.
##
## ## Dual-era behaviour
##
## MCP is dual-era. A modern request carries its version and capabilities in
## `_meta` and is served statelessly. A legacy client instead opens with
## `initialize` and expects a connection-scoped session. This server answers
## both: the era is decided per request from its own metadata, never from prior
## traffic, so no state accumulates between requests. The only per-connection
## state is the legacy negotiated version, which legacy semantics require and
## modern semantics explicitly forbid relying on.

import std/locks
import openparser/json
import ../prompts
import ../protocol/[errors, framing, meta, types, version]
import ../resources
import ../subscriptions
import ../tools/tool

const
  ServerName* = "datcontext"
  ServerVersion* = "0.1.0"
  ServerInstructions* = "MCP server with tools, resources, prompts and " &
    "subscriptions over stdio, HTTP, Unix socket and TCP. Register your " &
    "own tools, resources and prompts on top of the empty registries."

type
  McpServer* = ref object
    ## A protocol server. Thread-safe for concurrent `handleMessage` calls.
    name*: string
    version*: string
    instructions*: string
    registry*: ToolRegistry
    ## The tool registry, for adding server-specific tools.
    resources*: ResourceRegistry
    ## The resource registry, for adding server-specific resources.
    prompts*: PromptRegistry
    ## The prompt registry.
    subs*: SubscriptionManager
    ## Active `subscriptions/listen` streams.
    fileRoot*: string
    ## Root directory for `file://` resources; empty disables them.
    logLevel*: string

    eraLock: Lock
    ## Guards the legacy session fields below.
    legacyVersion*: string
    ## The version negotiated by `initialize`, scoped to the connection. Empty
    ## until a legacy client initializes.
    initialized*: bool
    ## True once a legacy client has sent `notifications/initialized`.

proc newMcpServer*(name = ServerName; version = ServerVersion;
                   instructions = ServerInstructions;
                   fileRoot = ""): McpServer =
  ## A bare MCP server with empty tool, resource and prompt registries.
  ##
  ## Higher-level apps register their own tools, resources and prompts on top.
  ## Pass `fileRoot` to enable `file://` resources rooted at that directory.
  ## Leave it empty to disable filesystem resources entirely, which is the
  ## right default for a server a model drives.
  result = McpServer(
    name: name,
    version: version,
    instructions: instructions,
    registry: newRegistry(),
    resources: buildResourceRegistry(fileRoot),
    prompts: buildPromptRegistry(),
    subs: newSubscriptionManager(),
    fileRoot: fileRoot,
    logLevel: "info"
  )
  initLock(result.eraLock)

proc registry*(srv: McpServer): ToolRegistry =
  ## The tool registry, for adding server-specific tools.
  srv.registry

proc resources*(srv: McpServer): ResourceRegistry =
  ## The resource registry, for adding server-specific resources.
  srv.resources

proc prompts*(srv: McpServer): PromptRegistry =
  ## The prompt registry, for adding server-specific prompts.
  srv.prompts

proc subscriptions*(srv: McpServer): SubscriptionManager =
  ## The subscription manager.
  srv.subs

proc serverCapabilities*(srv: McpServer): JsonNode =
  ## The `ServerCapabilities` this server advertises.
  ##
  ## Only capabilities that are actually implemented are declared. `listChanged`
  ## and `subscribe` are false because the tool, prompt, and resource sets are
  ## fixed for the server's lifetime: nothing changes them at runtime, so there
  ## is never a list-changed notification to send.
  result = newJObject()
  result["tools"] = %*{"listChanged": false}
  result["resources"] = %*{"listChanged": false, "subscribe": false}
  result["prompts"] = %*{"listChanged": false}

proc serverInfo*(srv: McpServer): JsonNode =
  ## The `Implementation` reported as `serverInfo`.
  makeImplementation(srv.name, srv.version)

proc resultEnvelope*(srv: McpServer; payload: JsonNode): JsonNode =
  ## Wrap a result payload with the fields the spec requires on every response.
  ##
  ## Every result MUST carry `resultType`; clients treat an absent one as
  ## `"complete"` for backwards compatibility, but emitting it keeps behaviour
  ## unambiguous. Results SHOULD also carry `_meta` with server identity so a
  ## client can identify the server without prior connection state.
  result = newJObject()
  result["resultType"] = newJString("complete")
  for k, v in payload:
    result[k] = v
  result["_meta"] = serverInfoMeta(srv.serverInfo)

proc newSuccess*(srv: McpServer; id: JsonNode; payload: JsonNode): JsonNode =
  ## A success response for `id`.
  newSuccessResponse(id, srv.resultEnvelope(payload)).raw

proc newFailure*(srv: McpServer; id: JsonNode; code: ErrorCode;
                 message: string; data: JsonNode = nil): JsonNode =
  ## An error response for `id`.
  newErrorResponse(id, code, message, data)

proc toErrorResponse*(srv: McpServer; id: JsonNode; e: ref McpError): JsonNode =
  ## Convert a caught `McpError` into a JSON-RPC error response.
  newErrorResponse(if e.id.isNil: id else: e.id, e.code, e.msg, e.data)

proc httpStatusFor*(srv: McpServer; node: JsonNode): int =
  ## The HTTP status a Streamable HTTP response carrying `node` should use.
  if node.isNil or node.kind != JObject:
    return 500
  let err = node{"error"}
  if err.isNil:
    return 200
  let codeNode = err{"code"}
  if codeNode.isNil or codeNode.kind != JInt:
    return 500
  case codeNode.getInt
  of -32602, -32600, -32020, -32021, -32022, -32700: 400
  of -32601: 404
  of -32603: 500
  else: 500

# ── Method handlers ──────────────────────────────────────────────────────────

proc handleDiscover*(srv: McpServer; id: JsonNode): JsonNode =
  ## `server/discover`. Servers MUST implement this.
  ##
  ## Advertises supported protocol versions, capabilities, and identity in one
  ## request, and doubles as the stdio probe a dual-era client uses to detect a
  ## modern server.
  var payload = newJObject()
  var versions = newJArray()
  for v in SupportedVersions:
    versions.add(newJString(v))
  payload["supportedVersions"] = versions
  payload["capabilities"] = srv.serverCapabilities()
  payload["instructions"] = newJString(srv.instructions)
  payload["ttlMs"] = newJInt(3_600_000)
  payload["cacheScope"] = newJString("public")
  # serverInfo travels in _meta per the spec, already added by resultEnvelope.
  srv.newSuccess(id, payload)

proc handleListTools*(srv: McpServer; id: JsonNode; params: JsonNode): JsonNode =
  ## `tools/list`.
  ##
  ## The tool set is fixed for the server's lifetime and does not vary
  ## per-connection, as the specification requires.
  var payload = newJObject()
  payload["tools"] = srv.registry.listJson()
  srv.newSuccess(id, payload)

proc handleCallTool*(srv: McpServer; id: JsonNode; params: JsonNode): JsonNode =
  ## `tools/call`.
  ##
  ## Distinguishes the two error mechanisms: an unknown tool name or a malformed
  ## request is a protocol error, while a handler failure becomes a tool
  ## execution error with `isError: true` so the model can self-correct.
  if params.isNil or params.kind != JObject:
    return srv.newFailure(id, ecInvalidParams, "params must be an object")
  let nameNode = params{"name"}
  if nameNode.isNil or nameNode.kind != JString:
    return srv.newFailure(id, ecInvalidParams, "missing required parameter: name")
  let name = nameNode.getStr
  let args = params{"arguments"}

  if not srv.registry.has(name):
    return srv.newFailure(id, ecInvalidParams, "Unknown tool: " & name)

  try:
    let res = srv.registry.call(name, args)
    var payload = newJObject()
    payload["content"] = contentArray(res.content)
    if not res.structuredContent.isNil:
      payload["structuredContent"] = res.structuredContent
    if res.isError:
      payload["isError"] = newJBool(true)
    srv.newSuccess(id, payload)
  except McpError as e:
    # A handler rejecting its arguments is model-recoverable, so surface it as a
    # tool execution error rather than failing the whole request.
    var payload = newJObject()
    payload["content"] = contentArray(@[textContent(e.msg)])
    payload["isError"] = newJBool(true)
    if not e.data.isNil:
      payload["structuredContent"] = e.data
    srv.newSuccess(id, payload)
  except CatchableError as e:
    # A handler raising for bad input is model-recoverable; the
    # specification wants the model to see these so it can correct itself.
    var payload = newJObject()
    payload["content"] = contentArray(@[textContent(e.msg)])
    payload["isError"] = newJBool(true)
    srv.newSuccess(id, payload)

proc handleInitialize*(srv: McpServer; id: JsonNode; params: JsonNode): JsonNode =
  ## `initialize`, for legacy clients only.
  ##
  ## Modern clients never send this; they probe with `server/discover` and then
  ## send requests carrying `_meta`. Legacy clients send `initialize` and expect
  ## an `InitializeResult` with no `resultType`, which is why this path builds
  ## its response directly rather than through `resultEnvelope`.
  if params.isNil or params.kind != JObject:
    return srv.newFailure(id, ecInvalidParams, "params must be an object")
  let requested = params{"protocolVersion"}
  var requestedVersion = ""
  if not requested.isNil and requested.kind == JString:
    requestedVersion = requested.getStr

  var served = ""
  try:
    served = negotiate(requestedVersion)
  except McpError as e:
    # A modern-only server must reject `initialize` and name its versions,
    # since legacy clients have no fall-forward mechanism. We are dual-era, so
    # this only fires for a version outside the supported range entirely.
    return srv.toErrorResponse(id, e)

  withLock srv.eraLock:
    srv.legacyVersion = served
    srv.initialized = false

  var result = newJObject()
  result["protocolVersion"] = newJString(served)
  result["capabilities"] = srv.serverCapabilities()
  result["serverInfo"] = srv.serverInfo()
  if srv.instructions.len > 0:
    result["instructions"] = newJString(srv.instructions)
  # Legacy InitializeResult carries no resultType; an unrecognized one would be
  # rejected by a strict legacy client.
  newSuccessResponse(id, result).raw

proc handleInitialized*(srv: McpServer) =
  ## `notifications/initialized`, legacy only.
  withLock srv.eraLock:
    srv.initialized = true

proc handlePing*(srv: McpServer; id: JsonNode): JsonNode =
  ## `ping`. An empty successful result.
  var payload = newJObject()
  srv.newSuccess(id, payload)

proc handleCancelled*(srv: McpServer; id: JsonNode; params: JsonNode) =
  ## `notifications/cancelled`.
  ##
  ## Cancellation is a notification, so nothing is replied. MCP is stateless and
  ## this server answers tool calls synchronously on the event loop, so there is
  ## no in-flight work to abandon; the notification is accepted for
  ## interoperability and ignored.

proc handleListResources*(srv: McpServer; id: JsonNode): JsonNode =
  ## `resources/list`.
  var payload = newJObject()
  payload["resources"] = srv.resources.listJson()
  srv.newSuccess(id, payload)

proc handleListResourceTemplates*(srv: McpServer; id: JsonNode): JsonNode =
  ## `resources/templates/list`.
  var payload = newJObject()
  payload["resourceTemplates"] = srv.resources.templatesJson()
  srv.newSuccess(id, payload)

proc handleReadResource*(srv: McpServer; id: JsonNode; params: JsonNode): JsonNode =
  ## `resources/read`.
  ##
  ## A missing resource is `-32602`, never an empty `contents` array: the spec
  ## forbids that, since an empty array cannot distinguish "no content" from
  ## "does not exist".
  if params.isNil or params.kind != JObject:
    return srv.newFailure(id, ecInvalidParams, "params must be an object")
  let uriNode = params{"uri"}
  if uriNode.isNil or uriNode.kind != JString:
    return srv.newFailure(id, ecInvalidParams, "missing required parameter: uri")
  let uri = uriNode.getStr
  let contents = srv.resources.read(uri)
  var payload = newJObject()
  payload["contents"] = contentsJson(contents)
  srv.newSuccess(id, payload)

proc handleListPrompts*(srv: McpServer; id: JsonNode): JsonNode =
  ## `prompts/list`.
  var payload = newJObject()
  payload["prompts"] = srv.prompts.listJson()
  srv.newSuccess(id, payload)

proc handleGetPrompt*(srv: McpServer; id: JsonNode; params: JsonNode): JsonNode =
  ## `prompts/get`.
  if params.isNil or params.kind != JObject:
    return srv.newFailure(id, ecInvalidParams, "params must be an object")
  let nameNode = params{"name"}
  if nameNode.isNil or nameNode.kind != JString:
    return srv.newFailure(id, ecInvalidParams, "missing required parameter: name")
  let name = nameNode.getStr
  if not srv.prompts.has(name):
    return srv.newFailure(id, ecInvalidParams, "Unknown prompt: " & name)

  let args = params{"arguments"}
  srv.prompts.validateArgs(name, args)
  let entry = srv.prompts.find(name)
  let resolved = entry.resolve(args)
  var payload = resolved.resultJson()
  srv.newSuccess(id, payload)


proc handleUnknown*(srv: McpServer; id: JsonNode; methodName: string): JsonNode =
  ## An unrecognized method. `-32601` is the correct code.
  srv.newFailure(id, ecMethodNotFound, "Unknown method: " & methodName)

# ── Dispatch ─────────────────────────────────────────────────────────────────

proc currentLegacyVersion*(srv: McpServer): string =
  ## The version negotiated for a legacy connection, defaulting to the newest
  ## legacy revision when the connection has not initialized.
  withLock srv.eraLock:
    if srv.legacyVersion.len > 0:
      return srv.legacyVersion
  if LegacyVersions.len > 0:
    LegacyVersions[0]
  else:
    ProtocolVersion

type
  DispatchResult* = ref object
    ## What dispatch produced: an ordinary reply, a subscription stream, or
    ## nothing at all for a notification.
    ##
    ## `subscriptions/listen` cannot be expressed as a single JSON-RPC response:
    ## the response to that request *is* a long-lived stream of notifications.
    ## Transports read `stream` to learn they must open a channel and wire
    ## `emit` into it.
    reply*: JsonNode
    ## The JSON-RPC response, or nil when there is none.
    stream*: Subscription
    ## Set when the request opened a notification stream.
    ack*: JsonNode
    ## The acknowledgment notification, which the transport MUST send before any
    ## notification on the stream.

proc handleSubscribe*(srv: McpServer; id: JsonNode; params: JsonNode): DispatchResult =
  ## `subscriptions/listen`.
  ##
  ## Returns a `DispatchResult` with `ack` set and no `reply`: the request has no
  ## immediate response because its response is the stream itself. The transport
  ## sends the acknowledgment, then registers the subscription with an `emit`
  ## that writes to the open channel.
  let filter = parseFilter(params)
  if filter.isEmpty:
    # Nothing to listen for is not an error, but there is no stream worth
    # opening; acknowledge the empty filter so the client can tell.
    raise newMcpError(ecInvalidParams,
      "subscriptions/listen requires at least one notification type")
  let subId = idToString(id)
  # Registered with a nil sink: the transport sets `emit` only after it has sent
  # the acknowledgment, which is what guarantees no notification precedes it.
  DispatchResult(ack: acknowledged(subId, filter),
                 stream: srv.subs.register(subId, filter, nil))


proc validateRequest*(srv: McpServer; params: JsonNode): string =
  ## Validate a request's protocol metadata and return the version to serve.
  ##
  ## The era is decided by the request's own `_meta`, never by the method name,
  ## since methods like `tools/call` exist in both eras:
  ##
  ## * No `_meta` at all: a legacy request, served under the connection's
  ##   negotiated revision (or the newest legacy revision if unnegotiated).
  ## * `_meta` carrying none of the modern protocol keys: still legacy. A legacy
  ##   client may legitimately send `progressToken` or an OpenTelemetry key.
  ## * `_meta` carrying some but not all modern keys: malformed. A modern
  ##   request MUST carry both `protocolVersion` and `clientCapabilities`, so a
  ##   partial set is a client bug and MUST be rejected with `-32602`.
  ## * Complete `_meta`: a modern request, validated against the supported set.
  let m = metaOf(params)
  if m.isNil:
    return srv.currentLegacyVersion()
  let hasVersion = m.hasKey(MetaProtocolVersion)
  let hasCaps = m.hasKey(MetaClientCapabilities)
  if not hasVersion and not hasCaps:
    return srv.currentLegacyVersion()
  validateModern(params)
  declaredVersion(params)

proc dispatch*(srv: McpServer; msg: JsonNode): DispatchResult =
  ## Dispatch one decoded message.
  ##
  ## Never raises: every failure becomes a JSON-RPC error response. Transports use
  ## this; `handleMessage` is the convenience form for transports that only ever
  ## produce ordinary replies.
  if msg.isNil or msg.kind != JObject:
    return DispatchResult(
      reply: newErrorResponse(nil, ecInvalidRequest,
                              "message must be a JSON object"))

  var id = newJNull()
  let idNode = msg{"id"}
  if not idNode.isNil:
    id = idNode

  var kind: MessageKind
  try:
    discard parseMessage(msg)
    kind = classify(msg)
  except McpError as e:
    return DispatchResult(
      reply: newErrorResponse(if id.kind == JNull: nil else: id,
                              e.code, e.msg, e.data))

  if kind == mkResponse:
    # Servers do not initiate requests, so a response is a client protocol error
    # on every transport.
    return DispatchResult(
      reply: newErrorResponse(id, ecInvalidRequest,
        "clients must not send JSON-RPC responses to a server"))

  let methodName = msg{"method"}.getStr
  let params = msg{"params"}
  # Notifications carry no id and MUST NOT be answered.
  let isNotification = kind == mkNotification

  template reply(r: JsonNode): DispatchResult =
    ## Yield an ordinary reply.
    DispatchResult(reply: r)

  template fail(code: ErrorCode, message: string, data: JsonNode = nil) =
    ## Yield a protocol error, unless this was a notification.
    if not isNotification:
      result.reply = srv.newFailure(id, code, message, data)
      return
    result = DispatchResult()

  try:
    # Notification-only methods, handled before validation: they legitimately
    # carry no modern `_meta`.
    if methodName == "notifications/initialized":
      srv.handleInitialized()
      return DispatchResult()
    if methodName == "notifications/cancelled":
      srv.handleCancelled(id, params)
      return DispatchResult()

    if methodName == "initialize":
      if isNotification: return DispatchResult()
      return reply(srv.handleInitialize(id, params))

    # Every other method must declare a supported protocol version.
    discard srv.validateRequest(params)

    case methodName
    of "server/discover":
      if isNotification: return DispatchResult()
      return reply(srv.handleDiscover(id))
    of "tools/list":
      if isNotification: return DispatchResult()
      return reply(srv.handleListTools(id, params))
    of "tools/call":
      if isNotification: return DispatchResult()
      return reply(srv.handleCallTool(id, params))
    of "resources/list":
      if isNotification: return DispatchResult()
      return reply(srv.handleListResources(id))
    of "resources/templates/list":
      if isNotification: return DispatchResult()
      return reply(srv.handleListResourceTemplates(id))
    of "resources/read":
      if isNotification: return DispatchResult()
      return reply(srv.handleReadResource(id, params))
    of "prompts/list":
      if isNotification: return DispatchResult()
      return reply(srv.handleListPrompts(id))
    of "prompts/get":
      if isNotification: return DispatchResult()
      return reply(srv.handleGetPrompt(id, params))
    of "subscriptions/listen":
      if isNotification: return DispatchResult()
      return srv.handleSubscribe(id, params)
    of "ping":
      if isNotification: return DispatchResult()
      return reply(srv.handlePing(id))
    of "logging/setLevel":
      # Deprecated in favour of the per-request `_meta` log level, but still
      # accepted for legacy clients.
      if isNotification: return DispatchResult()
      let level = params{"level"}
      if not level.isNil and level.kind == JString:
        srv.logLevel = level.getStr
      return reply(srv.handlePing(id))
    of "completion/complete", "resources/subscribe", "resources/unsubscribe":
      # Declared capabilities do not cover these, and the pre-2026 subscribe
      # RPCs were replaced by subscriptions/listen.
      if isNotification: return DispatchResult()
      return reply(srv.handleUnknown(id, methodName))
    else:
      if isNotification: return DispatchResult()
      return reply(srv.handleUnknown(id, methodName))
  except McpError as e:
    if isNotification:
      return DispatchResult()
    return DispatchResult(reply: srv.toErrorResponse(id, e))
  except CatchableError as e:
    if isNotification:
      return DispatchResult()
    return DispatchResult(reply: srv.newFailure(id, ecInternalError, e.msg))

proc handleMessage*(srv: McpServer; msg: JsonNode): JsonNode =
  ## Dispatch one message and return its reply, or nil when none is due.
  ##
  ## Convenient for transports and tests that never open a subscription; a
  ## `subscriptions/listen` request would need `dispatch` to obtain the stream.
  srv.dispatch(msg).reply

proc handleLine*(srv: McpServer; line: string): string =
  ## Decode and dispatch one NDJSON line, returning the NDJSON reply or an empty
  ## string when no reply is due.
  ##
  ## Parse failures become `-32700` rather than exceptions, so a malformed line
  ## never takes down the connection.
  var msg: JsonNode
  try:
    msg = parseJson(line)
  except CatchableError as e:
    return $newErrorResponse(nil, ecParseError, "Parse error: " & e.msg)
  let d = srv.dispatch(msg)
  if d.reply.isNil:
    ""
  else:
    encodeLine(d.reply)

proc notifyToolsChanged*(srv: McpServer) =
  ## Emit `notifications/tools/list_changed` to every subscriber that asked.
  srv.subs.broadcast("notifications/tools/list_changed")

proc notifyPromptsChanged*(srv: McpServer) =
  ## Emit `notifications/prompts/list_changed` to every subscriber that asked.
  srv.subs.broadcast("notifications/prompts/list_changed")

proc notifyResourcesChanged*(srv: McpServer) =
  ## Emit `notifications/resources/list_changed` to every subscriber that asked.
  srv.subs.broadcast("notifications/resources/list_changed")

proc notifyResourceUpdated*(srv: McpServer; uri: string) =
  ## Emit `notifications/resources/updated` to subscribers watching `uri`.
  srv.subs.broadcastResourceUpdated(uri)
