#!/usr/bin/env nim
# datcontext — MCP server exposing openparser, on powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## The `datcontext` binary.
##
## Transport is chosen by subcommand:
##
##   datcontext stdio            speak MCP on stdin/stdout (default)
##   datcontext http [port]      serve Streamable HTTP
##   datcontext unix <path>      serve over a Unix domain socket
##   datcontext tcp <port>       serve over TCP
##   datcontext tools            print the tool catalogue and exit
##
## All logging goes to stderr; stdout carries MCP messages only, which the stdio
## binding requires.

import std/os
import std/strutils
import powpow
import openparser/json
import datcontext/server/core
import datcontext/server/http
import datcontext/server/signals
import datcontext/server/stdio
import datcontext/server/stream
import datcontext/prompts
import datcontext/resources
import datcontext/tools/tool

const
  Usage = """
datcontext — MCP server for openparser

usage:
  datcontext stdio                 speak MCP on stdin/stdout (default)
  datcontext http [port]           serve Streamable HTTP (default 9000)
  datcontext unix <path>           serve over a Unix domain socket
  datcontext tcp <port>            serve over TCP
  datcontext tools                 print the tool catalogue as JSON
  datcontext resources             print the resource catalogue as JSON
  datcontext prompts               print the prompt catalogue as JSON

environment:
  DATCONTEXT_MAX_SOURCE_BYTES      cap on any single parsed document
  DATCONTEXT_FILE_ROOT             enable file:// resources under this directory
"""

proc fail(msg: string) =
  stderr.writeLine("datcontext: " & msg)
  stderr.writeLine(Usage)
  quit(1)

proc mainStdio() =
  let srv = newMcpServer(fileRoot = os.getEnv("DATCONTEXT_FILE_ROOT"))
  srv.runStdio(newLoop())

proc mainTools() =
  let srv = newMcpServer()
  echo $srv.registry.listJson

proc mainResources() =
  let srv = newMcpServer()
  echo $srv.resources.listJson

proc mainPrompts() =
  let srv = newMcpServer()
  echo $srv.prompts.listJson

proc mainHttp(port: int) =
  let srv = newMcpServer(fileRoot = os.getEnv("DATCONTEXT_FILE_ROOT"))
  srv.runHttp(port)

proc mainUnix(path: string) =
  let srv = newMcpServer(fileRoot = os.getEnv("DATCONTEXT_FILE_ROOT"))
  srv.runUnix(path)

proc mainTcp(port: int) =
  let srv = newMcpServer(fileRoot = os.getEnv("DATCONTEXT_FILE_ROOT"))
  srv.runTcp(port)

when isMainModule:
  let args = commandLineParams()
  let cmd = if args.len > 0: args[0] else: "stdio"

  case cmd
  of "stdio":
    mainStdio()
  of "tools":
    mainTools()
  of "resources":
    mainResources()
  of "prompts":
    mainPrompts()
  of "http":
    mainHttp(if args.len > 1: parseInt(args[1]) else: 9000)
  of "unix":
    if args.len < 2:
      fail("unix requires a socket path")
    mainUnix(args[1])
  of "tcp":
    if args.len < 2:
      fail("tcp requires a port")
    mainTcp(parseInt(args[1]))
  of "--help", "-h", "help":
    echo Usage
  else:
    fail("unknown subcommand: " & cmd)