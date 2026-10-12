# datcontext — generic MCP building blocks over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Resources.
##
## Resources are the read side of MCP: URI-addressed context a client can pull in
## without invoking a tool. A bare server ships no resources; higher-level apps
## register their own, and optionally enable `file://` resources under a
## configured root, which is what makes a server useful against real files.
##
## The `file://` handler is the security-sensitive one. It is backed by
## flysystem: a `LocalDriver` rooted at a directory, wrapped in a
## `FilesystemPolicy` that enforces read-only access, hidden-file denial, an
## extension allowlist, and a size cap. Containment itself is enforced inside
## flysystem by descriptor-walk (`securejoin`): prefix-sharing siblings,
## outward symlinks, and `..` escapes are all refused there, and violations
## surface here as `StorageError` mapped to `-32602` below.
##
## This module intentionally holds no path logic of its own beyond URI
## handling. The composed-stack guarantee is pinned by
## `tests/test_resources.nim`, so a flysystem regression fails loudly here.

import std/[os, strutils, tables, uri]
import flysystem
import openparser/json
import ./protocol/errors

const
  ResourceDisk* = "resources"
    ## The flysystem disk name for `file://` resources.

type
  FilePolicy* = object
    ## The policy applied to the `file://` disk. Exposed so an operator can
    ## narrow it: the defaults are read-only with a hidden-file denial and no
    ## extension allowlist, which suits a server a model drives.
    maxFileSize*: int64
    maxPathLength*: int
    maxDepth*: int
    denyHiddenFiles*: bool
    allowedExtensions*: seq[string]
    allowedMimeTypes*: seq[string]

proc defaultFilePolicy*(): FilePolicy =
  ## Read-only, hidden files denied, 32 MiB per file.
  FilePolicy(maxFileSize: 32 * 1024 * 1024, maxPathLength: 1024,
             maxDepth: 32, denyHiddenFiles: true,
             allowedExtensions: @[], allowedMimeTypes: @[])

proc policyRules*(f: FilePolicy): PolicyRules =
  ## Translate to flysystem's `PolicyRules`.
  PolicyRules(
    # A model-driven server must never mutate a client's files.
    readOnly: true,
    maxFileSize: f.maxFileSize,
    maxPathLength: f.maxPathLength,
    maxDepth: f.maxDepth,
    denyHiddenFiles: f.denyHiddenFiles,
    allowedExtensions: f.allowedExtensions,
    allowedMimeTypes: f.allowedMimeTypes
  )

type
  ResourceContents* = object
    ## One resource body.
    uri*: string
    mimeType*: string
    text*: string
    blob*: string
    ## Base64 payload for binary resources; empty when `text` is set.

  Resource* = ref object
    ## A resource definition for `resources/list`.
    uri*: string
    name*: string
    title*: string
    description*: string
    mimeType*: string
    annotations*: JsonNode

  ResourceTemplate* = ref object
    ## A parameterised resource for `resources/templates/list`.
    uriTemplate*: string
    name*: string
    description*: string
    mimeType*: string

  ResourceReader* = proc(uri: string): ResourceContents {.closure.}

  ResourceRegistry* = ref object
    ## Ordered resource storage.
    resources*: OrderedTable[string, Resource]
    templates*: seq[ResourceTemplate]
    readers*: Table[string, ResourceReader]
    ## Reader per URI prefix; the longest match wins.
    fs*: Filesystem
    ## The flysystem instance backing `file://` resources; nil when disabled.

proc newResourceRegistry*(): ResourceRegistry =
  ## An empty registry.
  ResourceRegistry(resources: initOrderedTable[string, Resource](),
                   readers: initTable[string, ResourceReader]())

proc add*(reg: ResourceRegistry; res: Resource) =
  ## Register a resource definition.
  reg.resources[res.uri] = res

proc addTemplate*(reg: ResourceRegistry; t: ResourceTemplate) =
  ## Register a resource template.
  reg.templates.add(t)

proc addReader*(reg: ResourceRegistry; prefix: string;
                reader: ResourceReader) =
  ## Register a reader for URIs beginning with `prefix`.
  reg.readers[prefix] = reader

proc matchesPrefix*(reg: ResourceRegistry; uri: string): string =
  ## The longest registered reader prefix matching `uri`, or `""`.
  var best = ""
  for prefix in reg.readers.keys:
    if uri.startsWith(prefix) and prefix.len > best.len:
      best = prefix
  best

proc has*(reg: ResourceRegistry; uri: string): bool =
  ## True when `uri` is a known resource or falls under a reader prefix.
  if uri in reg.resources:
    return true
  reg.matchesPrefix(uri).len > 0

proc listJson*(reg: ResourceRegistry): JsonNode =
  ## Render every resource for `resources/list`, in registration order.
  result = newJArray()
  for uri in reg.resources.keys:
    let r = reg.resources[uri]
    var o = newJObject()
    o["uri"] = newJString(r.uri)
    o["name"] = newJString(r.name)
    if r.title.len > 0: o["title"] = newJString(r.title)
    if r.description.len > 0: o["description"] = newJString(r.description)
    if r.mimeType.len > 0: o["mimeType"] = newJString(r.mimeType)
    if not r.annotations.isNil: o["annotations"] = r.annotations
    result.add(o)

proc templatesJson*(reg: ResourceRegistry): JsonNode =
  ## Render the templates for `resources/templates/list`.
  result = newJArray()
  for t in reg.templates:
    var o = newJObject()
    o["uriTemplate"] = newJString(t.uriTemplate)
    o["name"] = newJString(t.name)
    if t.description.len > 0: o["description"] = newJString(t.description)
    if t.mimeType.len > 0: o["mimeType"] = newJString(t.mimeType)
    result.add(o)

proc fileUriToPath*(uri: string): string =
  ## Convert a `file://` URI to a local path.
  result = uri["file://".len .. ^1]
  if result.startsWith("localhost/"):
    result = result["localhost".len .. ^1]
  if result.len > 0:
    result = decodeUrl(result)

proc fileUriToRelative*(uri: string): string =
  ## Convert a `file://` URI to a root-relative path.
  ##
  ## The leading separator is dropped: paths handed to the flysystem disk are
  ## relative to its root, so an absolute-looking URI is root-scoped rather than
  ## host-absolute. That is what makes `file:///etc/passwd` read
  ## `<root>/etc/passwd` instead of the real one.
  var relative = fileUriToPath(uri)
  while relative.len > 0 and (relative[0] == '/' or relative[0] == '\\'):
    relative = relative[1 .. ^1]
  relative

proc readFileResource*(reg: ResourceRegistry; uri: string): ResourceContents =
  ## Read a `file://` resource through flysystem.
  ##
  ## Containment (descriptor-walk) and policy (read-side rules) are both
  ## enforced inside the flysystem disk; violations surface as
  ## `StorageError`/`FilesystemPolicyError` and are mapped to `-32602` here.
  if reg.fs.isNil:
    raise newMcpError(ecInvalidParams, "file resources are not enabled")

  let relative = fileUriToRelative(uri)
  if relative.len == 0:
    raise newMcpError(ecInvalidParams, "file URI has no path: " & uri)

  let disk = reg.fs.disk(ResourceDisk)
  var exists = false
  var isDir = false
  var content = ""
  try:
    exists = disk.exists(relative)
    if exists:
      isDir = disk.metadata(relative).isDir
    if exists and not isDir:
      content = disk.read(relative)
  except FilesystemPolicyError as e:
    # A policy violation is a client-visible refusal, not a crash.
    raise newMcpError(ecInvalidParams,
      "resource refused by policy [" & e.rule & "]: " & e.operation)
  except StorageError as e:
    # flysystem raises this for traversal and missing files alike; keep the
    # message but not the class.
    raise newMcpError(ecInvalidParams, e.msg)

  if not exists:
    # The spec forbids an empty `contents` array for a missing resource, so this
    # has to be an error rather than an empty read.
    raise newMcpError(ecInvalidParams, "Resource not found")
  if isDir:
    raise newMcpError(ecInvalidParams, "not a regular file: " & relative)

  ResourceContents(uri: uri, mimeType: disk.mimeType(relative),
                   text: content)

proc contentsJson*(contents: seq[ResourceContents]): JsonNode =
  ## Render resource bodies for a `resources/read` result.
  result = newJArray()
  for c in contents:
    var o = newJObject()
    o["uri"] = newJString(c.uri)
    if c.mimeType.len > 0: o["mimeType"] = newJString(c.mimeType)
    # Exactly one of text or blob, per the spec.
    if c.blob.len > 0: o["blob"] = newJString(c.blob)
    else: o["text"] = newJString(c.text)
    result.add(o)

proc read*(reg: ResourceRegistry; uri: string): seq[ResourceContents] =
  ## Read a resource by URI.
  ##
  ## Raises `McpError` with `-32602` when the URI is unknown or the file is
  ## missing, which is what the spec requires for a non-existent resource.
  if uri in reg.resources:
    if uri in reg.readers:
      let reader = reg.readers[uri]
      if reader.isNil:
        raise newMcpError(ecInvalidParams, "Resource has no reader: " & uri)
      return @[reader(uri)]
    let prefix = reg.matchesPrefix(uri)
    if prefix.len > 0:
      return @[reg.readers[prefix](uri)]
    raise newMcpError(ecInvalidParams, "Resource has no reader: " & uri)
  let prefix = reg.matchesPrefix(uri)
  if prefix.len == 0:
    raise newMcpError(ecInvalidParams, "Resource not found")
  @[reg.readers[prefix](uri)]

proc buildResourceRegistry*(fileRoot: string = "";
                           policy = defaultFilePolicy()): ResourceRegistry =
  ## The standard resource set: empty, plus optional `file://` resources.
  ##
  ## `fileRoot` enables `file://` resources through a flysystem disk rooted
  ## there. Leave it empty to disable filesystem resources entirely, which is the
  ## right default for a server a model drives. Higher-level apps register
  ## their own URI schemes on top via `add`/`addReader`/`addTemplate`.
  result = newResourceRegistry()

  if fileRoot.len > 0:
    # Bind the registry to a local: inside the closure `result` would refer to
    # the closure's own ResourceContents, not the registry being built.
    let reg = result
    let fs = newFilesystem()
    # One driver: `newLocalDriver` creates the directory when missing, so
    # constructing two would do the work twice.
    let driver = newLocalDriver(fileRoot)
    fs.addDisk(ResourceDisk, driver, policy.policyRules())
    reg.fs = fs
    result.addReader("file://",
      proc(uri: string): ResourceContents = reg.readFileResource(uri))
    result.addTemplate(ResourceTemplate(
      uriTemplate: "file:///{path}",
      name: "Files",
      description: "Files under " & fileRoot & ", read-only.",
      mimeType: "application/octet-stream"))
    result.add(Resource(uri: "file:///", name: "root",
      title: "File root",
      description: "Files under " & fileRoot & ".",
      mimeType: "inode/directory"))