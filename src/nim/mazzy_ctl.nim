## mazzy-ctl — клиент биндов: switcher next | wallpaper reload | session
import std/[os, osproc, net, strutils]

if paramCount() == 1 and paramStr(1) == "session":
  let (outp, code) = execCmdEx("printf '%s\\n' 'Заблокировать' 'Выйти' | fuzzel --dmenu -p сессия", options = {poUsePath})
  if code != 0: quit(0)
  let sel = outp.strip
  if sel == "Заблокировать":
    discard execCmdEx("swaylock -f -i " & getHomeDir() & "/Pictures/Wallpapers/mazzy-09-lab.jpg", options = {poUsePath})
  elif sel == "Выйти":
    let sid = getEnv("XDG_SESSION_ID")
    if sid.len > 0: discard execCmdEx("loginctl terminate-session " & sid, options = {poUsePath})
  quit(0)

if paramCount() != 2: quit("usage: mazzy-ctl <switcher|wallpaper> <cmd> | mazzy-ctl session", 2)
let sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
try:
  sock.connectUnix(getEnv("XDG_RUNTIME_DIR", "/tmp") / ("mazzy-" & paramStr(1) & ".sock"))
  sock.send(paramStr(2) & "\n")
except CatchableError:
  quit("mazzy-ctl: демон mazzy-shell не запущен", 1)
