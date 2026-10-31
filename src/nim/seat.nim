## Один вход mazzy-shell к композитору.
## Hyprland: сокеты .socket.sock / .socket2.sock.
## Mango: сокет из MANGO_INSTANCE_SIGNATURE (mango выставляет его до exec_once).
## Команды Mango — те же, что у mmsg: одна строка с \n, ответ — JSON.
## Фокус окна: dispatch focusid client,<id>. Закрытие: dispatch killclient client,<id>.
## Стол: dispatch view,<номер>,0. Номер 1..9 — тег, не битовая маска.
import std/[os, net, json, strutils, posix]
import hypr, mazzy_common

const DeskCount* = 9

type
  SeatKind* = enum skNone, skHyprland, skMango
  SeatNote* = object
    ws*: int
    focus*: string
    closed*: string

proc nodeExists(path: string): bool =
  ## fileExists в Nim 2 считает только обычные файлы. IPC — это unix-сокет.
  if path.len == 0: return false
  var st: Stat
  stat(path.cstring, st) == 0

proc seatKind*(): SeatKind =
  ## Hyprland важнее: пока его сокет есть, оболочка не говорит с Mango.
  let sig = getEnv("HYPRLAND_INSTANCE_SIGNATURE")
  if sig.len > 0:
    let sock = getEnv("XDG_RUNTIME_DIR", "/tmp") / "hypr" / sig / ".socket.sock"
    if nodeExists(sock): return skHyprland
  let mango = getEnv("MANGO_INSTANCE_SIGNATURE")
  if mango.len > 0 and nodeExists(mango): return skMango
  skNone

proc mangoPath(): string = getEnv("MANGO_INSTANCE_SIGNATURE")

proc mangoQuery*(req: string, timeout = 800): string =
  let path = mangoPath()
  if path.len == 0: return
  var s = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  defer: s.close()
  try:
    s.connectUnix(path)
    s.send(req & "\n")
    var buf = newString(65536)
    while true:
      let n = s.recv(buf, 65536, timeout = timeout)
      if n <= 0: break
      result.add buf[0 ..< n]
  except CatchableError:
    discard

proc mangoJson(req: string): JsonNode =
  let s = mangoQuery(req).strip
  if s.len == 0: return newJNull()
  try: parseJson(s)
  except CatchableError: newJNull()

proc mangoWatchFd(cmd: string): cint =
  let path = mangoPath()
  if path.len == 0 or not nodeExists(path):
    raise newException(OSError, "mango socket missing")
  var s = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  s.connectUnix(path)
  s.send(cmd & "\n")
  result = s.getFd().cint
  GC_ref(s)

proc jBool(n: JsonNode): bool = n != nil and n.kind == JBool and n.getBool

proc jInt(n: JsonNode, default: int): int =
  if n == nil or n.kind == JNull: default
  elif n.kind == JInt: n.getInt
  elif n.kind == JFloat: int(n.getFloat)
  else: default

proc jStr(n: JsonNode): string =
  if n == nil or n.kind != JString: "" else: n.getStr

proc seatLayoutRead*(): tuple[ok: bool, name: string] =
  ## ok = false — сокет молчит, прошлый знак на панели оставляем.
  ## ok = true и пустое имя — знака нет. Это честный пустой ответ, не сбой.
  case seatKind()
  of skMango:
    let raw = mangoQuery("get keyboardlayout").strip
    if raw.len == 0: return (false, "")
    try:
      let node = parseJson(raw)
      if node.kind != JObject: return (false, "")
      (true, jStr(node{"layout"}))
    except CatchableError:
      (false, "")
  of skHyprland:
    let node = hyprJson("j/devices")
    if node.kind != JObject: return (false, "")
    let keys = node{"keyboards"}
    if keys == nil or keys.kind != JArray: return (true, "")
    for k in keys:
      if k.kind != JObject: continue
      let name = jStr(k{"active_keymap"})
      if name.len > 0: return (true, name)
    (true, "")
  of skNone:
    (false, "")

proc seatLayoutCycle*() =
  ## Следующая группа. Вызов только по щелчку знака, не из проверки.
  case seatKind()
  of skMango: discard mangoQuery("dispatch switch_keyboard_layout")
  of skHyprland: hyprDispatch("switchxkblayout all next")
  of skNone: discard

proc jFloat(n: JsonNode): float =
  if n == nil or n.kind == JNull: 0
  elif n.kind == JFloat: n.getFloat
  elif n.kind == JInt: n.getInt.float
  else: 0

proc jsonId(n: JsonNode): string =
  if n == nil or n.kind == JNull: ""
  elif n.kind == JInt:
    let id = n.getInt
    if id > 0: $id else: ""
  elif n.kind == JString: n.getStr
  else: ""

proc activeTagFrom(j: JsonNode): int =
  ## Первый активный тег первого монитора. 0 — в ответе нет активного тега.
  let tags = j{"all_tags"}
  if tags == nil or tags.kind != JArray: return
  for mon in tags:
    if mon.kind != JObject: continue
    let arr = mon{"tags"}
    if arr == nil or arr.kind != JArray: continue
    for t in arr:
      if t.kind == JObject and jBool(t{"is_active"}):
        let id = jInt(t{"index"}, 0)
        if id in 1 .. 20: return id

proc mangoClients(): seq[Win] =
  let j = mangoJson("get all-clients")
  let arr = j{"clients"}
  if arr == nil or arr.kind != JArray: return
  var focused: seq[Win]
  var rest: seq[Win]
  var seen: seq[string]
  for c in arr:
    if c.kind != JObject: continue
    if jBool(c{"is_minimized"}): continue
    let id = jsonId(c{"id"})
    if id.len == 0 or id in seen: continue
    let w = jInt(c{"width"}, 0)
    let h = jInt(c{"height"}, 0)
    if w <= 0 or h <= 0: continue
    let app = jStr(c{"appid"})
    let title = jStr(c{"title"})
    if app.len == 0 and title.len == 0: continue
    seen.add id
    var tag = 0
    let tags = c{"tags"}
    if tags != nil and tags.kind == JArray and tags.len > 0:
      tag = jInt(tags[0], 0)
    let win = Win(address: id, title: title, class: (if app.len > 0: app else: title),
                  ws: $tag, wsid: tag, capId: jStr(c{"foreign_toplevel_id"}),
                  x: jInt(c{"x"}, 0), y: jInt(c{"y"}, 0), w: w, h: h)
    if jBool(c{"is_focused"}): focused.add win
    else: rest.add win
  result = focused
  result.add rest

proc seatClients*(): seq[Win] =
  case seatKind()
  of skHyprland: clients()
  of skMango: mangoClients()
  of skNone: @[]

proc seatActiveWorkspace*(): int =
  case seatKind()
  of skHyprland:
    try: result = activeWorkspace()
    except CatchableError: result = 1
  of skMango:
    result = activeTagFrom(mangoJson("get all-tags"))
  of skNone:
    result = 1
  if result < 1: result = 1

proc seatCursor*(): (float, float) =
  case seatKind()
  of skHyprland: cursorPos()
  of skMango:
    let j = mangoJson("get cursorpos")
    (jFloat(j{"x"}), jFloat(j{"y"}))
  of skNone: (0.0, 0.0)

proc effectsCallHypr*(kind: SeatKind): bool =
  ## Страница эффектов зовёт hyprctl только на Hyprland. На Mango это была бы ложь.
  kind == skHyprland

proc seatView*(id: int) =
  if id < 1 or id > DeskCount: return
  case seatKind()
  of skHyprland: hyprDispatch("workspace " & $id)
  of skMango: discard mangoQuery("dispatch view," & $id & ",0")
  of skNone: discard

proc seatTake*(id: int) =
  ## Унести сфокусированное окно на стол и перейти туда.
  ## Hyprland movetoworkspace следует за окном. Mango tag тоже вызывает client_switch_view.
  if id < 1 or id > DeskCount: return
  case seatKind()
  of skHyprland: hyprDispatch("movetoworkspace " & $id)
  of skMango: discard mangoQuery("dispatch tag," & $id & ",0")
  of skNone: discard

proc seatOccupied*(): array[DeskCount, bool] =
  ## Точка на чипе, если на столе есть окно. Пустой ответ не рисует точки.
  case seatKind()
  of skHyprland:
    let j = hyprJson("j/workspaces")
    if j.kind != JArray: return
    for w in j:
      if w.kind != JObject: continue
      let id = jInt(w{"id"}, 0)
      if id >= 1 and id <= DeskCount and jInt(w{"windows"}, 0) > 0:
        result[id - 1] = true
  of skMango:
    let tags = mangoJson("get all-tags"){"all_tags"}
    if tags == nil or tags.kind != JArray: return
    for mon in tags:
      if mon.kind != JObject: continue
      let arr = mon{"tags"}
      if arr == nil or arr.kind != JArray: continue
      for t in arr:
        if t.kind != JObject: continue
        let id = jInt(t{"index"}, 0)
        if id >= 1 and id <= DeskCount and jInt(t{"client_count"}, 0) > 0:
          result[id - 1] = true
      break
  of skNone: discard

proc seatFocus*(w: Win) =
  ## Hyprland: со special-стола окно сначала переносится на текущий.
  ## Mango focusid сам открывает тег окна (client_active).
  case seatKind()
  of skHyprland:
    if w.address.len == 0: return
    if w.ws.startsWith("special:"):
      var cur = 1
      try: cur = activeWorkspace()
      except CatchableError: discard
      hyprDispatch("movetoworkspace " & $cur & ",address:" & w.address)
    hyprDispatch("focuswindow address:" & w.address)
  of skMango:
    if w.address.len == 0: return
    discard mangoQuery("dispatch focusid client," & w.address)
  of skNone: discard

proc seatClose*(address: string) =
  if address.len == 0: return
  case seatKind()
  of skHyprland: hyprDispatch("closewindow address:" & address)
  of skMango: discard mangoQuery("dispatch killclient client," & address)
  of skNone: discard

proc seatEventsFd*(): cint =
  ## Hyprland: поток socket2. Mango: watch all-tags (arrange шлёт его на смену тега и фокуса).
  case seatKind()
  of skHyprland: hyprEventsFd()
  of skMango: mangoWatchFd("watch all-tags")
  of skNone: raise newException(OSError, "no compositor socket")

proc seatFocusedAddress*(): string =
  if seatKind() != skMango: return ""
  jsonId(mangoJson("get focusing-client"){"id"})

proc seatReloadConfig*(): bool =
  ## Живой Mango перечитывает toml без exec_once. На Hyprland — ложь, hyprctl не трогаем.
  if seatKind() != skMango: return false
  let r = mangoQuery("dispatch reload_config", timeout = 4000).replace(" ", "")
  "\"success\":true" in r

proc seatParseLine*(line: string): SeatNote =
  ## Строка socket2 Hyprland или JSON watch all-tags Mango.
  if line.startsWith("activewindowv2>>"):
    let a = hyprAddr(line[16 .. ^1])
    if a.len > 2: result.focus = a
  elif line.startsWith("workspacev2>>"):
    ## Hyprland 0.56: workspacev2>>id,name. Имя может быть не числом.
    let rest = line[13 .. ^1]
    let comma = rest.find(',')
    let idPart = if comma >= 0: rest[0 ..< comma] else: rest
    try:
      let id = parseInt(idPart.strip())
      if id in 1 .. 20: result.ws = id
    except ValueError: discard
  elif line.startsWith("workspace>>"):
    try:
      let id = parseInt(line[11 .. ^1].strip())
      if id in 1 .. 20: result.ws = id
    except ValueError: discard
  elif line.startsWith("closewindow>>"):
    let a = hyprAddr(line[13 .. ^1])
    if a.len > 2: result.closed = a
  elif line.len > 0 and line[0] == '{':
    try:
      result.ws = activeTagFrom(parseJson(line))
    except CatchableError:
      discard
