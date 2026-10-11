# datcontext — MCP client/server exposing openparser over powpow transports.
#
# (c) 2026 George Lemon | MIT License
#          Made by Humans from OpenPeeps
#          https://github.com/openpeeps/datcontext

## Subscriptions.
##
## `subscriptions/listen` is a long-lived request: its response is not a payload
## but an open stream of notifications. That is why `SubscriptionManager.emit`
## is supplied by the transport rather than by the server core — the transport
## is the only thing that knows where bytes go (an SSE stream on HTTP, the shared
## channel on stdio).
##
## The specification is strict about ordering: the acknowledgment carrying the
## subscription id MUST be the first message on the stream, and no notification
## may precede it. `open` therefore returns the acknowledged filter and the
## transport sends the ack before wiring up `emit`.
##
## Because MCP is stateless, a subscription lives only as long as the request that
## opened it. Nothing here is persisted across a reconnect; the client is
## required to re-send `subscriptions/listen`.

import std/locks
import openparser/json
import ./protocol/meta

type
  NotificationFilter* = object
    ## Which notification types a client asked for.
    ##
    ## An omitted field means "not subscribed"; the server MUST NOT send a type
    ## the client did not request.
    toolsListChanged*: bool
    promptsListChanged*: bool
    resourcesListChanged*: bool
    resourceSubscriptions*: seq[string]

  Subscription* = ref object
    ## One active subscription.
    id*: string
    ## The JSON-RPC id of the originating `subscriptions/listen` request, which
    ## is what every notification on the stream carries in `_meta`.
    filter*: NotificationFilter
    emit*: proc(msg: JsonNode) {.closure.}
    ## Transport-supplied sink, receiving the complete notification message.
    ## Wrapping happens here rather than in each transport so the subscription id
    ## is attached in exactly one place.
    closed*: bool
    ## Set by `close`; makes further emissions no-ops.

  SubscriptionManager* = ref object
    ## The server's active subscriptions.
    subs*: seq[Subscription]
    lock: Lock

proc newSubscriptionManager*(): SubscriptionManager =
  ## An empty manager.
  result = SubscriptionManager()
  initLock(result.lock)

proc parseFilter*(params: JsonNode): NotificationFilter =
  ## Read the `notifications` filter from request params.
  result = NotificationFilter()
  if params.isNil or params.kind != JObject:
    return
  let f = params{"notifications"}
  if f.isNil or f.kind != JObject:
    return

  proc flag(key: string): bool =
    let v = f{key}
    v != nil and v.kind == JBool and v.getBool

  result.toolsListChanged = flag("toolsListChanged")
  result.promptsListChanged = flag("promptsListChanged")
  result.resourcesListChanged = flag("resourcesListChanged")
  let rs = f{"resourceSubscriptions"}
  if rs != nil and rs.kind == JArray:
    for u in rs:
      if u.kind == JString:
        result.resourceSubscriptions.add(u.getStr)

proc isEmpty*(f: NotificationFilter): bool =
  ## True when the client asked for nothing.
  not f.toolsListChanged and not f.promptsListChanged and
    not f.resourcesListChanged and f.resourceSubscriptions.len == 0

proc filterJson*(f: NotificationFilter): JsonNode =
  ## Render a filter for the acknowledgment.
  ##
  ## Only the fields the server agreed to honour are present, so a client can
  ## tell what was dropped.
  result = newJObject()
  if f.toolsListChanged:
    result["toolsListChanged"] = newJBool(true)
  if f.promptsListChanged:
    result["promptsListChanged"] = newJBool(true)
  if f.resourcesListChanged:
    result["resourcesListChanged"] = newJBool(true)
  if f.resourceSubscriptions.len > 0:
    var arr = newJArray()
    for u in f.resourceSubscriptions:
      arr.add(newJString(u))
    result["resourceSubscriptions"] = arr

proc acknowledged*(id: string; filter: NotificationFilter): JsonNode =
  ## The `notifications/subscriptions/acknowledged` notification.
  result = newJObject()
  result["jsonrpc"] = newJString("2.0")
  result["method"] = newJString("notifications/subscriptions/acknowledged")
  var params = newJObject()
  # The ack carries the subscription id in _meta; on stdio every subscription
  # shares one channel, so this is how the client demultiplexes.
  setMeta(params, MetaSubscriptionId, id)
  params["notifications"] = filterJson(filter)
  result["params"] = params

proc notification*(id: string; methodName: string; params: JsonNode): JsonNode =
  ## Build a notification tagged with its subscription id.
  result = newJObject()
  result["jsonrpc"] = newJString("2.0")
  result["method"] = newJString(methodName)
  var p = if params.isNil: newJObject() else: params
  setMeta(p, MetaSubscriptionId, id)
  result["params"] = p

proc closedResult*(s: Subscription): JsonNode =
  ## The graceful-closure result for the originating request.
  ##
  ## The spec requires this when the server ends a subscription on its own
  ## initiative, so a client can tell a clean close from an abrupt disconnect.
  result = newJObject()
  result["resultType"] = newJString("complete")
  var meta = newJObject()
  meta[MetaSubscriptionId] = newJString(s.id)
  result["_meta"] = meta

proc register*(m: SubscriptionManager; id: string; filter: NotificationFilter;
               emit: proc(msg: JsonNode) {.closure.} = nil): Subscription =
  ## Open a subscription and return it.
  ##
  ## `emit` may be nil: the caller MUST send the acknowledgment before setting
  ## it, which is what guarantees no notification precedes the acknowledgment.
  result = Subscription(id: id, filter: filter, emit: emit)
  withLock m.lock:
    m.subs.add(result)

proc close*(m: SubscriptionManager; id: string): bool =
  ## Close a subscription by id. Returns whether one was found.
  withLock m.lock:
    for i, s in m.subs:
      if s.id == id:
        s.closed = true
        m.subs.delete(i)
        return true
  false

proc closeAll*(m: SubscriptionManager): seq[Subscription] =
  ## Close every subscription, returning them so the caller can send graceful
  ## closures.
  withLock m.lock:
    result = m.subs
    for s in m.subs:
      s.closed = true
    m.subs = @[]

proc active*(m: SubscriptionManager): int =
  ## Number of open subscriptions.
  withLock m.lock:
    result = m.subs.len

proc broadcast*(m: SubscriptionManager; methodName: string;
                params: JsonNode = nil) =
  ## Deliver a notification to every subscription that asked for it.
  ##
  ## The filter check happens here rather than at emit time so a client is never
  ## sent a type it did not request.
  withLock m.lock:
    for s in m.subs:
      if s.closed:
        continue
      let wanted =
        (methodName == "notifications/tools/list_changed" and
          s.filter.toolsListChanged) or
        (methodName == "notifications/prompts/list_changed" and
          s.filter.promptsListChanged) or
        (methodName == "notifications/resources/list_changed" and
          s.filter.resourcesListChanged) or
        (methodName == "notifications/resources/updated" and
          s.filter.resourceSubscriptions.len > 0)
      if wanted and s.emit != nil:
        s.emit(notification(s.id, methodName, params))

proc broadcastResourceUpdated*(m: SubscriptionManager; uri: string) =
  ## Notify subscribers watching a specific resource URI.
  withLock m.lock:
    for s in m.subs:
      if s.closed or s.emit == nil:
        continue
      if uri notin s.filter.resourceSubscriptions:
        continue
      var p = newJObject()
      p["uri"] = newJString(uri)
      s.emit(notification(s.id, "notifications/resources/updated", p))