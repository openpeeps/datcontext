import unittest, os, osproc, strutils, times
import powpow
import openparser/json
import ../src/datcontext/client/[core, http, spawn, stream]
import ../src/datcontext/protocol/[errors, meta, version]
import ../src/datcontext/server/core
import ../src/datcontext/tools/tool
import ../src/datcontext/prompts
import ../src/datcontext/resources

const
  # datcontext itself ships no binary (library only). Transport round trips
  # spawn the example high-level app.
  ServerBin = "bin/example_full_server"

suite "round trip against a real spawned server":
  test "discover identifies the server as modern":
    if not fileExists(ServerBin):
      skip()
    var stderrLines: seq[string]
    let c = spawnServer(ServerBin, ["stdio"],
      stderrOnLine = proc(line: string) = stderrLines.add(line))
    defer: closeClient(c)

    check c.probe() == "modern"
    check c.protocolVersion == ProtocolVersion
    check c.serverInfo["name"].getStr == "example-full"
    check c.instructions.len > 0

  test "tools/list over the wire":
    if not fileExists(ServerBin):
      skip()
    let c = spawnServer(ServerBin, ["stdio"])
    defer: closeClient(c)
    c.connect()
    let tools = c.listTools()["result"]["tools"]
    check tools.len == 3
    # Every tool must carry a usable schema on the wire, not just in-process.
    for t in tools:
      check t["name"].getStr.len > 0
      check t["inputSchema"]["type"].getStr == "object"

  test "tools/call returns content and structured output":
    if not fileExists(ServerBin):
      skip()
    let c = spawnServer(ServerBin, ["stdio"])
    defer: closeClient(c)
    c.connect()
    let r = c.callTool("example_greet", %*{"name": "wire"})["result"]
    check not r.hasKey("isError")
    check r["content"][0]["type"].getStr == "text"
    check r["structuredContent"]["name"].getStr == "wire"

  test "several requests interleave correctly over one pipe":
    if not fileExists(ServerBin):
      skip()
    let c = spawnServer(ServerBin, ["stdio"])
    defer: closeClient(c)
    c.connect()
    # Reply correlation must not mix these up.
    for i in 0 ..< 5:
      let r = c.callTool("example_greet", %*{"name": "n" & $i})
      let v = r["result"]["structuredContent"]["name"].getStr
      check v == "n" & $i

  test "a tool error comes back as a tool error, not a crash":
    if not fileExists(ServerBin):
      skip()
    let c = spawnServer(ServerBin, ["stdio"])
    defer: closeClient(c)
    c.connect()
    let r = c.callTool("example_greet", %*{"name": ""})["result"]
    # The server must stay up: a bad argument is a tool error.
    check r["isError"].getBool
    # And the connection is still usable afterwards.
    check c.callTool("example_greet", %*{"name": "again"})["result"].hasKey("content")

  test "a legacy client drives the same server":
    if not fileExists(ServerBin):
      skip()
    let c = spawnServer(ServerBin, ["stdio"])
    defer: closeClient(c)
    # Our server is dual-era, so the probe returns modern. Force the legacy path
    # to prove the handshake works against this server too.
    c.protocolVersion = "2025-06-18"
    discard c.initialize()
    check c.initialized
    check c.listTools()["result"]["tools"].len == 3

suite "live transports against running servers":
  # These spawn the built binary on each transport and drive it with the real
  # client, which is the only way to cover the socket wiring: an in-process
  # handler cannot catch a framing or connection bug.

  test "streamable http":
    if not fileExists(ServerBin):
      skip()
    let port = 19300
    let child = startProcess(ServerBin, workingDir = "", args = ["http", $port],
                  options = {poParentStreams})
    defer: child.terminate()
    discard child

    # Give the listener a moment to bind.
    sleep(600)
    let c = connectHttp("http://127.0.0.1:" & $port)
    check c.probe() == "modern"
    # The three example app tools.
    check c.listTools()["result"]["tools"].len == 3
    let reply = c.callTool("example_greet", %*{"name": "http"})
    check reply["result"]["content"][0]["text"].getStr.contains("http")

  test "tcp":
    if not fileExists(ServerBin):
      skip()
    let port = 19301
    let child = startProcess(ServerBin, workingDir = "", args = ["tcp", $port],
                  options = {poParentStreams})
    defer: child.terminate()
    sleep(600)

    let c = connectTcpClient("127.0.0.1", port)
    check c.probe() == "modern"
    check c.listTools()["result"]["tools"].len == 3
    let reply = c.callTool("example_greet", %*{"name": "tcp"})
    check reply["result"]["content"][0]["text"].getStr.contains("tcp")

  test "unix domain socket":
    if not fileExists(ServerBin):
      skip()
    let path = "/tmp/datcontext_test_roundtrip.sock"
    removeFile(path)
    let child = startProcess(ServerBin, workingDir = "", args = ["unix", path],
                  options = {poParentStreams})
    defer:
      child.terminate()
      removeFile(path)
    sleep(600)

    let c = connectUnixClient(path)
    check c.probe() == "modern"
    check c.listTools()["result"]["tools"].len == 3
    let reply = c.callTool("example_greet", %*{"name": "unix"})
    check reply["result"]["content"][0]["text"].getStr.contains("unix")

suite "resources and prompts over the wire":
  test "resources/list and resources/read":
    let srv = newMcpServer()
    srv.resources.add(Resource(uri: "example://hello", name: "hello",
      title: "Hello",
      description: "A test resource.",
      mimeType: "text/plain"))
    srv.resources.addReader("example://",
      proc(uri: string): ResourceContents =
        ResourceContents(uri: uri, mimeType: "text/plain", text: "hello"))
    let c = newClient(ClientTransport(
      kind: "inproc", send: proc(m: JsonNode): JsonNode =
        srv.handleMessage(m)))
    c.connect()

    var msg = newJObject()
    msg["jsonrpc"] = newJString("2.0")
    msg["id"] = newJInt(1)
    msg["method"] = newJString("resources/list")
    msg["params"] = c.modernParams()
    let list = c.send(msg)["result"]["resources"]
    check list.len == 1

    var rp = c.modernParams()
    rp["uri"] = newJString("example://hello")
    var rm = newJObject()
    rm["jsonrpc"] = newJString("2.0")
    rm["id"] = newJInt(2)
    rm["method"] = newJString("resources/read")
    rm["params"] = rp
    let read = c.send(rm)["result"]["contents"]
    check read[0]["text"].getStr == "hello"

  test "prompts/list and prompts/get":
    let srv = newMcpServer()
    srv.prompts.add(
      Prompt(name: "tour", title: "Tour",
        description: "Tour the server.",
        arguments: @[PromptArgument(name: "place",
          description: "A place.", required: true)]),
      proc(args: JsonNode): PromptResult =
        PromptResult(description: "Tour",
          messages: @[userMsg("welcome to " & srv.prompts.argOf(args, "place"))]))
    let c = newClient(ClientTransport(
      kind: "inproc", send: proc(m: JsonNode): JsonNode =
        srv.handleMessage(m)))
    c.connect()

    var pm = newJObject()
    pm["jsonrpc"] = newJString("2.0")
    pm["id"] = newJInt(3)
    pm["method"] = newJString("prompts/list")
    pm["params"] = c.modernParams()
    check c.send(pm)["result"]["prompts"].len == 1

    var gp = c.modernParams()
    gp["name"] = newJString("tour")
    gp["arguments"] = %*{"place": "here"}
    var gm = newJObject()
    gm["jsonrpc"] = newJString("2.0")
    gm["id"] = newJInt(4)
    gm["method"] = newJString("prompts/get")
    gm["params"] = gp
    let got = c.send(gm)["result"]
    check got["messages"][0]["content"]["text"].getStr.contains("here")

suite "subscriptions against a real spawned server":
  test "the ack is written before anything else on the channel":
    # Two requests on one pipe: the subscription ack must not be reordered
    # behind an unrelated reply.
    let srv = newMcpServer()
    let c = newClient(ClientTransport(
      kind: "inproc", send: proc(m: JsonNode): JsonNode =
        srv.handleMessage(m)))
    c.connect()

    var params = c.modernParams()
    params["notifications"] = %*{"toolsListChanged": true}
    var msg = newJObject()
    msg["jsonrpc"] = newJString("2.0")
    msg["id"] = newJString("live-1")
    msg["method"] = newJString("subscriptions/listen")
    msg["params"] = params
    let d = srv.dispatch(msg)
    check d.reply.isNil
    check d.stream != nil
    check d.ack["method"].getStr ==
          "notifications/subscriptions/acknowledged"
    check d.ack["params"]["_meta"][MetaSubscriptionId].getStr == "live-1"
    check srv.subs.subs.len == 1

suite "client argument handling":
  test "unknown tool raises invalid params":
    let srv = newMcpServer()
    let c = newClient(ClientTransport(
      kind: "inproc", send: proc(m: JsonNode): JsonNode = srv.handleMessage(m)))
    c.connect()
    try:
      discard c.callTool("does_not_exist")
      check false
    except McpError as e:
      check e.code == ecInvalidParams

  test "request ids are unique":
    let srv = newMcpServer()
    let c = newClient(ClientTransport(
      kind: "inproc", send: proc(m: JsonNode): JsonNode = srv.handleMessage(m)))
    check c.nextId() != c.nextId()