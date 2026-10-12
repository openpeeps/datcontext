import unittest, os, strutils, tables
import openparser/json
import ../src/datcontext/protocol/errors
import ../src/datcontext/resources

proc buildRoot(): string =
  ## A scratch directory tree for the file-resource tests.
  ##
  ## Also creates a sibling directory whose name shares the root's prefix, and a
  ## symlink pointing outside the root, so the two containment gaps that flysystem
  ## leaves open are both exercised.
  result = getTempDir() / "datcontext_res_test"
  removeDir(result)
  removeDir(result & "-backup")
  createDir(result / "sub")
  createDir(result & "-backup")
  writeFile(result / "ok.yaml", "key: value")
  writeFile(result / "data.json", "{\"a\": 1}")
  writeFile(result / "sub" / "nested.toml", "b = 2")
  writeFile(result / ".hidden.yaml", "hidden: true")
  writeFile(result & "-backup" / "secret.yaml", "PREFIX-LEAK")
  writeFile(getTempDir() / "datcontext_outside.yaml", "OUTSIDE-LEAK")
  when not defined(windows):
    createSymlink(getTempDir() / "datcontext_outside.yaml", result / "link.yaml")

proc dropRoot(root: string) =
  removeFile(getTempDir() / "datcontext_outside.yaml")
  removeDir(root & "-backup")
  removeDir(root)

suite "containment":
  # Containment itself lives in flysystem (`securejoin`); these tests pin the
  # composed-stack guarantee — a flysystem regression fails loudly here —
  # through the same `reg.read` interface a client uses.
  let root = buildRoot()
  defer: dropRoot(root)

  test "a path inside the root reads":
    let reg = buildResourceRegistry(root)
    check reg.read("file:///ok.yaml")[0].text == "key: value"
    check reg.read("file:///sub/nested.toml")[0].text.contains("b = 2")

  test "a sibling sharing the root prefix is refused":
    # `datcontext_res_test-backup` starts with `datcontext_res_test` but is a
    # different directory; a bare startsWith(root) check would allow it.
    let reg = buildResourceRegistry(root)
    try:
      discard reg.read("file:///../" & (root & "-backup").splitFile.name & "/secret.yaml")
      check false
    except McpError as e:
      check e.code == ecInvalidParams
      check "Path traversal detected" in e.msg

  test "a path outside the root is refused":
    let reg = buildResourceRegistry(root)
    for uri in ["file:///../../../../etc/passwd",
                "file:///" & getTempDir().splitFile.name & "/elsewhere/x"]:
      try:
        discard reg.read(uri)
        check false
      except McpError as e:
        check e.code == ecInvalidParams

  test "a symlink out of the root is refused":
    when not defined(windows):
      let reg = buildResourceRegistry(root)
      try:
        discard reg.read("file:///link.yaml")
        check false
      except McpError as e:
        check e.code == ecInvalidParams
        check "Path traversal detected" in e.msg

suite "file resources":
  let root = buildRoot()
  defer: dropRoot(root)

  test "reads a file inside the root":
    let reg = buildResourceRegistry(root)
    let got = reg.read("file:///ok.yaml")
    check got.len == 1
    check got[0].text == "key: value"
    check got[0].mimeType == "text/yaml"

  test "reads a nested file":
    let reg = buildResourceRegistry(root)
    let got = reg.read("file:///sub/nested.toml")
    check got[0].text.contains("b = 2")
    check got[0].mimeType == "application/toml"

  test "percent-encoded traversal is refused":
    # %2e%2e decodes to `..`, so this must not slip past the guard.
    let reg = buildResourceRegistry(root)
    expect McpError:
      discard reg.read("file:///%2e%2e/%2e%2e/etc/passwd")

  test "a missing file is invalid params, not an empty read":
    # The spec forbids an empty `contents` array for a non-existent resource.
    let reg = buildResourceRegistry(root)
    try:
      discard reg.read("file:///nope.yaml")
      check false
    except McpError as e:
      check e.code == ecInvalidParams

  test "a directory is refused":
    let reg = buildResourceRegistry(root)
    expect McpError:
      discard reg.read("file:///sub")

  test "a prefix-sharing sibling is refused":
    # A resource read must never become a sibling-directory read.
    let reg = buildResourceRegistry(root)
    try:
      discard reg.read("file:///../" & (root & "-backup").splitFile.name & "/secret.yaml")
      check false
    except McpError as e:
      check e.code == ecInvalidParams
      check "Path traversal detected" in e.msg

  test "a symlink out of the root is refused":
    when not defined(windows):
      let reg = buildResourceRegistry(root)
      try:
        discard reg.read("file:///link.yaml")
        check false
      except McpError as e:
        check e.code == ecInvalidParams
        check "Path traversal detected" in e.msg

  test "a hidden file is refused by policy":
    let reg = buildResourceRegistry(root)
    try:
      discard reg.read("file:///.hidden.yaml")
      check false
    except McpError as e:
      check e.code == ecInvalidParams
      check "policy" in e.msg

  test "the policy can be narrowed to an extension allowlist":
    let reg = buildResourceRegistry(root,
      policy = FilePolicy(maxFileSize: 1024 * 1024, maxPathLength: 1024,
                          maxDepth: 32, denyHiddenFiles: true,
                          allowedExtensions: @["yaml"]))
    # The allowed extension still reads.
    check reg.read("file:///ok.yaml")[0].text.len > 0
    # A disallowed one is refused by the policy, not by containment.
    try:
      discard reg.read("file:///data.json")
      check false
    except McpError as e:
      check e.code == ecInvalidParams
      check "policy" in e.msg

  test "file resources are disabled without a root":
    let reg = buildResourceRegistry()
    check not reg.has("file:///ok.yaml")
    expect McpError:
      discard reg.read("file:///ok.yaml")

suite "policy translation":
  test "the default policy is read-only with a size cap":
    let rules = defaultFilePolicy().policyRules
    check rules.readOnly
    check rules.maxFileSize > 0
    check rules.denyHiddenFiles
    check rules.allowedExtensions.len == 0

  test "the policy maps every field":
    let rules = FilePolicy(maxFileSize: 10, maxPathLength: 20, maxDepth: 3,
                           denyHiddenFiles: true,
                           allowedExtensions: @["yaml"],
                           allowedMimeTypes: @["application/yaml"]).policyRules
    check rules.readOnly
    check rules.maxFileSize == 10
    check rules.maxPathLength == 20
    check rules.maxDepth == 3
    check rules.denyHiddenFiles
    check rules.allowedExtensions == @["yaml"]
    check rules.allowedMimeTypes == @["application/yaml"]

suite "mime types":
  # MIME types for files come from the flysystem disk: no second
  # extension table is kept here. Read-side policy is covered by the
  # "file resources" suite above and by flysystem's own read-side matrix
  # in its test_policy suite.
  test "file MIME types come from the disk":
    let root = buildRoot()
    defer: dropRoot(root)
    let reg = buildResourceRegistry(root)
    check reg.read("file:///ok.yaml")[0].mimeType == "text/yaml"
    check reg.read("file:///sub/nested.toml")[0].mimeType == "application/toml"

suite "resource listing with a file root":
  test "the file root is advertised":
    let reg = buildResourceRegistry("/tmp")
    var hasRoot = false
    var hasFileTemplate = false
    for r in reg.listJson():
      if r["uri"].getStr == "file:///": hasRoot = true
    for t in reg.templatesJson():
      if t["uriTemplate"].getStr == "file:///{path}": hasFileTemplate = true
    check hasRoot
    check hasFileTemplate

  test "no file resources without a root":
    let reg = buildResourceRegistry()
    for r in reg.listJson():
      check not r["uri"].getStr.startsWith("file://")
    check reg.templatesJson().len == 0

suite "longest prefix wins":
  test "the more specific reader handles the URI":
    let reg = buildResourceRegistry()
    reg.addReader("example://items/",
      proc(uri: string): ResourceContents =
        ResourceContents(uri: uri, mimeType: "text/plain", text: "item"))
    reg.addReader("example://",
      proc(uri: string): ResourceContents =
        ResourceContents(uri: uri, mimeType: "text/plain", text: "root"))
    check reg.matchesPrefix("example://items/1") == "example://items/"
    check reg.matchesPrefix("example://other") == "example://"
    check reg.matchesPrefix("other://x").len == 0

suite "contents rendering":
  test "text bodies carry text and not blob":
    let body = contentsJson(@[ResourceContents(uri: "u", mimeType: "text/plain",
                                               text: "hi")])
    check body[0]["text"].getStr == "hi"
    check not body[0].hasKey("blob")

  test "binary bodies carry blob and not text":
    let body = contentsJson(@[ResourceContents(uri: "u", mimeType: "image/png",
                                               blob: "AA==")])
    check body[0]["blob"].getStr == "AA=="
    check not body[0].hasKey("text")
