# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Format registration and the generic `list_formats` / `parse` tools.
##
## Each `fmt_*.nim` module exposes `register*(reg: ToolRegistry)` and is imported
## here. Importing all of them together is safe: openparser's format modules
## export no colliding names, which `tests/probe_imports.nim` verifies by
## calling one entry point per format in a single compilation unit.
##
## The generic tools sit alongside the per-format ones. A model that knows it
## wants TOML can call `parse_toml` and get a precise schema; a model working
## from an unknown format can call `parse` with a `format` argument and get the
## same behaviour without the server enumerating a tool per format.

import std/[sequtils, strutils]
import openparser/json
import openparser/toml
import openparser/sql
import openparser/css
import openparser/svg
import openparser/xml
import openparser/html
import openparser/yaml
import ./[fmt_data, fmt_json, fmt_markup, fmt_toml, fmt_yaml, load, summary, tool]

type
  FormatSpec* = object
    ## One format the generic tools understand.
    name*: string
    mimeType*: string
    description*: string
    depthBounded*: bool
    ## True when openparser exposes a depth bound for this format.
    render*: proc(src: string; maxDepth: int): string

proc jsonRender*(src: string; maxDepth: int): string =
  if maxDepth > 0:
    $fromJson(src, JsonOptions(maxDepth: maxDepth))
  else:
    $fromJson(src)

proc yamlRender*(src: string; maxDepth: int): string =
  discard maxDepth
  dump(parseYamlNode(src))

proc tomlRender*(src: string; maxDepth: int): string =
  discard maxDepth
  dumpToml(parseToml(src))

proc xmlRender*(src: string; maxDepth: int): string =
  discard maxDepth
  toXml(fromXml(src))

proc htmlRender*(src: string; maxDepth: int): string =
  discard maxDepth
  innerText(parseHtml(src))

proc cssRender*(src: string; maxDepth: int): string =
  discard maxDepth
  $parseCss(src).nodes.len & " top-level rules"

proc svgRender*(src: string; maxDepth: int): string =
  discard maxDepth
  toSvg(parseSvg(src))

proc sqlRender*(src: string; maxDepth: int): string =
  discard maxDepth
  $parseSql(src)

proc formats*(): seq[FormatSpec] =
  ## Every format the generic `parse` tool accepts.
  ##
  ## `depthBounded` reports honestly whether openparser enforces a nesting bound
  ## for the format: only JSON and YAML do. TOML, XML, HTML, CSS, SVG, and SQL
  ## rely on the source-size ceiling instead.
  result = @[
    FormatSpec(name: "json", mimeType: "application/json",
      description: "JSON", depthBounded: true, render: jsonRender),
    FormatSpec(name: "yaml", mimeType: "application/yaml",
      description: "YAML 1.2.2", depthBounded: true, render: yamlRender),
    FormatSpec(name: "toml", mimeType: "application/toml",
      description: "TOML v1.0", depthBounded: false, render: tomlRender),
    FormatSpec(name: "xml", mimeType: "application/xml",
      description: "XML", depthBounded: false, render: xmlRender),
    FormatSpec(name: "html", mimeType: "text/html",
      description: "HTML5", depthBounded: false, render: htmlRender),
    FormatSpec(name: "css", mimeType: "text/css",
      description: "CSS", depthBounded: false, render: cssRender),
    FormatSpec(name: "svg", mimeType: "image/svg+xml",
      description: "SVG", depthBounded: false, render: svgRender),
    FormatSpec(name: "sql", mimeType: "application/sql",
      description: "SQL", depthBounded: false, render: sqlRender),
  ]

proc findFormat*(name: string): FormatSpec =
  ## Look up a format spec by name, case-insensitively.
  for f in formats():
    if f.name == name.toLowerAscii:
      return f

proc registerGeneric*(reg: ToolRegistry) =
  ## Register the format-agnostic tools.
  reg.register("list_formats",
    "List every document format this server can parse, with its MIME type, " &
    "description, and whether a nesting-depth bound is available.",
    objSchema(properties = %*{}),
    proc(args: JsonNode): ToolResult =
      var arr = newJArray()
      for f in formats():
        var o = newJObject()
        o["name"] = newJString(f.name)
        o["mimeType"] = newJString(f.mimeType)
        o["description"] = newJString(f.description)
        o["depthBounded"] = newJBool(f.depthBounded)
        arr.add(o)
      var summaryNode = newJObject()
      summaryNode["count"] = newJInt(arr.len)
      summaryNode["formats"] = arr
      okStructured($arr.len & " formats supported: " &
        formats().mapIt(it.name).join(", "), summaryNode),
    title = "List formats",
    outputSchema = objSchema(
      properties = %*{
        "count": intProp("Number of supported formats."),
        "formats": arrayProp("Per-format metadata.")
      }))

  reg.register("parse",
    "Parse a document in any supported format and return its canonical " &
    "rendering. Prefer a format-specific tool (parse_yaml, parse_toml, ...) " &
    "when you already know the format; call list_formats for the full set.",
    objSchema(
      properties = %*{
        "format": stringProp("Format name, e.g. json, yaml, toml, xml, sql."),
        "source": stringProp("The document text."),
        "path": stringProp("Read the document from this file path instead."),
        "maxDepth": intProp("Maximum nesting depth. Only honoured by formats " &
                            "reporting depthBounded.")
      },
      required = @["format"]),
    proc(args: JsonNode): ToolResult =
      let fmtName = argStr(args, "format")
      let spec = findFormat(fmtName)
      if spec.render == nil:
        var available = newJArray()
        for f in formats():
          available.add(newJString(f.name))
        return errResult("Unknown format: " & fmtName &
          ". Supported formats: " & $available)
      let src = readSource(args)
      let maxDepth = argInt(args, "maxDepth", 0)
      let rendered = spec.render(src, maxDepth)
      var summaryNode = newJObject()
      summaryNode["format"] = newJString(spec.name)
      summaryNode["bytes"] = newJInt(src.len)
      summaryNode["rendered"] = newJString(preview(rendered))
      okStructured(rendered, summaryNode),
    title = "Parse document")

  reg.register("validate",
    "Validate a document in any supported format, reporting the first error " &
    "with line and column.",
    objSchema(
      properties = %*{
        "format": stringProp("Format name, e.g. json, yaml, toml, xml."),
        "source": stringProp("The document text."),
        "path": stringProp("Read the document from this file path instead."),
        "maxDepth": intProp("Maximum nesting depth.")
      },
      required = @["format"]),
    proc(args: JsonNode): ToolResult =
      let fmtName = argStr(args, "format")
      let spec = findFormat(fmtName)
      if spec.render == nil:
        return errResult("Unknown format: " & fmtName)
      let src = readSource(args)
      let maxDepth = argInt(args, "maxDepth", 0)
      try:
        discard spec.render(src, maxDepth)
      except CatchableError as e:
        return errResult("Invalid " & spec.description & ": " & e.msg)
      okStructured("Valid " & spec.description & ".",
                   %*{"valid": true, "format": spec.name, "bytes": src.len}),
    title = "Validate document")

  reg.register("normalize",
    "Canonicalize a document in any supported format. Output is idempotent, so " &
    "re-running produces byte-identical text, which makes it useful for " &
    "minimal-diff rewrites.",
    objSchema(
      properties = %*{
        "format": stringProp("Format name, e.g. json, yaml, toml."),
        "source": stringProp("The document text."),
        "path": stringProp("Read the document from this file path instead."),
        "maxDepth": intProp("Maximum nesting depth.")
      },
      required = @["format"]),
    proc(args: JsonNode): ToolResult =
      let fmtName = argStr(args, "format")
      let spec = findFormat(fmtName)
      if spec.render == nil:
        return errResult("Unknown format: " & fmtName)
      let src = readSource(args)
      let maxDepth = argInt(args, "maxDepth", 0)
      okResult(spec.render(src, maxDepth)),
    title = "Normalize document")

proc registerAll*(reg: ToolRegistry) =
  ## Register every openparser-backed tool.
  reg.registerJson()
  reg.registerYaml()
  reg.registerToml()
  reg.registerXml()
  reg.registerHtml()
  reg.registerCss()
  reg.registerSvg()
  reg.registerCsv()
  reg.registerSql()
  reg.registerIcal()
  reg.registerVcard()
  reg.registerRss()
  reg.registerAtom()
  reg.registerDotenv()
  reg.registerPlist()
  reg.registerBson()
  reg.registerNif()
  reg.registerScalar()
  reg.registerGeneric()