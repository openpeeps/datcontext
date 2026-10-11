# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## YAML tools.
##
## YAML's AST has no `JsonNode` bridge in openparser's public API, so `parse_yaml`
## returns the canonical dump as text. `maxDepth` is threaded through since
## openparser's YAML options expose it.

import openparser/json
import openparser/yaml
import ./[load, tool]

proc yamlOptions*(maxDepth: int; dupKeys = true): YamlOptions =
  ## Build YAML options, or nil when the defaults suffice.
  if maxDepth > 0 or not dupKeys:
    result = YamlOptions(maxDepth: maxDepth, allowDuplicateKeys: dupKeys)
  else:
    result = nil

proc registerYaml*(reg: ToolRegistry) =
  ## Register the YAML tools.
  reg.register("parse_yaml",
    "Parse a YAML document and return its canonical rendering. " &
    "Use parse_yaml_stream for multi-document sources.",
    objSchema(
      properties = props(
        ("source", stringProp("The YAML document text.")),
        ("path", stringProp("Read the document from this file path instead.")),
        ("maxDepth", intProp("Maximum nesting depth. 0 disables the bound.")),
        ("allowDuplicateKeys",
          boolProp("Permit duplicate mapping keys. Defaults to true."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let maxDepth = argInt(args, "maxDepth", 0)
      let dupKeys = argBool(args, "allowDuplicateKeys", true)
      okResult(dump(parseYamlNode(src, yamlOptions(maxDepth, dupKeys)))),
    title = "Parse YAML")

  reg.register("parse_yaml_stream",
    "Parse a multi-document YAML stream and return every document's canonical " &
    "rendering, separated by the --- document marker.",
    objSchema(
      properties = props(
        ("source", stringProp("The YAML stream text.")),
        ("path", stringProp("Read the stream from this file path instead.")),
        ("maxDepth", intProp("Maximum nesting depth. 0 disables the bound."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let maxDepth = argInt(args, "maxDepth", 0)
      let docs = parseYamlStream(src, yamlOptions(maxDepth))
      var summaryNode = newJObject()
      summaryNode["documentCount"] = newJInt(docs.len)
      var arr = newJArray()
      var text = ""
      for i, d in docs:
        let rendered = dump(d)
        arr.add(newJString(rendered))
        if i > 0: text.add("---\n")
        text.add(rendered)
      summaryNode["documents"] = arr
      okStructured(text, summaryNode),
    title = "Parse YAML stream",
    outputSchema = objSchema(
      properties = props(
        ("documentCount", intProp("Number of documents in the stream.")),
        ("documents", arrayProp("Canonical rendering of each document.")))))

  reg.register("normalize_yaml",
    "Canonicalize a YAML document: re-emit with consistent indentation and " &
    "quoting so equivalent documents render identically. Idempotent.",
    objSchema(
      properties = props(
        ("source", stringProp("The YAML document text.")),
        ("path", stringProp("Read the document from this file path instead.")),
        ("maxDepth", intProp("Maximum nesting depth. 0 disables the bound."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let maxDepth = argInt(args, "maxDepth", 0)
      okResult(dump(parseYamlNode(src, yamlOptions(maxDepth)))),
    title = "Normalize YAML")

  reg.register("parse_yaml_frontmatter",
    "Extract the --- delimited YAML frontmatter from a document, returning " &
    "the header and the remaining body separately.",
    objSchema(
      properties = props(
        ("source", stringProp("The document text.")),
        ("path", stringProp("Read the document from this file path instead."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let fm = splitFrontmatter(src)
      var summaryNode = newJObject()
      summaryNode["found"] = newJBool(fm.found)
      summaryNode["frontmatter"] = newJString(fm.frontmatter)
      summaryNode["body"] = newJString(fm.body)
      summaryNode["bodyOffset"] = newJInt(fm.bodyOffset)
      okStructured(fm.body, summaryNode),
    title = "Parse YAML frontmatter",
    outputSchema = objSchema(
      properties = props(
        ("found", boolProp("Whether a frontmatter block was present.")),
        ("frontmatter", stringProp("The raw frontmatter text.")),
        ("body", stringProp("The remaining document body.")),
        ("bodyOffset", intProp("Byte offset where the body starts.")))))

  reg.register("validate_yaml",
    "Validate a YAML document and report the first error with line and column.",
    objSchema(
      properties = props(
        ("source", stringProp("The YAML document text.")),
        ("path", stringProp("Read the document from this file path instead.")),
        ("maxDepth", intProp("Maximum nesting depth. 0 disables the bound."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let maxDepth = argInt(args, "maxDepth", 0)
      try:
        discard parseYamlNode(src, yamlOptions(maxDepth))
      except CatchableError as e:
        return errResult("Invalid YAML: " & e.msg)
      okStructured("Valid YAML.", %*{"valid": true, "bytes": src.len}),
    title = "Validate YAML",
    outputSchema = objSchema(
      properties = props(
        ("valid", boolProp("Always true when reported.")),
        ("bytes", intProp("Input size in bytes.")))))