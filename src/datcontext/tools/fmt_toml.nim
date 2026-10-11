# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## TOML tools.
##
## `dateRaw` is preserved when dumping, which keeps the UTC offset and fractional
## seconds that `std/times` cannot hold, so round-tripping through
## `normalize_toml` is lossless for TOML's four date/time types.

import std/tables
import openparser/json
import openparser/toml
import ./[load, tool]

proc tomlSummary*(doc: TomlDocument): JsonNode =
  ## Top-level key names plus nested table summaries, giving the model document
  ## shape without dumping every value.
  result = newJObject()
  result["kind"] = newJString("table")
  result["keyCount"] = newJInt(doc.tableVal.len)
  var keys = newJArray()
  var tables = newJArray()
  for k, v in doc.tableVal:
    keys.add(newJString(k))
    if v.kind == tvkTable:
      var t = newJObject()
      t["key"] = newJString(k)
      t["keyCount"] = newJInt(v.tableVal.len)
      tables.add(t)
  result["keys"] = keys
  result["tables"] = tables

proc registerToml*(reg: ToolRegistry) =
  ## Register the TOML tools.
  reg.register("parse_toml",
    "Parse a TOML document and return its canonical rendering, plus a summary " &
    "of its top-level keys and nested tables.",
    objSchema(
      properties = props(
        ("source", stringProp("The TOML document text.")),
        ("path", stringProp("Read the document from this file path instead."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let doc = parseToml(src)
      okStructured(dumpToml(doc), tomlSummary(doc)),
    title = "Parse TOML",
    outputSchema = objSchema(
      properties = props(
        ("kind", stringProp("Always table for a TOML document.")),
        ("keyCount", intProp("Number of top-level keys.")),
        ("keys", arrayProp("Top-level key names.")),
        ("tables", arrayProp("Nested table summaries.")))))

  reg.register("normalize_toml",
    "Canonicalize a TOML document: re-emit with consistent ordering and " &
    "spacing. Preserves date literals exactly. Idempotent.",
    objSchema(
      properties = props(
        ("source", stringProp("The TOML document text.")),
        ("path", stringProp("Read the document from this file path instead."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      okResult(dumpToml(parseToml(src))),
    title = "Normalize TOML")

  reg.register("validate_toml",
    "Validate a TOML document against TOML v1.0 and report the first error " &
    "with line and column.",
    objSchema(
      properties = props(
        ("source", stringProp("The TOML document text.")),
        ("path", stringProp("Read the document from this file path instead."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      try:
        discard parseToml(src)
      except CatchableError as e:
        return errResult("Invalid TOML: " & e.msg)
      okStructured("Valid TOML.", %*{"valid": true, "bytes": src.len}),
    title = "Validate TOML",
    outputSchema = objSchema(
      properties = props(
        ("valid", boolProp("Always true when reported.")),
        ("bytes", intProp("Input size in bytes.")))))