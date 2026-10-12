import unittest, strutils
import openparser/json
import ../src/datcontext/protocol/[errors, meta, version]
import ../src/datcontext/prompts
import ../src/datcontext/resources
import ../src/datcontext/server/core
import ../src/datcontext/subscriptions

proc call(srv: McpServer; methodName: string;
          params: JsonNode = nil): JsonNode =
  var msg = newJObject()
  msg["jsonrpc"] = newJString("2.0")
  msg["id"] = newJInt(1)
  msg["method"] = newJString(methodName)
  if not params.isNil:
    msg["params"] = params
  srv.dispatch(msg).reply

proc argsWith(pairs: openArray[(string, string)]): JsonNode =
  result = newJObject()
  for p in pairs:
    result[p[0]] = newJString(p[1])

proc getPrompt(srv: McpServer; name: string;
               args: JsonNode = nil): JsonNode =
  var params = modernParams(ProtocolVersion, "t", "1.0")
  params["name"] = newJString(name)
  if not args.isNil:
    params["arguments"] = args
  call(srv, "prompts/get", params)

proc promptServer(): McpServer =
  ## A server with one app-specific prompt, for prompts/get coverage.
  result = newMcpServer()
  let preg = result.prompts
  preg.add(
    Prompt(name: "tour",
      title: "Tour the server",
      description: "Walk through what this server offers.",
      arguments: @[
        PromptArgument(name: "place", description: "The place to tour.",
                       required: true),
      ]),
    proc(args: JsonNode): PromptResult =
      let place = preg.argOf(args, "place")
      PromptResult(
        description: "Tour " & place,
        messages: @[userMsg("Welcome to " & place & ". Call `tools/list` first.")]))

suite "prompts/list":
  test "a bare server starts with no prompts":
    let srv = newMcpServer()
    let r = call(srv, "prompts/list", modernParams(ProtocolVersion, "t", "1.0"))
    check r["result"]["prompts"].len == 0

  test "every prompt has a name and description":
    let srv = promptServer()
    let r = call(srv, "prompts/list", modernParams(ProtocolVersion, "t", "1.0"))
    let prompts = r["result"]["prompts"]
    check prompts.len == 1
    for p in prompts:
      check p["name"].getStr.len > 0
      check p["description"].getStr.len > 10

  test "arguments are declared with required flags":
    let srv = promptServer()
    let r = call(srv, "prompts/list", modernParams(ProtocolVersion, "t", "1.0"))
    var sawRequired = false
    for p in r["result"]["prompts"]:
      if not p.hasKey("arguments"): continue
      for a in p["arguments"]:
        check a["name"].getStr.len > 0
        check a.hasKey("required")
        if a["required"].getBool: sawRequired = true
    check sawRequired

  test "order is deterministic":
    let srv = promptServer()
    let a = call(srv, "prompts/list", modernParams(ProtocolVersion, "t", "1.0"))
    let b = call(srv, "prompts/list", modernParams(ProtocolVersion, "t", "1.0"))
    check $a == $b

suite "prompts/get":
  test "returns user messages with text content":
    let srv = promptServer()
    let r = getPrompt(srv, "tour", argsWith({"place": "here"}))
    check r["result"]["messages"].len > 0
    let m = r["result"]["messages"][0]
    check m["role"].getStr == "user"
    check m["content"]["type"].getStr == "text"
    check m["content"]["text"].getStr.len > 20

  test "the prompt interpolates its arguments":
    let srv = promptServer()
    let r = getPrompt(srv, "tour", argsWith({"place": "there"}))
    let text = r["result"]["messages"][0]["content"]["text"].getStr
    check text.contains("there")

  test "a missing required argument is invalid params":
    let srv = promptServer()
    let r = getPrompt(srv, "tour", newJObject())
    check r["error"]["code"].getInt == -32602

  test "no arguments at all is invalid params":
    let srv = promptServer()
    let r = getPrompt(srv, "tour")
    check r["error"]["code"].getInt == -32602

  test "an unknown prompt is invalid params":
    let srv = newMcpServer()
    let r = getPrompt(srv, "no_such_prompt")
    check r["error"]["code"].getInt == -32602

  test "a missing name parameter is invalid params":
    let srv = newMcpServer()
    let r = call(srv, "prompts/get", modernParams(ProtocolVersion, "t", "1.0"))
    check r["error"]["code"].getInt == -32602

  test "every registered prompt resolves":
    let srv = promptServer()
    for p in srv.prompts.listJson:
      # Supply every declared argument so validation passes.
      var args = newJObject()
      if p.hasKey("arguments"):
        for a in p["arguments"]:
          args[a["name"].getStr] = newJString("x")
      let r = getPrompt(srv, p["name"].getStr, args)
      check not r.hasKey("error")

suite "prompt text quality":
  test "prompts name concrete tools":
    let srv = promptServer()
    for e in srv.prompts.entries:
      # Supply every declared argument; a resolver validates before returning.
      var args = newJObject()
      for a in e.prompt.arguments:
        args[a.name] = newJString("x")
      let text = e.resolve(args)
      # A prompt that does not say which tool to call is not much use.
      var hasBacktick = false
      for m in text.messages:
        if m.text.contains("`"):
          hasBacktick = true
      check hasBacktick

suite "resources over the wire":
  test "a bare server lists no resources":
    let srv = newMcpServer()
    let r = call(srv, "resources/list", modernParams(ProtocolVersion, "t", "1.0"))
    check r["result"]["resources"].len == 0

  test "apps register their own resources":
    let srv = newMcpServer()
    srv.resources.add(Resource(uri: "example://hello", name: "hello",
      title: "Hello", description: "A test resource.", mimeType: "text/plain"))
    srv.resources.addReader("example://",
      proc(uri: string): ResourceContents =
        ResourceContents(uri: uri, mimeType: "text/plain", text: "hello"))
    let r = call(srv, "resources/list", modernParams(ProtocolVersion, "t", "1.0"))
    check r["result"]["resources"].len == 1

  test "resources/templates/list returns templates":
    let srv = newMcpServer()
    srv.resources.addTemplate(ResourceTemplate(uriTemplate: "example://{id}",
      name: "Examples", description: "Example items.", mimeType: "text/plain"))
    let r = call(srv, "resources/templates/list",
                 modernParams(ProtocolVersion, "t", "1.0"))
    check r["result"]["resourceTemplates"].len == 1

  test "resources/read returns contents":
    let srv = newMcpServer()
    srv.resources.add(Resource(uri: "example://hello", name: "hello",
      title: "Hello", description: "A test resource.", mimeType: "text/plain"))
    srv.resources.addReader("example://",
      proc(uri: string): ResourceContents =
        ResourceContents(uri: uri, mimeType: "text/plain", text: "hello"))
    var params = modernParams(ProtocolVersion, "t", "1.0")
    params["uri"] = newJString("example://hello")
    let r = call(srv, "resources/read", params)
    check r["result"]["contents"][0]["text"].getStr == "hello"

  test "a missing resource is invalid params, not an empty array":
    # The spec forbids an empty `contents` array for a non-existent resource.
    let srv = newMcpServer()
    var params = modernParams(ProtocolVersion, "t", "1.0")
    params["uri"] = newJString("datcontext://nope")
    let r = call(srv, "resources/read", params)
    check r["error"]["code"].getInt == -32602
    check not r.hasKey("result")

  test "a missing uri parameter is invalid params":
    let srv = newMcpServer()
    let r = call(srv, "resources/read", modernParams(ProtocolVersion, "t", "1.0"))
    check r["error"]["code"].getInt == -32602

  test "file resources are absent unless a root is configured":
    let srv = newMcpServer()
    let r = call(srv, "resources/list", modernParams(ProtocolVersion, "t", "1.0"))
    for res in r["result"]["resources"]:
      check not res["uri"].getStr.startsWith("file://")

suite "capabilities":
  test "only implemented capabilities are declared":
    let srv = newMcpServer()
    let caps = srv.serverCapabilities()
    check caps["tools"] != nil
    check caps["resources"] != nil
    check caps["prompts"] != nil
    # listChanged/subscribe are false because the sets never change at runtime.
    check caps["resources"]["subscribe"].getBool == false
    check caps["tools"]["listChanged"].getBool == false

  test "logging is not advertised":
    let srv = newMcpServer()
    check not srv.serverCapabilities().hasKey("logging")

suite "subscription filter parsing":
  test "an empty filter is empty":
    check parseFilter(newJObject()).isEmpty
    check parseFilter(nil).isEmpty
    check parseFilter(%*{"notifications": newJObject()}).isEmpty

  test "flags are read":
    let f = parseFilter(%*{"notifications": %*{"toolsListChanged": true,
                                               "promptsListChanged": true}})
    check f.toolsListChanged
    check f.promptsListChanged
    check not f.resourcesListChanged

  test "resource URIs are read":
    let f = parseFilter(%*{"notifications":
      %*{"resourceSubscriptions": ["file:///a", "file:///b"]}})
    check f.resourceSubscriptions.len == 2
    check f.resourceSubscriptions[0] == "file:///a"

suite "subscriptions over the wire":
  test "listen returns an ack and no immediate reply":
    let srv = newMcpServer()
    var params = modernParams(ProtocolVersion, "t", "1.0")
    params["notifications"] = %*{"toolsListChanged": true}
    var msg = newJObject()
    msg["jsonrpc"] = newJString("2.0")
    msg["id"] = newJString("sub-1")
    msg["method"] = newJString("subscriptions/listen")
    msg["params"] = params

    let d = srv.dispatch(msg)
    check d.reply.isNil                   # a stream request has no reply
    check d.stream != nil
    check not d.ack.isNil
    check d.ack["method"].getStr ==
          "notifications/subscriptions/acknowledged"
    # The ack must carry the subscription id, which is the listen request's id.
    check d.ack["params"]["_meta"][MetaSubscriptionId].getStr == "sub-1"
    check d.ack["params"]["notifications"]["toolsListChanged"].getBool

  test "an empty filter is rejected":
    let srv = newMcpServer()
    var params = modernParams(ProtocolVersion, "t", "1.0")
    params["notifications"] = newJObject()
    var msg = newJObject()
    msg["jsonrpc"] = newJString("2.0")
    msg["id"] = newJInt(2)
    msg["method"] = newJString("subscriptions/listen")
    msg["params"] = params
    let d = srv.dispatch(msg)
    check d.reply["error"]["code"].getInt == -32602

  test "only requested notification types are delivered":
    let srv = newMcpServer()
    var params = modernParams(ProtocolVersion, "t", "1.0")
    params["notifications"] = %*{"toolsListChanged": true}
    var msg = newJObject()
    msg["jsonrpc"] = newJString("2.0")
    msg["id"] = newJInt(3)
    msg["method"] = newJString("subscriptions/listen")
    msg["params"] = params
    let d = srv.dispatch(msg)

    var seen: seq[string]
    d.stream.emit = proc(m: JsonNode) = seen.add(m["method"].getStr)
    srv.notifyToolsChanged()
    srv.notifyPromptsChanged()
    srv.notifyResourcesChanged()
    check seen == @["notifications/tools/list_changed"]

  test "notifications carry the subscription id":
    let srv = newMcpServer()
    var params = modernParams(ProtocolVersion, "t", "1.0")
    params["notifications"] = %*{"resourcesListChanged": true}
    var msg = newJObject()
    msg["jsonrpc"] = newJString("2.0")
    msg["id"] = newJInt(99)
    msg["method"] = newJString("subscriptions/listen")
    msg["params"] = params
    let d = srv.dispatch(msg)

    var gotId = ""
    d.stream.emit = proc(m: JsonNode) =
      gotId = m["params"]["_meta"][MetaSubscriptionId].getStr
    srv.notifyResourcesChanged()
    check gotId == "99"

  test "resource subscriptions are URI-scoped":
    let srv = newMcpServer()
    var params = modernParams(ProtocolVersion, "t", "1.0")
    params["notifications"] = %*{"resourceSubscriptions": ["file:///watched"]}
    var msg = newJObject()
    msg["jsonrpc"] = newJString("2.0")
    msg["id"] = newJInt(4)
    msg["method"] = newJString("subscriptions/listen")
    msg["params"] = params
    let d = srv.dispatch(msg)

    var seen: seq[string]
    d.stream.emit = proc(m: JsonNode) = seen.add(m["params"]["uri"].getStr)
    srv.notifyResourceUpdated("file:///other")
    check seen.len == 0
    srv.notifyResourceUpdated("file:///watched")
    check seen == @["file:///watched"]

suite "subscription manager":
  test "close removes a subscription":
    let m = newSubscriptionManager()
    discard m.register("a", parseFilter(%*{"notifications":
      %*{"toolsListChanged": true}}))
    check m.active() == 1
    check m.close("a")
    check m.active() == 0
    check not m.close("a")

  test "closeAll returns and clears":
    let m = newSubscriptionManager()
    discard m.register("a", parseFilter(%*{"notifications":
      %*{"toolsListChanged": true}}))
    discard m.register("b", parseFilter(%*{"notifications":
      %*{"promptsListChanged": true}}))
    check m.active() == 2
    check m.closeAll().len == 2
    check m.active() == 0

  test "a closed subscription receives nothing":
    let m = newSubscriptionManager()
    let s = m.register("a", parseFilter(%*{"notifications":
      %*{"toolsListChanged": true}}))
    var count = 0
    s.emit = proc(m: JsonNode) = count.inc
    discard m.close("a")
    m.broadcast("notifications/tools/list_changed")
    check count == 0

  test "graceful closure carries the subscription id":
    let m = newSubscriptionManager()
    let s = m.register("abc", parseFilter(%*{"notifications":
      %*{"toolsListChanged": true}}))
    let closed = s.closedResult()
    check closed["resultType"].getStr == "complete"
    check closed["_meta"][MetaSubscriptionId].getStr == "abc"

  test "a nil emit is safe":
    let m = newSubscriptionManager()
    discard m.register("a", parseFilter(%*{"notifications":
      %*{"toolsListChanged": true}}), nil)
    m.broadcast("notifications/tools/list_changed")  # must not crash
    check m.active() == 1

suite "undeclared methods":
  test "replaced subscribe RPCs are method-not-found":
    # resources/subscribe and resources/unsubscribe were replaced by
    # subscriptions/listen, so advertising the capability must not imply support.
    let srv = newMcpServer()
    for m in ["resources/subscribe", "resources/unsubscribe"]:
      let r = call(srv, m, modernParams(ProtocolVersion, "t", "1.0"))
      check r["error"]["code"].getInt == -32601
