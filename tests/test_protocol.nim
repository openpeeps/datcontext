import unittest, strutils
import openparser/json
import ../src/datcontext/protocol/[errors, framing, meta, types, version]

suite "framing":
  test "single line in one chunk":
    var fb = initFrameBuffer()
    let lines = fb.feed("{\"a\":1}\n")
    check lines == @["{\"a\":1}"]
    check fb.buffered == 0

  test "unterminated line is buffered until its newline arrives":
    var fb = initFrameBuffer()
    check fb.feed("{\"a\":1}").len == 0
    check fb.buffered == 7

  test "line split across chunks":
    var fb = initFrameBuffer()
    discard fb.feed("""{"a":""")
    check fb.feed("""1}""").len == 0
    check fb.buffered == 7
    let lines = fb.feed("\n")
    check lines == @["{\"a\":1}"]
    check fb.buffered == 0

  test "multiple lines in one chunk":
    var fb = initFrameBuffer()
    let lines = fb.feed("{\"a\":1}\n{\"b\":2}\n")
    check lines.len == 2
    check lines[0] == "{\"a\":1}"
    check lines[1] == "{\"b\":2}"

  test "crlf line endings":
    var fb = initFrameBuffer()
    check fb.feed("{\"a\":1}\r\n") == @["{\"a\":1}"]

  test "blank lines skipped":
    var fb = initFrameBuffer()
    check fb.feed("\n\n{\"a\":1}\n\n").len == 1

  test "partial trailing line retained":
    var fb = initFrameBuffer()
    discard fb.feed("{\"a\":1}\n{\"b\":")
    check fb.buffered == 5
    check fb.feed("2}\n") == @["{\"b\":2}"]

  test "byte chunks work":
    var fb = initFrameBuffer()
    let chunk = "{\"a\":1}\n"
    check chunk.len == 8
    check fb.feed(chunk.toOpenArrayByte(0, 7)) == @["{\"a\":1}"]

  test "overflow is latched and bounded":
    var fb = initFrameBuffer(maxLineLen = 32)
    expect McpError:
      discard fb.feed("x".repeat(64))
    check fb.overflowed
    # Further input is refused rather than growing the buffer.
    expect McpError:
      discard fb.feed("y")
    check fb.buffered == 0
    fb.reset()
    check not fb.overflowed
    check fb.feed("{\"a\":1}\n") == @["{\"a\":1}"]

  test "encodeLine never emits a raw newline":
    let n = newJObject()
    n["text"] = newJString("line one\nline two")
    let line = encodeLine(n)
    check line.find('\n') < 0
    check parseJson(line)["text"].getStr == "line one\nline two"

suite "types":
  test "classify request":
    let n = parseJson("""{"jsonrpc":"2.0","id":1,"method":"x"}""")
    check classify(n) == mkRequest

  test "classify notification":
    let n = parseJson("""{"jsonrpc":"2.0","method":"x"}""")
    check classify(n) == mkNotification

  test "classify response":
    let n = parseJson("""{"jsonrpc":"2.0","id":1,"result":{}}""")
    check classify(n) == mkResponse

  test "batch arrays rejected":
    expect McpError:
      discard parseMessage(parseJson("""[{"jsonrpc":"2.0"}]"""))

  test "wrong jsonrpc version rejected":
    expect McpError:
      discard parseMessage(parseJson("""{"jsonrpc":"1.0","id":1,"method":"x"}"""))

  test "null id rejected on request":
    expect McpError:
      discard parseMessage(parseJson("""{"jsonrpc":"2.0","id":null,"method":"x"}"""))

  test "id must be string or int":
    check isValidId(newJInt(1))
    check isValidId(newJString("a"))
    check not isValidId(newJBool(true))
    check not isValidId(newJObject())
    check not isValidId(newJNull())
    check not isValidId(JsonNode(kind: JNull))

  test "success response round trip":
    let r = newSuccessResponse(newJInt(7), newJObject())
    let line = $responseToJson(r)
    let back = parseMessage(parseJson(line))
    check classify(back) == mkResponse
    check decodeResponse(back).id.getInt == 7

  test "error response omits null id":
    let r = newErrorResponseObj(nil, ecInvalidParams, "bad")
    check not r.raw.hasKey("id")
    check r.raw["error"]["code"].getInt == -32602

  test "content blocks serialize":
    check contentToJson(textContent("hi")) == %*{"type": "text", "text": "hi"}
    check contentToJson(imageContent("AAA", "image/png"))["mimeType"].getStr == "image/png"
    let rl = contentToJson(resourceLinkContent("file:///a", "a.txt", mimeType = "text/plain"))
    check rl["type"].getStr == "resource_link"
    check rl["uri"].getStr == "file:///a"

suite "errors":
  test "error code values match the spec":
    check codeOf(ecParseError) == -32700
    check codeOf(ecInvalidRequest) == -32600
    check codeOf(ecMethodNotFound) == -32601
    check codeOf(ecInvalidParams) == -32602
    check codeOf(ecInternalError) == -32603
    check codeOf(ecHeaderMismatch) == -32020
    check codeOf(ecMissingRequiredClientCapability) == -32021
    check codeOf(ecUnsupportedProtocolVersion) == -32022

  test "reserved range is respected":
    # -32002 and -32042 must never be emitted by this protocol version.
    let allCodes = [ecParseError, ecInvalidRequest, ecMethodNotFound,
                    ecInvalidParams, ecInternalError, ecHeaderMismatch,
                    ecMissingRequiredClientCapability,
                    ecUnsupportedProtocolVersion]
    for c in allCodes:
      check codeOf(c) != -32002
      check codeOf(c) != -32042
      # -32000..-32019 is legacy and must be avoided for new codes.
      check not (codeOf(c) >= -32019 and codeOf(c) <= -32000)

  test "version error data shape":
    let e = newErrorResponse(nil, ecUnsupportedProtocolVersion, "x",
      versionUnsupportedData("1900-01-01", SupportedVersions))
    check e["error"]["code"].getInt == -32022
    check e["error"]["data"]["requested"].getStr == "1900-01-01"
    check e["error"]["data"]["supported"].len == SupportedVersions.len

  test "http status for invalid params is 400":
    check defaultHttpStatus(ecInvalidParams) == 400
    check defaultHttpStatus(ecHeaderMismatch) == 400

suite "version":
  test "modern and legacy classification":
    check isModern(ProtocolVersion)
    check not isLegacy(ProtocolVersion)
    check isLegacy("2025-06-18")
    check not isModern("2025-06-18")

  test "negotiate exact match":
    check negotiate("2025-06-18") == "2025-06-18"
    check negotiate(ProtocolVersion) == ProtocolVersion

  test "empty defaults to current":
    check negotiate("") == ProtocolVersion

  test "unsupported raises with supported list":
    try:
      discard negotiate("1900-01-01")
      check false
    except McpError as e:
      check e.code == ecUnsupportedProtocolVersion
      check e.data["supported"].len == SupportedVersions.len

  test "era mapping":
    check eraFor(ProtocolVersion) == eraModern
    check eraFor("2024-11-05") == eraLegacy

suite "meta":
  test "modern params carry required fields":
    let p = modernParams(ProtocolVersion, "test-client", "1.0.0")
    check declaredVersion(p) == ProtocolVersion
    check clientCapabilities(p) != nil
    check clientInfo(p)["name"].getStr == "test-client"
    validateModern(p)  # must not raise

  test "missing protocolVersion is invalid params":
    var p = newJObject()
    setMetaNode(p, MetaClientCapabilities, newJObject())
    try:
      validateModern(p)
      check false
    except McpError as e:
      check e.code == ecInvalidParams

  test "missing capabilities is invalid params":
    var p = newJObject()
    setMeta(p, MetaProtocolVersion, ProtocolVersion)
    try:
      validateModern(p)
      check false
    except McpError as e:
      check e.code == ecInvalidParams

  test "unsupported declared version raises version error":
    var p = newJObject()
    setMeta(p, MetaProtocolVersion, "1900-01-01")
    setMetaNode(p, MetaClientCapabilities, newJObject())
    try:
      validateModern(p)
      check false
    except McpError as e:
      check e.code == ecUnsupportedProtocolVersion

  test "capability check and enforcement":
    let p = modernParams(ProtocolVersion, "c", "1.0",
      %*{"elicitation": {}})
    check hasCapability(p, "elicitation")
    check not hasCapability(p, "roots")
    requireClientCapability(p, "elicitation")
    try:
      requireClientCapability(p, "roots")
      check false
    except McpError as e:
      check e.code == ecMissingRequiredClientCapability
      check e.data["requiredCapabilities"][0].getStr == "roots"

  test "setMeta creates the _meta object":
    var p = newJObject()
    setMeta(p, MetaProtocolVersion, ProtocolVersion)
    check declaredVersion(p) == ProtocolVersion

  test "otel keys round trip":
    var p = newJObject()
    setMeta(p, MetaTraceParent, "00-abc-def-01")
    check metaStr(p, MetaTraceParent) == "00-abc-def-01"

  test "serverInfo meta object":
    let m = serverInfoMeta(makeImplementation("srv", "2.0"))
    check m[MetaServerInfo]["name"].getStr == "srv"