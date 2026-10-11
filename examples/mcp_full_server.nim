# mcp_full_server — a complete MCP server built on the datcontext library.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## A full-featured example MCP server.
##
## The stock `datcontext` binary is a fixed-function server. This example shows
## how to build your own on the same library: it starts from `newMcpServer`
## (so every openparser tool, resource, and prompt is already registered) and
## adds server-specific behaviour on top:
##
## * custom tools: `example_greet` (structured output plus the `isError` path),
##   `example_wordcount` (inline-or-file input, annotations, output schema),
##   `example_add_tool` (runtime registration with a broadcast)
## * a custom resource (`example://greeting`) with its own reader
## * a custom prompt (`tour_server`)
## * `file://` resources rooted at `examples/share` (or DATCONTEXT_FILE_ROOT)
## * every transport: stdio (default), Streamable HTTP, Unix socket, TCP
##
## Build:
##   clue build examples/mcp_full_server.nim --out:bin/example_full_server
##
## Run:
##   ./bin/example_full_server                    # stdio
##   ./bin/example_full_server http 9000
##   ./bin/example_full_server unix /tmp/example.sock
##   ./bin/example_full_server tcp 9001

import std/[os, strutils]
import openparser/json
import ../src/datcontext/server/core
import ../src/datcontext/server/http
import ../src/datcontext/server/stdio
import ../src/datcontext/server/stream
import ../src/datcontext/prompts
import ../src/datcontext/resources
import ../src/datcontext/tools/[tool, load]

const
  ExampleName = "example-full"
  ExampleVersion = "0.1.0"
  Usage = """
example-full — MCP server showcasing the datcontext library

usage:
  example_full_server stdio                 speak MCP on stdin/stdout (default)
  example_full_server http [port]           serve Streamable HTTP (default 9000)
  example_full_server unix <path>           serve over a Unix domain socket
  example_full_server tcp <port>            serve over TCP

environment:
  DATCONTEXT_FILE_ROOT             file:// resources under this directory
                                   (default: <package>/examples/share)
"""

proc shareDir(): string =
  ## Where `file://` resources are served from.
  let env = getEnv("DATCONTEXT_FILE_ROOT")
  if env.len > 0:
    return env
  joinPath(parentDir(getAppDir()), "examples", "share")

proc registerExampleTools(srv: McpServer) =
  let reg = srv.registry

  reg.register("example_greet",
    "Greet someone by name. Empty names are refused with a tool error.",
    objSchema(properties = props(
      ("name", stringProp("Who to greet.")),
      ("punctuation", stringProp("Trailing punctuation.", "!"))),
      required = @["name"]),
    proc(args: JsonNode): ToolResult =
      let name = argStrOr(args, "name", "")
      if name.len == 0:
        # A model-fixable failure: an `isError` result, not a protocol error.
        return errResult("supply a non-empty name")
      let punct = argStrOr(args, "punctuation", "!")
      okStructured("Hello, " & name & punct,
                   %*{"greeting": "Hello, " & name & punct, "name": name}),
    title = "Greet")

  # The `Tool` object form, for the knobs the convenience overload has no room
  # for: annotations on the wire and an output schema. The handler is wrapped
  # in `guard` by hand, which the convenience overload would do for us.
  reg.register(Tool(
    name: "example_wordcount",
    title: "Count words",
    description: "Count the lines, words, and bytes of inline text or a file. " &
      "Reads the filesystem when given a path, which is why it is annotated " &
      "read-only: a host can show the call to a human before allowing it.",
    inputSchema: objSchema(properties = props(
      ("source", stringProp("The text to count.")),
      ("path", stringProp("Read the text from this file path instead.")))),
    outputSchema: objSchema(properties = props(
      ("bytes", intProp("Byte length of the input.")),
      ("words", intProp("Whitespace-separated word count.")),
      ("lines", intProp("Line count.")))),
    annotations: %*{"readOnlyHint": true, "idempotentHint": true},
    handler: guard(proc(args: JsonNode): ToolResult =
      # Shared with every stock tool: exactly one of source/path, honours
      # DATCONTEXT_MAX_SOURCE_BYTES, understands file:// URIs.
      let src = readSource(args)
      let lines = if src.len == 0: 0 else: src.splitLines().len
      okStructured($src.splitWhitespace().len & " words, " & $lines &
                   " lines, " & $src.len & " bytes",
                   %*{"bytes": src.len, "words": src.splitWhitespace().len,
                      "lines": lines})),
    sideEffecting: true))

  reg.register("example_add_tool",
    "Register a new greeting tool at runtime and broadcast tools/list_changed " &
    "so subscribed clients re-list. Demonstrates the subscription emit path.",
    objSchema(properties = props(
      ("name", stringProp("Suffix for the new tool; letters, digits, " &
        "underscores. The tool is registered as example_dynamic_<name>."))),
      required = @["name"]),
    proc(args: JsonNode): ToolResult =
      # Bound to a local: inside the closures below, `result` would refer to
      # their own ToolResult rather than the server being built.
      let server = srv
      let suffix = argStr(args, "name")
      for ch in suffix:
        if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}:
          return errResult("name must be letters, digits, or underscores")
      let toolName = "example_dynamic_" & suffix
      if server.registry.has(toolName):
        return errResult("already registered: " & toolName)
      server.registry.register(toolName,
        "Dynamically registered by example_add_tool.",
        objSchema(),
        proc(a: JsonNode): ToolResult =
          okResult("hello from " & toolName),
        title = "Dynamic tool")
      # The stock server advertises tools.listChanged as false because its set
      # is fixed for its lifetime. This example deliberately mutates its set
      # to exercise the notification path instead.
      server.notifyToolsChanged()
      okResult("registered " & toolName & " and broadcast tools/list_changed"),
    title = "Add a tool at runtime")

proc registerExampleResource(srv: McpServer) =
  srv.resources.add(Resource(uri: "example://greeting", name: "greeting",
    title: "Example greeting",
    description: "A static greeting showing a custom resource and reader.",
    mimeType: "text/plain"))
  srv.resources.addReader("example://",
    proc(uri: string): ResourceContents =
      ResourceContents(uri: uri, mimeType: "text/plain",
                       text: "hello from the example server"))

proc registerExamplePrompt(srv: McpServer) =
  # Same local-binding rule as in buildPromptRegistry: inside the resolver,
  # `result` is the PromptResult being built, not the registry.
  let preg = srv.prompts
  preg.add(
    Prompt(name: "tour_server",
      title: "Tour this example server",
      description: "Walk through everything this example server offers.",
      arguments: @[
        PromptArgument(name: "transport",
          description: "Which transport you connected over, e.g. unix.",
          required: false),
      ]),
    proc(args: JsonNode): PromptResult =
      let transport = preg.argOf(args, "transport", false)
      let via = if transport.len > 0: transport else: "an MCP transport"
      PromptResult(
        description: "Tour the example server",
        messages: @[userMsg(
          "You are connected to the example-full server over " & via & "." &
          "\n\n1. Call `tools/list` and find the three `example_*` tools " &
          "among the openparser ones." &
          "\n2. Call `example_greet` with your name, then with an empty " &
          "name to see the `isError` path." &
          "\n3. Call `example_wordcount` on the sample config under " &
          "examples/share via its `file://` URI." &
          "\n4. Read `datcontext://formats` and one format sample." &
          "\n5. Read the `example://greeting` resource." &
          "\n6. Call `example_add_tool`, then `tools/list` again to see " &
          "the dynamic tool.")]))

proc main() =
  let args = commandLineParams()
  let cmd = if args.len > 0: args[0] else: "stdio"

  let srv = newMcpServer(name = ExampleName, version = ExampleVersion,
    instructions = "An example MCP server: every openparser tool plus " &
      "example_greet, example_wordcount, and example_add_tool; " &
      "datcontext:// and file:// resources; six prompts.",
    fileRoot = shareDir())
  registerExampleTools(srv)
  registerExampleResource(srv)
  registerExamplePrompt(srv)

  stderr.writeLine("example-full: " & $srv.registry.len & " tools, " &
    $srv.prompts.len & " prompts, file:// root " & shareDir())

  case cmd
  of "stdio":
    srv.runStdio()
  of "http":
    srv.runHttp(if args.len > 1: parseInt(args[1]) else: 9000)
  of "unix":
    if args.len < 2:
      stderr.writeLine("example-full: unix requires a socket path")
      stderr.writeLine(Usage)
      quit(1)
    srv.runUnix(args[1])
  of "tcp":
    if args.len < 2:
      stderr.writeLine("example-full: tcp requires a port")
      stderr.writeLine(Usage)
      quit(1)
    srv.runTcp(parseInt(args[1]))
  of "--help", "-h", "help":
    echo Usage
  else:
    stderr.writeLine("example-full: unknown subcommand: " & cmd)
    stderr.writeLine(Usage)
    quit(1)

when isMainModule:
  main()
