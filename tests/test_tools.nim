import unittest, os, strutils, tables
import openparser/json
import ../src/datcontext/protocol/errors
import ../src/datcontext/tools/[load, summary, tool]

suite "tool schemas":
  test "objSchema is valid JSON Schema":
    let s = objSchema(properties = props(("a", stringProp("x"))),
                      required = @["a"])
    check s["type"].getStr == "object"
    check s["properties"]["a"]["type"].getStr == "string"
    check s["required"][0].getStr == "a"
    check s["additionalProperties"].getBool == false

  test "parameterless tool uses a closed object schema":
    # The spec's recommended shape for a tool that takes no arguments.
    let s = objSchema()
    check s["type"].getStr == "object"
    check s.hasKey("additionalProperties")
    check s["additionalProperties"].getBool == false
    check s["properties"].len == 0

  test "inputSchema is never null in tools/list":
    let reg = newRegistry()
    reg.register("no_schema", "a tool with no explicit schema",
                 objSchema(), proc(args: JsonNode): ToolResult = okResult("ok"))
    for t in reg.listJson:
      check t["inputSchema"].kind == JObject
      check t["inputSchema"]["type"].getStr == "object"

  test "enumProp constrains values":
    let p = enumProp("a kind", ["a", "b"])
    check p["enum"].len == 2
    check p["enum"][0].getStr == "a"

  test "properties render their types":
    check intProp("n")["type"].getStr == "integer"
    check boolProp("b")["type"].getStr == "boolean"
    check arrayProp("a")["type"].getStr == "array"

suite "registry":
  test "registration and lookup":
    let reg = newRegistry()
    reg.register("t1", "first", objSchema(),
                 proc(args: JsonNode): ToolResult = okResult("one"))
    check reg.has("t1")
    check reg.get("t1") != nil
    check reg.len == 1
    check reg.get("nope").isNil

  test "ordering is insertion-stable":
    let reg = newRegistry()
    for n in ["zeta", "alpha", "mid"]:
      reg.register(n, n, objSchema(),
                   proc(args: JsonNode): ToolResult = okResult(n))
    check reg.names() == @["zeta", "alpha", "mid"]

  test "re-registering keeps position":
    let reg = newRegistry()
    reg.register("a", "a", objSchema(), proc(args: JsonNode): ToolResult = okResult("1"))
    reg.register("b", "b", objSchema(), proc(args: JsonNode): ToolResult = okResult("2"))
    reg.register("a", "a2", objSchema(), proc(args: JsonNode): ToolResult = okResult("3"))
    check reg.names() == @["a", "b"]
    check reg.get("a").description == "a2"

  test "deterministic listJson order":
    let reg = newRegistry()
    for n in ["c", "a", "b"]:
      reg.register(n, n, objSchema(),
                   proc(args: JsonNode): ToolResult = okResult(n))
    let first = reg.listJson()
    let second = reg.listJson()
    check $first == $second
    check first[0]["name"].getStr == "c"

  test "unknown tool raises invalid params":
    let reg = newRegistry()
    try:
      discard reg.call("missing", newJObject())
      check false
    except McpError as e:
      check e.code == ecInvalidParams

  test "call dispatches to the handler":
    let reg = newRegistry()
    reg.register("echo", "echo", objSchema(),
      proc(args: JsonNode): ToolResult = okResult("got:" & argStr(args, "v")))
    check reg.call("echo", %*{"v": "hi"}).content[0].text == "got:hi"

  test "nil args become an empty object":
    let reg = newRegistry()
    reg.register("t", "t", objSchema(),
      proc(args: JsonNode): ToolResult = okResult($args.kind))
    check reg.call("t", nil).content[0].text == "JObject"

suite "tool results":
  test "okResult is a single text block":
    let r = okResult("hi")
    check r.content.len == 1
    check r.content[0].kind == "text"
    check not r.isError

  test "errResult sets isError":
    # Tool execution errors must reach the model so it can self-correct.
    let r = errResult("bad input")
    check r.isError
    check r.content[0].text == "bad input"

  test "okStructured carries both blocks":
    let r = okStructured("{}", %*{"a": 1})
    check r.content[0].text == "{}"
    check r.structuredContent["a"].getInt == 1
    check not r.isError

suite "argument access":
  test "argStr requires the key":
    try:
      discard argStr(newJObject(), "missing")
      check false
    except McpError as e:
      check e.code == ecInvalidParams

  test "argStrOr falls back":
    check argStrOr(newJObject(), "missing", "dflt") == "dflt"

  test "argBool coerces":
    check argBool(%*{"a": true}, "a")
    check argBool(%*{"a": "true"}, "a")
    check not argBool(%*{"a": false}, "a")
    check argBool(newJObject(), "a", true)

  test "argInt coerces":
    check argInt(%*{"a": 5}, "a") == 5
    check argInt(%*{"a": "7"}, "a") == 7
    check argInt(%*{"a": 2.9}, "a") == 2
    check argInt(newJObject(), "a", 3) == 3

suite "source loading":
  test "inline source":
    check readSource(%*{"source": "hello"}) == "hello"

  test "path is read":
    let p = getTempDir() / "datcontext_test_src.txt"
    writeFile(p, "from file")
    check readSource(%*{"path": p}) == "from file"
    removeFile(p)

  test "file:// uri is decoded":
    let p = getTempDir() / "datcontext_test_uri.txt"
    writeFile(p, "uri content")
    check readSource(%*{"path": "file://" & p}) == "uri content"
    removeFile(p)

  test "both source and path is invalid":
    try:
      discard readSource(%*{"source": "a", "path": "b"})
      check false
    except McpError as e:
      check e.code == ecInvalidParams

  test "neither is invalid":
    try:
      discard readSource(newJObject())
      check false
    except McpError as e:
      check e.code == ecInvalidParams

  test "missing file raises a tool-level error":
    try:
      discard readSource(%*{"path": "/nonexistent/nope.txt"})
      check false
    except ValueError:
      discard

suite "bounded preview":
  test "short text is unchanged":
    check preview("short") == "short"

  test "long text is truncated with a marker":
    let long = "x".repeat(5000)
    let p = preview(long, 100)
    check p.len < 200
    check p.contains("truncated")