# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Protocol version negotiation.
##
## `datcontext` is dual-era. Modern revisions (`2026-07-28` and later) declare
## version and capabilities as per-request `_meta` with no handshake; legacy
## revisions (`2025-11-25` and earlier) establish a session through
## `initialize`. Both are served, and a request's own metadata decides which
## semantics apply.

import ./errors

const
  ProtocolVersion* = "2026-07-28"
  ## The revision this server prefers and reports as its own version.

const
  SupportedVersions*: seq[string] = @[
    "2026-07-28",
    "2025-11-25",
    "2025-06-18",
    "2025-03-26",
    "2024-11-05",
  ]
  ## Every revision this server can speak, newest first. Reported in
  ## `server/discover` and in `UnsupportedProtocolVersionError`.

const
  ModernVersions*: seq[string] = @["2026-07-28"]
  ## Revisions that carry version and capabilities as per-request `_meta`.

  LegacyVersions*: seq[string] = @[
    "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05",
  ]
  ## Revisions that expect an `initialize` handshake.

type
  ProtocolEra* = enum
    ## How a given request expects to be served.
    eraModern,  ## per-request `_meta`, stateless
    eraLegacy   ## `initialize` handshake, connection-scoped

proc isModern*(version: string): bool =
  ## True when `version` carries per-request metadata rather than relying on an
  ## `initialize` handshake.
  version in ModernVersions

proc isLegacy*(version: string): bool =
  ## True when `version` predates the stateless model.
  version in LegacyVersions

proc isSupported*(version: string): bool =
  ## True when this server can serve `version`.
  version in SupportedVersions

proc eraFor*(version: string): ProtocolEra =
  ## The serving era for a negotiated `version`.
  if isModern(version): eraModern else: eraLegacy

proc negotiate*(requested: string; supported: openArray[string] = SupportedVersions): string =
  ## Pick the version to serve for a client-requested `requested`.
  ##
  ## An exact match is served as-is. An empty request defaults to `ProtocolVersion`.
  ## Otherwise the server does NOT guess on the client's behalf: it raises
  ## `UnsupportedProtocolVersionError` advertising what it does support, and the
  ## client selects a mutually supported version and retries.
  if requested.len == 0:
    return ProtocolVersion
  if isSupported(requested):
    return requested
  raise newMcpError(
    ecUnsupportedProtocolVersion,
    "Unsupported protocol version",
    versionUnsupportedData(requested, supported))