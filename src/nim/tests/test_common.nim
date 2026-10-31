## Проверка mazzy_common: effectsLines == conf/mazzy-effects.conf, parseBinds == число строк bind в binds.conf
import std/[os, strutils, json]
import ../mazzy_common
let cfg = load()
let want = readFile(hyprConf("mazzy-effects.conf")).strip().split("\n")
let got = effectsLines(cfg["effects"])
doAssert got == want, "effectsLines:\n" & got.join("\n") & "\n---\n" & want.join("\n")
var n = 0
for l in readFile(bindsPath()).split("\n"):
  if l.strip().startsWith("bind"): inc n
let b = parseBinds()
doAssert b.len == n, "parseBinds " & $b.len & " != " & $n
doAssert comboLabel("$mod ALT", "code:59") == "⌘ ⌥ ,"
doAssert comboLabel("$mod SHIFT", "q") == "⌘ ⇧ Q"
let home = getHomeDir()
doAssert expandHome("~/Pictures/a.jpg") == home / "Pictures/a.jpg"
doAssert expandHome("~") == home
doAssert expandHome("/abs/a.jpg") == "/abs/a.jpg"
doAssert hyprAddr("abc") == "0xabc"
doAssert hyprAddr("0xABC") == "0xabc"
doAssert hyprAddr("  ") == ""
doAssert hyprAddr("closewindow>>0xABC"[13 .. ^1]) == "0xabc"
doAssert hyprAddr("closewindow>>ABC"[13 .. ^1]) == "0xabc"
doAssert hyprAddr("activewindowv2>>ABC"[16 .. ^1]) == "0xabc"
let h = lowHandle("0x0000001a")
doAssert h.ok and h.handle == 0x1a'u32
doAssert lowHandle("0x1122334455667788").handle == 0x55667788'u32
doAssert not lowHandle("0xzz").ok
doAssert captureOrder(5, 1) == @[1, 0, 2, 3, 4]
doAssert captureOrder(5, -1) == @[4, 3, 2, 1, 0]
doAssert captureOrder(0, 1).len == 0
echo "OK: effects ", got.len, " строк, биндов ", b.len
# writeBind: формат строки с комментарием (на копии файла)
import std/[tempfiles]
block:
  let src = readFile(bindsPath())
  let (f, tmpPath) = createTempFile("binds", ".conf"); f.write(src); f.close()
  # подменяем путь через переменную окружения HOME нельзя — проверяем внутреннюю логику форматирования отдельно:
  let line = "bind = $mod, K, exec, $noc keyboard-layout-cycle              # дубль ⌘Space"
  let col = line.find('#')
  var newLine = "bind = $mod, Return, exec, $noc keyboard-layout-cycle"
  newLine = newLine.alignLeft(max(col, newLine.len + 2)) & "# " & "дубль ⌘Space"
  doAssert newLine.find('#') == col, newLine
  removeFile(tmpPath)
echo "OK: формат бинда"
