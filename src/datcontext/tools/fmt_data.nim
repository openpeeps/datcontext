# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Data-format tools: CSV, SQL, iCal, vCard, RSS, Atom, dotenv, plist, BSON,
## NIF, and the scalar utilities.
##
## These are grouped in one module because each is a small adapter over a single
## openparser entry point. CSV gets special handling: openparser's CSV parser is
## the only streaming parser in the library, so its tool summarizes rather than
## materializing, which keeps a large file from being held in memory twice.

import std/[base64, os, strutils]
import openparser/json
import openparser/csv
import openparser/sql
import openparser/ical
import openparser/vcard
import openparser/rss
import openparser/feed
import openparser/dotenv
import openparser/plist
import openparser/bson
import openparser/nif
import openparser/colors
import openparser/uuid
import openparser/path
import openparser/regex
import openparser/fuzzy
import ../protocol/types
import ./[load, summary, tool]

# ── CSV ──────────────────────────────────────────────────────────────────────

type
  CsvSummary* = object
    rows*: int
    header*: seq[string]
    fieldCount*: int
    malformed*: int
    samples*: seq[seq[string]]

proc csvSummarize*(path: string; maxSamples: int;
                   options: CsvOptions): CsvSummary =
  ## Stream a CSV file and summarize it.
  ##
  ## openparser's CSV entry points take a file path rather than a string, so the
  ## path form is used directly and the callback bails out once enough rows have
  ## been collected. Rows are never all retained.
  var acc: CsvSummary
  parseFile(path,
    proc(fields: openArray[CsvFieldSlice], row: int): bool =
      acc.fieldCount = fields.len
      if row == 1:
        for f in fields:
          acc.header.add(f.toString)
      else:
        acc.rows = acc.rows + 1
      if row > 1 and acc.samples.len < maxSamples:
        var sample: seq[string]
        for f in fields:
          sample.add(f.toString)
        acc.samples.add(sample)
      true
    , options)
  result = acc

proc registerCsv*(reg: ToolRegistry) =
  ## Register the CSV tools.
  reg.register("parse_csv",
    "Parse a CSV file and return a summary: row count, header, field count, " &
    "and the first few rows. Streams the file, so large inputs stay cheap.",
    objSchema(
      properties = props(
        ("path", stringProp("Path to the CSV file. Required.")),
        ("delimiter", stringProp("Field delimiter. Defaults to a comma.")),
        ("quote", stringProp("Quote character. Defaults to a double quote.")),
        ("strict", boolProp("Reject malformed rows. Defaults to true.")),
        ("maxSamples", intProp("How many data rows to return. Defaults to 10."))),
      additionalProperties = false),
    proc(args: JsonNode): ToolResult =
      let path = argStr(args, "path")
      if not fileExists(path):
        return errResult("file not found: " & path)
      let delimStr = argStrOr(args, "delimiter", ",")
      let quoteStr = argStrOr(args, "quote", "\"")
      var options: CsvOptions
      options.delimiter = if delimStr.len > 0: delimStr[0] else: ','
      options.quote = if quoteStr.len > 0: quoteStr[0] else: '"'
      options.strict = argBool(args, "strict", true)
      let maxSamples = argInt(args, "maxSamples", 10)

      let s = csvSummarize(path, maxSamples, options)
      var summaryNode = newJObject()
      summaryNode["rows"] = newJInt(s.rows)
      summaryNode["fieldCount"] = newJInt(s.fieldCount)
      summaryNode["header"] = stringList(s.header)
      var samples = newJArray()
      for row in s.samples:
        samples.add(stringList(row))
      summaryNode["sampleRows"] = samples

      var text = $s.rows & " rows, " & $s.fieldCount & " fields\n"
      if s.header.len > 0:
        text.add("header: " & s.header.join(", ") & "\n")
      for row in s.samples:
        text.add(row.join(", ") & "\n")
      okStructured(text, summaryNode),
    title = "Parse CSV",
    outputSchema = objSchema(
      properties = props(
        ("rows", intProp("Total data rows, excluding the header.")),
        ("fieldCount", intProp("Fields per row.")),
        ("header", arrayProp("Header field names.")),
        ("sampleRows", arrayProp("The first few data rows.")))))

# ── SQL ──────────────────────────────────────────────────────────────────────

proc registerSql*(reg: ToolRegistry) =
  ## Register the SQL tools.
  reg.register("parse_sql",
    "Parse SQL and return its canonical rendering. Set dialect to enable " &
    "driver-specific syntax (pgsql, mysql, sqlite).",
    objSchema(
      properties = props(
        ("source", stringProp("The SQL text.")),
        ("path", stringProp("Read the SQL from this file path instead.")),
        ("dialect", enumProp("SQL dialect.", ["generic", "pgsql", "mysql",
                                               "sqlite"])),
        ("upperCase", boolProp("Uppercase SQL keywords when rendering."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let dialect = case argStrOr(args, "dialect", "generic")
        of "pgsql": SqlDriver.pgsql
        of "mysql": SqlDriver.mysql
        of "sqlite": SqlDriver.sqlite
        else: SqlDriver.generic
      let upper = argBool(args, "upperCase", false)
      let node = parseSql(src, dialect)
      let rendered = renderSql(node, upper, dialect)
      okStructured(rendered, %*{"bytes": src.len,
                                "dialect": argStrOr(args, "dialect", "generic")}),
    title = "Parse SQL",
    outputSchema = objSchema(
      properties = props(
        ("bytes", intProp("Input size in bytes.")),
        ("dialect", stringProp("The dialect used.")))))

# ── iCal and vCard ───────────────────────────────────────────────────────────

proc registerIcal*(reg: ToolRegistry) =
  ## Register the iCalendar tools.
  reg.register("parse_ical",
    "Parse an iCalendar (RFC 5545) document and return its canonical " &
    "rendering, so a calendar can be round-tripped losslessly.",
    objSchema(
      properties = props(
        ("source", stringProp("The iCalendar text.")),
        ("path", stringProp("Read the calendar from this file path instead."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let cal = parseIcal(src)
      okResult(toIcal(cal)),
    title = "Parse iCalendar")

proc registerVcard*(reg: ToolRegistry) =
  ## Register the vCard tools.
  reg.register("parse_vcard",
    "Parse one or more vCards (RFC 6350 / RFC 2426) and return their " &
    "canonical rendering.",
    objSchema(
      properties = props(
        ("source", stringProp("The vCard text.")),
        ("path", stringProp("Read the cards from this file path instead."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let cards = parseVCards(src)
      var summaryNode = newJObject()
      summaryNode["cardCount"] = newJInt(cards.len)
      var parts: seq[string]
      for c in cards:
        parts.add(toVCard(c))
      okStructured(parts.join("\n"), summaryNode),
    title = "Parse vCard",
    outputSchema = objSchema(
      properties = props(("cardCount", intProp("Number of cards found.")))))

# ── Feeds ────────────────────────────────────────────────────────────────────

proc registerRss*(reg: ToolRegistry) =
  ## Register the RSS tools.
  reg.register("parse_rss",
    "Parse an RSS 2.0 feed and return its canonical XML rendering, plus the " &
    "channel title and item count.",
    objSchema(
      properties = props(
        ("source", stringProp("The RSS XML text.")),
        ("path", stringProp("Read the feed from this file path instead."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let feed = parseRss(src)
      var summaryNode = newJObject()
      summaryNode["itemCount"] = newJInt(feed.items.len)
      summaryNode["title"] = newJString(feed.title)
      okStructured(toRssXml(feed), summaryNode),
    title = "Parse RSS",
    outputSchema = objSchema(
      properties = props(
        ("itemCount", intProp("Number of items.")),
        ("title", stringProp("Channel title.")))))

proc registerAtom*(reg: ToolRegistry) =
  ## Register the Atom tools.
  reg.register("parse_atom",
    "Parse an Atom feed and return its canonical XML rendering, plus the " &
    "feed title and entry count.",
    objSchema(
      properties = props(
        ("source", stringProp("The Atom XML text.")),
        ("path", stringProp("Read the feed from this file path instead."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let feed = parseAtom(src)
      var summaryNode = newJObject()
      summaryNode["entryCount"] = newJInt(feed.entries.len)
      summaryNode["title"] = newJString(feed.title.value)
      okStructured(toAtomXml(feed), summaryNode),
    title = "Parse Atom",
    outputSchema = objSchema(
      properties = props(
        ("entryCount", intProp("Number of entries.")),
        ("title", stringProp("Feed title.")))))

# ── dotenv ───────────────────────────────────────────────────────────────────

proc registerDotenv*(reg: ToolRegistry) =
  ## Register the dotenv tools.
  reg.register("parse_dotenv",
    "Parse a .env file into its key/value pairs, preserving order.",
    objSchema(
      properties = props(
        ("source", stringProp("The .env text.")),
        ("path", stringProp("Read the file from this path instead."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let entries = parseEnv(src)
      var summaryNode = newJObject()
      summaryNode["count"] = newJInt(entries.len)
      var obj = newJObject()
      var text = ""
      for e in entries:
        obj[e.key] = newJString(e.value)
        text.add(e.key & "=" & e.value & "\n")
      summaryNode["values"] = obj
      okStructured(text, summaryNode),
    title = "Parse dotenv",
    outputSchema = objSchema(
      properties = props(
        ("count", intProp("Number of variables.")),
        ("values", objSchema(properties = newJObject(),
                             additionalProperties = true)))))

# ── plist and BSON ───────────────────────────────────────────────────────────

proc registerPlist*(reg: ToolRegistry) =
  ## Register the Apple property-list tools.
  reg.register("parse_plist",
    "Parse an Apple property list (XML or binary bplist00) and return it as " &
    "JSON. The binary form is autodetected.",
    objSchema(
      properties = props(
        ("source", stringProp("The plist text or base64 for binary plists.")),
        ("path", stringProp("Read the plist from this file path instead."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      # A binary plist starts with "bplist00"; hand those bytes to the
      # sequence-based overload.
      let node = parsePlist(src)
      okStructured($node, %*{"kind": kindName(node.kind)}),
    title = "Parse plist")

proc registerBson*(reg: ToolRegistry) =
  ## Register the BSON tools.
  reg.register("parse_bson",
    "Parse BSON 1.1 and return it as extended JSON.",
    objSchema(
      properties = props(
        ("base64", stringProp("The BSON payload, base64 encoded."))),
      required = @["base64"]),
    proc(args: JsonNode): ToolResult =
      let b64 = argStr(args, "base64")
      var data: seq[byte]
      try:
        let raw = decode(b64)
        for ch in raw:
          data.add(byte(ord(ch) and 0xFF))
      except CatchableError as e:
        return errResult("could not decode base64: " & e.msg)
      if data.len == 0:
        return errResult("empty BSON payload")
      try:
        let node = fromBson(data)
        okStructured($node, %*{"kind": kindName(node.kind),
                              "byteLength": data.len})
      except CatchableError as e:
        errResult("Invalid BSON: " & e.msg),
    title = "Parse BSON")

# ── NIF ──────────────────────────────────────────────────────────────────────

proc registerNif*(reg: ToolRegistry) =
  ## Register the Erlang NIF tools.
  reg.register("parse_nif",
    "Parse an Erlang NIF module and return its canonical rendering. Every node " &
    "keeps its raw text, so dumping is lossless.",
    objSchema(
      properties = props(
        ("source", stringProp("The NIF source text.")),
        ("path", stringProp("Read the module from this file path instead."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let src = readSource(args)
      let module = fromNif(src)
      okResult(dumpNif(module)),
    title = "Parse NIF")

# ── Scalar utilities ─────────────────────────────────────────────────────────

proc registerScalar*(reg: ToolRegistry) =
  ## Register the scalar helpers: colors, identifiers, paths, regex, fuzzy.

  reg.register("parse_color",
    "Parse a CSS Color 4 value in any supported notation (hex, named, rgb, " &
    "hsl, hwb, lab, oklab, oklch) and report its canonical forms.",
    objSchema(
      properties = props(("color", stringProp("The color value."))),
      required = @["color"]),
    proc(args: JsonNode): ToolResult =
      let text = argStr(args, "color")
      try:
        let c = parseColor(text)
        var summaryNode = newJObject()
        summaryNode["valid"] = newJBool(c.valid)
        summaryNode["hex"] = newJString(c.toHex)
        summaryNode["rgb"] = newJString(c.toRgbString)
        summaryNode["hsl"] = newJString(c.toHslString)
        okStructured(c.toHex, summaryNode)
      except CatchableError as e:
        errResult("Invalid color: " & e.msg),
    title = "Parse color",
    outputSchema = objSchema(
      properties = props(
        ("valid", boolProp("Whether the value parsed.")),
        ("hex", stringProp("Canonical hex form.")),
        ("rgb", stringProp("Canonical rgb() form.")),
        ("hsl", stringProp("Canonical hsl() form.")))))

  reg.register("new_uuid",
    "Generate a UUID. Versions 1 through 8 are supported.",
    objSchema(
      properties = props(
        ("version", intProp("UUID version, 1 to 8. Defaults to 4 (random)."))),
      additionalProperties = true),
    proc(args: JsonNode): ToolResult =
      let v = argInt(args, "version", 4)
      # Versions 3 and 5 are name-based and need a namespace plus a name, so
      # they are not offered as bare generators.
      var id: Uuid
      case v
        of 1: id = newUuidV1()
        of 2: id = newUuidV2(0, uint32(argInt(args, "localId", 1)))
        of 6: id = newUuidV6()
        of 7: id = newUuidV7()
        else: id = newUuidV4()
      let text = $id
      okStructured(text, %*{"uuid": text, "version": id.version.int}),
    title = "Generate UUID")

  reg.register("parse_path",
    "Parse a filesystem path or URL and report its kind: local, http, https, " &
    "ssh, git, ftp, sftp, or mailto.",
    objSchema(
      properties = props(("path", stringProp("The path or URL."))),
      required = @["path"]),
    proc(args: JsonNode): ToolResult =
      let text = argStr(args, "path")
      try:
        let p = parsePath(text)
        var summaryNode = newJObject()
        summaryNode["kind"] = newJString($p.kind)
        summaryNode["isLocal"] = newJBool(p.isLocal)
        okStructured(p.raw, summaryNode)
      except CatchableError as e:
        errResult("Invalid path: " & e.msg),
    title = "Parse path")

  reg.register("match_regex",
    "Search text with a regular expression and report the match position and " &
    "capture groups. An unmatched optional group is reported as null.",
    objSchema(
      properties = props(
        ("pattern", stringProp("The regular expression.")),
        ("text", stringProp("The text to search.")),
        ("anchored", boolProp("Require the match to span the whole text. " &
                              "Defaults to false."))),
      required = @["pattern", "text"]),
    proc(args: JsonNode): ToolResult =
      let pattern = argStr(args, "pattern")
      let subject = argStr(args, "text")
      let anchored = argBool(args, "anchored", false)
      try:
        # The explicit VM is used rather than openparser's one-line `find`
        # convenience wrapper: that wrapper calls `closeRegexVM` before the
        # caller reads the MatchResult, which invalidates it.
        var vm = initRegexVM(compile(pattern))
        defer: vm.closeRegexVM()
        let m = if anchored: vm.match(subject) else: vm.find(subject)
        if not m.matched:
          return errResult("no match for /" & pattern & "/ in the text")
        var groups = newJObject()
        var unmatched = newJArray()
        # allGroups includes the whole match at index 0.
        for c in allGroups(m, subject):
          if c.matched:
            groups[$c.index] = newJString(c.str(subject))
          else:
            groups[$c.index] = newJNull()
            unmatched.add(newJInt(c.index))
        var summaryNode = newJObject()
        summaryNode["groups"] = groups
        summaryNode["unmatchedGroups"] = unmatched
        summaryNode["start"] = newJInt(m.start)
        summaryNode["stop"] = newJInt(m.stop)
        okStructured(groupStr(m, subject, 0), summaryNode)
      except CatchableError as e:
        errResult("Invalid pattern: " & e.msg),
    title = "Match regex",
    outputSchema = objSchema(
      properties = props(
        ("groups", objSchema(properties = newJObject(),
                             additionalProperties = true)),
        ("unmatchedGroups", arrayProp("Indices of optional groups that did not " &
                                      "participate.")),
        ("start", intProp("Match start offset.")),
        ("stop", intProp("Match end offset.")))))


  reg.register("fuzzy_search",
    "Rank candidates against a query using fuzzy subsequence matching, the way " &
    "a command palette does.",
    objSchema(
      properties = props(
        ("query", stringProp("The search query.")),
        ("candidates", arrayProp("Strings to rank.")),
        ("limit", intProp("Maximum results. 0 or less returns all.")),
        ("caseSensitive", boolProp("Match case exactly. Defaults to false.")),
        ("minScore", stringProp("Minimum score, 0.0 to 1.0 as a string."))),
      required = @["query", "candidates"]),
    proc(args: JsonNode): ToolResult =
      let query = argStr(args, "query")
      let candsNode = args{"candidates"}
      if candsNode.isNil or candsNode.kind != JArray:
        return errResult("candidates must be an array of strings")
      var cands: seq[string]
      for c in candsNode:
        if c.kind != JString:
          return errResult("candidates must all be strings")
        cands.add(c.getStr)
      let opts = FuzzyOptions(
        caseSensitive: argBool(args, "caseSensitive", false),
        limit: argInt(args, "limit", 0),
        minScore: parseFloat(argStrOr(args, "minScore", "0.0"))
      )
      let results = fuzzySearch(query, cands, opts)
      var arr = newJArray()
      var text = ""
      for r in results:
        var o = newJObject()
        o["candidate"] = newJString(r.text)
        o["score"] = newJFloat(r.score.float64)
        arr.add(o)
        text.add(r.text & "  (" & $r.score & ")\n")
      var summaryNode = newJObject()
      summaryNode["count"] = newJInt(arr.len)
      summaryNode["results"] = arr
      okStructured(text, summaryNode),
    title = "Fuzzy search",
    outputSchema = objSchema(
      properties = props(
        ("count", intProp("Number of matches returned.")),
        ("results", arrayProp("Ranked candidates with scores.")))))