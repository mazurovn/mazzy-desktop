## Хост трея на сессионной шине. Композитор не нужен.
import std/[os, osproc, times]
import ../sni

doAssert sniPath(-1).len == 0
doAssert sniPath(0).len == 0
sniActivate(-1, 0, 0)
let pathArg = sniSplit("/StatusNotifierItem", ":1.5")
doAssert pathArg.service == ":1.5" and pathArg.path == "/StatusNotifierItem"
let nameArg = sniSplit("org.mazzy.SniProbe", ":1.5")
doAssert nameArg.service == "org.mazzy.SniProbe" and nameArg.path == "/StatusNotifierItem"
doAssert sniSplit("", ":1.9").service == ":1.9"

if not sniStart() or not sniWaitOwned(1500):
  sniStop()
  echo "FAIL watcher name"
  quit(1)

let probe = "org.mazzy.SniProbe"
var p: Process
try:
  p = startProcess("busctl", args = ["--user", "call", "org.kde.StatusNotifierWatcher",
    "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem", "s", probe],
    options = {poUsePath, poStdErrToStdOut})
except OSError:
  sniStop()
  echo "FAIL busctl"
  quit(1)

proc hasProbe(): bool =
  for i in 0 ..< sniCount():
    if sniService(i) == probe: return true

let deadline = epochTime() + 2
var seen = false
while epochTime() < deadline:
  sniPump()
  if hasProbe():
    seen = true
    break
  sleep(10)
var code = p.peekExitCode
let replyDeadline = epochTime() + 2
while code < 0 and epochTime() < replyDeadline:
  sniPump()
  sleep(10)
  code = p.peekExitCode
if code < 0:
  code = p.waitForExit(500)
var listed = ""
var pathOk = false
for i in 0 ..< sniCount():
  if listed.len > 0: listed.add " "
  listed.add sniService(i)
  if sniService(i) == probe and sniPath(i) == "/StatusNotifierItem": pathOk = true
let count = sniCount()
sniStop()
if not seen or code != 0 or not pathOk:
  echo "FAIL register count=" & $count & " busctl=" & $code & " path=" & $pathOk & " items=" & listed
  quit(1)
echo "OK sni"
