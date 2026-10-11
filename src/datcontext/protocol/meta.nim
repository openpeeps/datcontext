# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## `_meta` access for the `io.modelcontextprotocol/*` reserved keys.
##
## On modern revisions every request MUST carry `protocolVersion` and
## `clientCapabilities` in `_meta`; a request missing either is malformed and is
## rejected with `-32602`. On Streamable HTTP these are mirrored into the
## `MCP-Protocol-Version` header, with the body remaining the source of truth.

import openparser/json
import ./errors
import ./version

const
  MetaProtocolVersion* = "io.modelcontextprotocol/protocolVersion"
  MetaClientInfo* = "io.modelcontextprotocol/clientInfo"
  MetaClientCapabilities* = "io.modelcontextprotocol/clientCapabilities"
  MetaServerInfo* = "io.modelcontextprotocol/serverInfo"
  MetaLogLevel* = "io.modelcontextprotocol/logLevel"
  MetaSubscriptionId* = "io.modelcontextprotocol/subscriptionId"
  MetaProgressToken* = "progressToken"
  MetaTraceParent* = "traceparent"
  MetaTraceState* = "tracestate"
  MetaBaggage* = "baggage"

proc metaOf*(params: JsonNode): JsonNode =
  ## The `_meta` object of `params`, or nil when absent.
  if params.isNil or params.kind != JObject:
    return nil
  let m = params{"_meta"}
  if m.isNil or m.kind != JObject:
    return nil
  m

proc metaStr*(params: JsonNode; key: string; default = ""): string =
  ## Read a string field out of `params._meta`.
  let m = metaOf(params)
  if m.isNil: return default
  let v = m{key}
  if v.isNil or v.kind != JString: return default
  v.getStr

proc ensureMeta(params: var JsonNode): JsonNode =
  ## Guarantee `params` is an object carrying an object-valued `_meta`, creating
  ## either as needed, and return the `_meta` object.
  if params.isNil or params.kind != JObject:
    params = newJObject()
  let existing = params{"_meta"}
  if existing.isNil or existing.kind != JObject:
    params["_meta"] = newJObject()
  params["_meta"]

proc setMeta*(params: var JsonNode; key, value: string) =
  ## Set a string field in `params._meta`, creating `_meta` if needed.
  let m = ensureMeta(params)
  m[key] = newJString(value)

proc setMetaNode*(params: var JsonNode; key: string; value: JsonNode) =
  ## Set an arbitrary JSON field in `params._meta`.
  let m = ensureMeta(params)
  m[key] = value

proc declaredVersion*(params: JsonNode): string =
  ## The protocol version this request declares, or `""` when it declares none.
  metaStr(params, MetaProtocolVersion)

proc isModernRequest*(params: JsonNode): bool =
  ## True when the request carries modern per-request metadata.
  let v = declaredVersion(params)
  v.len > 0 and isModern(v)

proc clientInfo*(params: JsonNode): JsonNode =
  ## The declared client `Implementation`, or nil.
  let m = metaOf(params)
  if m.isNil: return nil
  let i = m{MetaClientInfo}
  if i.isNil or i.kind != JObject: return nil
  i

proc clientCapabilities*(params: JsonNode): JsonNode =
  ## The declared client capabilities, or nil.
  let m = metaOf(params)
  if m.isNil: return nil
  let c = m{MetaClientCapabilities}
  if c.isNil or c.kind != JObject: return nil
  c

proc hasCapability*(params: JsonNode; capability: string): bool =
  ## True when the request's declared client capabilities include `capability`.
  let c = clientCapabilities(params)
  if c.isNil: return false
  c.hasKey(capability)

proc requireClientCapability*(params: JsonNode; capability: string) =
  ## Assert the client declared `capability`, else raise
  ## `MissingRequiredClientCapabilityError`.
  if not hasCapability(params, capability):
    raise newMcpError(
      ecMissingRequiredClientCapability,
      "Missing required client capability: " & capability,
      missingCapabilityData([capability]))

proc validateModern*(params: JsonNode) =
  ## Enforce the required modern `_meta` fields. A request missing either is
  ## malformed and MUST be rejected with `-32602`.
  if params.isNil or params.kind != JObject:
    raise newMcpError(ecInvalidParams, "params must be an object")
  let v = declaredVersion(params)
  # Presence is checked before version support: a request missing the field is
  # malformed (-32602), while a request carrying an unknown version gets the
  # version error (-32022) so the client can reselect.
  if v.len == 0:
    raise newMcpError(ecInvalidParams,
      "_meta." & MetaProtocolVersion & " is required")
  if not isSupported(v):
    raise newMcpError(
      ecUnsupportedProtocolVersion,
      "Unsupported protocol version",
      versionUnsupportedData(v, SupportedVersions))
  if clientCapabilities(params).isNil:
    raise newMcpError(ecInvalidParams,
      "_meta." & MetaClientCapabilities & " is required")

proc idToString*(id: JsonNode): string =
  ## Render a JSON-RPC id as the plain string used for correlation.
  ##
  ## `$` on a `JsonNode` renders JSON, so a string id would come back quoted
  ## (`"abc"`), which would then mismatch every client-side comparison. The id
  ## is a plain value here, not embedded JSON.
  if id.isNil:
    return ""
  case id.kind
  of JString: id.getStr
  of JInt, JFloat: $id.getInt
  else: ""

proc serverInfoMeta*(info: JsonNode): JsonNode =
  ## Build the per-response `_meta` object carrying server identity.
  result = newJObject()
  result[MetaServerInfo] = info

proc makeImplementation*(name, version: string): JsonNode =
  ## Build an `Implementation` object.
  result = newJObject()
  result["name"] = newJString(name)
  result["version"] = newJString(version)

proc modernParams*(protocolVersion, clientName, clientVersion: string;
                   capabilities: JsonNode = nil): JsonNode =
  ## Build a modern `params` object pre-populated with the required `_meta`
  ## fields. Used by the client on every outgoing request.
  result = newJObject()
  setMeta(result, MetaProtocolVersion, protocolVersion)
  setMetaNode(result, MetaClientInfo, makeImplementation(clientName, clientVersion))
  if capabilities.isNil:
    setMetaNode(result, MetaClientCapabilities, newJObject())
  else:
    setMetaNode(result, MetaClientCapabilities, capabilities)