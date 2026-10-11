import unittest, strutils
import powpow
import openparser/json
import ../src/datcontext/protocol/[errors, meta, types, version]
import ../src/datcontext/server/core
import ../src/datcontext/tools/tool
import std/httpcore
import ../src/datcontext/client/[core, http]
import ../src/datcontext/server/sse

suite "client era detection":
  test "a modern server is detected and stays modern":
    let srv = newMcpServer()
    # A transport that answers with the real server, in-process.
    let c = newClient(ClientTransport(
      kind: "inproc",
      send: proc(msg: JsonNode): JsonNode = srv.handleMessage(msg)))
    check c.probe() == "modern"
    check c.protocolVersion == ProtocolVersion
    check c.serverInfo["name"].getStr == "datcontext"
    # Era is cached, not re-probed per request.
    check c.probe() == "modern"

  test "a legacy server falls back to initialize":
    let srv = newMcpServer()
    let c = newClient(ClientTransport(
      kind: "inproc",
      send: proc(msg: JsonNode): JsonNode =
        # Reject server/discover the way a legacy server would: with an
        # implementation-defined error, not a modern one.
        if msg{"method"}.getStr == "server/discover":
          newErrorResponse(msg{"id"}, ecMethodNotFound, "Unknown method")
        else:
          srv.handleMessage(msg)))
    check c.probe() == "legacy"
    discard c.initialize()
    check c.initialized
    check c.protocolVersion == LegacyVersions[0]

  test "an unsupported-version error means modern, not legacy":
    let c = newClient(ClientTransport(
      kind: "inproc",
      send: proc(msg: JsonNode): JsonNode =
        # A modern server that does not speak our revision.
        newErrorResponse(msg{"id"}, ecUnsupportedProtocolVersion,
          "Unsupported protocol version",
          versionUnsupportedData("2099-01-01", ["2025-06-18"]))))
    # Must NOT fall back to initialize.
    check c.probe() == "modern"
    check c.protocolVersion == "2025-06-18"

  test "a non-modern error means legacy":
    let c = newClient(ClientTransport(
      kind: "inproc",
      send: proc(msg: JsonNode): JsonNode =
        newErrorResponse(msg{"id"}, ecInvalidParams, "bad request")))
    check c.probe() == "legacy"

  test "a timeout means legacy":
    let c = newClient(ClientTransport(
      kind: "inproc",
      send: proc(msg: JsonNode): JsonNode = nil))
    check c.probe() == "legacy"

suite "client requests over a modern server":
  test "tools/list works after probing":
    let srv = newMcpServer(withOpenParserTools = true)
    let c = newClient(ClientTransport(
      kind: "inproc",
      send: proc(msg: JsonNode): JsonNode = srv.handleMessage(msg)))
    c.connect()
    let tools = c.listTools()["result"]["tools"]
    check tools.len > 0
    # Every modern request must carry the required _meta.
    check tools.len == len(srv.registry.names())

  test "tools/call round trips through a real server":
    let srv = newMcpServer(withOpenParserTools = true)
    let c = newClient(ClientTransport(
      kind: "inproc",
      send: proc(msg: JsonNode): JsonNode = srv.handleMessage(msg)))
    c.connect()
    let r = c.callTool("parse_yaml", %*{"source": "a: 1"})["result"]
    # `isError` is omitted on success, not set to false.
    check not r.hasKey("isError")
    check r["content"][0]["text"].getStr.contains("a:")

  test "a legacy client can still list tools":
    let srv = newMcpServer(withOpenParserTools = true)
    let c = newClient(ClientTransport(
      kind: "inproc",
      send: proc(msg: JsonNode): JsonNode =
        if msg{"method"}.getStr == "server/discover":
          newErrorResponse(msg{"id"}, ecMethodNotFound, "Unknown method")
        else:
          srv.handleMessage(msg)))
    c.connect()
    check c.era == "legacy"
    check c.listTools()["result"]["tools"].len > 0

  test "an unknown tool surfaces as invalid params":
    let srv = newMcpServer()
    let c = newClient(ClientTransport(
      kind: "inproc",
      send: proc(msg: JsonNode): JsonNode = srv.handleMessage(msg)))
    c.connect()
    try:
      discard c.callTool("nope")
      check false
    except McpError as e:
      check e.code == ecInvalidParams

suite "sse parsing":
  test "extracts the data payload":
    let body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1}\n\n"
    let msg = parseSse(body)
    check msg["id"].getInt == 1

  test "handles multi-line data":
    let body = "event: x\ndata: {\"a\":\ndata: 1}\n\n"
    let msg = parseSse(body)
    check msg["a"].getInt == 1

  test "no data field yields nil":
    check parseSse("event: ping\n\n").isNil

suite "http url parsing":
  test "host and port are extracted":
    let t = newHttpTransport("http://127.0.0.1:9000")
    check t.host == "127.0.0.1"
    check t.port == 9000
    check not t.tls
    check t.endpoint == "/mcp"

  test "https defaults to 443":
    let t = newHttpTransport("https://example.com")
    check t.tls
    check t.port == 443

  test "http defaults to 80":
    let t = newHttpTransport("http://example.com")
    check t.port == 80

  test "a bare path defaults to /mcp":
    check newHttpTransport("http://h:1/").endpoint == "/mcp"
    check newHttpTransport("http://h:1/mcp").endpoint == "/mcp"

  test "a missing scheme is treated as http":
    let t = newHttpTransport("127.0.0.1:9000")
    check not t.tls
    check t.host == "127.0.0.1"

suite "sse framing":
  test "a frame carries event and data lines":
    let f = sseFrame("message", "{}")
    check f.contains("event: message")
    check f.contains("data: {}")
    check f.endsWith("\n\n")

  test "multi-line data is split across fields":
    let f = sseFrame("x", "a\nb")
    check f.contains("data: a")
    check f.contains("data: b")

  test "chunked framing wraps and terminates":
    let c = chunk("hello")
    check c.startsWith("5\r\n") or c.startsWith("0005\r\n")
    check c.endsWith("\r\n")
    check lastChunk().startsWith("0\r\n")

  test "the response head declares chunked encoding":
    let h = headFor(Http200, [("Content-Type", "text/event-stream")])
    check h.startsWith("HTTP/1.1 200")
    check h.contains("Transfer-Encoding: chunked")
    check h.contains("Content-Type: text/event-stream")
    check h.endsWith("\r\n\r\n")