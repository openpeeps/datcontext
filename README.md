<p align="center">
  <img src="https://github.com/openpeeps/PKG/blob/main/.github/logo.png" width="90px"><br>
  An MCP client and server that exposes openparser as tools,<br>over powpow transports. Written in Nim language
</p>

<p align="center">
  <code>nimble install datcontext</code>
</p>

<p align="center">
  <a href="https://openpeeps.github.io/datcontext">API reference</a><br>
  <img src="https://github.com/openpeeps/datcontext/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/openpeeps/datcontext/workflows/docs/badge.svg" alt="Github Actions">
</p>

## 😍 Key Features
- [x] Open Source | MIT License
- [x] Written in Nim language
- [x] Document parsing for language models through 36 tools covering JSON, YAML, TOML, XML, HTML, CSS, SVG, CSV, SQL, iCalendar, vCard, RSS, Atom, dotenv, plist, BSON and NIF, useful for letting an assistant read, check and convert config and data files directly
- [x] Scalar helpers for colors, UUIDs, paths, regular expressions and fuzzy search, useful for small validation and cleanup jobs without writing a parser
- [x] Generic parse, validate and normalize tools that work with any supported format, useful for format detection flows and for producing minimal diff rewrites
- [x] Four transports on both client and server (standard input/output, Streamable HTTP, Unix socket and TCP), useful for local subprocess use, web services and socket based agents
- [x] Dual era protocol support for the 2026-07-28 revision plus the legacy initialize handshake, useful for connecting current and older hosts without extra setup
- [x] Read side resources with per format samples and optional file backed resources, useful for giving a model safe context about available formats and project files
- [x] Five guided prompts for diagnosing documents, converting between formats, reviewing configs, explaining parse errors and picking a parser, useful as slash commands in MCP hosts
- [x] Notification subscriptions on every transport, useful for learning when the tool, resource or prompt catalogue changes
- [x] Usable as a Nim library for building custom servers and clients, useful for adding your own tools, resources and prompts on top of the stock set
- [x] Safe filesystem access backed by flysystem with read only policy, hidden file denial and containment checks, useful for exposing a project directory without risk of escape through parent paths, symlinks or sibling prefix tricks
- [x] Clear separation of protocol errors and model fixable tool errors with line, column and caret context, useful because a model can see exactly where a document broke

## Examples

Check what the server offers:

```console
$ datcontext tools | jq length
36
$ datcontext resources | jq length
1
$ datcontext prompts | jq length
5
```

Run it over your preferred transport:

```console
datcontext stdio               # speak MCP on stdin/stdout (default)
datcontext http 9000           # Streamable HTTP
datcontext unix /tmp/mcp.sock  # Unix domain socket
datcontext tcp 9001            # TCP
datcontext tools               # print the tool catalogue as JSON
```

Point a host at it with:

```json
{ "mcpServers": { "datcontext": { "command": "datcontext", "args": ["stdio"] } } }
```

Use it as a library, server side:

```nim
import datcontext/server/core

let srv = newMcpServer()
discard srv.listTools()  # 36 tools, registration order preserved
```

Call a tool over HTTP, client side:

```nim
import datcontext/client/[core, http]

let c = connectHttp("http://127.0.0.1:9000")
doAssert c.probe() == "modern"
let reply = c.callTool("parse_yaml", %*{"source": "a: 1"})
```

Read a resource and fetch a prompt:

```nim
import flysystem

let srv = newMcpServer(fileRoot = "/srv/data")
let formats = srv.resources.read("datcontext://formats")
let prompt = srv.prompts.find("select_parser").resolve(%*{"path": "a.ron"})

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

`datcontext` turns a document parser into something a language model can call.
36 tools cover JSON, YAML, TOML, XML, HTML, CSS, SVG, CSV, SQL, iCalendar,
vCard, RSS, Atom, dotenv, plist, BSON, and NIF, plus scalar helpers for colors,
UUIDs, paths, regular expressions, and fuzzy search. Alongside them it serves
resources, prompts, and notification subscriptions.

It targets the **2026-07-28** revision of the MCP specification and is
dual era: it serves modern stateless requests and also answers the legacy
`initialize` handshake, so current and older hosts both connect.

## Install

Built with [clue](https://github.com/openpeeps/clue). Both dependencies are
`clue develop` symlinks, so clue resolves them as local develop paths.

```console
clue build src/datcontext.nim --out:bin/datcontext
```

## Run

```console
datcontext stdio               # speak MCP on stdin/stdout (default)
datcontext http [port]         # Streamable HTTP (default 9000)
datcontext unix <path>         # Unix domain socket
datcontext tcp <port>          # TCP
datcontext tools               # print the tool catalogue as JSON
```

All logging goes to stderr. stdout carries MCP messages only, which the stdio
binding requires.

## Resources

Read-side context, URI-addressed. Enabled by default:

- `datcontext://formats` (the format table as JSON)
- `datcontext://formats/{format}/sample` (a minimal valid document per format)

Filesystem resources are **off by default**. Set `DATCONTEXT_FILE_ROOT` to serve
`file://` URIs from under a directory:

```console
DATCONTEXT_FILE_ROOT=~/project datcontext stdio
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

Five workflows, each naming the tools it expects:

`diagnose_document`, `convert_document`, `review_config`, `explain_parse_error`,
`select_parser`.

They are user-controlled in the protocol's sense (a host offers them as slash
commands) and each returns a single user message.

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

## Tools

Format-specific tools (`parse_yaml`, `validate_toml`, ...) carry precise JSON
Schemas. Four generic tools work with any supported format:

- `list_formats` (every format, with MIME type and whether a depth bound exists)
- `parse` (parse and canonically render)
- `validate` (report the first error with line and column)
- `normalize` (idempotent canonical output, useful for minimal-diff rewrites)

### Error reporting

The specification distinguishes two failure modes, and this server keeps them
apart:

- **Protocol errors** (JSON-RPC `-32602` etc.) for malformed requests and
  unknown tool names.
- **Tool execution errors** (`isError: true`) for everything a model can fix:
  a bad argument, an unparseable document. These carry openparser's caret
  context so the model can see where the problem is.

Handler exceptions are caught centrally in `tools/tool.nim`, so no tool needs its
own `try`/`except` and a parser failure can never take the connection down.

## Tests

```console
clue build src/datcontext.nim --out:bin/datcontext
for t in tests/test_*.nim; do clue build "$t" --out:"bin/$(basename ${t%.nim})"; done
for t in bin/test_*; do "$t"; done
```

260 tests across eight files, all passing. The round-trip suite spawns the real
binary and drives it over every transport, which is the only way to catch
framing and connection bugs.

## Environment

| Variable | Effect |
| - | - |
| `DATCONTEXT_MAX_SOURCE_BYTES` | Cap on any single parsed document (default 32 MiB) |
| `DATCONTEXT_FILE_ROOT` | Enable `file://` resources under this directory (flysystem-backed) |

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
