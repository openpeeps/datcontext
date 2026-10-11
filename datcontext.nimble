# Package

version       = "0.1.0"
author        = "George Lemon"
description   = "MCP client/server library over powpow transports with optional openparser tools"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 2.2.12"
requires "powpow >= 0.2.1"
requires "openparser >= 0.3.9"
requires "flysystem >= 0.2.0"


# Tasks

task examples, "Build the example server and Unix socket client":
  exec "clue build examples/mcp_full_server.nim --out:bin/example_full_server"
  exec "clue build examples/mcp_unix_client.nim --out:bin/example_unix_client"
