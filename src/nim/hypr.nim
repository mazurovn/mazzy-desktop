## IPC с Hyprland: запросы через .socket.sock (JSON) и поток событий .socket2.sock
import std/[os, net, json, strutils, posix, algorithm]

proc hyprDir*(): string =
  getEnv("XDG_RUNTIME_DIR", "/tmp") / "hypr" / getEnv("HYPRLAND_INSTANCE_SIGNATURE")

proc hyprQuery*(req: string): string =
  ## Один запрос — одно соединение (как hyprctl). "j/clients" → JSON.
  var s = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  defer: s.close()
  try:
    s.connectUnix(hyprDir() / ".socket.sock")
    s.send(req)
    var buf = newString(65536)
    while true:
      let n = s.recv(buf, 65536, timeout = 500)
      if n <= 0: break
      result.add buf[0 ..< n]
  except CatchableError:
    discard

proc hyprJson*(req: string): JsonNode =
  let s = hyprQuery(req)
  try: parseJson(s)
  except CatchableError: newJNull()

proc hyprDispatch*(args: string) = discard hyprQuery("dispatch " & args)

proc hyprEventsFd*(): cint =
  ## Подключение к потоку событий; вернёт fd для poll().
  var s = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  s.connectUnix(hyprDir() / ".socket2.sock")
  result = s.getFd().cint
  # сокет-объект отпускаем, fd остаётся открытым
  GC_ref(s)

proc readLines*(fd: cint, buf: var string): seq[string] =
  ## Неблокирующее дочитывание: вернёт готовые строки, хвост — в buf.
  var tmp = newString(8192)
  let n = posix.read(fd, addr tmp[0], 8192)
  if n > 0:
    buf.add tmp[0 ..< n]
    while true:
      let i = buf.find('\n')
      if i < 0: break
      result.add buf[0 ..< i]
      buf = buf[i + 1 .. ^1]

type Win* = object
  address*, title*, class*, ws*, capId*: string
  wsid*, x*, y*, w*, h*: int

proc jBool(n: JsonNode): bool = n != nil and n.kind == JBool and n.getBool

proc jInt(n: JsonNode, default: int): int =
  if n == nil or n.kind == JNull: default
  elif n.kind == JInt: n.getInt
  elif n.kind == JFloat: int(n.getFloat)
  else: default

proc jStr(n: JsonNode): string =
  if n == nil or n.kind != JString: "" else: n.getStr

proc clients*(): seq[Win] =
  ## Окна в порядке недавнего фокуса (focusHistoryID), без скрытых.
  ## Один проход: пропущенное поле не роняет список и не сдвигает индекс.
  let j = hyprJson("j/clients")
  if j.kind != JArray: return
  var keyed: seq[(int, Win)]
  for c in j:
    if c.kind != JObject: continue
    if not jBool(c{"mapped"}) or jBool(c{"hidden"}): continue
    let cls = jStr(c{"class"})
    if cls.len == 0: continue
    let size = c{"size"}
    if size == nil or size.kind != JArray or size.len < 2: continue
    let w = jInt(size[0], 0)
    let h = jInt(size[1], 0)
    if w <= 0 or h <= 0: continue
    let at = c{"at"}
    let ws = c{"workspace"}
    keyed.add((jInt(c{"focusHistoryID"}, 999),
               Win(address: jStr(c{"address"}), title: jStr(c{"title"}), class: cls,
                   ws: (if ws == nil: "" else: jStr(ws{"name"})),
                   wsid: (if ws == nil: 0 else: jInt(ws{"id"}, 0)),
                   x: (if at == nil or at.kind != JArray or at.len < 1: 0 else: jInt(at[0], 0)),
                   y: (if at == nil or at.kind != JArray or at.len < 2: 0 else: jInt(at[1], 0)),
                   w: w, h: h)))
  keyed.sort(proc(a, b: (int, Win)): int = cmp(a[0], b[0]))
  for k in keyed: result.add k[1]

proc activeWorkspace*(): int = hyprJson("j/activeworkspace"){"id"}.getInt(1)

proc cursorPos*(): (float, float) =
  ## Сырой ответ "x, y" — без JSON-парсинга (вызывается несколько раз в секунду)
  let r = hyprQuery("cursorpos").split(",")
  if r.len < 2: return (0.0, 0.0)
  try: (parseFloat(r[0].strip()), parseFloat(r[1].strip()))
  except ValueError: (0.0, 0.0)
