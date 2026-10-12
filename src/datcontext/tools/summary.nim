# datcontext — generic MCP building blocks over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Shallow structural summaries.
##
## Small helpers for tool results: a bounded text preview and a shallow
## `JsonNode` summary (kind, key names, length) so the model gets document
## shape without the server reconstructing the tree.

import openparser/json

proc preview*(text: string; maxChars = 4000): string =
  ## A bounded preview of a document.
  if text.len <= maxChars:
    return text
  text[0 ..< maxChars] & "\n... [truncated, " & $(text.len) & " bytes total]"

proc kindName*(k: JsonNodeKind): string =
  ## A short name for a `JsonNode` kind.
  case k
  of JObject: "object"
  of JArray: "array"
  of JString: "string"
  of JInt: "integer"
  of JFloat: "number"
  of JBool: "boolean"
  of JNull: "null"

proc jsonSummary*(node: JsonNode; maxKeys = 64): JsonNode =
  ## A shallow summary of a `JsonNode`: its kind, key names, length, and a
  ## bounded scalar preview. Deliberately does not recurse.
  result = newJObject()
  result["kind"] = newJString(kindName(node.kind))
  case node.kind
  of JObject:
    result["keyCount"] = newJInt(node.len)
    var keys = newJArray()
    for k in node.keys:
      if keys.len >= maxKeys: break
      keys.add(newJString(k))
    result["keys"] = keys
  of JArray:
    result["length"] = newJInt(node.len)
  of JString:
    let s = node.getStr
    result["preview"] = newJString(if s.len > 200: s[0 ..< 200] else: s)
  of JInt:
    result["value"] = newJInt(node.getInt)
  of JFloat:
    result["value"] = newJFloat(node.getFloat)
  of JBool:
    result["value"] = newJBool(node.getBool)
  of JNull:
    discard

proc stringList*(items: openArray[string]): JsonNode =
  ## Render a string sequence as a JSON array.
  result = newJArray()
  for i in items:
    result.add(newJString(i))

proc countSummary*(kindName: string; keys: openArray[string];
                   extra: JsonNode = nil): JsonNode =
  ## Build a summary for formats whose AST has no `JsonNode` bridge: the
  ## document kind plus its key names.
  result = newJObject()
  result["kind"] = newJString(kindName)
  result["keyCount"] = newJInt(keys.len)
  result["keys"] = stringList(keys)