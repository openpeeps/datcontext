# Package

version       = "0.1.0"
author        = "George Lemon"
description   = "MCP client/server exposing openparser as tools over powpow transports"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 2.2.12"
requires "powpow >= 0.2.1"
requires "openparser >= 0.3.9"
requires "flysystem >= 0.2.0"


# Binaries

bin = @["bin/datcontext"]


# Tasks

task build, "Build the server binary":
  exec "clue build src/datcontext.nim --out:bin/datcontext"

task testSmoke, "Run the spawn-based round-trip tests against the built binary":
  ## The round-trip suite spawns bin/datcontext, so the binary has to be current.
  exec "clue build src/datcontext.nim --out:bin/datcontext"
  exec "clue build tests/test_roundtrip.nim --out:bin/test_roundtrip"
  exec "./bin/test_roundtrip"

task testTools, "Print the tool catalogue as JSON":
  exec "clue build src/datcontext.nim --out:bin/datcontext"
  exec "./bin/datcontext tools"

task catalogue, "Print tools, resources, and prompts":
  exec "clue build src/datcontext.nim --out:bin/datcontext"
  exec "./bin/datcontext tools"
  exec "./bin/datcontext resources"
  exec "./bin/datcontext prompts"

task examples, "Build the example server and Unix socket client":
  exec "clue build examples/mcp_full_server.nim --out:bin/example_full_server"
  exec "clue build examples/mcp_unix_client.nim --out:bin/example_unix_client"
