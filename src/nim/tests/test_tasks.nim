## Контракты задач оболочки без композитора и без живой панели.
import std/[os, posix, strutils, times, json]
import ../seat, ../mazzy_common

doAssert not effectsCallHypr(skMango)
doAssert not effectsCallHypr(skNone)
doAssert effectsCallHypr(skHyprland)

let absent = nightLightPlan(false, false)
doAssert absent.cmd.len == 0
doAssert "wlsunset" in absent.note
doAssert nightLightPlan(false, true).cmd.len == 0
doAssert nightLightPlan(true, true).cmd == "pkill -x wlsunset"
doAssert nightLightPlan(true, false).cmd == "wlsunset -t 4500"
doAssert not carouselCaptures(false, false)
doAssert carouselCaptures(true, false)
doAssert carouselCaptures(false, true)
doAssert captureBudget(0) == 0
doAssert captureBudget(1) == 1
doAssert captureBudget(9) == 3
doAssert thumbScale(1920, 1080, 640) == 3
doAssert thumbScale(100, 80, 640) == 1
doAssert shmBytesOk(1920, 1080)
doAssert not shmBytesOk(8000, 4000)
doAssert not shmBytesOk(8193, 1)

doAssert volumeIconName(0, true) == "audio-volume-muted-symbolic"
doAssert volumeIconName(10, false) == "audio-volume-low-symbolic"
doAssert volumeIconName(50, false) == "audio-volume-medium-symbolic"
doAssert volumeIconName(80, false) == "audio-volume-high-symbolic"
doAssert volumeIconName(120, false) == "audio-volume-overamplified-symbolic"
doAssert volumeIconName(-1, false) == "audio-volume-medium-symbolic"
doAssert volumeParts("звук выкл").muted
doAssert volumeParts("звук 80%").pct == 80
doAssert batteryIconName(-1, false) == "battery-missing-symbolic"
doAssert batteryIconName(4, false) == "battery-level-0-symbolic"
doAssert batteryIconName(42, false) == "battery-level-40-symbolic"
doAssert batteryIconName(42, true) == "battery-level-40-charging-symbolic"
doAssert batteryIconName(100, true) == "battery-level-100-charged-symbolic"
doAssert batteryParts("42%+").charging and batteryParts("42%+").pct == 42
doAssert batteryParts("89% 1ч").pct == 89 and not batteryParts("89% 1ч").charging
doAssert batteryParts("—").pct == -1
let cal = calendarLines(2026, 10, 31, 5)
doAssert cal.title == "31 октября" and cal.sub == "суббота 2026"
doAssert calendarLines(1999, 10, 31, 5).title.len == 0
doAssert micLabel(59, false, true) == "мик 59%"
doAssert micLabel(59, true, true) == "мик выкл"
doAssert micLabel(59, false, false).len == 0
doAssert micIconName(true) == "microphone-sensitivity-muted-symbolic"
doAssert profileLabel("performance") == "быстро"
doAssert profileLabel("balanced") == "баланс"
doAssert profileLabel("power-saver") == "эконом"
doAssert profileLabel("sleep").len == 0
doAssert profileIconName("performance").len > 0
doAssert ProfileIds.len == 3
doAssert batteryMinutes("Discharging", 41669000, 23987000) == 104
doAssert batteryMinutes("Charging", 41669000, 23987000) == -1
doAssert batteryMinutes("Discharging", 100, 0) == -1
doAssert batteryMinutes("Discharging", 1, 1) == 60
doAssert batteryMinutes("Discharging", 3000, 1) == -1
doAssert batteryTimeShort(104) == "1ч"
doAssert batteryTimeShort(40) == "40м"
doAssert batteryTimeShort(-1).len == 0
doAssert vpnActive("802-11-wireless:activated\ntun:activated")
doAssert vpnActive("vpn:activated")
doAssert not vpnActive("802-11-wireless:activated\nloopback:activated")
doAssert not vpnActive("")
doAssert unpinnedClasses(@["firefox_firefox"], @["firefox", "Rio", "firefox"], 8) == @["Rio"]
doAssert unpinnedClasses(@["firefox"], @[""], 8).len == 0
doAssert dockBody(0) == 68 and dockBody(2) == 120
doAssert dockZone(0) == 76 and dockZone(1) == 128
doAssert menuPicks(@[MenuPick(id: "a", name: "А"), MenuPick(id: "a", name: "Б"), MenuPick(id: "b", name: "В")], 1)[0].id == "a"
doAssert menuPicks(@[MenuPick(id: "a", name: "А")], 0).len == 0
doAssert osdText(1, 40, false) == "звук 40%"
doAssert osdText(1, 40, true) == "звук выкл"
doAssert osdText(2, 40, false) == "яркость 40%"
doAssert osdText(0, 40, false).len == 0
let bat = batteryReport()
doAssert bat.pct == -1 or bat.pct in 0 .. 100
doAssert networkIconName(true) == "network-wireless-connected-symbolic"
doAssert networkIconName(false) == "network-wireless-offline-symbolic"
doAssert controlsIconName() == "view-app-grid-symbolic"
doAssert brightIconName() == "display-brightness-symbolic"
doAssert themeIcon(brightIconName()).len > 0
doAssert pctClamp(-3) == 0 and pctClamp(140) == 100 and pctClamp(40) == 40
doAssert brightPct(244, 4882) == 5
doAssert backlightDevOk("intel_backlight")
doAssert not backlightDevOk("")
doAssert not backlightDevOk("../etc")
doAssert not backlightDevOk("a/b")
doAssert backlightAbs(5, 4882) == 244
doAssert backlightAbs(40, 4882) == 1953
doAssert backlightAbs(50, 4882) == 2441
doAssert menuGroupOf("AudioVideo") == "Звук и видео"
doAssert menuGroupOf("Foo") == "Прочее"
doAssert menuPicks(@[MenuPick(id: "a", name: "А", icon: "i", group: "Сеть")], 1)[0].group == "Сеть"
doAssert wifiSignal("46") == 46
doAssert wifiSignal("--") == -1
doAssert wifiSignal("") == -1
doAssert wifiRows("*:Дом:70\n :Кафе:--\n").len == 2
doAssert wifiRows("*:Дом:70\n")[0].signal == 70
doAssert wifiRows(" :Кафе:--\n")[0].signal == -1
doAssert loadLabel("0.42 0.31 0.20 1/200 1") == "нагр 0.4"
doAssert loadLabel("") == ""
doAssert monitorScale("monitor = eDP-1, preferred, 0x0, 1") == 1
doAssert monitorScale("# monitor = eDP-1, preferred, 0x0, 2") == -1
doAssert chromeWidget(defaults(), "clip") == false
doAssert chromeWidget(defaults(), "volume") == true
doAssert chromeLabels(defaults()) == false
doAssert chromeLabels(nil) == false
doAssert chromeDismiss(defaults()) == 1000
doAssert chromeDismiss(nil) == 1000
doAssert dismissDue(0, 2, 1000, false) == false
doAssert dismissDue(1, 1.5, 1000, false) == false
doAssert dismissDue(1, 2.1, 1000, false) == true
doAssert dismissDue(1, 3, 1000, true) == false
doAssert dismissDue(1, 3, 0, false) == false
doAssert layoutMark("") == ""
doAssert layoutMark("Russian") == "RU"
doAssert layoutMark("English (US)") == "EN"
doAssert layoutMark("German") == "GE"
doAssert powerStep("", "sleep").fire == false
doAssert powerStep("", "sleep").arm == "sleep"
doAssert powerStep("sleep", "sleep").fire == true
doAssert powerStep("sleep", "off").arm == "off"
doAssert powerStep("sleep", "off").fire == false
doAssert powerStep("", "lock").fire == true
doAssert sessionAct("logout", "").go == false
doAssert sessionAct("logout", "").note == "Нет номера сессии"
doAssert sessionAct("logout", "7").go == true
doAssert sessionAct("lock", "").go == true
doAssert sessionAct("sleep", "").go == true
doAssert sessionAct("off", "").go == true
doAssert sessionAct("nope", "7").go == false
doAssert widgetMeta("layout").title == "Раскладка"
doAssert widgetMeta("volume").title == "Звук"
doAssert widgetMeta("night").title.len == 0
doAssert clipPush(@["a"], "a", 4) == @["a"]
doAssert clipPush(@["a"], "b", 4) == @["b", "a"]
doAssert clipPush(@["a"], "", 4) == @["a"]
doAssert dndOn("do-not-disturb") == 1
doAssert dndOn("default") == 0
doAssert dndOn("") == -1
doAssert notifyLines("Notification 2: Hello\n  App name: Terminal\nNotification 1: Сеть\n  App name: nm\n", 4) == @["Hello · Terminal", "Сеть · nm"]
doAssert clipRunes("Привет", 4) == "При…"
doAssert clipRunes("abcdef", 4) == "abc…"
doAssert clipRunes("abc", 4) == "abc"
doAssert firstRune("") == ""
doAssert firstRune("A") == "A"
doAssert firstRune("Яблоко") == "Я"
doAssert firstRune("ёж") == "ё"
doAssert foldSearch("Звук") == "звук"
doAssert foldSearch("Яблоко") == "яблоко"
doAssert foldSearch("Ёж") == "ёж"
doAssert foldSearch("EN") == "en"
doAssert "звук" in foldSearch("Звук и видео")
doAssert notifyLines("", 4).len == 0
doAssert notifyLines("Notification 1: One\nNotification 2: Two\n", 1) == @["One"]
doAssert rfkillSoft("0: hci0: Bluetooth\n\tSoft blocked: no\n", "bluetooth") == 0
doAssert rfkillSoft("0: hci0: Bluetooth\n\tSoft blocked: yes\n", "bluetooth") == 1
doAssert rfkillSoft("", "bluetooth") == -1
doAssert mediaLine("  ") == ""
doAssert mediaLine(" - ") == ""
doAssert mediaLine("Artist - Title") == "Artist - Title"
let cyrMedia = "абвгдежзийклмнопрстуфхцчшщъыьэюяабв"
doAssert mediaLine(cyrMedia) == clipRunes(cyrMedia, 32)
doAssert mediaLine(cyrMedia).endsWith("…")
let face = dockMetrics(0, true)
doAssert face.icon == 40 and face.slot == 54
doAssert face.body > dockMetrics(0, false).body
doAssert dockBody(0) == 68
doAssert backlightAbs(10, 0) == -1
doAssert BrightPresets == [10, 40, 70, 100]
let bus = backlightBusArgs("intel_backlight", 1953)
doAssert bus[0] == "busctl" and bus[^1] == "1953"
doAssert "brightnessctl" notin bus.join(" ")
doAssert "SetBrightness" in bus
let liveMax = backlightMax("intel_backlight")
doAssert liveMax == 4882
doAssert backlightCommand("intel_backlight", 40) == backlightBusArgs("intel_backlight", backlightAbs(40, liveMax)).join(" ")
doAssert brightPct(0, 100) == 0 and brightPct(50, 100) == 50
doAssert brightPct(1, 0) == -1
doAssert sliderPct(0, 0, 100) == 0
doAssert sliderPct(50, 0, 100) == 50
doAssert sliderPct(100, 0, 100) == 100
doAssert sliderPct(-10, 0, 100) == 0
doAssert sliderPct(150, 0, 100) == 100
let sinkText = """
Audio
 ├─ Sinks:
 │  *   58. Built-in Audio Analog Stereo        [vol: 1.00]
 │      71. Headphones        [vol: 0.40]
 ├─ Sources:
 │      59. Built-in Audio Analog Stereo
"""
let sinks = parseSinks(sinkText)
doAssert sinks.len == 2
doAssert sinks[0].current and sinks[0].id == "58"
doAssert sinks[1].id == "71" and sinks[1].name == "Headphones"
doAssert nextSink(sinks).id == "71"
doAssert nextSink(@[sinks[0]]).id == "58"
doAssert parseSinks("Audio\n ├─ Sources:\n │      59. Mic\n").len == 0
doAssert wpctlVolume("Volume: 1.00").pct == 100
doAssert wpctlVolume("Volume: 0.40 [MUTED]").muted
doAssert wpctlVolume("Volume: 0.40 [MUTED]").pct == 40
doAssert themeIcon(volumeIconName(80, false)).len > 0
doAssert themeIcon(batteryIconName(40, false)).len > 0
doAssert themeIcon(controlsIconName()).len > 0
doAssert dockSpan(1, 58, 28, 1200) == 86
doAssert dockSpan(17, 58, 28, 1200) == 1014
doAssert dockSpan(40, 58, 28, 1200) == 1200
doAssert DockPinCap == 19
doAssert dockSpan(DockPinCap + 1, 58, 28, 1200) == 1188
doAssert dockSpan(DockPinCap + 2, 58, 28, 1200) == 1200
doAssert themeIcon(networkIconName(false)).len > 0
doAssert netShort(true) == "сеть" and netShort(false) == "нет"
doAssert fuzzelFontLine("font=Inter:size=13", "Noto Sans") == "font=Noto Sans:size=13"
doAssert fuzzelFontLine("font=Noto Sans:size=13", "Inter") == "font=Inter:size=13,Noto Sans:size=13"
doAssert fuzzelFontLine("", "Inter Display") == "font=Inter Display:size=13,Noto Sans:size=13"
doAssert "size=11" notin fuzzelFontLine("font=Inter:size=13", "Inter")
doAssert pinRuns("firefox_firefox", "firefox")
doAssert pinRuns("firefox_firefox", "firefox_firefox")
doAssert pinRuns("com.rioterm.Rio", "Rio")
doAssert pinRuns("org.gnome.Nautilus", "nautilus")
doAssert pinRuns("org.gnome.Nautilus", "org.gnome.Nautilus")
doAssert pinRuns("kitty", "kitty")
doAssert pinRuns("org.telegram.desktop._abc", "org.telegram.desktop")
doAssert not pinRuns("firefox_firefox", "thunderbird")
doAssert not pinRuns("org.gnome.Nautilus", "org")
doAssert not pinRuns("com.rioterm.Rio", "c")
doAssert not pinRuns("", "firefox")
proc wipeTree(path: string) =
  if dirExists(path):
    for kind, p in walkDir(path):
      if kind == pcDir or kind == pcLinkToDir: wipeTree(p)
      else:
        try: removeFile(p) except OSError: discard
    try: removeDir(path) except OSError: discard
  elif fileExists(path):
    try: removeFile(path) except OSError: discard

let deskRoot = "/tmp/mazzy-desk-fixture"
let netRoot = "/tmp/mazzy-net-fixture"
wipeTree(deskRoot)
wipeTree(netRoot)
createDir(deskRoot / "applications")
createDir(deskRoot / "icons/hicolor/48x48/apps")
writeFile(deskRoot / "applications/demo.desktop", "Name=Demo\nIcon=demo\n")
writeFile(deskRoot / "icons/hicolor/48x48/apps/demo.png", "x")
writeFile(deskRoot / "applications/abs.desktop", "Icon=" & deskRoot & "/icons/hicolor/48x48/apps/demo.png\n")
doAssert findDesktopFile("demo", @[deskRoot / "applications"]).endsWith("demo.desktop")
doAssert findDesktopFile("../etc/passwd", @[deskRoot / "applications"]).len == 0
doAssert findDesktopFile("a/b", @[deskRoot / "applications"]).len == 0
doAssert desktopValue(readFile(deskRoot / "applications/demo.desktop"), "Name") == "Demo"
doAssert appIconPath("demo", @[deskRoot / "icons/hicolor"]).endsWith("demo.png")
doAssert appIconPath(deskRoot & "/icons/hicolor/48x48/apps/demo.png", @[]).len > 0
doAssert appIconPath("/no/such-icon", @[]).len == 0
createDir(netRoot / "lo")
createDir(netRoot / "wlan0")
writeFile(netRoot / "lo/operstate", "up\n")
writeFile(netRoot / "wlan0/operstate", "down\n")
doAssert not linkUp(netRoot)
doAssert not linkUp(netRoot & "-missing")
writeFile(netRoot / "wlan0/operstate", "up\n")
doAssert linkUp(netRoot)
wipeTree(deskRoot)
wipeTree(netRoot)
let dirs = desktopSearchDirs()
doAssert "/var/lib/snapd/desktop/applications" in dirs
doAssert "/var/lib/flatpak/exports/share/applications" in dirs
let ff = findDesktopFile("firefox_firefox", dirs)
let rio = findDesktopFile("com.rioterm.Rio", dirs)
let tb = findDesktopFile("thunderbird_thunderbird", dirs)
doAssert "snapd" in ff and fileExists(desktopValue(readFile(ff), "Icon"))
doAssert "flatpak" in rio
doAssert appIconPath(desktopValue(readFile(rio), "Icon"), iconSearchRoots()).len > 0
doAssert "snapd" in tb and fileExists(desktopValue(readFile(tb), "Icon"))
var quickIds: seq[string]
for item in quickCatalog():
  doAssert item.id.len > 0 and item.icon.len > 0 and item.title.len > 0
  doAssert item.id notin quickIds
  quickIds.add item.id
doAssert quickIds.len == 10
for need in ["audio", "wifi", "bluetooth", "night", "apps", "power"]:
  doAssert need in quickIds

proc statusField(pid: int, key: string): string =
  try:
    for line in lines("/proc/" & $pid & "/status"):
      if line.startsWith(key & ":"):
        return line[key.len + 1 .. ^1].strip
  except IOError, OSError:
    discard

proc zombieChildren(parent: int): int =
  for kind, path in walkDir("/proc"):
    if kind != pcDir: continue
    var pid: int
    try: pid = parseInt(path.splitPath.tail)
    except ValueError: continue
    if statusField(pid, "PPid") == $parent and statusField(pid, "State").startsWith("Z"):
      result += 1

let me = int(getCurrentProcessId())
let mark = "/tmp/mazzy-detach-" & $me
try: removeFile(mark) except OSError: discard
let started = epochTime()
let code = detachSpawn(@["/bin/sh", "-c", "echo $$ > " & mark & "; exec sleep 30"])
doAssert code == 0
doAssert epochTime() - started < 2
var child = 0
for _ in 0 ..< 50:
  if fileExists(mark):
    try: child = parseInt(readFile(mark).strip) except ValueError, IOError: child = 0
    if child > 0: break
  sleep(20)
doAssert child > 0
doAssert statusField(child, "PPid") != $me
doAssert not statusField(child, "State").startsWith("Z")
doAssert zombieChildren(me) == 0
discard kill(Pid(child), SIGTERM)

var bare: MenuLive
bare.session = true
let bareTiles = controlTiles(bare)
doAssert bareTiles[0].id == "volume"
doAssert bareTiles[^1].id == "session"
doAssert bareTiles.len == 2
for tile in bareTiles:
  doAssert tile.id != "brightness"
  doAssert tile.id != "night"
  doAssert tile.id != "weather"
bare.brightness = "69%"
bare.bluetooth = "bt"
bare.dnd = "тихо"
bare.network = "сеть"
let moreTiles = controlTiles(bare)
doAssert moreTiles[1].id == "brightness"
doAssert moreTiles[2].id == "network"
var sawBt = false
for tile in moreTiles:
  if tile.id == "bluetooth": sawBt = true
  doAssert tile.id != "night"
doAssert sawBt
doAssert tileHot("bluetooth", "bt")
doAssert not tileHot("bluetooth", "bt выкл")
doAssert tileHot("dnd", "тихо")
doAssert not tileHot("dnd", "уведом")
doAssert tileHot("mic", "мик 10%")
doAssert not tileHot("mic", "мик выкл")
doAssert not tileHot("volume", "звук 40%")
doAssert widgetMark(true, "40%") == "вкл · 40%"
doAssert widgetMark(false, "") == "выкл"
doAssert widgetMark(true, "  ") == "вкл"
doAssert flipBtHint("bt") == "bt выкл"
doAssert flipBtHint("bt выкл") == "bt"
doAssert flipBtHint("") == ""
doAssert flipDndHint("тихо") == "уведом"
doAssert flipDndHint("уведом") == "тихо"
doAssert flipMicHint("мик 59%") == "мик выкл"
doAssert flipMicHint("мик выкл") == "мик"
doAssert menuAppCap("") == 16
doAssert menuAppCap("  ") == 16
doAssert menuAppCap("fire") == 40
doAssert menuTabOf("tab:0") == 0
doAssert menuTabOf("tab:2") == 2
doAssert menuTabOf("volume") == -1
doAssert menuStatusLine("RU", "user") == "RU  ·  user"
doAssert menuStatusLine("RU", "") == "RU"
doAssert menuStatusLine("", "") == ""
doAssert menuReturnId("", @[MenuSlot(kind: mkApp, id: "a")]) == ""
doAssert menuReturnId("f", @[MenuSlot(kind: mkApp, id: "a")]) == "a"
doAssert menuReturnId("f", @[MenuSlot(kind: mkApp, id: "a"), MenuSlot(kind: mkApp, id: "b")]) == ""
let boxes = menuBoxes([mkTab, mkTab, mkTab, mkSearch, mkTile, mkTile, mkTile], menuWide)
doAssert boxes.len == 7
doAssert boxes[0].y == boxes[1].y and boxes[1].y == boxes[2].y
doAssert boxes[0].x < boxes[1].x and boxes[1].x < boxes[2].x
doAssert boxes[4].y == boxes[5].y
doAssert boxes[6].y > boxes[4].y
doAssert boxes[6].x == boxes[4].x
doAssert menuHit(boxes[5].x + 1, boxes[5].y + 1, boxes) == 5
doAssert menuHit(-1, -1, boxes) == -1
doAssert menuSheetHeight([mkSearch], menuWide) >= 180
doAssert menuSheetHeight([mkSearch], menuWide) <= 920
var many: seq[MenuSlot]
many.add MenuSlot(kind: mkTab, id: "tab:0")
many.add MenuSlot(kind: mkTab, id: "tab:1")
many.add MenuSlot(kind: mkTab, id: "tab:2")
many.add MenuSlot(kind: mkSearch, id: "search")
many.add MenuSlot(kind: mkHead, id: "")
for i in 0 ..< 40:
  many.add MenuSlot(kind: mkApp, id: "app" & $i)
many.add MenuSlot(kind: mkHead, id: "")
many.add MenuSlot(kind: mkAct, id: "all")
let fit = menuFit(many, menuWide, 840)
var fitKinds = newSeq[int](fit.len)
for i, r in fit: fitKinds[i] = r.kind
doAssert menuSpanHeight(fitKinds, menuWide) <= 840
doAssert fit[0].id == "tab:0"
doAssert fit[^1].id == "all"
for i, r in fit:
  if r.kind == mkHead:
    doAssert i + 1 < fit.len
    doAssert fit[i + 1].id != "all"
    doAssert fit[i + 1].kind != mkHead
let short = menuFit(@[MenuSlot(kind: mkSearch, id: "search")], menuWide, 840)
doAssert short.len == 1 and short[0].id == "search"
var widgetKinds = @[mkTab, mkTab, mkTab, mkSearch, mkHead]
for i in 0 ..< 11: widgetKinds.add mkWidget
widgetKinds.add mkHead
for i in 0 ..< 6: widgetKinds.add mkWidget
widgetKinds.add mkHead
widgetKinds.add mkWidget
widgetKinds.add mkWidget
doAssert menuSpanHeight(widgetKinds, menuWide) <= 920
doAssert menuSheetHeight(widgetKinds, menuWide) == menuSpanHeight(widgetKinds, menuWide)

doAssert chromeOpacity(defaults()) == 100
doAssert chromeOpacity(nil) == 100
doAssert chromeStyle(defaults()) == "paper"
doAssert chromeStyle(nil) == "paper"
doAssert styleTitle("ink") == "Чернила"
doAssert styleCycle("paper") == "ink"
doAssert styleCycle("ink") == "dawn"
doAssert styleCycle("dawn") == "paper"
doAssert styleCycle("nope") == "paper"
doAssert opacityCycle(100) == 80
doAssert opacityCycle(80) == 60
doAssert opacityCycle(60) == 40
doAssert opacityCycle(40) == 100
doAssert opacityCycle(90) == 80
doAssert chromeInk("ink").paperB > chromeInk("paper").paperB
doAssert chromeInk("dawn").paperR > chromeInk("paper").paperR
doAssert chromeOrder(nil) == widgetRightIds()
doAssert "desks" notin chromeOrder(defaults())
doAssert "clock" notin chromeOrder(defaults())
doAssert chromeOrder(defaults())[0] == "battery"
doAssert chromeOrder(defaults())[^1] == "tray"
let moved = orderMove(widgetRightIds(), "battery", 1)
doAssert moved[0] == "layout" and moved[1] == "battery"
doAssert orderMove(widgetRightIds(), "battery", -1)[0] == "battery"
doAssert orderMove(widgetRightIds(), "missing", 1) == widgetRightIds()
let custom = %*{"chrome": {"order": ["tray", "nope", "volume", "tray"], "opacity": 20, "style": "glass"}}
doAssert chromeOrder(custom)[0] == "tray"
doAssert chromeOrder(custom)[1] == "volume"
doAssert "nope" notin chromeOrder(custom)
doAssert chromeOrder(custom).len == widgetRightIds().len
doAssert chromeOpacity(custom) == 40
doAssert chromeStyle(custom) == "paper"
var heard: MenuLive
heard.media = "track"
var ids: seq[string]
for t in controlTiles(heard): ids.add t.id
doAssert "media-prev" in ids and "media" in ids and "media-next" in ids
var quiet: MenuLive
for t in controlTiles(quiet):
  doAssert t.id notin ["media-prev", "media", "media-next"]
var editKinds = @[mkTab, mkTab, mkTab, mkSearch, mkAct, mkAct, mkAct, mkAct, mkHead]
for i in 0 ..< widgetRightIds().len: editKinds.add mkWidget
doAssert menuSpanHeight(editKinds, menuWide) <= 920
var ctrl = @[mkTab, mkTab, mkTab, mkSearch, mkHead, mkHead]
for i in 0 ..< 15: ctrl.add mkTile
ctrl.add mkHead
for i in 0 ..< 5: ctrl.add mkAct
doAssert menuSpanHeight(ctrl, menuWide) <= 920

doAssert cpuSample("cpu  1 2 3 4 1 0 0 0").idle == 5
doAssert cpuSample("cpu  1 2 3 4 1 0 0 0").total == 11
doAssert cpuSample("").idle == -1
doAssert cpuPct(0, 0, 10, 100) == -1
doAssert cpuPct(5, 11, 15, 111) == 90
doAssert cpuLabel(12) == "цп 12%"
doAssert cpuLabel(-1) == ""
doAssert memLabel("MemTotal: 1000 kB\nMemAvailable: 600 kB\n") == "пам 40%"
doAssert memLabel("MemTotal: 1000 kB\n") == ""
doAssert netBytes("lo: 5 0 0 0 0 0 0 0 9\neth0: 1000 0 0 0 0 0 0 0 200\n").rx == 1000
doAssert netBytes("").rx == -1
doAssert netLabel(-1, -1, 1000, 200, 3.0) == ""
doAssert netLabel(1000, 200, 1000, 200, 3.0) == "0/с"
doAssert netLabel(0, 0, 3000, 0, 1.0) == "3К/с"
doAssert weekdayMon0(2026, 10, 31) == 5
doAssert weekdayMon0(2026, 10, 1) == 3
doAssert daysInMonth(2024, 2) == 29
doAssert daysInMonth(2026, 2) == 28
let grid = monthGrid(2026, 10, 31)
doAssert grid.title == "октябрь 2026"
doAssert grid.cells[3] == 1
doAssert grid.cells[33] == 31
doAssert clockCaption("time", 21, 5, 31, 10) == "21:05"
doAssert clockCaption("date", 21, 5, 31, 10) == "21:05  31 окт"
doAssert clockCaption("hands", 21, 5, 31, 10) == ""
doAssert chromeClock(nil) == "time"
doAssert chromeClock(%*{"chrome": {"clock": "hands"}}) == "hands"
doAssert chromeClock(%*{"chrome": {"clock": "glass"}}) == "time"
doAssert opacityAt(0, 0, 100) == 40
doAssert opacityAt(100, 0, 100) == 100
doAssert opacityAt(50, 0, 100) == 70
doAssert "cpu" in widgetRightIds()
doAssert "mem" in widgetRightIds()
doAssert "netio" in widgetRightIds()
doAssert widgetRightIds()[0] == "battery"
doAssert widgetRightIds()[^1] == "tray"
let band = menuBoxes(@[mkBand, mkBand, mkBand], menuWide)
doAssert band.len == 3
doAssert band[0].y == band[1].y and band[2].y == band[0].y
doAssert dashIdAt(24, 120, 460) == "time"
doAssert dashIdAt(24, 160, 460) == "settings"
doAssert dashIdAt(24, 400, 460) == "lock"
doAssert dashIdAt(24, 250, 460) == ""

echo "OK tasks"
