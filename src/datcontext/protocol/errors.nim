# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## JSON-RPC 2.0 and MCP error codes.
##
## MCP partitions the JSON-RPC server-error range: `-32000` to `-32019` is
## legacy implementation-defined territory and `-32020` to `-32099` is reserved
## for the specification. This module defines only the reserved codes the
## specification actually assigns, plus the standard JSON-RPC set.
##
## Note: `-32002` (resource not found) and `-32042` (URL elicitation) MUST NOT
## be emitted by an implementation of this protocol version.

import openparser/json

type
  ErrorCode* = enum
    ## Standard JSON-RPC 2.0 codes.
    ecParseError = -32700
    ecInvalidRequest = -32600
    ecMethodNotFound = -32601
    ecInvalidParams = -32602
    ecInternalError = -32603

    ## Codes defined by the MCP specification.
    ecHeaderMismatch = -32020
    ecMissingRequiredClientCapability = -32021
    ecUnsupportedProtocolVersion = -32022

proc codeOf*(code: ErrorCode): int {.inline.} =
  ## The wire integer for `code`.
  case code
  of ecParseError: -32700
  of ecInvalidRequest: -32600
  of ecMethodNotFound: -32601
  of ecInvalidParams: -32602
  of ecInternalError: -32603
  of ecHeaderMismatch: -32020
  of ecMissingRequiredClientCapability: -32021
  of ecUnsupportedProtocolVersion: -32022

type
  McpError* = object of CatchableError
    ## Raised internally to signal a protocol-level failure carrying a specific
    ## code and optional `data` payload. Transport layers catch this and turn it
    ## into a JSON-RPC error response.
    code*: ErrorCode
    data*: JsonNode
    id*: JsonNode
    httpStatus*: int
    ## HTTP status to use when surfaced over Streamable HTTP. `0` means the
    ## transport picks the default for the code.

proc newMcpError*(code: ErrorCode; message: string; data: JsonNode = nil;
                  id: JsonNode = nil; httpStatus: int = 0): ref McpError =
  ## Construct an `McpError`.
  result = newException(McpError, message)
  result.code = code
  result.data = data
  result.id = id
  result.httpStatus = httpStatus

template raiseMcp*(code: ErrorCode, message: string,
                   data: JsonNode = nil, id: JsonNode = nil,
                   httpStatus: int = 0) =
  ## Raise an `McpError` with the given code.
  raise newMcpError(code, message, data, id, httpStatus)

proc newError*(code: ErrorCode; message: string; data: JsonNode = nil): JsonNode =
  ## Build a standalone JSON-RPC `error` object.
  result = newJObject()
  result["code"] = newJInt(codeOf(code))
  result["message"] = newJString(message)
  if not data.isNil:
    result["data"] = data

proc newErrorResponse*(id: JsonNode; code: ErrorCode; message: string;
                      data: JsonNode = nil): JsonNode =
  ## Build a complete JSON-RPC error response.
  ##
  ## `id` is echoed verbatim. JSON-RPC permits an absent `id` when the id could
  ## not be parsed from a malformed request.
  result = newJObject()
  result["jsonrpc"] = newJString("2.0")
  if not id.isNil and id.kind != JNull:
    result["id"] = id
  result["error"] = newError(code, message, data)

proc defaultHttpStatus*(code: ErrorCode): int =
  ## The HTTP status Streamable HTTP must use for a given code.
  ##
  ## The specification pins `400 Bad Request` to invalid params, header
  ## mismatch, and missing capability.
  case code
  of ecInvalidParams, ecHeaderMismatch, ecMissingRequiredClientCapability: 400
  of ecInvalidRequest: 400
  of ecParseError: 400
  of ecMethodNotFound: 404
  of ecInternalError: 500
  of ecUnsupportedProtocolVersion: 400

proc versionUnsupportedData*(requested: string;
                             supported: openArray[string]): JsonNode =
  ## `data` payload for `UnsupportedProtocolVersionError`. MUST list the
  ## versions the server does support so the client can select one and retry.
  result = newJObject()
  var arr = newJArray()
  for v in supported:
    arr.add(newJString(v))
  result["supported"] = arr
  result["requested"] = newJString(requested)

proc missingCapabilityData*(missing: openArray[string]): JsonNode =
  ## `data` payload for `MissingRequiredClientCapabilityError`.
  result = newJObject()
  var arr = newJArray()
  for c in missing:
    arr.add(newJString(c))
  result["requiredCapabilities"] = arr

proc headerMismatchData*(expected, actual: string): JsonNode =
  ## `data` payload for `HeaderMismatchError`, raised when a Streamable HTTP
  ## request's header and body metadata disagree. The body is the source of
  ## truth.
  result = newJObject()
  result["expected"] = newJString(expected)
  result["actual"] = newJString(actual)