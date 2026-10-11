# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Transport-agnostic MCP client.
##
## ## Era detection
##
## A client that speaks both eras must probe with `server/discover` before any
## other request, because era-ambiguous methods such as `tools/call` exist in
## both and a legacy server would otherwise process one under the wrong
## semantics. The rules, per the spec's stdio backward-compatibility section:
##
## * A `DiscoverResult` means the server is modern; select a version from
##   `supportedVersions`.
## * A recognized modern error such as `UnsupportedProtocolVersionError` means
##   the server is modern but rejected our version; retry with one it lists. Do
##   NOT fall back to `initialize`.
## * Any other error, or a timeout, means the server is legacy: fall back to
##   `initialize`.
##
## The fallback MUST NOT be keyed to a single error code, since legacy servers
## answer unknown pre-initialize requests with implementation-defined errors.
##
## Era is a property of the server process or origin, not of a request, so it is
## determined once and cached here.

import std/locks
import openparser/json
import ../protocol/[errors, meta, types, version]

type
  ClientTransport* = ref object
    ## How a client reaches a server.
    ##
    ## Implementations send one request and deliver the reply, or deliver nil to
    ## signal "no response" (as for a notification). Errors are raised as
    ## `McpError`; a nil `reply` with no error is a legitimate "nothing to say".
    kind*: string
    send*: proc(msg: JsonNode): JsonNode {.closure.}

  McpClient* = ref object
    ## An MCP client.
    transport*: ClientTransport
    name*: string
    version*: string
    protocolVersion*: string
    ## The version in use after negotiation.
    capabilities*: JsonNode
    era*: string
    ## `"modern"` or `"legacy"`.
    serverInfo*: JsonNode
    instructions*: string
    probed*: bool
    ## Whether `server/discover` has already been attempted.
    initialized*: bool
    ## Whether the legacy `initialize` handshake completed.
    nextId*: int
    probeTimeoutMs*: int
    lock: Lock

proc newClient*(transport: ClientTransport; name = "datcontext-client";
                version = "0.1.0"): McpClient =
  ## A client bound to `transport`.
  result = McpClient(
    transport: transport,
    name: name,
    version: version,
    protocolVersion: ProtocolVersion,
    capabilities: newJObject(),
    era: "",
    probeTimeoutMs: 5000
  )
  initLock(result.lock)

proc nextId*(c: McpClient): int =
  ## Allocate a request id.
  withLock c.lock:
    result = c.nextId
    inc c.nextId

proc modernParams*(c: McpClient; extra: JsonNode = nil): JsonNode =
  ## Build `params` carrying this client's required modern `_meta`, plus any
  ## method-specific fields merged in.
  result = modernParams(c.protocolVersion, c.name, c.version, c.capabilities)
  if not extra.isNil:
    for k, v in extra:
      result[k] = v

proc legacyParams*(c: McpClient; extra: JsonNode = nil): JsonNode =
  ## Build `params` for a legacy handshake, where version and capabilities are
  ## explicit fields rather than `_meta`.
  result = newJObject()
  result["protocolVersion"] = newJString(c.protocolVersion)
  result["capabilities"] = c.capabilities
  result["clientInfo"] = makeImplementation(c.name, c.version)
  if not extra.isNil:
    for k, v in extra:
      result[k] = v

proc send*(c: McpClient; msg: JsonNode): JsonNode =
  ## Hand `msg` to the transport and return its reply.
  result = c.transport.send(msg)

proc requestRaw*(c: McpClient; methodName: string; params: JsonNode): JsonNode =
  ## Issue one request and return the decoded reply.
  ##
  ## Raises `McpError` on transport failure or a malformed reply.
  var msg = newJObject()
  msg["jsonrpc"] = newJString("2.0")
  msg["id"] = newJInt(c.nextId())
  msg["method"] = newJString(methodName)
  if not params.isNil:
    msg["params"] = params

  let reply = c.send(msg)
  if reply.isNil:
    raise newMcpError(ecInternalError,
      "no reply to " & methodName & " over " & c.transport.kind)
  let err = reply{"error"}
  if not err.isNil and err.kind == JObject:
    let codeNode = err{"code"}
    let code = if codeNode.isNil or codeNode.kind != JInt: -32603
               else: codeNode.getInt.int
    let msgText = if err{"message"}.isNil: "unknown error"
                  else: err{"message"}.getStr
    var data: JsonNode
    if err.hasKey("data"):
      data = err{"data"}
    let mapped = case code
      of -32700: ecParseError
      of -32600: ecInvalidRequest
      of -32601: ecMethodNotFound
      of -32602: ecInvalidParams
      of -32020: ecHeaderMismatch
      of -32021: ecMissingRequiredClientCapability
      of -32022: ecUnsupportedProtocolVersion
      else: ecInternalError
    raise newMcpError(mapped, msgText, data)
  reply

proc notify*(c: McpClient; methodName: string; params: JsonNode = nil) =
  ## Send a notification. No reply is expected.
  var msg = newJObject()
  msg["jsonrpc"] = newJString("2.0")
  msg["method"] = newJString(methodName)
  if not params.isNil:
    msg["params"] = params
  discard c.send(msg)

proc isModernError*(reply: JsonNode): bool =
  ## True when `reply` carries an error the modern spec defines.
  ##
  ## Used to decide between "retry with a different version" and "fall back to
  ## the legacy handshake".
  let err = reply{"error"}
  if err.isNil or err.kind != JObject:
    return false
  let code = err{"code"}
  if code.isNil or code.kind != JInt:
    return false
  case code.getInt
  of -32020, -32021, -32022: true
  else: false

proc adoptVersion*(c: McpClient; versions: JsonNode) =
  ## Choose a mutually supported version from a `supportedVersions` list.
  ##
  ## Prefers our own preference, then the newest the server offers, so a client
  ## that is ahead of the server still ends up speaking a revision both
  ## understand.
  if versions.isNil or versions.kind != JArray or versions.len == 0:
    c.protocolVersion = ProtocolVersion
    return
  var offered: seq[string]
  for v in versions:
    if v.kind == JString:
      offered.add(v.getStr)
  if c.protocolVersion in offered:
    return
  if offered.len > 0:
    c.protocolVersion = offered[0]

proc probe*(c: McpClient): string =
  ## Determine the server's era and protocol version.
  ##
  ## Returns `"modern"` or `"legacy"`. The result is cached: era is a property of
  ## the server process or origin, not of an individual request.
  if c.probed:
    return c.era

  try:
    let reply = c.requestRaw("server/discover",
                             c.modernParams())
    c.era = "modern"
    let result = reply{"result"}
    if not result.isNil:
      c.adoptVersion(result{"supportedVersions"})
      let meta = result{"_meta"}
      if not meta.isNil:
        let si = meta{MetaServerInfo}
        if not si.isNil:
          c.serverInfo = si
      let instr = result{"instructions"}
      if not instr.isNil and instr.kind == JString:
        c.instructions = instr.getStr
      let caps = result{"capabilities"}
      if not caps.isNil and caps.kind == JObject:
        # Record what the server offers; the client does not gain anything by
        # asserting them, but callers need them for `listCapabilities`.
        discard caps
  except McpError as e:
    if e.code == ecUnsupportedProtocolVersion and not e.data.isNil:
      # A modern server that rejected our version: retry with one it supports
      # and do NOT fall back to initialize.
      c.era = "modern"
      var supported: seq[string]
      if e.data{"supported"}.kind == JArray:
        for v in e.data{"supported"}:
          if v.kind == JString:
            supported.add(v.getStr)
      c.adoptVersion(newJArray())
      if supported.len > 0:
        c.protocolVersion = supported[0]
      try:
        let reply = c.requestRaw("server/discover", c.modernParams())
        let result = reply{"result"}
        if not result.isNil:
          c.adoptVersion(result{"supportedVersions"})
      except McpError:
        discard
    else:
      # Any other error, or a timeout, means the server is legacy.
      c.era = "legacy"
  except CatchableError:
    c.era = "legacy"

  c.probed = true
  c.era

proc initialize*(c: McpClient): JsonNode =
  ## Run the legacy handshake. Only meaningful for a legacy server.
  ##
  ## A legacy server never saw our modern default, so the handshake has to
  ## advertise a revision it actually understands. Offering `2026-07-28` here
  ## would have a stateless server answer as if it were a legacy one, which is
  ## exactly the era ambiguity the probe exists to avoid.
  if isModern(c.protocolVersion):
    c.protocolVersion = if LegacyVersions.len > 0: LegacyVersions[0]
                        else: ProtocolVersion
  let reply = c.requestRaw("initialize", c.legacyParams())
  let result = reply{"result"}
  if not result.isNil:
    let pv = result{"protocolVersion"}
    if not pv.isNil and pv.kind == JString:
      c.protocolVersion = pv.getStr
    let si = result{"serverInfo"}
    if not si.isNil:
      c.serverInfo = si
    let instr = result{"instructions"}
    if not instr.isNil and instr.kind == JString:
      c.instructions = instr.getStr
  c.notify("notifications/initialized")
  c.initialized = true
  result

proc connect*(c: McpClient) =
  ## Probe, then handshake if the server turns out to be legacy.
  if c.probe() == "modern":
    return
  discard c.initialize()

proc modernRequest*(c: McpClient; methodName: string;
                   extra: JsonNode = nil): JsonNode =
  ## Issue a request as a modern client, including the required `_meta`.
  ##
  ## On `UnsupportedProtocolVersionError`, retry once with a version the server
  ## advertises rather than surfacing the failure.
  # Copy rather than mutate `extra`: a nil `_meta` merged over the modern one
  # would leave a nil node in the tree, which `$` then dereferences.
  let extraM = newJObject()
  if not extra.isNil:
    for k, v in extra:
      if k != "_meta":
        extraM[k] = v
  try:
    return c.requestRaw(methodName, c.modernParams(extraM))
  except McpError as e:
    if e.code != ecUnsupportedProtocolVersion or e.data.isNil:
      raise
    if e.data{"supported"}.kind != JArray:
      raise
    var supported: seq[string]
    for v in e.data{"supported"}:
      if v.kind == JString:
        supported.add(v.getStr)
    if supported.len == 0:
      raise
    c.protocolVersion = supported[0]
    c.requestRaw(methodName, c.modernParams(extraM))

proc listTools*(c: McpClient): JsonNode =
  ## `tools/list`. Probes and handshakes first if needed.
  if not c.probed:
    c.connect()
  if c.era == "modern":
    return c.modernRequest("tools/list")
  return c.requestRaw("tools/list", nil)

proc callTool*(c: McpClient; name: string;
               args: JsonNode = nil): JsonNode =
  ## `tools/call`. Probes and handshakes first if needed.
  if not c.probed:
    c.connect()
  var extra = newJObject()
  extra["name"] = newJString(name)
  extra["arguments"] = if args.isNil: newJObject() else: args
  if c.era == "modern":
    return c.modernRequest("tools/call", extra)
  c.requestRaw("tools/call", extra)

proc ping*(c: McpClient): JsonNode =
  ## `ping`.
  if c.era == "modern":
    return c.modernRequest("ping")
  c.requestRaw("ping", nil)