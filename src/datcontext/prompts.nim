# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Prompts.
##
## Prompts are user-controlled: the host decides when to offer one, and the
## server supplies the text. For a document parser the useful ones are workflows
## rather than single tool calls, since a model can already call the tools
## directly. Each prompt here names the tools it expects and states what to do
## with the result, which is the part a bare tool call cannot express.

import std/[strutils, sequtils]
import openparser/json
import ./protocol/errors
import ./tools/formats

type
  PromptArgument* = object
    name*: string
    description*: string
    required*: bool

  Prompt* = ref object
    ## A prompt definition for `prompts/list`.
    name*: string
    title*: string
    description*: string
    arguments*: seq[PromptArgument]

  PromptMessage* = object
    ## One message in a `prompts/get` result.
    role*: string       ## "user" or "assistant"
    text*: string

  PromptResult* = object
    ## What `prompts/get` returns.
    description*: string
    messages*: seq[PromptMessage]

  PromptResolver* = proc(args: JsonNode): PromptResult {.closure.}

  PromptEntry* = tuple[prompt: Prompt, resolve: PromptResolver]

  PromptRegistry* = ref object
    ## Ordered prompt storage.
    ##
    ## The resolver lives beside its definition in one seq rather than in a
    ## parallel Table: a Table lookup of a closure-typed value does not
    ## type-check, and keeping them together makes a half-registered prompt
    ## impossible.
    entries*: seq[PromptEntry]

proc newPromptRegistry*(): PromptRegistry =
  ## An empty registry.
  PromptRegistry(entries: @[])

proc add*(reg: PromptRegistry; p: Prompt; resolve: PromptResolver) =
  ## Register a prompt and its resolver, replacing any prompt of the same name
  ## while keeping its position.
  for i, e in reg.entries:
    if e.prompt.name == p.name:
      reg.entries[i] = (p, resolve)
      return
  reg.entries.add((p, resolve))

proc indexOf*(reg: PromptRegistry; name: string): int =
  ## Index of `name` in the registry, or -1 when absent.
  for i, e in reg.entries:
    if e.prompt.name == name:
      return i
  -1

proc has*(reg: PromptRegistry; name: string): bool =
  ## True when `name` is registered.
  reg.indexOf(name) >= 0

proc find*(reg: PromptRegistry; name: string): PromptEntry =
  ## Look up a prompt entry.
  ##
  ## Raises `-32602` when absent. Absence is signalled by exception rather than
  ## a sentinel tuple because `Prompt()` allocates a default instance rather than
  ## yielding nil, so a caller checking `entry.prompt != nil` would be wrong.
  let i = reg.indexOf(name)
  if i < 0:
    raise newMcpError(ecInvalidParams, "Unknown prompt: " & name)
  reg.entries[i]

proc len*(reg: PromptRegistry): int =
  ## Number of registered prompts.
  reg.entries.len

proc listJson*(reg: PromptRegistry): JsonNode =
  ## Render every prompt for `prompts/list`, in registration order.
  result = newJArray()
  for e in reg.entries:
    let p = e.prompt
    var o = newJObject()
    o["name"] = newJString(p.name)
    if p.title.len > 0: o["title"] = newJString(p.title)
    if p.description.len > 0: o["description"] = newJString(p.description)
    if p.arguments.len > 0:
      var args = newJArray()
      for a in p.arguments:
        var ao = newJObject()
        ao["name"] = newJString(a.name)
        if a.description.len > 0: ao["description"] = newJString(a.description)
        ao["required"] = newJBool(a.required)
        args.add(ao)
      o["arguments"] = args
    result.add(o)

proc argOf*(reg: PromptRegistry; args: JsonNode; name: string;
            required = true): string =
  ## Read a prompt argument.
  if args.isNil or args.kind != JObject:
    if required:
      raise newMcpError(ecInvalidParams, "missing prompt arguments")
    return ""
  let v = args{name}
  if v.isNil or v.kind != JString:
    if required:
      raise newMcpError(ecInvalidParams,
        "missing or non-string prompt argument: " & name)
    return ""
  v.getStr

proc validateArgs*(reg: PromptRegistry; name: string; args: JsonNode) =
  ## Check that every required argument is present.
  let p = reg.entries[reg.indexOf(name)].prompt
  for a in p.arguments:
    if a.required:
      discard reg.argOf(args, a.name, true)

proc resultJson*(r: PromptResult): JsonNode =
  ## Render a `PromptResult` for the wire.
  result = newJObject()
  if r.description.len > 0:
    result["description"] = newJString(r.description)
  var arr = newJArray()
  for m in r.messages:
    var o = newJObject()
    o["role"] = newJString(m.role)
    var content = newJObject()
    content["type"] = newJString("text")
    content["text"] = newJString(m.text)
    o["content"] = content
    arr.add(o)
  result["messages"] = arr

proc userMsg*(text: string): PromptMessage =
  ## A single user message.
  PromptMessage(role: "user", text: text)

proc formatList*(): string =
  ## A compact format list for prompt text.
  result = formats().mapIt(it.name).join(", ")

proc buildPromptRegistry*(): PromptRegistry =
  ## The standard prompt set.
  result = newPromptRegistry()
  # Resolvers are closures, and inside them `result` would refer to their own
  # PromptResult rather than the registry, so bind the registry to a local.
  let reg = result

  result.add(
    Prompt(name: "diagnose_document",
      title: "Diagnose a document",
      description: "Find out why a document will not parse, then fix it.",
      arguments: @[
        PromptArgument(name: "format", description: "The document format.",
                       required: true),
        PromptArgument(name: "source", description: "The document text.",
                       required: true),
      ]),
    proc(args: JsonNode): PromptResult =
      let fmt = reg.argOf(args, "format")
      let src = reg.argOf(args, "source")
      PromptResult(
        description: "Diagnose why this " & fmt & " document fails to parse",
        messages: @[userMsg(
          "This " & fmt & " document does not parse. Work through it in order:" &
          "\n\n1. Call `validate_" & fmt & "` on the source. It reports the " &
          "first error with a line and column and shows the offending text." &
          "\n2. Read the caret in the error output: it points at the exact " &
          "column that failed." &
          "\n3. If the error is about nesting, re-run with `maxDepth` raised, " &
          "since openparser bounds depth for some formats." &
          "\n4. If the format is wrong, call `list_formats` and pick the one " &
          "that actually matches." &
          "\n5. Once it parses, call `normalize_" & fmt & "` to canonicalize " &
          "it, so later edits produce a minimal diff." &
          "\n\nSource:" &
          "\n```" & fmt & "\n" & src & "\n```")]))

  result.add(
    Prompt(name: "convert_document",
      title: "Convert between formats",
      description: "Move a document from one format to another.",
      arguments: @[
        PromptArgument(name: "from", description: "Source format.",
                       required: true),
        PromptArgument(name: "to", description: "Target format.",
                       required: true),
        PromptArgument(name: "source", description: "The document text.",
                       required: true),
      ]),
    proc(args: JsonNode): PromptResult =
      let srcFmt = reg.argOf(args, "from")
      let dstFmt = reg.argOf(args, "to")
      let src = reg.argOf(args, "source")
      PromptResult(
        description: "Convert " & srcFmt & " to " & dstFmt,
        messages: @[userMsg(
          "Convert this document from " & srcFmt & " to " & dstFmt & "." &
          "\n\nopenparser does not have a universal transcode bus, so convert " &
          "in two hops and be explicit about which you use:" &
          "\n\n1. `parse_" & srcFmt & "` the source and take the canonical text." &
          "\n2. `parse_" & dstFmt & "` that text." &
          "\n3. `normalize_" & dstFmt & "` the result so the output is canonical." &
          "\n\nIf step 2 fails, say which construct has no equivalent in " &
          dstFmt & " rather than dropping it silently." &
          "\n\nSource:" &
          "\n```" & srcFmt & "\n" & src & "\n```")]))

  result.add(
    Prompt(name: "review_config",
      title: "Review a configuration file",
      description: "Check a config file and describe what it does.",
      arguments: @[
        PromptArgument(name: "format",
          description: "Config format: yaml, toml, json, or dotenv.",
          required: true),
        PromptArgument(name: "path",
          description: "Path to the config file.",
          required: true),
      ]),
    proc(args: JsonNode): PromptResult =
      let fmt = reg.argOf(args, "format")
      let path = reg.argOf(args, "path")
      PromptResult(
        description: "Review this " & fmt & " config",
        messages: @[userMsg(
          "Review the " & fmt & " config at " & path & "." &
          "\n\n1. `validate_" & fmt & "` it first; do not review a file that " &
          "does not parse." &
          "\n2. `parse_" & fmt & "` it to get the canonical structure and a " &
          "key summary." &
          "\n3. Report: what the file configures, any keys that look wrong or " &
          "contradict each other, and anything sensitive enough to move to an " &
          "environment variable." &
          "\n4. Quote the offending line for each finding so it can be found.")]))

  result.add(
    Prompt(name: "explain_parse_error",
      title: "Explain a parse error",
      description: "Turn a parser error into an actionable explanation.",
      arguments: @[
        PromptArgument(name: "format", description: "The document format.",
                       required: true),
        PromptArgument(name: "error", description: "The parser error text.",
                       required: true),
      ]),
    proc(args: JsonNode): PromptResult =
      let fmt = reg.argOf(args, "format")
      let err = reg.argOf(args, "error")
      PromptResult(
        description: "Explain this " & fmt & " parse error",
        messages: @[userMsg(
          "Explain this " & fmt & " parse error and how to fix it:" &
          "\n\n```\n" & err & "\n```" &
          "\n\nopenparser reports errors with a caret under the failing " &
          "column and a line:col pair. Use both." &
          "\n\n1. Point at the caret's column and quote the offending text." &
          "\n2. Say what the parser expected at that position in " & fmt & "." &
          "\n3. Give the minimal edit that fixes it." &
          "\n4. If the error is a nesting-depth limit, say so: only " &
          "json, yaml, toml, plist, and nif are depth-bounded in this " &
          "server, and the bound is raised with `maxDepth`.")]))

  result.add(
    Prompt(name: "select_parser",
      title: "Choose a parser",
      description: "Pick the right tool for an unfamiliar file.",
      arguments: @[
        PromptArgument(name: "path",
          description: "Path or description of the file.", required: true),
      ]),
    proc(args: JsonNode): PromptResult =
      let path = reg.argOf(args, "path")
      PromptResult(
        description: "Choose a parser for " & path,
        messages: @[userMsg(
          "Work out how to read " & path & "." &
          "\n\n1. Call `list_formats`. It returns every supported format with " &
          "its MIME type, and a `depthBounded` flag telling you whether a " &
          "nesting limit is enforced." &
          "\n2. Match the extension or content against those MIME types." &
          "\n3. If several fit, `validate_` each candidate and keep the ones " &
          "that pass." &
          "\n4. Report the single best tool and the runner-up, with the " &
          "evidence for each.")]))