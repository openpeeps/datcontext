import unittest, os, strutils, tables
import openparser/json
import ../src/datcontext/protocol/errors
import ../src/datcontext/tools/[formats, load, summary, tool]

proc ok(reg: ToolRegistry; name: string; args: JsonNode): ToolResult =
  reg.call(name, args)


proc buildRegistry(): ToolRegistry =
  ## A registry with every tool wired.
  result = newRegistry()
  registerAll(result)

proc sampleFor(name: string): string =
  ## The smallest valid document per format for the generic dispatch test.
  case name
  of "json": "{\"a\": 1}"
  of "yaml": "a: 1"
  of "toml": "a = 1"
  of "xml": "<a>1</a>"
  of "html": "<p>hi</p>"
  of "css": "a { b: c; }"
  of "svg": "<svg width=\"1\" height=\"1\"></svg>"
  of "sql": "SELECT 1"
  else: ""

suite "format tools parse valid documents":
  let reg = buildRegistry()

  test "json":
    let r = ok(reg, "parse_json", %*{"source": "{\"a\": 1}"})
    check not r.isError
    check r.structuredContent["kind"].getStr == "object"
    check r.structuredContent["keys"][0].getStr == "a"

  test "yaml":
    let r = ok(reg, "parse_yaml", %*{"source": "a: 1\nb: two"})
    check not r.isError
    check r.content[0].text.contains("a:")

  test "yaml stream":
    let r = ok(reg, "parse_yaml_stream", %*{"source": "a: 1\n---\nb: 2"})
    check not r.isError
    check r.structuredContent["documentCount"].getInt == 2

  test "yaml frontmatter":
    let r = ok(reg, "parse_yaml_frontmatter",
      %*{"source": "---\ntitle: x\n---\nbody text"})
    check not r.isError
    check r.structuredContent["found"].getBool
    check r.structuredContent["body"].getStr.contains("body text")

  test "toml":
    let r = ok(reg, "parse_toml", %*{"source": "a = 1\n[t]\nb = 2"})
    check not r.isError
    check r.structuredContent["keyCount"].getInt == 2

  test "xml":
    let r = ok(reg, "parse_xml", %*{"source": "<a b=\"1\"><c/></a>"})
    check not r.isError
    check r.structuredContent["rootTag"].getStr == "a"
    check r.structuredContent["attributeCount"].getInt == 1
    check r.structuredContent["childCount"].getInt == 1

  test "html":
    let r = ok(reg, "parse_html", %*{"source": "<p>hello</p>"})
    check not r.isError
    # HtmlDocument has no serializer, so the text block carries the extraction.
    check r.content[0].text.contains("hello")
    check r.structuredContent["textLength"].getInt == 5

  test "css":
    let r = ok(reg, "parse_css", %*{"source": "a { b: c; d: e; }"})
    check not r.isError
    check r.structuredContent["declarationCount"].getInt == 2

  test "svg":
    let r = ok(reg, "parse_svg",
      %*{"source": "<svg width=\"1\" height=\"1\"></svg>"})
    check not r.isError
    check r.content[0].text.contains("svg")

  test "sql":
    let r = ok(reg, "parse_sql", %*{"source": "SELECT 1 FROM t"})
    check not r.isError
    check r.content[0].text.toUpperAscii.contains("SELECT")

  test "ical":
    let r = ok(reg, "parse_ical",
      %*{"source": "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nEND:VCALENDAR"})
    check not r.isError

  test "vcard":
    let r = ok(reg, "parse_vcard",
      %*{"source": "BEGIN:VCARD\r\nVERSION:4.0\r\nFN:A\r\nEND:VCARD"})
    check not r.isError
    check r.structuredContent["cardCount"].getInt == 1

  test "rss":
    let r = ok(reg, "parse_rss",
      %*{"source": "<rss version=\"2.0\"><channel><title>T</title></channel></rss>"})
    check not r.isError
    check r.structuredContent["title"].getStr == "T"

  test "atom":
    let r = ok(reg, "parse_atom",
      %*{"source": "<feed xmlns=\"http://www.w3.org/2005/Atom\">" &
           "<id>urn:x</id><title>T</title><updated>2024-01-01T00:00:00Z</updated>" &
           "</feed>"})
    check not r.isError
    check r.structuredContent["title"].getStr == "T"

  test "dotenv":
    let r = ok(reg, "parse_dotenv", %*{"source": "A=1\nB=two"})
    check not r.isError
    check r.structuredContent["count"].getInt == 2
    check r.structuredContent["values"]["B"].getStr == "two"

  test "plist":
    let r = ok(reg, "parse_plist",
      %*{"source": "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>a</key><string>1</string></dict></plist>"})
    check not r.isError

  test "nif":
    # NIF is the Erlang abstract format, not Erlang source.
    let r = ok(reg, "parse_nif", %*{"source": "(.nif27)(stmts 123)"})
    check not r.isError
    check r.content[0].text.contains("stmts")

suite "format tools report errors as tool errors":
  let reg = buildRegistry()

  test "malformed json":
    let r = ok(reg, "parse_json", %*{"source": "{not json"})
    check r.isError
    # The message carries openparser's caret context, which helps the model
    # locate the problem.
    check r.content[0].text.contains("^")

  test "malformed yaml":
    check ok(reg, "parse_yaml", %*{"source": "a: [1, 2"}).isError

  test "malformed toml":
    let r = ok(reg, "parse_toml", %*{"source": "a = = 1"})
    check r.isError
    # openparser's error carries a caret context, which is useful to a model.
    check r.content[0].text.contains("^")

  test "malformed xml":
    check ok(reg, "validate_xml", %*{"source": "<a><b></a>"}).isError

  test "valid documents pass validation":
    check not ok(reg, "validate_json", %*{"source": "{\"a\":1}"}).isError
    check not ok(reg, "validate_toml", %*{"source": "a = 1"}).isError

  test "missing source is an error":
    check ok(reg, "parse_json", newJObject()).isError

  test "both source and path is an error":
    check ok(reg, "parse_json", %*{"source": "{}", "path": "x"}).isError

  test "nonexistent path is an error":
    let r = ok(reg, "parse_json", %*{"path": "/nonexistent/file.json"})
    check r.isError
    check r.content[0].text.contains("not found")

suite "normalize is idempotent":
  let reg = buildRegistry()

  test "json":
    let first = ok(reg, "normalize_json", %*{"source": "{\"a\":1,\"b\":2}"}).content[0].text
    let second = ok(reg, "normalize_json", %*{"source": first}).content[0].text
    check first == second

  test "yaml":
    let first = ok(reg, "normalize_yaml", %*{"source": "a:    1"}).content[0].text
    let second = ok(reg, "normalize_yaml", %*{"source": first}).content[0].text
    check first == second

  test "toml":
    let first = ok(reg, "normalize_toml", %*{"source": "a=1"}).content[0].text
    let second = ok(reg, "normalize_toml", %*{"source": first}).content[0].text
    check first == second

suite "generic dispatch":
  let reg = buildRegistry()

  test "every listed format renders":
    for f in formats():
      let r = ok(reg, "parse", %*{"format": f.name,
                                   "source": sampleFor(f.name)})
      check not r.isError
      check r.structuredContent["format"].getStr == f.name

  test "an unknown format lists the alternatives":
    let r = ok(reg, "parse", %*{"format": "nope", "source": "x"})
    check r.isError
    check r.content[0].text.contains("json")

  test "validate reports the first error per format":
    let r = ok(reg, "validate", %*{"format": "json", "source": "{"})
    check r.isError

  test "normalize renders for json":
    let r = ok(reg, "normalize", %*{"format": "json", "source": "{\"a\":1}"})
    check not r.isError

suite "depth bounds":
  let reg = buildRegistry()

  test "json honours maxDepth":
    var deep = ""
    for i in 0 ..< 12: deep.add("{\"a\":")
    deep.add("1")
    for i in 0 ..< 12: deep.add("}")
    check ok(reg, "parse_json", %*{"source": deep, "maxDepth": 3}).isError

  test "the depth bound is opt-out at zero":
    var deep = ""
    for i in 0 ..< 6: deep.add("{\"a\":")
    deep.add("1")
    for i in 0 ..< 6: deep.add("}")
    check not ok(reg, "parse_json", %*{"source": deep, "maxDepth": 0}).isError

suite "csv":
  let reg = buildRegistry()

  test "summarizes a csv file":
    let p = getTempDir() / "datcontext_test.csv"
    writeFile(p, "name,age\nalice,30\nbob,25\ncarol,41\n")
    let r = ok(reg, "parse_csv", %*{"path": p})
    check not r.isError
    check r.structuredContent["rows"].getInt == 3
    check r.structuredContent["fieldCount"].getInt == 2
    check r.structuredContent["header"][0].getStr == "name"
    check r.structuredContent["sampleRows"][0][0].getStr == "alice"
    removeFile(p)

  test "respects maxSamples":
    let p = getTempDir() / "datcontext_test2.csv"
    var csv = "a\n"
    for i in 0 ..< 20: csv.add($i & "\n")
    writeFile(p, csv)
    let r = ok(reg, "parse_csv", %*{"path": p, "maxSamples": 3})
    # 20 data rows; the header is counted separately.
    check r.structuredContent["rows"].getInt == 20
    check r.structuredContent["sampleRows"].len == 3
    removeFile(p)

  test "a missing file is an error":
    check ok(reg, "parse_csv", %*{"path": "/nonexistent/x.csv"}).isError

  test "a custom delimiter is honoured":
    let p = getTempDir() / "datcontext_semi.csv"
    writeFile(p, "a;b\n1;2\n")
    let r = ok(reg, "parse_csv", %*{"path": p, "delimiter": ";"})
    check not r.isError
    check r.structuredContent["fieldCount"].getInt == 2
    removeFile(p)

suite "scalar tools":
  let reg = buildRegistry()

  test "parse_color handles hex and named":
    let hex = ok(reg, "parse_color", %*{"color": "#ff0000"})
    check not hex.isError
    check hex.structuredContent["valid"].getBool
    let named = ok(reg, "parse_color", %*{"color": "rebeccapurple"})
    check not named.isError

  test "an invalid color is a tool error":
    check ok(reg, "parse_color", %*{"color": "not-a-color"}).isError

  test "new_uuid produces a v4 by default":
    let r = ok(reg, "new_uuid", newJObject())
    check not r.isError
    check r.structuredContent["uuid"].getStr.len == 36
    check r.structuredContent["version"].getInt == 4

  test "new_uuid v7 is supported":
    let r = ok(reg, "new_uuid", %*{"version": 7})
    check r.structuredContent["version"].getInt == 7

  test "match_regex reports capture groups":
    let r = ok(reg, "match_regex",
      %*{"pattern": r"(\d{4})-(\d{2})-(\d{2})", "text": "on 2024-01-15 ok"})
    check not r.isError
    check r.structuredContent["groups"]["0"].getStr == "2024-01-15"
    check r.structuredContent["groups"]["1"].getStr == "2024"
    check r.structuredContent["groups"]["3"].getStr == "15"

  test "match_regex anchored mode requires a full match":
    let r = ok(reg, "match_regex",
      %*{"pattern": r"\d+", "text": "abc 123", "anchored": true})
    check r.isError

  test "a non-match is a tool error":
    check ok(reg, "match_regex",
      %*{"pattern": "zzz", "text": "abc"}).isError

  test "parse_path classifies a url":
    let r = ok(reg, "parse_path", %*{"path": "https://example.com/x"})
    check not r.isError
    check not r.structuredContent["isLocal"].getBool

  test "parse_path classifies a local path":
    let r = ok(reg, "parse_path", %*{"path": "/tmp/x"})
    check r.structuredContent["isLocal"].getBool

  test "fuzzy_search ranks candidates":
    let r = ok(reg, "fuzzy_search",
      %*{"query": "abc", "candidates": ["abcd", "zzz", "aXbXc"]})
    check not r.isError
    check r.structuredContent["count"].getInt == 2

  test "fuzzy_search honours limit":
    let r = ok(reg, "fuzzy_search",
      %*{"query": "a", "candidates": ["ab", "ac", "ad"], "limit": 2})
    check r.structuredContent["count"].getInt == 2

  test "fuzzy_search rejects non-string candidates":
    check ok(reg, "fuzzy_search",
      %*{"query": "a", "candidates": [1, 2]}).isError

suite "tool catalogue integrity":
  let reg = buildRegistry()

  test "every tool declares a closed or open object schema":
    for t in reg.listJson:
      check t["inputSchema"]["type"].getStr == "object"
      check t["inputSchema"].hasKey("additionalProperties")

  test "tool names are unique and spec-conformant":
    var seen: OrderedTable[string, bool]
    for n in reg.names():
      check not seen.hasKey(n)
      seen[n] = true
      check n.len >= 1 and n.len <= 128
      for c in n:
        check c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.'}

  test "required arguments are declared in the schema":
    # `parse` requires format; its schema must say so.
    let required = reg.get("parse").inputSchema["required"]
    check required.kind == JArray
    var found = false
    for r in required:
      if r.getStr == "format": found = true
    check found

  test "the generic tools are documented":
    for n in ["list_formats", "parse", "validate", "normalize"]:
      check reg.get(n).description.len > 20