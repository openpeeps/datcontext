# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## JSON-RPC 2.0 message shapes and MCP content types.
##
## Messages are represented as `JsonNode` throughout rather than as Nim types:
## the wire format is JSON, `openparser/json` is already the package's pivot
## type, and keeping one representation avoids a lossy translation layer. These
## procs are the constructors and accessors that give the raw JSON structure.

import std/locks
import openparser/json
import ./errors

type
  MessageKind* = enum
    ## The three JSON-RPC 2.0 message shapes.
    mkRequest, mkNotification, mkResponse

  Request* = ref object
    ## A JSON-RPC request. `id` MUST be a string or integer and MUST NOT be null.
    id*: JsonNode
    methodName*: string
    params*: JsonNode
    raw*: JsonNode

  Notification* = ref object
    ## A JSON-RPC notification. Carries no `id`; the receiver MUST NOT respond.
    methodName*: string
    params*: JsonNode
    raw*: JsonNode

  Response* = ref object
    ## A JSON-RPC response, carrying exactly one of `result` or `error`.
    id*: JsonNode
    result*: JsonNode
    error*: JsonNode
    raw*: JsonNode

  Content* = ref object
    ## One tool result content block.
    kind*: string       ## text, image, audio, resource_link, resource
    text*: string
    data*: string       ## base64 payload for image/audio
    mimeType*: string
    uri*: string
    name*: string
    description*: string
    resource*: JsonNode ## embedded resource body
    annotations*: JsonNode

const
  ContentText* = "text"
  ContentImage* = "image"
  ContentAudio* = "audio"
  ContentResourceLink* = "resource_link"
  ContentResource* = "resource"

proc textContent*(text: string): Content =
  ## A text content block.
  Content(kind: ContentText, text: text)

proc imageContent*(base64Data, mimeType: string): Content =
  ## An image content block.
  Content(kind: ContentImage, data: base64Data, mimeType: mimeType)

proc audioContent*(base64Data, mimeType: string): Content =
  ## An audio content block.
  Content(kind: ContentAudio, data: base64Data, mimeType: mimeType)

proc resourceLinkContent*(uri, name: string; description = "";
                          mimeType = ""): Content =
  ## A resource link block.
  Content(kind: ContentResourceLink, uri: uri, name: name,
          description: description, mimeType: mimeType)

proc embeddedResourceContent*(uri, text: string; mimeType: string = ""): Content =
  ## An embedded resource block.
  Content(kind: ContentResource, uri: uri, text: text, mimeType: mimeType,
          resource: if mimeType.len > 0:
                       (block:
                         var r = newJObject()
                         r["uri"] = newJString(uri)
                         r["mimeType"] = newJString(mimeType)
                         r["text"] = newJString(text)
                         r)
                     else: nil)

proc contentToJson*(c: Content): JsonNode =
  ## Render a content block.
  result = newJObject()
  result["type"] = newJString(c.kind)
  case c.kind
  of ContentText: result["text"] = newJString(c.text)
  of ContentImage, ContentAudio:
    result["data"] = newJString(c.data)
    if c.mimeType.len > 0: result["mimeType"] = newJString(c.mimeType)
  of ContentResourceLink:
    result["uri"] = newJString(c.uri)
    result["name"] = newJString(c.name)
    if c.description.len > 0: result["description"] = newJString(c.description)
    if c.mimeType.len > 0: result["mimeType"] = newJString(c.mimeType)
  of ContentResource:
    var r = c.resource
    if r.isNil:
      r = newJObject()
      r["uri"] = newJString(c.uri)
      r["text"] = newJString(c.text)
      if c.mimeType.len > 0: r["mimeType"] = newJString(c.mimeType)
    result["resource"] = r
  else: discard
  if not c.annotations.isNil:
    result["annotations"] = c.annotations

proc contentArray*(blocks: seq[Content]): JsonNode =
  ## Render a content array.
  result = newJArray()
  for b in blocks:
    result.add(contentToJson(b))

var requestCounter: uint64 = 0
  ## Monotonic request-id source. Guarded so ids stay unique under
  ## `--threads:on` when a thread pool is in play.

when defined(datcontextNoLock):
  proc nextRequestId*(): uint64 {.inline.} =
    ## Next request id. Integer ids are valid JSON-RPC and cheap to correlate.
    inc requestCounter
    requestCounter
else:
  var requestCounterLock: Lock
  initLock(requestCounterLock)
  proc nextRequestId*(): uint64 =
    ## Next request id. Integer ids are valid JSON-RPC and cheap to correlate.
    result = requestCounter
    withLock requestCounterLock:
      inc requestCounter
      result = requestCounter

proc newId*(): JsonNode =
  ## A fresh request id.
  newJInt(int64(nextRequestId()))

proc newRequest*(methodName: string; id: JsonNode = nil;
                 params: JsonNode = nil): Request =
  ## Build a request message object.
  result = Request(
    id: if id.isNil: newId() else: id,
    methodName: methodName,
    params: params,
    raw: newJObject()
  )
  result.raw["jsonrpc"] = newJString("2.0")
  result.raw["id"] = result.id
  result.raw["method"] = newJString(methodName)
  if not params.isNil:
    result.raw["params"] = params

proc newNotification*(methodName: string; params: JsonNode = nil): Notification =
  ## Build a notification message object (no `id`).
  result = Notification(methodName: methodName, params: params, raw: newJObject())
  result.raw["jsonrpc"] = newJString("2.0")
  result.raw["method"] = newJString(methodName)
  if not params.isNil:
    result.raw["params"] = params

proc newSuccessResponse*(id: JsonNode; payload: JsonNode): Response =
  ## Build a success response.
  result = Response(id: id, result: payload, raw: newJObject())
  result.raw["jsonrpc"] = newJString("2.0")
  result.raw["id"] = id
  result.raw["result"] = payload

proc newErrorResponseObj*(id: JsonNode; code: ErrorCode; message: string;
                          data: JsonNode = nil): Response =
  ## Build an error response.
  result = Response(id: id, error: newError(code, message, data),
                    raw: newJObject())
  result.raw["jsonrpc"] = newJString("2.0")
  if not id.isNil and id.kind != JNull:
    result.raw["id"] = id
  result.raw["error"] = result.error

proc requestToJson*(r: Request): JsonNode {.inline.} = r.raw
proc notificationToJson*(n: Notification): JsonNode {.inline.} = n.raw
proc responseToJson*(r: Response): JsonNode {.inline.} = r.raw

proc classify*(node: JsonNode): MessageKind =
  ## Classify a decoded JSON-RPC message by shape.
  if node.isNil or node.kind != JObject:
    raise newMcpError(ecInvalidRequest, "message must be a JSON object")
  let idN = node{"id"}
  let hasId = not idN.isNil and idN.kind != JNull
  if hasId:
    # A message with both `method` and `result`/`error` is malformed.
    if node.hasKey("method"): mkRequest
    elif node.hasKey("result") or node.hasKey("error"): mkResponse
    else:
      raise newMcpError(ecInvalidRequest,
        "message has an id but neither method nor result/error")
  elif node.hasKey("method"):
    mkNotification
  else:
    raise newMcpError(ecInvalidRequest,
      "message is neither a request, notification, nor response")

proc isValidId*(id: JsonNode; kind: JsonNodeKind): bool =
  ## Request ids MUST be a string or integer and MUST NOT be null.
  ##
  ## The `kind` is passed separately because an absent `id` reads back as
  ## `JNull` from `JsonNode` access, which must also be rejected.
  discard id
  kind == JString or kind == JInt or kind == JFloat

proc isValidId*(id: JsonNode): bool =
  ## Convenience overload: a nil node is always invalid.
  if id.isNil: return false
  isValidId(id, id.kind)

proc parseMessage*(node: JsonNode): JsonNode =
  ## Validate the top-level envelope and return it unchanged.
  ##
  ## Rejects a non-object payload, a missing or non-`"2.0"` `jsonrpc` field, and
  ## (for requests and responses) an invalid `id`. Batch arrays were removed
  ## from the protocol and are not accepted.
  if node.isNil or node.kind != JObject:
    raise newMcpError(ecInvalidRequest, "message must be a JSON object")
  let v = node{"jsonrpc"}
  if v.isNil or v.kind != JString or v.getStr != "2.0":
    raise newMcpError(ecInvalidRequest, "jsonrpc field must be \"2.0\"")
  # An explicitly null `id` is malformed even though a bare notification has no
  # `id` at all: the spec requires ids to be a string or integer, never null.
  if node.hasKey("id") and node{"id"}.kind == JNull:
    raise newMcpError(ecInvalidRequest, "id must not be null")
  let kind = classify(node)
  if kind in {mkRequest, mkResponse}:
    let idN = node{"id"}
    if not isValidId(idN):
      raise newMcpError(ecInvalidRequest,
        "id must be a string or integer")
  node

proc decodeRequest*(node: JsonNode): Request =
  ## Decode a validated message as a request.
  result = Request(
    id: node{"id"},
    methodName: node{"method"}.getStr,
    params: node{"params"},
    raw: node
  )

proc decodeNotification*(node: JsonNode): Notification =
  ## Decode a validated message as a notification.
  result = Notification(
    methodName: node{"method"}.getStr,
    params: node{"params"},
    raw: node
  )

proc decodeResponse*(node: JsonNode): Response =
  ## Decode a validated message as a response.
  result = Response(
    id: node{"id"},
    result: node{"result"},
    error: node{"error"},
    raw: node
  )