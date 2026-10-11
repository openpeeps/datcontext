# mcp_unix_client — an MCP client over a Unix domain socket.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Walk through a full session against a server on a Unix socket.
##
## Every byte-stream transport (Unix socket, TCP, spawned stdio) shares the
## NDJSON framing and the id-matched request/reply discipline, so this is the
## shape of all three: probe the era, then list tools, call one, read a
## resource, and fetch a prompt.
##
## Two things this client deliberately does not do yet:
##
## * `subscriptions/listen` has no stream delivery on the client: the ack is an
##   id-less notification and `deliver` drops id-less messages, so the call
##   would sit out the 30-second reply deadline. Server-side emit over the
##   socket already works; client delivery is planned work, not a wire problem.
## * `closeStreamClient` needs the `StreamClient` handle, which
##   `connectUnixClient` keeps inside its transport closure. This client owns
##   the `Loop` instead and stops it on the way out; the process exit reclaims
##   the connection itself.
##
## Build:
##   clue build examples/mcp_unix_client.nim --out:bin/example_unix_client
##
## Run (against the example server):
##   ./bin/example_full_server unix /tmp/example.sock &
##   ./bin/example_unix_client /tmp/example.sock

import std/[os, strutils]
import powpow
import openparser/json
import ../src/datcontext/client/[core, stream]
import ../src/datcontext/protocol/errors

proc call(c: McpClient; meth: string; params: JsonNode = nil): JsonNode =
  ## One request, unwrapping the `result` envelope.
  ##
  ## Raw `send` rather than `requestRaw`: resource and prompt methods have no
  ## convenience wrappers, and `send` returns the reply untouched so the
  ## caller sees both results and errors.
  var msg = newJObject()
  msg["jsonrpc"] = newJString("2.0")
  msg["id"] = newJInt(c.nextId())
  msg["method"] = newJString(meth)
  msg["params"] = c.modernParams(params)
  let reply = c.send(msg)
  if reply.hasKey("error"):
    raise newMcpError(ecInvalidParams,
      reply["error"]["message"].getStr("unknown error"))
  reply["result"]

proc preview(s: string; maxLen = 120): string =
  if s.len <= maxLen: s else: s[0 ..< maxLen] & "…"

proc main(path: string) =
  # Our loop, so we can stop it when done. Nothing else here owns one.
  let loop = newLoop()
  let c =
    try:
      connectUnixClient(path, loop)
    except McpError as e:
      stderr.writeLine("example-client: " & e.msg)
      quit(1)
  try:
    # Era first: `connect` probes with server/discover and only falls back to
    # the legacy initialize handshake when the probe says to.
    c.connect()
    echo "era:         " & c.era & " (" & c.protocolVersion & ")"
    echo "server:      " & c.serverInfo["name"].getStr
    echo "instructions: " & preview(c.instructions)

    let tools = c.listTools()["result"]["tools"]
    echo "tools:       " & $tools.len & " (e.g. " &
      tools[0]["name"].getStr & ", " & tools[1]["name"].getStr & ")"

    # The example server's custom tool, with structured output.
    let greet = c.callTool("example_greet",
      %*{"name": "unix"})["result"]
    echo "greet:       " & greet["content"][0]["text"].getStr
    echo "structured:  " & $greet["structuredContent"]

    # And its `isError` path: no exception, just a flagged result.
    let bad = c.callTool("example_greet", %*{"name": ""})["result"]
    echo "empty name:  isError=" & $bad["isError"].getBool &
      " (" & preview(bad["content"][0]["text"].getStr) & ")"

    # Optional openparser bundle tool over the socket.
    let parsed = c.callTool("parse_toml",
      %*{"source": "a = 1"})["result"]
    echo "parse_toml:  " & preview(parsed["content"][0]["text"].getStr)

    let resources = call(c, "resources/list")["resources"]
    echo "resources:   " & $resources.len
    for r in resources:
      echo "  - " & r["uri"].getStr

    let formats = call(c, "resources/read",
      %*{"uri": "datcontext://formats"})
    echo "formats:     " &
      preview(formats["contents"][0]["text"].getStr)

    # Present only when the server enables file:// resources (the example
    # server does, rooted at examples/share). Against a server without them
    # this prints the -32602 refusal instead of failing.
    var fileMsg = newJObject()
    fileMsg["jsonrpc"] = newJString("2.0")
    fileMsg["id"] = newJInt(c.nextId())
    fileMsg["method"] = newJString("resources/read")
    fileMsg["params"] = c.modernParams(%*{"uri": "file:///config.toml"})
    let fileReply = c.send(fileMsg)
    if fileReply.hasKey("error"):
      echo "file://:      refused (" &
        fileReply["error"]["message"].getStr & ")"
    else:
      echo "file://:      " &
        preview(fileReply["result"]["contents"][0]["text"].getStr)

    let prompts = call(c, "prompts/list")["prompts"]
    echo "prompts:     " & $prompts.len
    let tour = call(c, "prompts/get",
      %*{"name": "tour_server", "arguments": {"transport": "unix"}})
    echo "tour_server: " &
      preview(tour["messages"][0]["content"]["text"].getStr, 160)
  finally:
    if loop.isRunning:
      loop.stop()
    loop.close()

when isMainModule:
  if paramCount() < 1:
    stderr.writeLine("usage: example_unix_client <socket-path>")
    quit(1)
  main(paramStr(1))
