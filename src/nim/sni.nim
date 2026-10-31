## Хост StatusNotifierWatcher. Не требует Hyprland и не рисует пиксели сам.
## Имя org.kde.StatusNotifierWatcher берём только если оно свободно, без подмены чужого хоста.
import std/[sequtils, strutils, times, os]

{.passC: staticExec("pkg-config --cflags gio-2.0").}
{.passL: staticExec("pkg-config --libs gio-2.0").}

{.emit: """
#include <gio/gio.h>
#include <stdio.h>

static GDBusInterfaceInfo *mazzy_watcher_iface(GDBusNodeInfo *n) {
  return n && n->interfaces ? n->interfaces[0] : NULL;
}

static int mazzy_icon_name(GDBusConnection *c, const char *service, const char *path,
                           char *out, int cap) {
  GError *err = NULL;
  GVariant *res;
  if (!c || !service || !path || cap < 2) { if (out) out[0] = 0; return 0; }
  res = g_dbus_connection_call_sync(c, service, path,
    "org.freedesktop.DBus.Properties", "Get",
    g_variant_new("(ss)", "org.kde.StatusNotifierItem", "IconName"),
    G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NONE, 200, NULL, &err);
  if (!res) { if (err) g_error_free(err); out[0] = 0; return 0; }
  GVariant *inner = NULL;
  g_variant_get(res, "(v)", &inner);
  g_variant_unref(res);
  if (!inner || !g_variant_is_of_type(inner, G_VARIANT_TYPE_STRING)) {
    if (inner) g_variant_unref(inner);
    out[0] = 0;
    return 0;
  }
  const char *s = g_variant_get_string(inner, NULL);
  snprintf(out, (size_t)cap, "%s", s ? s : "");
  g_variant_unref(inner);
  return 1;
}

static int mazzy_copy_string(GVariant *v, char *out, int cap) {
  if (!out || cap < 2) return 0;
  out[0] = 0;
  if (!v || !g_variant_is_of_type(v, G_VARIANT_TYPE_STRING)) return 0;
  const char *s = g_variant_get_string(v, NULL);
  snprintf(out, (size_t)cap, "%s", s ? s : "");
  return 1;
}

static void mazzy_emit_registered(GDBusConnection *c, const char *service) {
  GError *err = NULL;
  if (!c || !service) return;
  g_dbus_connection_emit_signal(c, NULL, "/StatusNotifierWatcher",
    "org.kde.StatusNotifierWatcher", "StatusNotifierItemRegistered",
    g_variant_new("(s)", service), &err);
  if (err) g_error_free(err);
}

static GDBusInterfaceVTable mazzy_vt;

static void mazzy_set_vtable(void *method, void *get, void *set) {
  mazzy_vt.method_call = (GDBusInterfaceMethodCallFunc)method;
  mazzy_vt.get_property = (GDBusInterfaceGetPropertyFunc)get;
  mazzy_vt.set_property = (GDBusInterfaceSetPropertyFunc)set;
}

static unsigned int mazzy_register_watcher(GDBusConnection *c, GDBusInterfaceInfo *iface, GError **err) {
  return g_dbus_connection_register_object(c, "/StatusNotifierWatcher", iface,
    &mazzy_vt, NULL, NULL, err);
}

static unsigned int mazzy_subscribe_owner(GDBusConnection *c, void *cb) {
  return g_dbus_connection_signal_subscribe(c,
    "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
    "/org/freedesktop/DBus", NULL, G_DBUS_SIGNAL_FLAGS_NONE,
    (GDBusSignalCallback)cb, NULL, NULL);
}

static unsigned int mazzy_own_watcher(GDBusConnection *c, void *acquired, void *lost) {
  return g_bus_own_name_on_connection(c, "org.kde.StatusNotifierWatcher",
    G_BUS_NAME_OWNER_FLAGS_DO_NOT_QUEUE,
    (GBusNameAcquiredCallback)acquired, (GBusNameLostCallback)lost,
    NULL, NULL);
}

static void mazzy_activate_done(GObject *src, GAsyncResult *res, gpointer data) {
  GError *err = NULL;
  GVariant *out = g_dbus_connection_call_finish((GDBusConnection *)src, res, &err);
  if (out) g_variant_unref(out);
  if (err) g_error_free(err);
}

static void mazzy_activate(GDBusConnection *c, const char *service, const char *path, int x, int y) {
  if (!c || !service || !service[0] || !path || !path[0]) return;
  g_dbus_connection_call(c, service, path,
    "org.kde.StatusNotifierItem", "Activate",
    g_variant_new("(ii)", x, y),
    NULL, G_DBUS_CALL_FLAGS_NONE, 800, NULL,
    mazzy_activate_done, NULL);
}
""".}

type
  GDBusConnection {.importc: "GDBusConnection", header: "<gio/gio.h>", incompleteStruct.} = object
  GDBusNodeInfo {.importc: "GDBusNodeInfo", header: "<gio/gio.h>", incompleteStruct.} = object
  GDBusInterfaceInfo {.importc: "GDBusInterfaceInfo", header: "<gio/gio.h>", incompleteStruct.} = object
  GDBusMethodInvocation {.importc: "GDBusMethodInvocation", header: "<gio/gio.h>", incompleteStruct.} = object
  GVariant {.importc: "GVariant", header: "<glib.h>", incompleteStruct.} = object
  GError {.importc: "GError", header: "<glib.h>", incompleteStruct.} = object

proc g_bus_get_sync(bus: cint, cancellable: pointer, err: ptr ptr GError): ptr GDBusConnection {.importc, header: "<gio/gio.h>".}
proc g_bus_unown_name(id: cuint) {.importc, header: "<gio/gio.h>".}
proc g_dbus_node_info_new_for_xml(xml: cstring, err: ptr ptr GError): ptr GDBusNodeInfo {.importc, header: "<gio/gio.h>".}
proc mazzy_watcher_iface(n: ptr GDBusNodeInfo): ptr GDBusInterfaceInfo {.importc, nodecl.}
proc g_dbus_connection_unregister_object(connection: ptr GDBusConnection, id: cuint) {.importc, header: "<gio/gio.h>".}
proc mazzy_set_vtable(call, get, set: pointer) {.importc, nodecl.}
proc mazzy_register_watcher(c: ptr GDBusConnection, iface: ptr GDBusInterfaceInfo, err: ptr ptr GError): cuint {.importc, nodecl.}
proc mazzy_subscribe_owner(c: ptr GDBusConnection, cb: pointer): cuint {.importc, nodecl.}
proc mazzy_own_watcher(c: ptr GDBusConnection, acquired, lost: pointer): cuint {.importc, nodecl.}
proc g_dbus_method_invocation_get_sender(invocation: ptr GDBusMethodInvocation): cstring {.importc, header: "<gio/gio.h>".}
proc g_dbus_method_invocation_return_value(invocation: ptr GDBusMethodInvocation, parameters: ptr GVariant) {.importc, header: "<gio/gio.h>".}
proc g_variant_get_child_value(value: ptr GVariant, index: uint): ptr GVariant {.importc, header: "<glib.h>".}
proc g_variant_get_string(value: ptr GVariant, length: pointer): cstring {.importc, header: "<glib.h>".}
proc g_variant_unref(value: ptr GVariant) {.importc, header: "<glib.h>".}
proc g_variant_new_boolean(value: cint): ptr GVariant {.importc, header: "<glib.h>".}
proc g_variant_new_int32(value: int32): ptr GVariant {.importc, header: "<glib.h>".}
proc g_variant_new_strv(strv: pointer, length: int64): ptr GVariant {.importc, header: "<glib.h>".}
proc g_variant_new_tuple(children: pointer, n: uint): ptr GVariant {.importc, header: "<glib.h>".}
proc g_error_free(err: ptr GError) {.importc, header: "<glib.h>".}
proc g_main_context_iteration(ctx: pointer, may_block: cint): cint {.importc, header: "<glib.h>".}
proc mazzy_icon_name(c: ptr GDBusConnection, service, path, outp: cstring, cap: cint): cint {.importc, nodecl.}
proc mazzy_copy_string(v: ptr GVariant, outp: cstring, cap: cint): cint {.importc, nodecl.}
proc mazzy_emit_registered(c: ptr GDBusConnection, service: cstring) {.importc, nodecl.}
proc mazzy_activate(c: ptr GDBusConnection, service, path: cstring, x, y: cint) {.importc, nodecl.}

const WatcherXml = """
<node>
  <interface name="org.kde.StatusNotifierWatcher">
    <method name="RegisterStatusNotifierItem">
      <arg name="service" type="s" direction="in"/>
    </method>
    <method name="RegisterStatusNotifierHost">
      <arg name="service" type="s" direction="in"/>
    </method>
    <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
    <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
    <property name="ProtocolVersion" type="i" access="read"/>
    <signal name="StatusNotifierItemRegistered">
      <arg name="service" type="s"/>
    </signal>
    <signal name="StatusNotifierItemUnregistered">
      <arg name="service" type="s"/>
    </signal>
    <signal name="StatusNotifierHostRegistered"/>
  </interface>
</node>
"""

type Item = object
  service, path, icon: string

var
  bus: ptr GDBusConnection
  node: ptr GDBusNodeInfo
  ownerId, regId: cuint
  owned: bool
  generation: int
  items: seq[Item]
  vtableBound: bool

proc sniOwned*(): bool = owned
proc sniCount*(): int = items.len
proc sniGeneration*(): int = generation

proc sniService*(i: int): string =
  if i >= 0 and i < items.len: items[i].service else: ""

proc sniIcon*(i: int): string =
  if i >= 0 and i < items.len: items[i].icon else: ""

proc sniPath*(i: int): string =
  if i >= 0 and i < items.len: items[i].path else: ""

proc sniActivate*(i, x, y: int) =
  ## Щелчок Activate без ожидания ответа. Синхронный вызов шины здесь встанет в дедлок.
  if bus == nil or i < 0 or i >= items.len: return
  mazzy_activate(bus, items[i].service.cstring, items[i].path.cstring, cint(x), cint(y))

proc sniSplit*(argument, sender: string): tuple[service, path: string] =
  ## Аргумент с «/» — путь объекта, отправитель — сервис. Иначе аргумент — имя сервиса.
  if argument.startsWith("/"):
    (sender, argument)
  elif argument.len > 0:
    (argument, "/StatusNotifierItem")
  else:
    (sender, "/StatusNotifierItem")

proc variantString(v: ptr GVariant): string =
  if v == nil: return ""
  var buf = newString(255)
  if mazzy_copy_string(v, buf.cstring, 255) == 0: return ""
  $cast[cstring](addr buf[0])

proc onGet(connection: ptr GDBusConnection, sender, object_path, interface_name, property_name: cstring,
           error: ptr ptr GError, user_data: pointer): ptr GVariant {.cdecl.} =
  let name = $property_name
  if name == "ProtocolVersion":
    return g_variant_new_int32(0)
  if name == "IsStatusNotifierHostRegistered":
    return g_variant_new_boolean(1)
  if name == "RegisteredStatusNotifierItems":
    var names = newSeq[cstring](items.len)
    for i, it in items:
      names[i] = it.service.cstring
    let p = if names.len == 0: nil else: cast[pointer](addr names[0])
    return g_variant_new_strv(p, names.len.int64)
  nil

proc onSet(connection: ptr GDBusConnection, sender, object_path, interface_name, property_name: cstring,
           value: ptr GVariant, error: ptr ptr GError, user_data: pointer): cint {.cdecl.} =
  0

proc dropService(service: string) =
  let before = items.len
  items.keepItIf(it.service != service)
  if items.len != before: generation += 1

proc onOwner(connection: ptr GDBusConnection, sender, path, iface, member: cstring, parameters: ptr GVariant,
             user_data: pointer) {.cdecl.} =
  if parameters == nil: return
  let nameV = g_variant_get_child_value(parameters, 0)
  let newV = g_variant_get_child_value(parameters, 2)
  let name = variantString(nameV)
  let neu = variantString(newV)
  if nameV != nil: g_variant_unref(nameV)
  if newV != nil: g_variant_unref(newV)
  if neu.len == 0 and name.len > 0: dropService(name)

proc onMethod(connection: ptr GDBusConnection, sender, object_path, interface_name, method_name: cstring,
              parameters: ptr GVariant, invocation: ptr GDBusMethodInvocation, user_data: pointer) {.cdecl.} =
  let callName = $method_name
  if callName == "RegisterStatusNotifierHost":
    g_dbus_method_invocation_return_value(invocation, g_variant_new_tuple(nil, 0))
    return
  if callName != "RegisterStatusNotifierItem":
    g_dbus_method_invocation_return_value(invocation, g_variant_new_tuple(nil, 0))
    return
  var arg = ""
  if parameters != nil:
    let child = g_variant_get_child_value(parameters, 0)
    arg = variantString(child)
    if child != nil: g_variant_unref(child)
  let who = if sender == nil: "" else: $sender
  let parts = sniSplit(arg, who)
  var known = false
  for it in items:
    if it.service == parts.service and it.path == parts.path: known = true
  if not known and parts.service.len > 0:
    var icon = ""
    var buf = newString(255)
    if mazzy_icon_name(bus, parts.service.cstring, parts.path.cstring, buf.cstring, 255) != 0:
      icon = $cast[cstring](addr buf[0])
    items.add Item(service: parts.service, path: parts.path, icon: icon)
    generation += 1
    mazzy_emit_registered(bus, parts.service.cstring)
  g_dbus_method_invocation_return_value(invocation, g_variant_new_tuple(nil, 0))

proc onAcquired(connection: ptr GDBusConnection, name: cstring, user_data: pointer) {.cdecl.} =
  owned = true
  generation += 1

proc onLost(connection: ptr GDBusConnection, name: cstring, user_data: pointer) {.cdecl.} =
  owned = false
  generation += 1

proc sniPump*() =
  if bus == nil: return
  for _ in 0 ..< 8:
    if g_main_context_iteration(nil, 0) == 0: break

proc sniWaitOwned*(ms: int): bool =
  let deadline = epochTime() + ms.float / 1000
  while epochTime() < deadline:
    sniPump()
    if owned: return true
    sleep(10)
  owned

proc sniStart*(): bool =
  if bus != nil: return true
  var err: ptr GError
  bus = g_bus_get_sync(2, nil, addr err)
  if bus == nil:
    if err != nil: g_error_free(err)
    return false
  err = nil
  node = g_dbus_node_info_new_for_xml(WatcherXml.cstring, addr err)
  if node == nil:
    if err != nil: g_error_free(err)
    return false
  if not vtableBound:
    mazzy_set_vtable(cast[pointer](onMethod), cast[pointer](onGet), cast[pointer](onSet))
    vtableBound = true
  err = nil
  regId = mazzy_register_watcher(bus, mazzy_watcher_iface(node), addr err)
  if regId == 0:
    if err != nil: g_error_free(err)
    return false
  discard mazzy_subscribe_owner(bus, cast[pointer](onOwner))
  ownerId = mazzy_own_watcher(bus, cast[pointer](onAcquired), cast[pointer](onLost))
  ownerId != 0

proc sniStop*() =
  if bus != nil and regId != 0:
    g_dbus_connection_unregister_object(bus, regId)
  if ownerId != 0:
    g_bus_unown_name(ownerId)
  ownerId = 0
  regId = 0
  owned = false
  items.setLen(0)
  generation += 1
