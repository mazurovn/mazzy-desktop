## Общее для mazzy-shell и mazzy-settings: конфиг ~/.config/mazzy/settings.json (один источник дефолтов),
## команды демону по сокетам, эффекты Hyprland (conf/mazzy-effects.conf), разбор/запись conf/binds.conf.
import std/[os, json, net, strutils, osproc, tables, algorithm, posix]

const
  MesaEgl* = "__EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json"   # как в autostart.conf

proc expandHome*(p: string): string =
  ## `~/a` — каталог пользователя. Срез `p[1..]` даёт абсолютный `/a`, и `/` его не склеивает.
  if p == "~": return getHomeDir()
  if p.startsWith("~/"):
    let rest = p[2 .. ^1]
    return if rest.len == 0: getHomeDir() else: getHomeDir() / rest
  p

proc hyprAddr*(raw: string): string =
  ## Адрес окна в одном виде: события socket2 приходят и с «0x», и без.
  let a = raw.strip()
  if a.len == 0: return ""
  var h = a
  if h.startsWith("0x") or h.startsWith("0X"): h = h[2 .. ^1]
  "0x" & h.toLowerAscii()

proc lowHandle*(address: string): tuple[ok: bool, handle: uint32] =
  ## Младшие 32 бита адреса. parseHexInt не принимает префикс 0x.
  var h = address.strip()
  if h.startsWith("0x") or h.startsWith("0X"): h = h[2 .. ^1]
  if h.len == 0: return (false, 0'u32)
  if h.len > 8: h = h[^8 .. ^1]
  try: (true, uint32(parseHexInt(h)))
  except ValueError: (false, 0'u32)

proc captureOrder*(n, prefer: int): seq[int] =
  ## Сначала выбранная карточка, затем соседи по прямой ленте. Не с конца списка.
  if n <= 0: return @[]
  let p = ((prefer mod n) + n) mod n
  var idx = newSeq[int](n)
  for i in 0 ..< n: idx[i] = i
  result = idx.sortedByIt((abs(it - p), it))

proc configDir*(): string = getHomeDir() / ".config/mazzy"
proc configPath*(): string = configDir() / "settings.json"
proc hyprConf*(name: string): string = getHomeDir() / ".config/hypr/conf" / name
proc sockPath*(name: string): string = getEnv("XDG_RUNTIME_DIR", "/tmp") / ("mazzy-" & name & ".sock")

proc defaults*(): JsonNode =
  %*{
    "parallax": {"enabled": true, "mouse_px": 18, "workspace_px": 48, "zoom": 1.10, "smooth": 8.0, "mouse_hz": 8},
    "switcher": {"tilt": 55, "depth": 520, "spacing": 300, "center_gap": 380, "card_w": 1000, "card_h": 630,
                 "mouse_parallax": 60, "dim": 0.55, "reflection": true, "glow": true},
    "effects": {"blur": true, "blur_size": 2, "blur_passes": 1, "rounding": 12, "gaps_in": 6, "gaps_out": 14,
                "shadow": true, "inactive_opacity": 0.96, "dim_inactive": 0.06, "animations": true},
    "chrome": {"labels": false, "dismiss_ms": 1000, "opacity": 100, "style": "paper", "widgets": {
      "desks": true, "clock": true, "layout": true, "volume": true, "brightness": true, "battery": true,
      "network": true, "mic": true, "profile": true, "vpn": true, "tray": true,
      "dnd": true, "bluetooth": true, "media": true, "load": true, "cpu": true,
      "mem": true, "netio": true, "shot": true,
      "clip": false, "session": true, "scale": true}}
  }

proc load*(): JsonNode =
  ## Дефолты + файл: секции сливаются по ключам, лишние ключи файла сохраняются.
  result = defaults()
  try:
    let user = parseJson(readFile(configPath()))
    if user.kind == JObject:
      for sec, vals in user:
        if vals.kind != JObject: continue
        if not result.hasKey(sec): result[sec] = newJObject()
        for k, v in vals: result[sec][k] = v
  except CatchableError, OSError:
    discard

proc save*(cfg: JsonNode) =
  ## Атомарно: tmp + rename — демон не прочитает половину файла.
  createDir(configDir())
  let tmp = configPath() & ".tmp"
  writeFile(tmp, cfg.pretty(2) & "\n")
  moveFile(tmp, configPath())

proc send*(name, cmd: string): bool =
  ## Команда демону ("wallpaper"/"switcher"); false — не запущен.
  var s = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  defer: s.close()
  try:
    s.connectUnix(sockPath(name)); s.send(cmd & "\n"); true
  except CatchableError, OSError:
    false

proc cSignal(sig: cint, handler: pointer): pointer {.importc: "signal", header: "<signal.h>".}

template withChildWait*(body: untyped) =
  ## SIG_IGN в mazzy-settings ломает waitpid. На время вызова возвращаем прежний обработчик.
  let prevChild = cSignal(SIGCHLD, cast[pointer](SIG_DFL))
  try:
    body
  finally:
    discard cSignal(SIGCHLD, prevChild)

proc nightLightPlan*(hasBin, running: bool): tuple[cmd, note: string] =
  ## Нет бинаря — только текст. Тёплый слой отсюда не рисуется.
  if not hasBin:
    return ("", "Ночной свет: пакет wlsunset не установлен")
  if running:
    return ("pkill -x wlsunset", "Ночной свет выключен")
  ("wlsunset -t 4500", "Ночной свет включён")

proc detachSpawn*(args: seq[string]): int =
  ## setsid -f выходит сразу, внук не остаётся ребёнком этого процесса.
  ## poParentStreams: у внука нет трубы, которую родитель закроет.
  ## SIGCHLD не трогаем: подпись громкости сама ждёт waitpid.
  if args.len == 0: return 1
  let p = startProcess("/usr/bin/setsid", args = @["-f", "--"] & args,
                       options = {poParentStreams})
  try:
    result = waitForExit(p)
  finally:
    close(p)

proc carouselCaptures*(hypr, copy: bool): bool =
  ## Превью есть, если композитор отдаёт hyprland toplevel export или захват окна Mango.
  hypr or copy

proc captureBudget*(n: int): int =
  ## Центр и два соседа. Пустая лента — ни одного кадра.
  if n <= 0: 0 else: min(n, 3)

proc thumbScale*(w, h, cap: int): int =
  ## Целый шаг, чтобы длинная сторона миниатюры не превышала cap.
  if cap < 1: return 1
  let long = max(w, h)
  if long <= cap: return 1
  (long + cap - 1) div cap

proc shmBytesOk*(w, h: int): bool =
  ## Один полноразмерный кадр. Больше 12 МБ или сторона больше 8192 — не берём.
  if w < 1 or h < 1 or w > 8192 or h > 8192: return false
  w.int64 * h.int64 * 4 <= 12_000_000'i64

proc volumeIconName*(pct: int, muted: bool): string =
  ## Имя символического значка. Уровень неизвестен — средний, не «выключено».
  if muted: return "audio-volume-muted-symbolic"
  if pct < 0: return "audio-volume-medium-symbolic"
  if pct <= 0: return "audio-volume-muted-symbolic"
  if pct < 34: return "audio-volume-low-symbolic"
  if pct < 67: return "audio-volume-medium-symbolic"
  if pct > 100: return "audio-volume-overamplified-symbolic"
  "audio-volume-high-symbolic"

proc batteryIconName*(pct: int, charging: bool): string =
  ## Полоса Adwaita с шагом 10. Заряд 100 — отдельное имя charged.
  if pct < 0: return "battery-missing-symbolic"
  var band = ((pct + 5) div 10) * 10
  if band > 100: band = 100
  if charging and band >= 100: return "battery-level-100-charged-symbolic"
  let tail = if charging: "-charging-symbolic" else: "-symbolic"
  "battery-level-" & $band & tail

proc networkIconName*(online: bool): string =
  ## Без измерения сигнала. Имя connected — глиф темы, не уровень сети.
  if online: "network-wireless-connected-symbolic" else: "network-wireless-offline-symbolic"

proc controlsIconName*(): string =
  "view-app-grid-symbolic"

proc brightIconName*(): string =
  "display-brightness-symbolic"

proc pctClamp*(v: int): int =
  if v < 0: 0 elif v > 100: 100 else: v

proc brightPct*(cur, maxv: int): int =
  ## Проценты подсветки. Нет максимума — уровень неизвестен.
  if maxv <= 0 or cur < 0: return -1
  pctClamp(int(cur.float * 100 / maxv.float + 0.5))

proc sliderPct*(x, origin, width: float32): int =
  ## Позиция на дорожке ползунка, 0..100.
  if width <= 1: return 0
  var t = (x - origin) / width
  if t < 0: t = 0
  if t > 1: t = 1
  int(t * 100 + 0.5)

proc backlightDev*(): string =
  ## Имя подсветки в sysfs. intel_backlight предпочтителен, иначе первый каталог.
  let root = "/sys/class/backlight"
  if not dirExists(root): return ""
  if dirExists(root / "intel_backlight"): return "intel_backlight"
  for kind, path in walkDir(root):
    if kind == pcDir or kind == pcLinkToDir: return path.splitPath.tail
  ""

proc backlightDevOk*(dev: string): bool =
  ## Имя подсветки из sysfs. Чужой путь в команду не подставляем.
  if dev.len == 0 or dev.len > 64: return false
  for ch in dev:
    if ch notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '-', '.'}: return false
  true

proc backlightMax*(dev: string): int =
  if not backlightDevOk(dev): return -1
  try: parseInt(readFile("/sys/class/backlight" / dev / "max_brightness").strip)
  except CatchableError: -1

proc backlightAbs*(pct, maxv: int): int =
  ## Абсолютные единицы sysfs. Процент 40 от 4882 — 1953.
  if maxv <= 0: return -1
  int(pctClamp(pct).float * maxv.float / 100.0 + 0.5)

proc backlightBusArgs*(dev: string, abs: int): seq[string] =
  ## logind пишет подсветку от сессии. brightnessctl без группы video отвечает Permission denied.
  @[
    "busctl", "call", "org.freedesktop.login1",
    "/org/freedesktop/login1/session/auto",
    "org.freedesktop.login1.Session", "SetBrightness", "ssu",
    "backlight", dev, $abs,
  ]

proc backlightCommand*(dev: string, pct: int): string =
  if not backlightDevOk(dev): return ""
  let absv = backlightAbs(pct, backlightMax(dev))
  if absv < 0: return ""
  backlightBusArgs(dev, absv).join(" ")

const BrightPresets* = [10, 40, 70, 100]

proc readBacklight*(): tuple[pct: int, dev: string] =
  let dev = backlightDev()
  if dev.len == 0: return (-1, "")
  proc numAt(path: string): int =
    try: parseInt(readFile(path).strip)
    except CatchableError: -1
  let cur = numAt("/sys/class/backlight" / dev / "brightness")
  let mx = numAt("/sys/class/backlight" / dev / "max_brightness")
  (brightPct(cur, mx), dev)

type SinkChip* = object
  id*, name*: string
  current*: bool

proc parseSinks*(text: string): seq[SinkChip] =
  ## Разбор секции Sinks из `wpctl status`. Секции ниже не читаются.
  var on = false
  for line in text.splitLines:
    let raw = line.strip
    if raw.endsWith("Sinks:"):
      on = true
      continue
    if not on or raw.len == 0: continue
    if raw.endsWith(":") and '.' notin raw: break
    var i = 0
    while i < raw.len and raw[i] notin {'0' .. '9'}: inc i
    var j = i
    while j < raw.len and raw[j] in {'0' .. '9'}: inc j
    if j >= raw.len or j == i or raw[j] != '.': continue
    var name = raw[j + 1 .. ^1].strip
    let br = name.find('[')
    if br >= 0: name = name[0 ..< br].strip
    if name.len == 0: name = raw[i ..< j]
    result.add SinkChip(id: raw[i ..< j], name: name, current: '*' in raw)

proc nextSink*(rows: seq[SinkChip]): SinkChip =
  ## Следующий выход после текущего. Один выход возвращается сам.
  if rows.len == 0: return
  var cur = 0
  for i, row in rows:
    if row.current: cur = i
  rows[(cur + 1) mod rows.len]

proc wpctlVolume*(text: string): tuple[pct: int, muted: bool] =
  ## Строка `wpctl get-volume`: доля 0..1.5 и пометка MUTED.
  result = (-1, "MUTED" in text)
  for w in text.splitWhitespace:
    try:
      let f = parseFloat(w)
      if f >= 0 and f <= 1.5:
        result.pct = int(f * 100 + 0.5)
        break
    except ValueError:
      discard

proc volumeParts*(label: string): tuple[pct: int, muted: bool] =
  if "выкл" in label: return (0, true)
  var digits = ""
  for ch in label:
    if ch in {'0' .. '9'}: digits.add ch
  if digits.len == 0: return (-1, false)
  try: (parseInt(digits), false)
  except ValueError: (-1, false)

proc batteryParts*(label: string): tuple[pct: int, charging: bool] =
  ## Первое число — процент. «89% 1ч» остаётся 89, а не 891.
  if label.len == 0 or label == "—": return (-1, false)
  var digits = ""
  var started = false
  for ch in label:
    if ch in {'0' .. '9'}:
      digits.add ch
      started = true
    elif started:
      break
  if digits.len == 0: return (-1, false)
  try: (parseInt(digits), '+' in label)
  except ValueError: (-1, false)

const DockPinCap* = 19
  ## Закрепов в доке. Вместе с кнопкой приложений это 20 слотов и уже 1200.

proc dockSpan*(count, slot, pad, limit: int): int =
  ## Ширина плавающего дока вместе с кнопкой приложений. Упирается в limit.
  var n = count
  if n < 1: n = 1
  let raw = n * slot + pad
  if raw > limit: limit else: raw

proc pushUnique(outp: var seq[string], seen: var seq[string], p: string) =
  if p.len == 0 or p in seen: return
  seen.add p
  outp.add p

proc desktopSearchDirs*(): seq[string] =
  ## Каталоги .desktop: дом, XDG, Flatpak и snap. Домашний файл идёт раньше системного.
  var seen: seq[string]
  let home = getHomeDir()
  pushUnique(result, seen, home / ".local/share/applications")
  let dataHome = getEnv("XDG_DATA_HOME")
  if dataHome.len > 0: pushUnique(result, seen, dataHome / "applications")
  pushUnique(result, seen, "/usr/local/share/applications")
  pushUnique(result, seen, "/usr/share/applications")
  for part in getEnv("XDG_DATA_DIRS").split(':'):
    if part.len > 0: pushUnique(result, seen, part / "applications")
  pushUnique(result, seen, home / ".local/share/flatpak/exports/share/applications")
  pushUnique(result, seen, "/var/lib/flatpak/exports/share/applications")
  pushUnique(result, seen, "/var/lib/snapd/desktop/applications")

proc findDesktopFile*(id: string, dirs: openArray[string]): string =
  ## Файл id.desktop в переданных каталогах. Путь с косой чертой не открываем.
  let name = id.strip
  if name.len == 0 or '/' in name or '\\' in name or ".." in name: return ""
  let file = if name.endsWith(".desktop"): name else: name & ".desktop"
  for d in dirs:
    let p = d / file
    if fileExists(p): return p

proc desktopValue*(text, key: string): string =
  let prefix = key & "="
  for line in text.splitLines:
    let t = line.strip
    if t.startsWith(prefix): return t[prefix.len .. ^1].strip

proc iconSearchRoots*(): seq[string] =
  ## Корни значков приложений, включая экспорт Flatpak. Тема символов сюда не входит.
  var seen: seq[string]
  let home = getHomeDir()
  pushUnique(result, seen, home / ".local/share/icons/hicolor")
  pushUnique(result, seen, home / ".local/share/icons/Papirus-Dark")
  pushUnique(result, seen, home / ".local/share/flatpak/exports/share/icons/hicolor")
  pushUnique(result, seen, "/var/lib/flatpak/exports/share/icons/hicolor")
  pushUnique(result, seen, "/usr/share/icons/hicolor")
  pushUnique(result, seen, "/usr/share/icons/Papirus-Dark")
  pushUnique(result, seen, "/usr/share/pixmaps")

proc appIconPath*(name: string, roots: openArray[string]): string =
  ## Абсолютный Icon= берём как файл. Имя ищем в apps. Чужой относительный путь не открываем.
  if name.len == 0 or ".." in name: return ""
  if name[0] == '/': return if fileExists(name): name else: ""
  if '/' in name: return ""
  for root in roots:
    if root.endsWith("pixmaps"):
      for ext in [".png", ".svg", ".xpm"]:
        let p = root / (name & ext)
        if fileExists(p): return p
      continue
    for size in ["48x48", "64x64", "128x128", "256x256", "scalable", "32x32"]:
      for ext in [".png", ".svg"]:
        let p = root / size / "apps" / (name & ext)
        if fileExists(p): return p

proc linkUp*(root: string): bool =
  ## Интерфейс кроме lo в состоянии up. Каталога нет — связь не утверждаем.
  if root.len == 0 or not dirExists(root): return false
  for kind, path in walkDir(root):
    if kind != pcDir and kind != pcLinkToDir: continue
    let name = path.splitPath.tail
    if name.len == 0 or name == "lo": continue
    let st = try: readFile(path / "operstate").strip.toLowerAscii
             except IOError, OSError: ""
    if st == "up": return true
  false

proc netShort*(online: bool): string =
  if online: "сеть" else: "нет"

proc fuzzelFontLine*(current, family: string): string =
  ## Меняет семейство строки font=. Размер size= из файла сохраняет, иначе 13.
  var size = "13"
  let at = current.find("size=")
  if at >= 0:
    var j = at + 5
    var digits = ""
    while j < current.len and current[j] in {'0' .. '9'}:
      digits.add current[j]
      inc j
    if digits.len > 0: size = digits
  let fam = family.strip
  if fam.len == 0 or fam == "Noto Sans":
    "font=Noto Sans:size=" & size
  else:
    "font=" & fam & ":size=" & size & ",Noto Sans:size=" & size

proc pinRuns*(pinId, klass: string): bool =
  ## Закреп и класс окна. Короткий обрывок вроде «org» не считается совпадением.
  let a = pinId.strip.toLowerAscii
  let b = klass.strip.toLowerAscii
  if a.len == 0 or b.len == 0: return false
  if a == b: return true
  if b.len >= 3 and (a.startsWith(b & "_") or b.startsWith(a & "_")): return true
  let parts = a.rsplit('.', maxsplit = 1)
  if parts.len == 2 and parts[1].len >= 3 and parts[1] == b: return true
  if b.len >= 3 and '.' in b and a.startsWith(b & "._"): return true
  false

type QuickItem* = object
  id*, icon*, title*, detail*: string

proc calendarLines*(year, month, day, monday0: int): tuple[title, sub: string] =
  ## Дата для листа. monday0: 0 понедельник … 6 воскресенье. Событий здесь нет.
  const months = ["", "января", "февраля", "марта", "апреля", "мая", "июня",
    "июля", "августа", "сентября", "октября", "ноября", "декабря"]
  const days = ["понедельник", "вторник", "среда", "четверг", "пятница", "суббота", "воскресенье"]
  if year < 2000 or year > 2100 or month notin 1 .. 12 or day notin 1 .. 31 or monday0 notin 0 .. 6:
    return ("", "")
  ($day & " " & months[month], days[monday0] & " " & $year)

proc micLabel*(pct: int, muted, hasSource: bool): string =
  ## Пустой источник не даёт подписи, и панель его не рисует.
  if not hasSource or pct < 0: return ""
  if muted: "мик выкл" else: "мик " & $pctClamp(pct) & "%"

proc micIconName*(muted: bool): string =
  if muted: "microphone-sensitivity-muted-symbolic" else: "audio-input-microphone-symbolic"

const ProfileIds* = ["performance", "balanced", "power-saver"]

proc profileLabel*(raw: string): string =
  case raw.strip.toLowerAscii
  of "performance": "быстро"
  of "balanced": "баланс"
  of "power-saver": "эконом"
  else: ""

proc profileIconName*(raw: string): string =
  case raw.strip.toLowerAscii
  of "performance": "power-profile-performance-symbolic"
  of "balanced": "power-profile-balanced-symbolic"
  of "power-saver": "power-profile-power-saver-symbolic"
  else: ""

proc batteryMinutes*(status: string, energyNow, powerNow: int64): int =
  ## Минуты только на разряде при ненулевой мощности. Иначе -1.
  if status != "Discharging" or energyNow < 0 or powerNow <= 0: return -1
  let mins = energyNow * 60 div powerNow
  if mins > int64(48 * 60): return -1
  int(mins)

proc batteryTimeShort*(minutes: int): string =
  if minutes < 0: return ""
  if minutes < 60: $minutes & "м" else: $(minutes div 60) & "ч"

type BatteryRead* = object
  pct*: int
  status*, extra*: string

proc batteryReport*(root = "/sys/class/power_supply"): BatteryRead =
  ## Процент, статус и короткая оценка. Нет батареи — процент -1.
  result.pct = -1
  for bat in ["BAT0", "BAT1", "BAT"]:
    let dir = root / bat
    if not dirExists(dir): continue
    let capT = try: readFile(dir / "capacity").strip
               except IOError, OSError: ""
    if capT.len == 0: continue
    var cap = -1
    try: cap = parseInt(capT)
    except ValueError: continue
    let st = try: readFile(dir / "status").strip
             except IOError, OSError: ""
    var energy: int64 = -1
    var power: int64 = -1
    try: energy = parseBiggestInt(readFile(dir / "energy_now").strip)
    except CatchableError: discard
    try: power = parseBiggestInt(readFile(dir / "power_now").strip)
    except CatchableError: discard
    return BatteryRead(pct: cap, status: st, extra: batteryTimeShort(batteryMinutes(st, energy, power)))

proc vpnActive*(text: string): bool =
  ## tun, vpn или wireguard в активных соединениях. Обычный Wi-Fi сюда не входит.
  for line in text.splitLines:
    let t = line.strip.toLowerAscii
    if "activated" notin t: continue
    let head = t.split(':')[0]
    if head in ["tun", "vpn", "wireguard"]: return true
  false

proc unpinnedClasses*(pinIds, classes: openArray[string], limit: int): seq[string] =
  ## Класс окна, который не совпал ни с одним закрепом. Пустой класс пропускаем.
  for klass in classes:
    let name = klass.strip
    if name.len == 0: continue
    var hit = false
    for pin in pinIds:
      if pinRuns(pin, name):
        hit = true
        break
    if hit: continue
    var seen = false
    for u in result:
      if u.toLowerAscii == name.toLowerAscii:
        seen = true
        break
    if seen: continue
    result.add name
    if limit > 0 and result.len >= limit: break

proc dockBody*(extras: int): int =
  ## Второй ряд только когда есть незакреплённые окна.
  if extras <= 0: 68 else: 120

proc dockZone*(extras: int): int =
  dockBody(extras) + 8

type MenuPick* = object
  id*, name*, icon*, group*: string

proc menuPicks*(rows: openArray[MenuPick], limit: int): seq[MenuPick] =
  ## Первые имена меню. Хвост остаётся поиску fuzzel. limit меньше 1 — пусто.
  if limit < 1: return
  var seen: seq[string]
  for row in rows:
    let id = row.id.strip
    let name = row.name.strip
    if id.len == 0 or name.len == 0 or id in seen: continue
    seen.add id
    result.add MenuPick(id: id, name: name, icon: row.icon, group: row.group)
    if result.len >= limit: break

proc menuGroupOf*(categories: string): string =
  ## Одна группа меню из Categories=. Неизвестное не прячется в пустую строку.
  let c = categories.toLowerAscii
  if "audio" in c or "video" in c: "Звук и видео"
  elif "game" in c: "Игры"
  elif "network" in c or "webbrowser" in c: "Сеть"
  elif "office" in c: "Офис"
  elif "development" in c: "Разработка"
  elif "settings" in c or "system" in c: "Система"
  elif "utility" in c: "Служебные"
  else: "Прочее"

const
  menuWide* = 560
  mkHead* = 0
  mkAct* = 1
  mkApp* = 2
  mkWidget* = 3
  mkTile* = 4
  mkSearch* = 5
  mkTab* = 6
  mkBand* = 7
  mkSlide* = 8

type
  MenuBox* = object
    x*, y*, w*, h*: int
  MenuSlot* = object
    kind*: int
    id*: string
  MenuLive* = object
    volume*, brightness*, network*, bluetooth*, mic*, profile*, dnd*, media*, battery*, vpn*: string
    notify*, session*, shot*, clip*: bool

proc menuRowH*(kind: int): int =
  ## Высота строки меню. Плитка выше строки приложения: подпись и показание.
  case kind
  of mkHead: 24
  of mkSearch: 44
  of mkTab: 42
  of mkTile: 68
  of mkWidget: 30
  of mkBand: 52
  of mkSlide: 52
  of mkApp, mkAct: 38
  else: 32

proc menuBoxes*(kinds: openArray[int], width: int): seq[MenuBox] =
  ## Вкладки — три в ряд, плитки — две. Остальное на всю ширину.
  let wide = if width < 80: 80 else: width
  var y = 10
  var i = 0
  while i < kinds.len:
    let k = kinds[i]
    if k == mkTile or k == mkTab or k == mkBand:
      let want = if k == mkTab or k == mkBand: 3 else: 2
      var n = 0
      while n < want and i + n < kinds.len and kinds[i + n] == k: inc n
      if n < 1: n = 1
      let gap = 8
      let inner = wide - 24
      let side = max(36, (inner - gap * (n - 1)) div n)
      let rh = menuRowH(k)
      let bh = max(20, rh - 8)
      for j in 0 ..< n:
        result.add MenuBox(x: 12 + j * (side + gap), y: y, w: side, h: bh)
      y += rh
      i += n
    else:
      let rh = menuRowH(k)
      if k == mkHead:
        result.add MenuBox(x: 16, y: y, w: wide - 32, h: rh)
      else:
        result.add MenuBox(x: 12, y: y, w: wide - 24, h: max(20, rh - 4))
      y += rh
      inc i

proc menuSpanHeight*(kinds: openArray[int], width: int): int =
  let boxes = menuBoxes(kinds, width)
  if boxes.len == 0: 0 else: boxes[^1].y + boxes[^1].h + 14

proc menuSheetHeight*(kinds: openArray[int], width: int): int =
  ## 920 оставляет место бару и доку на экране 1080. Ниже список виджетов срезал масштаб.
  let h = menuSpanHeight(kinds, width)
  if h < 180: 180 elif h > 920: 920 else: h

proc menuHit*(x, y: int, boxes: openArray[MenuBox]): int =
  result = -1
  for i, b in boxes:
    if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h:
      return i

proc menuAppCap*(query: string): int =
  ## Без запроса — короткая витрина. С запросом — больше имён, хвост остаётся fuzzel.
  if query.strip.len == 0: 16 else: 40

proc menuTabOf*(id: string): int =
  case id
  of "tab:0": 0
  of "tab:1": 1
  of "tab:2": 2
  else: -1

proc menuStatusLine*(layout, user: string): string =
  ## Строка состояния, не кнопка. Пустые части не становятся буквами.
  let a = layout.strip
  let b = user.strip
  if a.len > 0 and b.len > 0: a & "  ·  " & b
  elif a.len > 0: a
  else: b

proc tileHot*(id, hint: string): bool =
  ## Золотая плитка только у включённого тумблера. Навигация золотом не красится.
  let h = hint.strip
  case id
  of "bluetooth": h.len > 0 and "выкл" notin h
  of "dnd": "тихо" in h
  of "mic": h.len > 0 and "выкл" notin h
  else: false

proc controlTiles*(live: MenuLive): seq[tuple[id, title, hint: string]] =
  ## Плитка без чтения не рисуется. Ночь, погода и деления сигнала сюда не входят.
  ## Звук и сессия — действия, которые лист умеет и без заранее прочитанного процента.
  result.add (id: "volume", title: "Звук", hint: live.volume)
  if live.brightness.len > 0:
    result.add (id: "brightness", title: "Яркость", hint: live.brightness)
  if live.network.len > 0:
    result.add (id: "network", title: "Сеть", hint: live.network)
  if live.bluetooth.len > 0:
    result.add (id: "bluetooth", title: "Bluetooth", hint: live.bluetooth)
  if live.mic.len > 0:
    result.add (id: "mic", title: "Микрофон", hint: live.mic)
  if live.profile.len > 0:
    result.add (id: "profile", title: "Профиль", hint: live.profile)
  if live.dnd.len > 0:
    result.add (id: "dnd", title: "Тишина", hint: live.dnd)
  if live.media.len > 0:
    result.add (id: "media-prev", title: "Назад", hint: "")
    result.add (id: "media", title: "Медиа", hint: live.media)
    result.add (id: "media-next", title: "Дальше", hint: "")
  if live.battery.len > 0:
    result.add (id: "battery", title: "Батарея", hint: live.battery)
  if live.vpn.len > 0:
    result.add (id: "vpn", title: "VPN", hint: live.vpn)
  if live.notify:
    result.add (id: "notify", title: "Уведомления", hint: "")
  if live.shot:
    result.add (id: "shot", title: "Снимок", hint: "")
  if live.clip:
    result.add (id: "clip", title: "Буфер", hint: "")
  if live.session:
    result.add (id: "session", title: "Сессия", hint: "")

proc widgetMark*(on: bool, live: string): string =
  let state = if on: "вкл" else: "выкл"
  let t = live.strip
  if t.len == 0: state else: state & " · " & t

proc flipBtHint*(hint: string): string =
  let h = hint.strip
  if h.len == 0: return ""
  if "выкл" in h: "bt" else: "bt выкл"

proc flipDndHint*(hint: string): string =
  if hint.strip.len == 0: return ""
  if "тихо" in hint: "уведом" else: "тихо"

proc flipMicHint*(hint: string): string =
  let h = hint.strip
  if h.len == 0: return ""
  if "выкл" in h: "мик" else: "мик выкл"

proc menuReturnId*(query: string, rows: openArray[MenuSlot]): string =
  ## Enter запускает приложение только когда запрос оставил ровно одно имя.
  if query.strip.len == 0: return ""
  var found = ""
  for row in rows:
    if row.kind != mkApp: continue
    if found.len > 0: return ""
    found = row.id
  found

proc menuFit*(rows: openArray[MenuSlot], width, maxH: int): seq[MenuSlot] =
  ## Срезает приложения с хвоста, пока лист не выше maxH. Вкладки и поиск остаются.
  if maxH < 1 or width < 40:
    for r in rows: result.add r
    return
  var cur: seq[MenuSlot]
  for r in rows: cur.add r
  proc tooTall(): bool =
    var kinds = newSeq[int](cur.len)
    for i, r in cur: kinds[i] = r.kind
    menuSpanHeight(kinds, width) > maxH
  while tooTall():
    var cut = -1
    for i in countdown(cur.len - 1, 0):
      if cur[i].kind == mkApp:
        cut = i
        break
    if cut < 0: break
    cur.delete(cut)
    var i = 0
    while i < cur.len:
      if cur[i].kind != mkHead:
        inc i
        continue
      let orphan = i + 1 >= cur.len or cur[i + 1].kind == mkHead or cur[i + 1].id == "all"
      if orphan: cur.delete(i)
      else: inc i
  while tooTall() and cur.len > 4:
    cur.delete(cur.len - 1)
  result = cur

proc widgetIds*(): seq[string] =
  @[
    "desks", "clock", "layout", "volume", "brightness", "battery", "network",
    "mic", "profile", "vpn", "tray", "dnd", "bluetooth", "media",
    "load", "cpu", "mem", "netio", "shot", "clip", "session", "scale",
  ]

proc widgetDefault*(id: string): bool =
  ## Буфер выключен, пока человек сам его не включит. Остальные видны, если есть чтение.
  id != "clip"

proc widgetMeta*(id: string): tuple[title, sample, group: string] =
  case id
  of "desks": ("Столы", "пример: стол 3", "Панель")
  of "clock": ("Часы", "пример: 14:05", "Панель")
  of "layout": ("Раскладка", "только живое имя композитора", "Панель")
  of "volume": ("Звук", "пример: звук 40%", "Панель")
  of "brightness": ("Яркость", "пример: 69%", "Панель")
  of "battery": ("Батарея", "пример: 93%+", "Панель")
  of "network": ("Сеть", "пример: сеть", "Панель")
  of "mic": ("Микрофон", "пример: мик 59%", "Панель")
  of "profile": ("Профиль", "пример: быстро", "Панель")
  of "vpn": ("VPN", "пример: vpn", "Панель")
  of "tray": ("Трей", "значки приложений, если имя наше", "Панель")
  of "dnd": ("Тишина", "только если makoctl ответил режимом", "Службы")
  of "bluetooth": ("Bluetooth", "только если rfkill ответил", "Службы")
  of "media": ("Медиа", "только если playerctl видит плеер", "Службы")
  of "load": ("Нагрузка", "пример: нагр 0.4", "Службы")
  of "cpu": ("Процессор", "пример: цп 12%", "Службы")
  of "mem": ("Память", "пример: пам 40%", "Службы")
  of "netio": ("Канал", "пример: 1.2М/с", "Службы")
  of "shot": ("Снимок", "grim, если он установлен", "Службы")
  of "clip": ("Буфер", "выключен, пока нет явного согласия", "Службы")
  of "session": ("Сессия", "блокировка и выход через подтверждение", "Система")
  of "scale": ("Масштаб", "число из файла монитора, без смены экрана", "Система")
  else: ("", "", "")

proc chromeLabels*(cfg: JsonNode): bool =
  ## Нет секции — как в defaults: подписи выключены.
  if cfg == nil or cfg.kind != JObject or not cfg.hasKey("chrome"): return false
  let c = cfg["chrome"]
  if c.kind != JObject or not c.hasKey("labels") or c["labels"].kind != JBool: return false
  c["labels"].getBool

proc chromeWidget*(cfg: JsonNode, id: string): bool =
  let fallback = widgetDefault(id)
  if cfg == nil or cfg.kind != JObject or not cfg.hasKey("chrome"): return fallback
  let c = cfg["chrome"]
  if c.kind != JObject or not c.hasKey("widgets") or c["widgets"].kind != JObject: return fallback
  let w = c["widgets"]
  if not w.hasKey(id) or w[id].kind != JBool: return fallback
  w[id].getBool

proc widgetRightIds*(): seq[string] =
  ## Правый ряд. Столы и часы к этому списку не относятся: у них свои места.
  @[
    "battery", "layout", "volume", "mic", "brightness", "network", "vpn", "profile",
    "dnd", "bluetooth", "media", "load", "cpu", "mem", "netio", "shot", "clip", "session", "scale", "tray",
  ]

proc chromeOpacity*(cfg: JsonNode): int =
  ## 40..100. 100 — сплошная бумага. Нет ключа — как раньше, бар непрозрачный.
  if cfg == nil or cfg.kind != JObject or not cfg.hasKey("chrome"): return 100
  let c = cfg["chrome"]
  if c.kind != JObject or not c.hasKey("opacity"): return 100
  let n = c["opacity"]
  var v = 100
  if n.kind == JInt: v = n.getInt
  elif n.kind == JFloat: v = int(n.getFloat)
  else: return 100
  if v < 40: 40 elif v > 100: 100 else: v

proc chromeStyle*(cfg: JsonNode): string =
  if cfg == nil or cfg.kind != JObject or not cfg.hasKey("chrome"): return "paper"
  let c = cfg["chrome"]
  if c.kind != JObject or not c.hasKey("style") or c["style"].kind != JString: return "paper"
  let s = c["style"].getStr
  if s in ["paper", "ink", "dawn"]: s else: "paper"

proc styleTitle*(id: string): string =
  case id
  of "ink": "Чернила"
  of "dawn": "Рассвет"
  else: "Бумага"

proc chromeClock*(cfg: JsonNode): string =
  ## time, date или hands. Чужое слово — время.
  if cfg == nil or cfg.kind != JObject or not cfg.hasKey("chrome"): return "time"
  let c = cfg["chrome"]
  if c.kind != JObject or not c.hasKey("clock") or c["clock"].kind != JString: return "time"
  let s = c["clock"].getStr
  if s in ["time", "date", "hands"]: s else: "time"

proc clockModeTitle*(id: string): string =
  case id
  of "date": "Время и дата"
  of "hands": "Стрелки"
  else: "Только время"

type DashBox* = object
  id*: string
  x*, y*, w*, h*: float32

proc clockSheetW*(): int = 460
proc clockSheetH*(): int = 584

proc clockDashBoxes*(sheetW: float32): seq[DashBox] =
  ## Режимы, настройки и сессия. Календарь между ними — не кнопка.
  let w = if sheetW < 200: 460'f32 else: sheetW
  let inner = w - 32
  let gap = 8'f32
  let bw = (inner - gap * 2) / 3
  for i, id in ["time", "date", "hands"]:
    result.add DashBox(id: id, x: 16'f32 + i.float32 * (bw + gap), y: 108'f32, w: bw, h: 36'f32)
  result.add DashBox(id: "settings", x: 16'f32, y: 152'f32, w: inner, h: 36'f32)
  for i, id in ["lock", "logout", "sleep", "off"]:
    result.add DashBox(id: id, x: 16'f32, y: 392'f32 + i.float32 * 44, w: inner, h: 40'f32)

proc dashIdAt*(x, y, sheetW: float32): string =
  for b in clockDashBoxes(sheetW):
    if x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h:
      return b.id

proc calendarGeom*(sheetW: float32): tuple[x, y, cw, ch: float32] =
  let w = if sheetW < 200: 460'f32 else: sheetW
  result = (16'f32, 200'f32, (w - 32'f32) / 7, 26'f32)

proc styleCycle*(id: string): string =
  case id
  of "paper": "ink"
  of "ink": "dawn"
  else: "paper"

proc opacityCycle*(cur: int): int =
  ## Шаг меню: плотнее не добавляет, только следующий более прозрачный, с 40 снова 100.
  let v = if cur < 40: 40 elif cur > 100: 100 else: cur
  if v > 80: 80 elif v > 60: 60 elif v > 40: 40 else: 100

type ChromeInk* = object
  paperR*, paperG*, paperB*: float32
  plateR*, plateG*, plateB*: float32
  trackR*, trackG*, trackB*: float32
  goldR*, goldG*, goldB*: float32
  inkR*, inkG*, inkB*: float32
  idleR*, idleG*, idleB*: float32
  hotR*, hotG*, hotB*: float32
  darkR*, darkG*, darkB*: float32

proc chromeInk*(style: string): ChromeInk =
  case style
  of "ink":
    ChromeInk(
      paperR: 0.07'f32, paperG: 0.08'f32, paperB: 0.10'f32,
      plateR: 0.12'f32, plateG: 0.14'f32, plateB: 0.18'f32,
      trackR: 0.16'f32, trackG: 0.18'f32, trackB: 0.24'f32,
      goldR: 0.62'f32, goldG: 0.78'f32, goldB: 0.92'f32,
      inkR: 0.90'f32, inkG: 0.93'f32, inkB: 0.96'f32,
      idleR: 0.14'f32, idleG: 0.16'f32, idleB: 0.20'f32,
      hotR: 0.20'f32, hotG: 0.26'f32, hotB: 0.34'f32,
      darkR: 0.08'f32, darkG: 0.10'f32, darkB: 0.14'f32)
  of "dawn":
    ChromeInk(
      paperR: 0.18'f32, paperG: 0.14'f32, paperB: 0.11'f32,
      plateR: 0.26'f32, plateG: 0.20'f32, plateB: 0.16'f32,
      trackR: 0.32'f32, trackG: 0.24'f32, trackB: 0.18'f32,
      goldR: 0.95'f32, goldG: 0.72'f32, goldB: 0.38'f32,
      inkR: 0.98'f32, inkG: 0.94'f32, inkB: 0.88'f32,
      idleR: 0.28'f32, idleG: 0.22'f32, idleB: 0.16'f32,
      hotR: 0.38'f32, hotG: 0.28'f32, hotB: 0.18'f32,
      darkR: 0.20'f32, darkG: 0.14'f32, darkB: 0.08'f32)
  else:
    ChromeInk(
      paperR: 0.11'f32, paperG: 0.09'f32, paperB: 0.08'f32,
      plateR: 0.18'f32, plateG: 0.15'f32, plateB: 0.12'f32,
      trackR: 0.24'f32, trackG: 0.20'f32, trackB: 0.16'f32,
      goldR: 0.91'f32, goldG: 0.75'f32, goldB: 0.50'f32,
      inkR: 0.96'f32, inkG: 0.93'f32, inkB: 0.86'f32,
      idleR: 0.20'f32, idleG: 0.17'f32, idleB: 0.14'f32,
      hotR: 0.30'f32, hotG: 0.25'f32, hotB: 0.18'f32,
      darkR: 0.16'f32, darkG: 0.12'f32, darkB: 0.08'f32)

proc chromeOrder*(cfg: JsonNode): seq[string] =
  ## Известные id в записанном порядке. Чужак отбрасывается, пропуск дописывается в хвост.
  let base = widgetRightIds()
  if cfg != nil and cfg.kind == JObject and cfg.hasKey("chrome"):
    let c = cfg["chrome"]
    if c.kind == JObject and c.hasKey("order") and c["order"].kind == JArray:
      for n in c["order"]:
        if n.kind != JString: continue
        let id = n.getStr
        if id notin base or id in result: continue
        result.add id
  for id in base:
    if id notin result: result.add id

proc orderMove*(order: openArray[string], id: string, dir: int): seq[string] =
  ## dir 1 — к центру (позже в ряду, который рисуется справа налево). dir -1 — к краю экрана.
  for x in order: result.add x
  if dir != -1 and dir != 1: return
  var at = -1
  for i, x in result:
    if x == id:
      at = i
      break
  if at < 0: return
  let j = at + dir
  if j < 0 or j >= result.len: return
  let tmp = result[at]
  result[at] = result[j]
  result[j] = tmp

proc dockMetrics*(extras: int, labels: bool): tuple[slot, icon, body, zone, row: int] =
  ## Значок 40, как компактный док. Подпись — одна строка под курсором, не имя под каждым значком.
  let slot = 54
  let icon = 40
  let row = icon + (if labels: 18 else: 10)
  let body = if extras <= 0: row + 14 else: row * 2 + 14
  (slot, icon, body, body + 8, row)

proc chromeDismiss*(cfg: JsonNode): int =
  ## Миллисекунды после ухода курсора. 0 выключает таймер, щелчок снаружи остаётся.
  if cfg == nil or cfg.kind != JObject or not cfg.hasKey("chrome"): return 1000
  let c = cfg["chrome"]
  if c.kind != JObject or not c.hasKey("dismiss_ms"): return 1000
  let n = c["dismiss_ms"]
  var v = 1000
  if n.kind == JInt: v = n.getInt
  elif n.kind == JFloat: v = int(n.getFloat)
  else: return 1000
  if v < 0: 0 elif v > 3000: 3000 else: v

proc dismissDue*(leaveAt, now: float, ms: int, dragging: bool): bool =
  ## Таймер идёт только после ухода и не во время перетаскивания ползунка.
  if dragging or ms <= 0 or leaveAt <= 0: return false
  now - leaveAt >= ms.float / 1000.0

proc layoutMark*(name: string): string =
  ## Короткий знак из имени, которое вернул композитор. Пустое имя не становится буквами.
  let n = name.strip.toLowerAscii
  if n.len == 0: return ""
  if "russian" in n or n == "ru": return "RU"
  if "english" in n or n == "us" or n == "en": return "EN"
  var letters = ""
  for ch in n:
    if ch in {'a' .. 'z'}:
      letters.add toUpperAscii(ch)
      if letters.len == 2: break
  letters

proc powerStep*(armed, id: string): tuple[arm: string, fire: bool] =
  ## Блокировка сразу. Сон, выход и выключение — второй щелчок по той же строке.
  if id == "lock": return (arm: "", fire: true)
  if id notin ["logout", "sleep", "off"]: return (arm: armed, fire: false)
  if armed == id: return (arm: "", fire: true)
  (arm: id, fire: false)

proc sessionAct*(id, sessionId: string): tuple[go: bool, note: string] =
  ## go = false — лист не закрывать и команду не звать.
  ## Выход без номера сессии ничего не запускает.
  if id == "logout" and sessionId.len == 0:
    return (false, "Нет номера сессии")
  if id in ["lock", "logout", "sleep", "off"]:
    return (true, "")
  (false, "")

proc wifiSignal*(cell: string): int =
  ## Цифры 0..100. Прочерк и пусто — нет делений.
  let t = cell.strip
  if t.len == 0 or t == "--": return -1
  try:
    let n = parseInt(t)
    if n < 0 or n > 100: -1 else: n
  except ValueError:
    -1

proc wifiRows*(text: string): seq[tuple[ssid: string, signal: int, active: bool]] =
  for line in text.splitLines:
    if line.len == 0 or line[0] == '#': continue
    var parts = line.split(':')
    if parts.len < 3: continue
    let active = parts[0].strip == "*"
    let signal = wifiSignal(parts[^1])
    var ssid = parts[1]
    if parts.len > 3:
      ssid = parts[1 .. ^2].join(":")
    ssid = ssid.strip
    if ssid.len == 0: continue
    result.add (ssid, signal, active)

proc loadLabel*(text: string): string =
  let p = text.strip.splitWhitespace
  if p.len == 0: return ""
  try:
    let v = parseFloat(p[0])
    if v < 0: return ""
    "нагр " & formatFloat(v, ffDecimal, 1)
  except ValueError:
    ""

proc cpuSample*(text: string): tuple[idle, total: int64] =
  ## Первая строка cpu из /proc/stat. idle включает iowait. Пусто — (-1, -1).
  result = (-1'i64, -1'i64)
  for line in text.splitLines:
    let p = line.strip.splitWhitespace
    if p.len < 5 or p[0] != "cpu": continue
    var total = 0'i64
    var idle = 0'i64
    var ok = true
    for i in 1 ..< p.len:
      try:
        let n = parseBiggestInt(p[i])
        total += n
        if i == 4 or i == 5: idle += n
      except ValueError:
        ok = false
        break
    if ok and total > 0: return (idle, total)
    return

proc cpuPct*(prevIdle, prevTotal, idle, total: int64): int =
  ## Процент с прошлой пары. Нет базы или счётчик откатился — -1, не среднее с загрузки.
  if prevTotal <= 0 or total <= prevTotal or idle < prevIdle or prevIdle < 0: return -1
  let dt = total - prevTotal
  let di = idle - prevIdle
  if dt <= 0 or di > dt: return -1
  int((dt - di) * 100 div dt)

proc cpuLabel*(pct: int): string =
  if pct notin 0 .. 100: "" else: "цп " & $pct & "%"

proc memLabel*(text: string): string =
  ## Занято от MemTotal и MemAvailable. Нет пары — пусто.
  var total = -1'i64
  var avail = -1'i64
  for line in text.splitLines:
    let p = line.splitWhitespace
    if p.len < 2: continue
    try:
      let n = parseBiggestInt(p[1])
      if p[0] == "MemTotal:": total = n
      elif p[0] == "MemAvailable:": avail = n
    except ValueError:
      discard
  if total <= 0 or avail < 0 or avail > total: return ""
  "пам " & $((total - avail) * 100 div total) & "%"

proc netBytes*(text: string): tuple[rx, tx: int64] =
  ## Сумма rx/tx из /proc/net/dev без lo. Нет строки — (-1, -1).
  result = (-1'i64, -1'i64)
  var rx = 0'i64
  var tx = 0'i64
  var n = 0
  for line in text.splitLines:
    let t = line.strip
    let colon = t.find(':')
    if colon <= 0: continue
    let name = t[0 ..< colon].strip
    if name.len == 0 or name == "lo": continue
    let rest = t[colon + 1 .. ^1].strip.splitWhitespace
    if rest.len < 9: continue
    try:
      rx += parseBiggestInt(rest[0])
      tx += parseBiggestInt(rest[8])
      n += 1
    except ValueError:
      discard
  if n > 0: result = (rx, tx)

proc netRate*(bytes: int64, dt: float): string =
  if dt < 0.4 or bytes < 0: return ""
  let per = bytes.float / dt
  if per < 1000: return $int(per)
  if per < 1_000_000:
    let k = per / 1000
    if k < 10:
      let shown = formatFloat(k, ffDecimal, 1)
      if shown.endsWith(".0"): return $int(k) & "К"
      return shown & "К"
    return $int(k) & "К"
  let m = per / 1_000_000
  if m < 10:
    let shown = formatFloat(m, ffDecimal, 1)
    if shown.endsWith(".0"): return $int(m) & "М"
    return shown & "М"
  return $int(m) & "М"

proc netLabel*(prevRx, prevTx, rx, tx: int64, dt: float): string =
  ## Скорость между двумя чтениями. Первая пара без базы пустая.
  if prevRx < 0 or prevTx < 0 or rx < prevRx or tx < prevTx: return ""
  let rate = netRate((rx - prevRx) + (tx - prevTx), dt)
  if rate.len == 0: "" else: rate & "/с"

proc weekdayMon0*(year, month, day: int): int =
  ## Понедельник 0 … воскресенье 6. Вне диапазона — -1.
  if year < 2000 or year > 2100 or month notin 1 .. 12 or day notin 1 .. 31: return -1
  var y = year
  var m = month
  const t = [0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4]
  if m < 3: y -= 1
  let sun0 = (y + y div 4 - y div 100 + y div 400 + t[m - 1] + day) mod 7
  result = (sun0 + 6) mod 7

proc daysInMonth*(year, month: int): int =
  if month notin 1 .. 12 or year < 2000 or year > 2100: return 0
  var n = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month]
  if month == 2 and (year mod 4 == 0) and (year mod 100 != 0 or year mod 400 == 0): n = 29
  n

proc monthGrid*(year, month, today: int): tuple[title: string, cells: seq[int]] =
  ## 42 клетки. 0 — пусто. Событий нет.
  let n = daysInMonth(year, month)
  let lead = weekdayMon0(year, month, 1)
  if n == 0 or lead < 0 or lead + n > 42: return
  const months = ["", "январь", "февраль", "март", "апрель", "май", "июнь",
    "июль", "август", "сентябрь", "октябрь", "ноябрь", "декабрь"]
  result.title = months[month] & " " & $year
  for i in 0 ..< 42: result.cells.add 0
  for d in 1 .. n:
    result.cells[lead + d - 1] = d
  if today notin 1 .. n: discard

proc clockCaption*(mode: string, hour, minute, day, month: int): string =
  ## time — часы. date — часы и короткий день. hands — без строки, лицо рисует стрелки.
  if hour notin 0 .. 23 or minute notin 0 .. 59: return ""
  let hh = if hour < 10: "0" & $hour else: $hour
  let mm = if minute < 10: "0" & $minute else: $minute
  let hm = hh & ":" & mm
  if mode == "hands": return ""
  if mode == "date":
    if month notin 1 .. 12 or day notin 1 .. 31: return hm
    const mon = ["", "янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]
    return hm & "  " & $day & " " & mon[month]
  hm

proc opacityAt*(x, origin, width: float32): int =
  ## 40..100 по дорожке плотности. Узкая дорожка остаётся сплошной.
  if width <= 1: return 100
  var t = (x - origin) / width
  if t < 0: t = 0
  if t > 1: t = 1
  40 + int(t * 60 + 0.5)

proc monitorScale*(line: string): int =
  let t = line.strip
  if t.len == 0 or t[0] == '#' or not t.startsWith("monitor"): return -1
  let parts = t.split(',')
  if parts.len < 4: return -1
  try:
    let n = parseInt(parts[^1].strip)
    if n <= 0 or n > 8: -1 else: n
  except ValueError:
    -1

proc clipPush*(prev: openArray[string], line: string, limit: int): seq[string] =
  let t = line.strip
  if t.len == 0 or limit < 1:
    for x in prev: result.add x
    return
  if prev.len > 0 and prev[0] == t:
    for x in prev: result.add x
    return
  result.add t
  for old in prev:
    if old == t: continue
    result.add old
    if result.len >= limit: break

proc dndOn*(text: string): int =
  let t = text.strip.toLowerAscii
  if t.len == 0: return -1
  if "do-not-disturb" in t: return 1
  if "default" in t: return 0
  -1

proc rfkillSoft*(text, kind: string): int =
  ## 0 открыт, 1 закрыт, -1 нет такой строки.
  result = -1
  var hit = false
  let want = kind.toLowerAscii
  for line in text.splitLines:
    let low = line.strip.toLowerAscii
    if low.len == 0: continue
    if low.startsWith("soft blocked:"):
      if hit:
        if low.endsWith("yes"): return 1
        if low.endsWith("no"): return 0
        return -1
    elif low.startsWith("hard blocked:"):
      discard
    elif want in low:
      hit = true
    else:
      hit = false

proc firstRune*(s: string): string =
  ## Одна первая буква. Срез [0..0] для «Я» даёт половину UTF-8.
  if s.len == 0: return ""
  let c = ord(s[0])
  var step = 1
  if (c and 0xE0) == 0xC0: step = 2
  elif (c and 0xF0) == 0xE0: step = 3
  elif (c and 0xF8) == 0xF0: step = 4
  if step > s.len: step = s.len
  s[0 ..< step]

proc foldSearch*(s: string): string =
  ## Строчные ASCII и русские буквы. toLowerAscii кириллицу не трогает, и поиск «звук» не находит «Звук».
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    let c = ord(s[i])
    if c < 0x80:
      if c in 0x41 .. 0x5A: result.add char(c + 32)
      else: result.add char(c)
      inc i
    elif c == 0xD0 and i + 1 < s.len:
      let b = ord(s[i + 1])
      if b == 0x81:
        result.add "ё"
      elif b in 0x90 .. 0x9F:
        result.add char(0xD0)
        result.add char(b + 0x20)
      elif b in 0xA0 .. 0xAF:
        result.add char(0xD1)
        result.add char(b - 0x20)
      else:
        result.add s[i .. i + 1]
      i += 2
    else:
      var step = 1
      if (c and 0xE0) == 0xC0: step = 2
      elif (c and 0xF0) == 0xE0: step = 3
      elif (c and 0xF8) == 0xF0: step = 4
      if i + step > s.len: step = s.len - i
      result.add s[i ..< i + step]
      i += step

proc clipRunes*(s: string, n: int): string =
  ## Режет по буквам. Срез по байтам рвёт UTF-8 и Pango рисует пустой знак.
  if n < 2 or s.len == 0: return s
  var steps: seq[int]
  var i = 0
  while i < s.len:
    let c = ord(s[i])
    var step = 1
    if (c and 0xE0) == 0xC0: step = 2
    elif (c and 0xF0) == 0xE0: step = 3
    elif (c and 0xF8) == 0xF0: step = 4
    if i + step > s.len: step = s.len - i
    steps.add step
    i += step
  if steps.len <= n: return s
  result = ""
  i = 0
  for k in 0 ..< n - 1:
    let step = steps[k]
    result.add s[i ..< i + step]
    i += step
  result.add "…"

proc mediaLine*(text: string): string =
  var t = text.strip
  if t.len == 0 or t == "-" or t == " - ": return ""
  clipRunes(t, 32)

proc notifyLines*(text: string, limit: int): seq[string] =
  ## Текущий список mako. История в этот разбор не входит.
  if limit < 1: return
  var cur = ""
  for line in text.splitLines:
    let t = line.strip
    if t.startsWith("Notification "):
      if cur.len > 0 and result.len < limit: result.add cur
      if result.len >= limit:
        cur = ""
        break
      let colon = t.find(':')
      if colon >= 0 and colon + 1 < t.len: cur = t[colon + 1 .. ^1].strip
      else: cur = t
    elif cur.len > 0 and " · " notin cur and t.toLowerAscii.startsWith("app name:"):
      let app = t[9 .. ^1].strip
      if app.len > 0: cur = cur & " · " & app
  if cur.len > 0 and result.len < limit: result.add cur

proc osdText*(kind, pct: int, muted: bool): string =
  if kind == 1:
    if muted: "звук выкл" else: "звук " & $pctClamp(pct) & "%"
  elif kind == 2:
    "яркость " & $pctClamp(pct) & "%"
  else:
    ""

proc quickCatalog*(): seq[QuickItem] =
  ## Кнопки, которые уже умеет оболочка. Погода и загрузка сюда не входят.
  @[
    QuickItem(id: "audio", icon: "audio-speakers-symbolic", title: "Звук", detail: "Громкость и устройство вывода"),
    QuickItem(id: "bright-down", icon: "display-brightness-symbolic", title: "Яркость ниже", detail: "Шаг 10 процентов подсветки"),
    QuickItem(id: "bright-up", icon: "display-brightness-symbolic", title: "Яркость выше", detail: "Шаг 10 процентов подсветки"),
    QuickItem(id: "wifi", icon: "network-wireless-connected-symbolic", title: "Wi-Fi", detail: "Радио сети"),
    QuickItem(id: "bluetooth", icon: "bluetooth-active-symbolic", title: "Bluetooth", detail: "Адаптер"),
    QuickItem(id: "night", icon: "night-light-symbolic", title: "Ночной свет", detail: "Только если установлен wlsunset"),
    QuickItem(id: "dnd", icon: "notifications-disabled-symbolic", title: "Не беспокоить", detail: "Режим mako"),
    QuickItem(id: "apps", icon: "view-app-grid-symbolic", title: "Приложения", detail: "Поиск fuzzel"),
    QuickItem(id: "display", icon: "preferences-desktop-display-symbolic", title: "Экран", detail: "Раздел экрана Ubuntu"),
    QuickItem(id: "power", icon: "power-profile-balanced-symbolic", title: "Питание", detail: "Профили и сон"),
  ]

proc themeIcon*(name: string): string =
  ## Путь к значку трея. Пустое имя — пустой путь, заглушку темы не подставляем.
  if name.len == 0: return ""
  if name[0] == '/': return if fileExists(name): name else: ""
  let bases = [
    getHomeDir() / ".local/share/icons",
    "/usr/share/icons/Papirus-Dark",
    "/usr/share/icons/hicolor",
    "/usr/share/icons/Adwaita",
  ]
  let sizes = ["24x24", "22x22", "16x16", "32x32", "48x48", "symbolic", "scalable"]
  let cats = ["status", "panel", "devices", "apps", "places", "actions"]
  for base in bases:
    for size in sizes:
      for cat in cats:
        for ext in [".svg", ".png"]:
          let p = base / size / cat / (name & ext)
          if fileExists(p): return p
  ""

proc hyprctl*(args: varargs[string]): string =
  ## stdout hyprctl (ошибки глушим)
  withChildWait:
    try: result = execProcess("hyprctl", args = args, options = {poUsePath, poStdErrToStdOut}).strip()
    except OSError: result = ""

# ------------------------------------------------------------ эффекты Hyprland
proc fmt2(x: float): string = formatFloat(x, ffDecimal, 2)

proc effectsLines*(e: JsonNode): seq[string] =
  template i(k: string): string = $int(e[k].getFloat)          # 1.0 → "1"
  template b(k: string): string = (if e[k].getBool: "1" else: "0")
  @["# Сгенерировано MAZZY Environment (mazzy-settings) — правь через него",
    "decoration:blur:enabled = " & b("blur"),
    "decoration:blur:size = " & i("blur_size"),
    "decoration:blur:passes = " & i("blur_passes"),
    "decoration:rounding = " & i("rounding"),
    "general:gaps_in = " & i("gaps_in"),
    "general:gaps_out = " & i("gaps_out"),
    "decoration:shadow:enabled = " & b("shadow"),
    "decoration:inactive_opacity = " & fmt2(e["inactive_opacity"].getFloat),
    "decoration:dim_inactive = " & (if e["dim_inactive"].getFloat > 0: "1" else: "0"),
    "decoration:dim_strength = " & fmt2(e["dim_inactive"].getFloat),
    "animations:enabled = " & b("animations")]

proc applyEffects*(e: JsonNode) =
  let lines = effectsLines(e)
  for l in lines[1 .. ^1]:
    let kv = l.split(" = ", 1)
    discard hyprctl("keyword", kv[0], kv[1])
  writeFile(hyprConf("mazzy-effects.conf"), lines.join("\n") & "\n")

# ------------------------------------------------------------ бинды Hyprland
type Bind* = object
  lineno*: int
  kind*, mods*, key*, action*, comment*, section*: string

const
  NiceKeys = {"left": "←", "right": "→", "up": "↑", "down": "↓", "return": "Enter", "space": "Space", "tab": "Tab",
              "code:59": ",", "code:60": ".", "code:49": "`", "grave": "`", "comma": ",", "period": ".",
              "print": "PrtSc", "escape": "Esc", "mouse:272": "ЛКМ", "mouse:273": "ПКМ",
              "mouse_down": "колесо ↓", "mouse_up": "колесо ↑"}.toTable
  NiceMods = {"SUPER": "⌘", "$MOD": "⌘", "SHIFT": "⇧", "ALT": "⌥", "CTRL": "Ctrl", "CONTROL": "Ctrl"}.toTable
  Actions = {"killactive": "Закрыть окно", "fullscreen 0": "Полный экран", "fullscreen 1": "Максимизировать",
             "togglefloating": "Плавающее / в сетке", "pseudo": "Псевдотайл",
             "layoutmsg togglesplit": "Сменить направление деления",
             "movefocus l": "Фокус влево", "movefocus r": "Фокус вправо", "movefocus u": "Фокус вверх", "movefocus d": "Фокус вниз",
             "movewindow l": "Сдвинуть окно влево", "movewindow r": "Сдвинуть окно вправо", "movewindow u": "Сдвинуть окно вверх", "movewindow d": "Сдвинуть окно вниз",
             "resizeactive -40 0": "Уже на 40 px", "resizeactive 40 0": "Шире на 40 px", "resizeactive 0 -40": "Ниже на 40 px", "resizeactive 0 40": "Выше на 40 px",
             "movewindow": "Перетащить окно мышью", "resizewindow": "Изменить размер мышью",
             "workspace e-1": "Предыдущий стол", "workspace e+1": "Следующий стол"}.toTable

proc bindsPath*(): string = hyprConf("binds.conf")

proc splitBind(rest: string): (seq[string], string) =
  ## тело после "=" → (части до 4 через ",", комментарий)
  let body = rest.split("#", 1)
  var parts: seq[string]
  for p in body[0].split(",", 3): parts.add p.strip()
  (parts, (if body.len > 1: body[1].strip() else: ""))

proc parseBinds*(): seq[Bind] =
  var section = "Общее"
  var lines: seq[string]
  try: lines = readFile(bindsPath()).split("\n")
  except OSError, IOError: return
  for i, line in lines:
    let t = line.strip()
    if t.startsWith("# ---"):
      section = t.strip(chars = {'#', ' ', '-'}); continue
    if not t.startsWith("bind"): continue
    let kv = t.split("=", 1)
    if kv.len < 2: continue
    let (parts, comment) = splitBind(kv[1])
    if parts.len < 3: continue
    let args = if parts.len > 3: parts[3] else: ""
    result.add Bind(lineno: i, kind: kv[0].strip(), mods: parts[0], key: parts[1],
                    action: (parts[2] & " " & args).strip(), comment: comment, section: section)

proc comboLabel*(mods, key: string): string =
  var m: seq[string]
  for x in mods.replace("$mod", "SUPER").splitWhitespace(): m.add NiceMods.getOrDefault(x.toUpperAscii, x)
  var k = NiceKeys.getOrDefault(key.toLowerAscii, key)
  if k.len == 1: k = k.toUpperAscii
  (m & k).join(" ")

proc describe*(b: Bind): string =
  if b.comment.len > 0: return b.comment
  let a = b.action
  if a in Actions: return Actions[a]
  if a.startsWith("workspace "): return "Стол " & a.split()[1]
  if a.startsWith("movetoworkspace "): return "Перенести окно на стол " & a.split()[1].split(",")[0]
  if a.startsWith("exec "): return a[5 .. ^1]
  a

proc writeBind*(lineno: int, mods, key: string): string =
  ## Переписать сочетание в строке lineno. Комментарий сохраняется. Композитор не перечитывается.
  var lines = readFile(bindsPath()).split("\n")
  let line = lines[lineno]
  let kv = line.split("=", 1)
  let (parts0, comment) = splitBind(kv[1])
  var parts = parts0
  parts[0] = mods; parts[1] = key
  var newLine = kv[0].strip(leading = false) & " = " & parts.join(", ")
  if line.contains("#"):
    # комментарий — в той же колонке, что был (минимум два пробела, если новое сочетание длиннее)
    newLine = newLine.alignLeft(max(line.find('#'), newLine.len + 2)) & "# " & comment
  lines[lineno] = newLine
  writeFile(bindsPath(), lines.join("\n"))
  # Следующий вход. hyprctl reload на живом 0.53.3 подхватил бы синтаксис 0.56.
  ""
