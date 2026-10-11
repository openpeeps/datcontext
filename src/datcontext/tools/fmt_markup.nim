# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## XML, HTML, CSS, and SVG tools.
##
## These four live together because they are all markup and all share the same
## lenient-versus-strict policy shape. Note that openparser exposes a depth bound
## for JSON, YAML, TOML, plist, and NIF but for none of these four, so
## `DATCONTEXT_MAX_SOURCE_BYTES` is the only ceiling on nesting here.

import std/tables
import openparser/json
import openparser/xml
import openparser/html
import openparser/css
import openparser/svg
import ../protocol/types
import ./[load, summary, tool]

proc registerXml*(reg: ToolRegistry) =
  ## Register the XML tools.
  reg.register("parse_xml",
    "Parse an XML document into a DOM tree and return its canonical " &
    "serialization, plus the root element's tag, attribute count, and child " &
    "count.",
    objSchema(
      properties = props(
        ("source", stringProp("The XML document text.")),
        ("path", stringProp("Read the document from this file path instead.")),
        ("strict", boolProp("Reject close-tag mismatches instead of recovering."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let strict = argBool(args, "strict", false)
      let node = fromXml(src, XmlOptions(
        policy: if strict: xpStrict else: xpLenient))
      var summaryNode = newJObject()
      summaryNode["kind"] = newJString($node.kind)
      if node.kind == xnElement:
        summaryNode["rootTag"] = newJString(node.tag)
        summaryNode["attributeCount"] = newJInt(len(node.attrs))
        summaryNode["childCount"] = newJInt(node.children.len)
      okStructured(toXml(node), summaryNode),
    title = "Parse XML",
    outputSchema = objSchema(
      properties = props(
        ("kind", stringProp("The root node kind.")),
        ("rootTag", stringProp("The root element tag name.")),
        ("attributeCount", intProp("Attributes on the root element.")),
        ("childCount", intProp("Children of the root element.")))))

  reg.register("validate_xml",
    "Validate XML well-formedness and report the first error with line and " &
    "column. Strict mode also rejects close-tag mismatches.",
    objSchema(
      properties = props(
        ("source", stringProp("The XML document text.")),
        ("path", stringProp("Read the document from this file path instead.")),
        ("strict", boolProp("Reject close-tag mismatches. Defaults to true."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let strict = argBool(args, "strict", true)
      try:
        discard fromXml(src, XmlOptions(
          policy: if strict: xpStrict else: xpLenient))
      except CatchableError as e:
        return errResult("Invalid XML: " & e.msg)
      okStructured("Valid XML.", %*{"valid": true, "bytes": src.len}),
    title = "Validate XML",
    outputSchema = objSchema(
      properties = props(
        ("valid", boolProp("Always true when reported.")),
        ("bytes", intProp("Input size in bytes.")))))

proc registerHtml*(reg: ToolRegistry) =
  ## Register the HTML tools.
  reg.register("parse_html",
    "Parse an HTML document and return its extracted visible text. Markup, " &
    "comments, and script/style content are discarded.",
    objSchema(
      properties = props(
        ("source", stringProp("The HTML document text.")),
        ("path", stringProp("Read the document from this file path instead."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let text = innerText(parseHtml(src))
      var summaryNode = newJObject()
      summaryNode["textLength"] = newJInt(text.len)
      summaryNode["bytes"] = newJInt(src.len)
      okStructured(text, summaryNode),
    title = "Parse HTML",
    outputSchema = objSchema(
      properties = props(
        ("textLength", intProp("Length of the extracted text.")),
        ("bytes", intProp("Input size in bytes.")))))

proc registerCss*(reg: ToolRegistry) =
  ## Register the CSS tools.
  reg.register("parse_css",
    "Parse a CSS stylesheet and return a summary of its rules, at-rules, and " &
    "declaration count.",
    objSchema(
      properties = props(
        ("source", stringProp("The CSS source text.")),
        ("path", stringProp("Read the stylesheet from this file path instead."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let sheet = parseCss(src)
      var rules = newJArray()
      var atRules = newJArray()
      var declCount = 0
      for node in sheet.nodes:
        case node.kind
        of cssRuleSet:
          declCount += node.declarations.len
          rules.add(newJString(toString(node)))
        of cssAtRule:
          atRules.add(newJString(toString(node)))
          for child in node.atRules:
            if child.kind == cssRuleSet:
              declCount += child.declarations.len
              rules.add(newJString(toString(child)))
        else:
          discard
      var summaryNode = newJObject()
      summaryNode["topLevelNodeCount"] = newJInt(sheet.nodes.len)
      summaryNode["declarationCount"] = newJInt(declCount)
      summaryNode["rules"] = rules
      summaryNode["atRules"] = atRules
      okStructured($sheet.nodes.len & " top-level nodes, " &
                   $declCount & " declarations", summaryNode),
    title = "Parse CSS",
    outputSchema = objSchema(
      properties = props(
        ("topLevelNodeCount", intProp("Nodes at the stylesheet root.")),
        ("declarationCount", intProp("Total declarations across all rules.")),
        ("rules", arrayProp("Canonical text of each rule set.")),
        ("atRules", arrayProp("Canonical text of each at-rule.")))))

  reg.register("validate_css",
    "Validate a CSS stylesheet against the CSS property vocabulary, listing " &
    "every unrecognized property.",
    objSchema(
      properties = props(
        ("source", stringProp("The CSS source text.")),
        ("path", stringProp("Read the stylesheet from this file path instead."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let sheet = parseCss(src)
      let policy = defaultPolicy()
      var problems = newJArray()
      var checked = 0
      template checkDecls(decls: openArray[CssNode]) =
        for decl in decls:
          if decl.kind != cssDeclaration: continue
          inc checked
          if not isPropertyAllowed(policy, decl.property):
            problems.add(%*{"property": decl.property,
                            "raw": decl.rawValue})
      for node in sheet.nodes:
        case node.kind
        of cssRuleSet: checkDecls(node.declarations)
        of cssAtRule:
          for child in node.atRules:
            if child.kind == cssRuleSet:
              checkDecls(child.declarations)
        else: discard
      var summaryNode = newJObject()
      summaryNode["declarationsChecked"] = newJInt(checked)
      summaryNode["unrecognized"] = problems
      if problems.len == 0:
        okStructured("No unrecognized properties in " & $checked &
                     " declarations.", summaryNode)
      else:
        var text = $problems.len & " unrecognized propert" &
          (if problems.len == 1: "y" else: "ies") & ":"
        for p in problems:
          text.add("\n  " & p{"property"}.getStr & ": " & p{"raw"}.getStr)
        # Reported as an execution error so the model sees the specifics.
        ToolResult(content: @[textContent(text)],
                   structuredContent: summaryNode,
                   isError: true),
    title = "Validate CSS",
    outputSchema = objSchema(
      properties = props(
        ("declarationsChecked", intProp("Declarations inspected.")),
        ("unrecognized", arrayProp("Properties outside the CSS vocabulary.")))))

proc registerSvg*(reg: ToolRegistry) =
  ## Register the SVG tools.
  reg.register("parse_svg",
    "Parse an SVG document into a typed DOM and return its canonical " &
    "serialization, optionally pretty-printed.",
    objSchema(
      properties = props(
        ("source", stringProp("The SVG document text.")),
        ("path", stringProp("Read the document from this file path instead.")),
        ("pretty", boolProp("Pretty-print the output."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let pretty = argBool(args, "pretty", false)
      let rendered = toSvg(parseSvg(src),
        SvgSerializeOptions(pretty: pretty, indentSize: 2))
      okStructured(rendered, %*{"bytes": src.len}),
    title = "Parse SVG")