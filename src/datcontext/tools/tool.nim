# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Tool definitions and the registry that backs `tools/list` and `tools/call`.
##
## A tool is a name, a description, a JSON Schema, and a handler. Handlers
## receive arguments and return a `ToolResult`, which separates the two failure
## modes the specification distinguishes: a protocol error (raised via
## `McpError`) versus a tool execution error (`isError: true`, which the model
## can act on and retry).

import std/[strutils, tables]
import openparser/json
import ../protocol/[errors, types]

type
  ToolHandler* = proc(args: JsonNode): ToolResult {.closure.}

  Tool* = ref object
    ## A single model-callable tool.
    name*: string
    title*: string
    description*: string
    inputSchema*: JsonNode
    outputSchema*: JsonNode
    annotations*: JsonNode
    handler*: ToolHandler
    ## When true the tool reads the filesystem. The specification requires a
    ## human to be able to see and deny such calls, so servers surface this in
    ## `annotations`.
    sideEffecting*: bool

  ToolResult* = ref object
    ## What a handler returns.
    content*: seq[Content]
    structuredContent*: JsonNode
    isError*: bool

const
  AnnotationReadOnly* = "readOnly"
  AnnotationDestructive* = "destructiveHint"
  AnnotationIdempotent* = "idempotentHint"
  AnnotationOpenWorld* = "openWorldHint"

proc okResult*(text: string): ToolResult =
  ## A successful single-text-block result.
  ToolResult(content: @[textContent(text)])

proc okStructured*(text: string; structured: JsonNode): ToolResult =
  ## A successful result carrying both a text block and structured content.
  ##
  ## The specification recommends that a tool returning structured content also
  ## return the serialized JSON as a text block, which this satisfies.
  ToolResult(content: @[textContent(text)], structuredContent: structured)

proc errResult*(text: string): ToolResult =
  ## A tool execution error.
  ##
  ## Model-visible by design: input validation failures and parse errors belong
  ## here rather than in a protocol error, so the model can self-correct.
  ToolResult(content: @[textContent(text)], isError: true)

# ── JSON Schema construction ─────────────────────────────────────────────────
# `%*{...}` cannot be used for schema properties: the object-literal macro only
# accepts literals, and every property here is built by a proc.

proc objSchema*(properties: JsonNode = nil; required: seq[string] = @[];
                additionalProperties = false): JsonNode =
  ## Build a JSON Schema 2020-12 object schema.
  result = newJObject()
  result["type"] = newJString("object")
  result["properties"] = if properties.isNil: newJObject() else: properties
  if required.len > 0:
    var req = newJArray()
    for r in required:
      req.add(newJString(r))
    result["required"] = req
  result["additionalProperties"] = newJBool(additionalProperties)

proc props*(fields: varargs[(string, JsonNode)]): JsonNode =
  ## Build a `properties` map from `(name, schema)` pairs.
  result = newJObject()
  for f in fields:
    result[f[0]] = f[1]

proc stringProp*(description: string; defaultValue = ""): JsonNode =
  ## A string property schema.
  result = newJObject()
  result["type"] = newJString("string")
  if description.len > 0:
    result["description"] = newJString(description)
  if defaultValue.len > 0:
    result["default"] = newJString(defaultValue)

proc boolProp*(description: string; defaultValue = false): JsonNode =
  ## A boolean property schema.
  result = newJObject()
  result["type"] = newJString("boolean")
  if description.len > 0:
    result["description"] = newJString(description)
  result["default"] = newJBool(defaultValue)

proc intProp*(description: string; defaultValue = 0): JsonNode =
  ## An integer property schema.
  result = newJObject()
  result["type"] = newJString("integer")
  if description.len > 0:
    result["description"] = newJString(description)
  result["default"] = newJInt(defaultValue)

proc arrayProp*(description: string; items: JsonNode = nil): JsonNode =
  ## An array property schema.
  result = newJObject()
  result["type"] = newJString("array")
  if description.len > 0:
    result["description"] = newJString(description)
  result["items"] = if items.isNil: newJObject() else: items

proc enumProp*(description: string; values: openArray[string]): JsonNode =
  ## A string property constrained to a fixed set of values.
  result = newJObject()
  result["type"] = newJString("string")
  if description.len > 0:
    result["description"] = newJString(description)
  var arr = newJArray()
  for v in values:
    arr.add(newJString(v))
  result["enum"] = arr

proc renderTool*(t: Tool): JsonNode =
  ## Render a tool definition for `tools/list`.
  ##
  ## `inputSchema` MUST be a valid JSON Schema object, never null. Tools with
  ## no parameters use `{"type":"object","additionalProperties":false}`.
  result = newJObject()
  result["name"] = newJString(t.name)
  if t.title.len > 0:
    result["title"] = newJString(t.title)
  if t.description.len > 0:
    result["description"] = newJString(t.description)
  result["inputSchema"] =
    if t.inputSchema.isNil: objSchema() else: t.inputSchema
  if not t.outputSchema.isNil:
    result["outputSchema"] = t.outputSchema
  if not t.annotations.isNil:
    result["annotations"] = t.annotations

# ── Registry ─────────────────────────────────────────────────────────────────

type
  ToolRegistry* = ref object
    ## Ordered tool storage. `tools/list` must return a deterministic order so
    ## clients can cache the list and so tools stay stable in the model's
    ## prompt cache, so insertion order is preserved rather than sorted.
    tools*: OrderedTable[string, Tool]

proc newRegistry*(): ToolRegistry =
  ## An empty registry.
  ToolRegistry(tools: initOrderedTable[string, Tool]())

proc guard*(handler: ToolHandler): ToolHandler =
  ## Wrap a handler so no exception escapes it.
  ##
  ## openparser raises a distinct `CatchableError` per format, and a tool that
  ## failed to anticipate one would take the connection down instead of telling
  ## the model what went wrong. Wrapping centrally means a handler can just
  ## parse and let the failure become a tool execution error, which is what the
  ## specification wants: a self-correctable error the model can act on, not a
  ## protocol error.
  result = proc(args: JsonNode): ToolResult =
    try:
      handler(args)
    except McpError as e:
      # Argument-shape failures are model-recoverable too.
      errResult(e.msg)
    except CatchableError as e:
      errResult(e.msg)

proc register*(reg: ToolRegistry; tool: Tool) =
  ## Add or replace `tool`. Replacing keeps the original position so ordering
  ## stays stable across updates.
  reg.tools[tool.name] = tool

proc register*(reg: ToolRegistry; name, description: string;
               inputSchema: JsonNode; handler: ToolHandler;
               title = ""; outputSchema: JsonNode = nil;
               sideEffecting = false) =
  ## Convenience registration without building a `Tool` by hand.
  ##
  ## The handler is wrapped in `guard`, so a tool never needs its own try/except
  ## around parser calls.
  reg.register(Tool(
    name: name,
    title: title,
    description: description,
    inputSchema: inputSchema,
    outputSchema: outputSchema,
    handler: guard(handler),
    sideEffecting: sideEffecting
  ))

proc get*(reg: ToolRegistry; name: string): Tool =
  ## Look up a tool, or nil when absent.
  if name notin reg.tools:
    return nil
  reg.tools[name]

proc has*(reg: ToolRegistry; name: string): bool =
  ## True when `name` is registered.
  name in reg.tools

proc len*(reg: ToolRegistry): int =
  ## Number of registered tools.
  reg.tools.len

proc names*(reg: ToolRegistry): seq[string] =
  ## Registered names in insertion order.
  result = @[]
  for k in reg.tools.keys:
    result.add(k)

proc listJson*(reg: ToolRegistry): JsonNode =
  ## Render every tool for `tools/list`, in registration order.
  result = newJArray()
  for k in reg.tools.keys:
    result.add(renderTool(reg.tools[k]))

proc call*(reg: ToolRegistry; name: string; args: JsonNode): ToolResult =
  ## Invoke a registered tool.
  ##
  ## Raises `McpError` with `-32602` for an unknown tool name, which the
  ## specification classifies as a protocol error rather than a tool error.
  let tool = reg.get(name)
  if tool.isNil:
    raise newMcpError(ecInvalidParams, "Unknown tool: " & name)
  let a = if args.isNil or args.kind != JObject: newJObject() else: args
  tool.handler(a)

# ── Argument access ──────────────────────────────────────────────────────────
# Handlers validate their own arguments. A bad shape raises `McpError` with
# `ecInvalidParams`; the dispatch layer reports it to the model as a tool
# execution error so the model can correct itself.
#
# These are `func` rather than templates so they can be `gcsafe`: tool handlers
# are invoked from powpow's `OnRequestCallback`, which is `gcsafe`, so the whole
# call path has to be too.

func argStr*(args: JsonNode; key: string; required = true): string =
  ## Read a required string argument.
  let v = args{key}
  if v.isNil or v.kind != JString:
    if required:
      raise newMcpError(ecInvalidParams,
        "missing or non-string argument: " & key)
    ""
  else:
    v.getStr

func argStrOr*(args: JsonNode; key, default: string): string =
  ## Read a string argument, falling back to `default`.
  let v = args{key}
  if v.isNil or v.kind != JString: default else: v.getStr

func argBool*(args: JsonNode; key: string; default = false): bool =
  ## Read a boolean argument, coercing string and integer forms.
  let v = args{key}
  if v.isNil: default
  elif v.kind == JBool: v.getBool
  elif v.kind == JInt: v.getInt != 0
  elif v.kind == JString:
    v.getStr.len == 4 and cmpIgnoreCase(v.getStr, "true") == 0
  else: default

func parseIntSafe*(s: string; fallback: int): int =
  ## A `gcsafe` integer parse that never raises.
  if s.len == 0: return fallback
  var neg = false
  var i = 0
  if s[0] == '-':
    neg = true
    i = 1
  elif s[0] == '+':
    i = 1
  if i >= s.len: return fallback
  var acc = 0
  while i < s.len:
    if s[i] < '0' or s[i] > '9': return fallback
    acc = acc * 10 + (ord(s[i]) - ord('0'))
    if acc > high(int) div 10: return fallback
    inc i
  if neg: -acc else: acc

func argInt*(args: JsonNode; key: string; default = 0): int =
  ## Read an integer argument, coercing string and float forms.
  let v = args{key}
  if v.isNil: default
  elif v.kind == JInt: v.getInt.int
  elif v.kind == JFloat: v.getFloat.int
  elif v.kind == JString: parseIntSafe(v.getStr, default)
  else: default
