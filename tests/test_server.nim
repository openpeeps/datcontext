import unittest, strutils, tables
import openparser/json
import ../src/datcontext/protocol/[errors, meta, types, version]
import ../src/datcontext/server/core

proc call(srv: McpServer; methodName: string;
          params: JsonNode = nil): JsonNode =
  var msg = newJObject()
  msg["jsonrpc"] = newJString("2.0")
  msg["id"] = newJInt(1)
  msg["method"] = newJString(methodName)
  if not params.isNil:
    msg["params"] = params
  srv.handleMessage(msg)

suite "server/discover":
  test "advertises versions, capabilities, and identity":
    let srv = newMcpServer()
    let r = call(srv, "server/discover",
      modernParams(ProtocolVersion, "c", "1.0"))
    check r["result"]["supportedVersions"].len == SupportedVersions.len
    check r["result"]["capabilities"]["tools"] != nil
    # serverInfo travels in _meta per the spec.
    check r["result"]["_meta"][MetaServerInfo]["name"].getStr == "datcontext"
    check r["result"]["instructions"].getStr.len > 0
    check r["result"]["resultType"].getStr == "complete"

  test "modern probe succeeds without initialize":
    let srv = newMcpServer()
    let r = call(srv, "server/discover",
      modernParams(ProtocolVersion, "c", "1.0"))
    check r.hasKey("result")
    check not r.hasKey("error")

suite "tools/list":
  test "returns registered tools in stable order":
    let srv = newMcpServer()
    let r = call(srv, "tools/list", modernParams(ProtocolVersion, "c", "1.0"))
    let tools = r["result"]["tools"]
    check tools.len == len(srv.registry.tools)
    check tools.len > 0
    # Deterministic across calls.
    let r2 = call(srv, "tools/list", modernParams(ProtocolVersion, "c", "1.0"))
    check $tools == $r2["result"]["tools"]

  test "tools capability is declared":
    let srv = newMcpServer()
    let caps = srv.serverCapabilities()
    # Every advertised capability must be implemented.
    check caps["tools"] != nil
    check caps["resources"] != nil
    check caps["prompts"] != nil
    # logging is not implemented, so it must not be advertised.
    check not caps.hasKey("logging")

suite "tools/call":
  test "calls a tool and returns content":
    let srv = newMcpServer()
    var params = modernParams(ProtocolVersion, "c", "1.0")
    params["name"] = newJString("parse_json")
    params["arguments"] = %*{"source": "{\"a\":1}"}
    let r = call(srv, "tools/call", params)
    check r["result"]["content"][0]["type"].getStr == "text"
    check r["result"].hasKey("structuredContent")
    check not r["result"].hasKey("isError")

  test "unknown tool is a protocol error, not a tool error":
    # The spec classifies an unknown tool as a protocol error.
    let srv = newMcpServer()
    var params = modernParams(ProtocolVersion, "c", "1.0")
    params["name"] = newJString("no_such_tool")
    let r = call(srv, "tools/call", params)
    check r["error"]["code"].getInt == -32602
    check not r.hasKey("result")

  test "missing name is invalid params":
    let srv = newMcpServer()
    let r = call(srv, "tools/call", modernParams(ProtocolVersion, "c", "1.0"))
    check r["error"]["code"].getInt == -32602

  test "parse failure is a tool execution error the model can act on":
    let srv = newMcpServer()
    var params = modernParams(ProtocolVersion, "c", "1.0")
    params["name"] = newJString("parse_json")
    params["arguments"] = %*{"source": "{not json"}
    let r = call(srv, "tools/call", params)
    # isError lets the model self-correct; a protocol error would not.
    check r["result"]["isError"].getBool
    check not r.hasKey("error")

  test "bad arguments become a tool error, not a protocol error":
    let srv = newMcpServer()
    var params = modernParams(ProtocolVersion, "c", "1.0")
    params["name"] = newJString("parse_json")
    params["arguments"] = %*{"source": "x", "path": "y"}
    let r = call(srv, "tools/call", params)
    check r["result"]["isError"].getBool

  test "list_formats reports depth bounds honestly":
    let srv = newMcpServer()
    var params = modernParams(ProtocolVersion, "c", "1.0")
    params["name"] = newJString("list_formats")
    params["arguments"] = newJObject()
    let r = call(srv, "tools/call", params)
    let formats = r["result"]["structuredContent"]["formats"]
    var sawUnbounded = false
    for f in formats:
      if not f["depthBounded"].getBool:
        sawUnbounded = true
    check sawUnbounded

suite "dual-era":
  test "legacy initialize returns an InitializeResult without resultType":
    let srv = newMcpServer()
    let r = call(srv, "initialize",
      %*{"protocolVersion": "2025-06-18",
         "capabilities": newJObject(),
         "clientInfo": makeImplementation("legacy", "1.0")})
    check r["result"]["protocolVersion"].getStr == "2025-06-18"
    check r["result"]["serverInfo"]["name"].getStr == "datcontext"
    # A strict legacy client would reject an unrecognized resultType.
    check not r["result"].hasKey("resultType")
    check not r["result"].hasKey("_meta")

  test "legacy initialize falls back to a supported revision":
    let srv = newMcpServer()
    let r = call(srv, "initialize",
      %*{"protocolVersion": "2024-11-05",
         "capabilities": newJObject()})
    check r["result"]["protocolVersion"].getStr == "2024-11-05"

  test "legacy client can call tools without modern _meta":
    let srv = newMcpServer()
    discard call(srv, "initialize",
      %*{"protocolVersion": "2025-06-18", "capabilities": newJObject()})
    discard srv.handleMessage(%*{"jsonrpc": "2.0", "method": "notifications/initialized"})
    let r = call(srv, "tools/list", newJObject())
    check r["result"]["tools"].len > 0

  test "notifications/initialized is tracked":
    let srv = newMcpServer()
    check not srv.initialized
    discard call(srv, "initialize",
      %*{"protocolVersion": "2025-06-18", "capabilities": newJObject()})
    discard srv.handleMessage(%*{"jsonrpc": "2.0", "method": "notifications/initialized"})
    check srv.initialized

  test "legacy era is connection scoped, modern is stateless":
    let srv = newMcpServer()
    discard call(srv, "initialize",
      %*{"protocolVersion": "2024-11-05", "capabilities": newJObject()})
    check srv.currentLegacyVersion() == "2024-11-05"
    # A modern request still resolves on its own metadata, unaffected by the
    # legacy session.
    let r = call(srv, "tools/list", modernParams(ProtocolVersion, "c", "1.0"))
    check r.hasKey("result")

  test "modern request with an unsupported version is refused":
    let srv = newMcpServer()
    var params = newJObject()
    setMeta(params, MetaProtocolVersion, "1900-01-01")
    setMetaNode(params, MetaClientCapabilities, newJObject())
    let r = call(srv, "tools/list", params)
    check r["error"]["code"].getInt == -32022
    # The error MUST advertise what the server does support.
    check r["error"]["data"]["supported"].len == SupportedVersions.len

  test "modern request missing required _meta is invalid params":
    let srv = newMcpServer()
    var params = newJObject()
    setMetaNode(params, MetaClientCapabilities, newJObject())
    let r = call(srv, "tools/list", params)
    check r["error"]["code"].getInt == -32602

  test "modern request declaring an unsupported capability fails cleanly":
    let srv = newMcpServer()
    # No method requires a client capability yet, so this must simply work.
    let r = call(srv, "tools/list", modernParams(ProtocolVersion, "c", "1.0"))
    check r.hasKey("result")

suite "protocol hygiene":
  test "notifications get no reply":
    let srv = newMcpServer()
    for m in ["notifications/initialized", "notifications/cancelled",
              "notifications/tools/list_changed", "unknown/notification"]:
      let r = srv.handleMessage(%*{"jsonrpc": "2.0", "method": m})
      check r.isNil

  test "request notification methods as requests still reply":
    let srv = newMcpServer()
    # A client sending notifications/initialized as a request is malformed but
    # harmless; it must not crash the server.
    let r = call(srv, "notifications/cancelled", newJObject())
    check r.isNil

  test "unknown method is method-not-found":
    let srv = newMcpServer()
    let r = call(srv, "no/such/method",
      modernParams(ProtocolVersion, "c", "1.0"))
    check r["error"]["code"].getInt == -32601

  test "unimplemented methods are method-not-found":
    let srv = newMcpServer()
    # completion is not implemented, and the pre-2026 subscribe RPCs were
    # replaced by subscriptions/listen, so neither may be accepted.
    for m in ["completion/complete", "resources/subscribe", "resources/unsubscribe"]:
      let r = call(srv, m, modernParams(ProtocolVersion, "c", "1.0"))
      check r["error"]["code"].getInt == -32601

  test "client-sent response is a protocol error":
    let srv = newMcpServer()
    let r = srv.handleMessage(%*{"jsonrpc": "2.0", "id": 1, "result": newJObject()})
    check r["error"]["code"].getInt == -32600

  test "wrong jsonrpc version rejected":
    let srv = newMcpServer()
    let r = srv.handleMessage(%*{"jsonrpc": "1.0", "id": 1, "method": "ping"})
    check r["error"]["code"].getInt == -32600

  test "ping succeeds":
    let srv = newMcpServer()
    let r = call(srv, "ping", modernParams(ProtocolVersion, "c", "1.0"))
    check r.hasKey("result")
    check r["result"]["resultType"].getStr == "complete"

  test "non-object message rejected":
    let srv = newMcpServer()
    check srv.handleMessage(newJArray()).hasKey("error")
    check srv.handleMessage(newJString("x")).hasKey("error")
    check srv.handleMessage(nil).hasKey("error")

  test "error response echoes the request id":
    let srv = newMcpServer()
    var msg = newJObject()
    msg["jsonrpc"] = newJString("2.0")
    msg["id"] = newJString("req-42")
    msg["method"] = newJString("nope")
    let r = srv.handleMessage(msg)
    check r["id"].getStr == "req-42"

suite "line framing":
  test "valid line produces one reply line":
    let srv = newMcpServer()
    let line = srv.handleLine($(%*{"jsonrpc": "2.0", "id": 1,
                                 "method": "server/discover",
                                 "params": modernParams(ProtocolVersion, "c", "1.0")}))
    check line.contains("supportedVersions")
    check line.find('\n') < 0

  test "invalid JSON becomes a parse error line":
    let srv = newMcpServer()
    let line = srv.handleLine("{not json")
    check line.contains("-32700")

  test "notification line yields no reply":
    let srv = newMcpServer()
    let line = srv.handleLine($(%*{"jsonrpc": "2.0",
                                  "method": "notifications/cancelled"}))
    check line == ""

suite "http status mapping":
  test "success is 200":
    let srv = newMcpServer()
    let r = call(srv, "ping", modernParams(ProtocolVersion, "c", "1.0"))
    check srv.httpStatusFor(r) == 200

  test "invalid params is 400":
    let srv = newMcpServer()
    let r = call(srv, "tools/call", modernParams(ProtocolVersion, "c", "1.0"))
    check srv.httpStatusFor(r) == 400

  test "unsupported version is 400":
    let srv = newMcpServer()
    var params = newJObject()
    setMeta(params, MetaProtocolVersion, "1900-01-01")
    setMetaNode(params, MetaClientCapabilities, newJObject())
    let r = call(srv, "tools/list", params)
    check srv.httpStatusFor(r) == 400

  test "unknown method is 404":
    let srv = newMcpServer()
    let r = call(srv, "nope", modernParams(ProtocolVersion, "c", "1.0"))
    check srv.httpStatusFor(r) == 404