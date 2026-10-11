# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## JSON tools.
##
## JSON is the one format that yields `JsonNode` natively, so `parse_json` can
## return real structured content rather than a re-serialized string. `maxDepth`
## is threaded through because unbounded nesting is the one documented DoS vector
## in the format.

import openparser/json
import ../protocol/types
import ./[load, summary, tool]

proc jsonParse(input: string; maxDepth: int): JsonNode =
  ## Parse JSON with an optional depth bound.
  if maxDepth > 0:
    fromJson(input, JsonOptions(maxDepth: maxDepth))
  else:
    fromJson(input)

proc sourceSchema*(): JsonNode =
  ## The shared `source` / `path` argument pair used by every document tool.
  objSchema(
    properties= props(
      ("source", stringProp("The JSON document text.")),
      ("path", stringProp("Read the document from this file path instead."))),
    additionalProperties= true)

proc registerJson*(reg: ToolRegistry) =
  ## Register the JSON tools.
  reg.register("parse_json",
    "Parse a JSON document into a structure. Returns the canonical rendering " &
    "plus a structural summary (kind, keys, length).",
    objSchema(
      properties = props(
        ("source", stringProp("The JSON document text.")),
        ("path", stringProp("Read the document from this file path instead.")),
        ("maxDepth", intProp("Maximum nesting depth. 0 disables the bound."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let maxDepth = argInt(args, "maxDepth", 0)
      let node = jsonParse(src, maxDepth)
      okStructured($node, jsonSummary(node)),
    title = "Parse JSON",
    outputSchema = objSchema(
      properties = props(("kind", stringProp("JsonNode kind."))),
      additionalProperties = true))

  reg.register("normalize_json",
    "Canonicalize a JSON document: pretty-print with two-space indentation " &
    "while preserving key order. Idempotent, so re-running produces " &
    "identical output, which makes it useful for minimal-diff rewrites.",
    objSchema(
      properties = props(
        ("source", stringProp("The JSON document text.")),
        ("path", stringProp("Read the document from this file path instead."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let node = fromJson(src)
      # openparser's `JsonOptions.pretty` is not publicly settable and its
      # `toJson` ignores it, so pretty-printing uses std/json's `pretty`.
      okResult(pretty(node, indent = 2)),
    title = "Normalize JSON")

  reg.register("validate_json",
    "Validate a JSON document and report the first error with line and column.",
    objSchema(
      properties = props(
        ("source", stringProp("The JSON document text.")),
        ("path", stringProp("Read the document from this file path instead.")),
        ("maxDepth", intProp("Maximum nesting depth. 0 disables the bound."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let maxDepth = argInt(args, "maxDepth", 0)
      try:
        discard jsonParse(src, maxDepth)
      except CatchableError as e:
        # A tool execution error, not a protocol error: the model can fix it.
        return errResult("Invalid JSON: " & e.msg)
      okStructured("Valid JSON.", %*{"valid": true, "bytes": src.len}),
    title = "Validate JSON",
    outputSchema = objSchema(
      properties = props(
        ("valid", boolProp("Always true when reported.")),
        ("bytes", intProp("Input size in bytes.")))))