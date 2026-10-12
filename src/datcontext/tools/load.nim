# datcontext — generic MCP building blocks over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Tool input loading and size bounds.
##
## Tools that accept document text share one loader that takes either inline
## `source` or a `path`, and applies a shared byte ceiling so a model cannot ask
## the server to pull an arbitrarily large file into memory.
##
## The specification requires servers to validate all tool inputs and rate limit
## invocations; size bounds are enforced here rather than per-tool.

import std/[os, strutils, uri]
import openparser/json
import ../protocol/errors

const
  DefaultMaxSourceBytes* = 32 * 1024 * 1024
  ## Ceiling on any single document handed to a tool.

proc maxSourceBytes*(): int =
  ## Configurable ceiling, overridable by an environment variable so an operator
  ## can tighten it without a rebuild.
  let v = getEnv("DATCONTEXT_MAX_SOURCE_BYTES")
  if v.len > 0:
    try:
      return parseInt(v)
    except ValueError:
      discard
  DefaultMaxSourceBytes

proc isFileUri*(s: string): bool =
  ## True when `s` looks like a `file://` URI rather than inline content.
  s.startsWith("file://")

proc fileUriToPath*(s: string): string =
  ## Convert a `file://` URI to a local path.
  ##
  ## Handles the `file://localhost/path` form by ignoring the authority, and
  ## percent-decodes the path.
  result = s["file://".len .. ^1]
  if result.startsWith("localhost/"):
    result = result["localhost".len .. ^1]
  if result.len > 0:
    result = decodeUrl(result)

proc readSource*(args: JsonNode; key = "source"): string =
  ## Load tool input from either an inline `source` string or a `path`.
  ##
  ## Exactly one of `source` or `path` must be supplied. Raises `McpError` with
  ## `-32602` for a malformed argument and a `ValueError` for an unreadable
  ## file, which the dispatch layer reports as a tool execution error.
  let inline = args{"source"}
  let pathArg = args{"path"}
  let hasInline = not inline.isNil and inline.kind == JString
  let hasPath = not pathArg.isNil and pathArg.kind == JString

  if hasInline and hasPath:
    raise newMcpError(ecInvalidParams,
      "supply either source or path, not both")

  if hasInline:
    return inline.getStr

  if hasPath:
    var path = pathArg.getStr
    if path.len == 0:
      raise newMcpError(ecInvalidParams, "path must not be empty")
    if isFileUri(path):
      path = fileUriToPath(path)
    if not fileExists(path):
      raise newException(ValueError, "file not found: " & path)
    if dirExists(path):
      raise newException(ValueError, "path is a directory: " & path)
    let size = getFileSize(path)
    let limit = maxSourceBytes()
    if size > int64(limit):
      raise newException(ValueError, 
        "source is " & $size & " bytes, over the " & $limit & " byte limit")
    return readFile(path)

  raise newMcpError(ecInvalidParams,
    "missing required argument: source or path")

proc summarize*(text: string; maxPreview = 4000): string =
  ## A bounded preview of a document, for including in parse output.
  if text.len <= maxPreview:
    return text
  text[0 ..< maxPreview] & "\n... [truncated, " & $(text.len) & " bytes total]"

proc errorMessage*(e: ref Exception): string =
  ## The message of a caught exception.
  e.msg