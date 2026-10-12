<p align="center">
  A Nim library for building MCP clients and servers over powpow transports
</p>

<p align="center">
  <code>nimble install datcontext</code> / <code>clue install datcontext</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/datcontext">API reference</a><br>
  <img src="https://github.com/openpeeps/datcontext/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/datcontext/workflows/docs/badge.svg" alt="Github Actions">
</p>

## 😍 Key Features
- Generic MCP server and client building blocks in Nim
  Useful for high level apps that need tools, resources, prompts and subscriptions without writing protocol framing

- Four transports on both client and server
  Standard input/output, Streamable HTTP, Unix socket and TCP, useful for local
  subprocess use, web services and socket based agents

- Dual era protocol support for the 2026-07-28 revision
  Plus the legacy initialize handshake, useful for connecting current and older hosts without extra setup

- Empty by default, app defined everything
  A bare server registers no tools, resources or prompts. Higher level libs add their own,
  for example an openparser backed document bundle, without forking the core

- Tool registry with JSON Schema helpers and guarded handlers
  Useful for exposing model callable functions with precise schemas while keeping
  handler failures as model fixable tool errors instead of dropped connections

- Shared input helpers for inline source or file path loading with size bounds
  Useful for tools that accept document text without duplicating validation logic

- Read side resources with optional file backed resources
  Useful for giving a model safe context about project files

- Guided prompts registered by the app
  Useful as slash commands in MCP hosts for multi step workflows

- Notification subscriptions on every transport
  Useful for learning when the tool, resource or prompt catalogue changes

- Safe filesystem access backed by flysystem with read only policy
  Hidden file denial and containment checks, useful for exposing a project directory
  without risk of escape through parent paths, symlinks or sibling prefix tricks

- Clear separation of protocol errors and model fixable tool errors
  Useful because a model can see exactly what went wrong and correct itself

## Examples

datcontext ships no binary. High level apps integrate it as a library.
See `examples/mcp_full_server.nim` for a complete app.

Start with a bare server and add your own tool:

```nim
import datcontext/server/core

let srv = newMcpServer(name = "my-app", version = "0.1.0")
srv.registry.register("greet",
  "Greet someone by name.",
  objSchema(properties = props(
    ("name", stringProp("Who to greet.")))),
  proc(args: JsonNode): ToolResult =
    okResult("Hello, " & argStr(args, "name")))
```

Add a resource and a prompt on top:

```nim
srv.resources.add(Resource(uri: "example://greeting", name: "greeting",
  title: "Example greeting",
  description: "A static greeting showing a custom resource and reader.",
  mimeType: "text/plain"))
srv.resources.addReader("example://",
  proc(uri: string): ResourceContents =
    ResourceContents(uri: uri, mimeType: "text/plain",
                     text: "hello from the example server"))

srv.prompts.add(
  Prompt(name: "tour_server",
    title: "Tour this example server",
    description: "Walk through everything this example server offers.",
    arguments: @[]),
  proc(args: JsonNode): PromptResult =
    PromptResult(description: "Tour the example server",
      messages: @[userMsg("Call `tools/list` first.")]))
```

Serve over your preferred transport from your own app binary:

```nim
import datcontext/server/[core, stdio, http, stream]

let srv = newMcpServer(name = "my-app", version = "0.1.0")
srv.runStdio()          # speak MCP on stdin/stdout
srv.runHttp(9000)       # Streamable HTTP
srv.runUnix("/tmp/mcp.sock")  # Unix domain socket
srv.runTcp(9001)        # TCP
```

Call a tool over HTTP, client side:

```nim
import datcontext/client/[core, http]

let c = connectHttp("http://127.0.0.1:9000")
doAssert c.probe() == "modern"
let reply = c.callTool("greet", %*{"name": "ada"})
```

Read a resource and fetch a prompt:

```nim
import flysystem

let srv = newMcpServer(fileRoot = "/srv/data")
let greeting = srv.resources.read("example://greeting")
let prompt = srv.prompts.find("tour_server").resolve(newJObject())

# Narrow the file disk to config formats only.
let narrow = buildResourceRegistry("/srv/data",
  policy = FilePolicy(maxFileSize: 1 << 20, denyHiddenFiles: true,
                      allowedExtensions: @["yaml", "toml"]))
```

Build and try the bundled example server and Unix socket client:

```console
clue build examples/mcp_full_server.nim --out:bin/example_full_server
clue build examples/mcp_unix_client.nim --out:bin/example_unix_client

./bin/example_full_server unix /tmp/example.sock &
./bin/example_unix_client /tmp/example.sock
```

Subscribe to catalogue changes over Streamable HTTP:

```console
$ curl -N -X POST http://127.0.0.1:9000/mcp -H 'Accept: text/event-stream' \
    -d '{"jsonrpc":"2.0","id":"sub-1","method":"subscriptions/listen","params":{
          "notifications":{"toolsListChanged":true},
          "_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28",
                   "io.modelcontextprotocol/clientCapabilities":{}}}}'

event: message
data: {"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{
  "_meta":{"io.modelcontextprotocol/subscriptionId":"sub-1"},
  "notifications":{"toolsListChanged":true}}}
```

## What it is

`datcontext` is a library for building MCP clients and servers, not a CLI app.
A bare server starts with empty tool, resource and prompt registries. Higher
level apps register their own tools, resources and prompts, for example by
adding openparser backed document tools in their own core.

It targets the **2026-07-28** revision of the MCP specification and is
dual era: it serves modern stateless requests and also answers the legacy
`initialize` handshake, so current and older hosts both connect.

JSON handling inside uses openparser for JSON.

## Install

```console
nimble install datcontext
```

Built with [clue](https://github.com/openpeeps/clue).

## Resources

A bare server ships no resources. Apps register their own URI schemes:

```nim
srv.resources.add(Resource(uri: "example://greeting", name: "greeting",
  description: "A static greeting.", mimeType: "text/plain"))
srv.resources.addReader("example://",
  proc(uri: string): ResourceContents =
    ResourceContents(uri: uri, mimeType: "text/plain", text: "hello"))
```

Filesystem resources are **off by default**. Pass `fileRoot` to serve
`file://` URIs from under a directory:

```nim
let srv = newMcpServer(fileRoot = "/srv/data")
```

Backed by [flysystem](https://github.com/openpeeps/flysystem): a `LocalDriver`
rooted at the directory, wrapped in a `FilesystemPolicy` that makes it read-only,
denies hidden files, caps file size and path depth. Configure it via `FilePolicy`
(`allowedExtensions` is the useful knob if you want to expose only config
formats).

Containment is enforced inside flysystem itself (descriptor-walk, no
string-comparison gap): escape the root by `..`, via a symlink inside the
root, or by confusing a prefix-sharing sibling directory, and all three are
refused (see the note at the bottom of this file). A missing file returns
`-32602`, never an empty result, as the specification requires.

## Prompts

A bare server ships no prompts. Apps register their own workflows:

```nim
srv.prompts.add(
  Prompt(name: "tour_server",
    description: "Walk through everything this server offers.",
    arguments: @[]),
  proc(args: JsonNode): PromptResult =
    PromptResult(description: "Tour",
      messages: @[userMsg("Call `tools/list` first.")]))
```

They are user-controlled in the protocol's sense (a host offers them as slash
commands) and each returns one or more messages.

## Subscriptions

`subscriptions/listen` is implemented on every transport. The server sends
`notifications/subscriptions/acknowledged` with the subscription id before any
other notification, and only delivers the types a client asked for (see the
curl example above).

Because MCP is stateless, a subscription lives only as long as its request. The
client re-sends `subscriptions/listen` after a reconnect.

## Transports

All four are implemented on both sides, and the byte-stream ones share the
newline-delimited JSON framing, as the specification directs.

| Transport | Server | Client |
| - | - | - |
| stdio (subprocess) | `server/stdio.nim` | `client/spawn.nim` |
| Streamable HTTP | `server/http.nim` | `client/http.nim` |
| Unix domain socket | `server/stream.nim` | `client/stream.nim` |
| TCP | `server/stream.nim` | `client/stream.nim` |

Streamable HTTP also speaks SSE, hand-rolled in `server/sse.nim` because powpow
has no SSE helper and SSE cannot use `Content-Length`.

All logging goes to stderr in the example apps. stdout carries MCP messages
only, which the stdio binding requires.

## Tools

A bare server registers no tools. Apps add their own with precise JSON Schemas:

```nim
srv.registry.register("greet",
  "Greet someone by name.",
  objSchema(properties = props(
    ("name", stringProp("Who to greet.")))),
  proc(args: JsonNode): ToolResult =
    okResult("Hello, " & argStr(args, "name")))
```

Shared helpers live in `tools/load.nim` (`readSource` for inline source or
file path input with size bounds) and `tools/summary.nim` (bounded previews
and shallow JSON summaries).

### Error reporting

The specification distinguishes two failure modes, and this library keeps them
apart:

- **Protocol errors** (JSON-RPC `-32602` etc.) for malformed requests and
  unknown tool names.
- **Tool execution errors** (`isError: true`) for everything a model can fix:
  a bad argument or a bad document. These carry the failure message so the
  model can see where the problem is.

Handler exceptions are caught centrally in `tools/tool.nim`, so no tool needs its
own `try`/`except` and a handler failure can never take the connection down.

## Tests

```console
for t in tests/test_*.nim; do clue build "$t" --out:"bin/$(basename ${t%.nim})"; done
for t in bin/test_*; do "$t"; done
```

The round-trip suite spawns the example app binary (`examples/mcp_full_server`)
and drives it over every transport, which is the only way to catch
framing and connection bugs.

## Environment

| Variable | Effect |
| - | - |
| `DATCONTEXT_MAX_SOURCE_BYTES` | Cap on single tool inputs loaded via `readSource` (default 32 MiB) |

`fileRoot` is a constructor argument (`newMcpServer(fileRoot = ...)`),
not an environment variable. The example app reads `DATCONTEXT_FILE_ROOT`
as a convenience for its own `file://` root.

## A note on flysystem's containment

`datcontext` uses flysystem as its storage layer and policy engine, and holds
no path logic of its own: containment and read-side policy both live upstream,
in `securejoin` (descriptor-walk, no resolve-compare-operate gap) and
`FilesystemPolicy` (`checkAccess` on reads, filtering on queries). Three gaps
that used to live there are now fixed at the source, each pinned by tests in
both repos:

1. **Prefix confusion.** `resolvePath` used to compare with
   `resolved.startsWith(d.root)`, without a separator boundary, so a sibling
   like `root-backup` passed as inside `root`. The walk opens every component
   through a held parent descriptor, which makes prefix confusion
   inexpressible.
2. **Symlink escape.** Containment used to be lexical, so a link inside the
   root pointing outside it was served. Links now fail loudly at open time and
   are followed only via readlink-plus-re-walk when the target stays inside
   the drive; absolute targets are refused outright.
3. **Policy was not enforced on reads.** `read` used to call only `checkPath`,
   so `denyHiddenFiles` and the allowlists never fired for a read-only
   consumer. They now apply to every read-side accessor (`exists` still
   reports hidden files, matching its long-standing contract; listings filter
   them).

`tests/test_resources.nim` asserts the composed-stack guarantee end to end
(prefix sibling, symlink, hidden, and `..` all refused, legitimate reads
unaffected) so a flysystem regression fails loudly here.

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/openpeeps/datcontext/issues)
- 👋 Wanna help? [Fork it!](https://github.com/openpeeps/datcontext/fork)

### 🎩 License
MIT license. [Made by Humans from OpenPeeps](https://github.com/openpeeps).<br>
Copyright OpenPeeps & Contributors &mdash; All rights reserved.
