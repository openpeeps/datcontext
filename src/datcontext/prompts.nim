# datcontext — generic MCP building blocks over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Prompts.
##
## Prompts are user-controlled: the host decides when to offer one, and the
## server supplies the text. A bare server ships no prompts; higher-level apps
## register their own workflows via `add`, since only the app knows which
## tools its prompts should name.

import openparser/json
import ./protocol/errors

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

proc buildPromptRegistry*(): PromptRegistry =
  ## The standard prompt set: empty.
  ##
  ## Higher-level apps add their own prompts on top, since prompt text
  ## names app-specific tools and workflows.
  newPromptRegistry()