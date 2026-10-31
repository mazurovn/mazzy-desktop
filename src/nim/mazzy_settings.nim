## MAZZY Environment — центр настроек окружения (Nim + libadwaita): параллакс, 3D-переключатель,
## эффекты Hyprland, запуск демонов, хоткеи. Всё применяется сразу. Заменяет Python-версию (bin/mazzy-settings).
import std/[os, json, strutils, osproc, math, tables, times, sequtils, posix]
import adw, mazzy_common, seat

putEnv("GSK_RENDERER", "cairo")   # окно статичное: без EGL/Mesa старт быстрее, PSS 29 МБ вместо 52 (gl); Vulkan (hasvk) на Haswell неполный
putEnv("__EGL_VENDOR_LIBRARY_FILENAMES", "/usr/share/glvnd/egl_vendor.d/50_mesa.json")   # без nvidia-EGL: −25 МБ и без опроса PCI

# ------------------------------------------------------------ состояние
type
  RowCtx = ref object
    ## контекст ряда настроек — живёт до конца программы (глобальный seq), адрес уходит в data сигнала
    sec, key: string
    digits: int
    isSpin: bool
    row: GObj
    onChange: proc()
    pending: int
    timer: cuint
  Ctx = ref object
    cfg: JsonNode
    win, toast, stack, bindsPage: GObj
    saveId: cuint
    saveSec: string
    saveCb: proc()
    statusRows: Table[string, GObj]
    bindGroups: seq[GObj]
    keep: seq[RowCtx]
    dialog: GObj
    dialogLine: int
    audioPage: GObj
    audioGroups: seq[GObj]
    audioFilling: bool
    scoBroken: bool
  LocaleUi = ref object
    lang, layout, switchKey: string
    capsShift, ready: bool
    status, capsRow: GObj

var C: Ctx
var localeUi: LocaleUi

proc sh(cmd: string) =
  ## фоновая команда через sh, без ожидания; stdout/stderr — родительские (иначе пайп без читателя
  ## переполняется и, например, gnome-control-center виснет), зомби не копятся: SIGCHLD игнорируется в main
  discard startProcess("/bin/sh", args = ["-c", cmd], options = {poDaemon, poParentStreams})

proc cmdOut(cmd: string): tuple[output: string, exitCode: int] =
  ## execCmdEx после SIG_IGN не дожидается потомка и крутит CPU.
  withChildWait:
    try:
      result = execCmdEx(cmd)
    except CatchableError:
      result = ("", 1)

proc notify(text: string) =
  let t = adw_toast_new(text.cstring); adw_toast_set_timeout(t, 2)
  adw_toast_overlay_add_toast(C.toast, t)

proc daemonRunning(name: string): bool = send(name, "ping")
proc startDaemon(name: string) =
  if not send(name, "start"): sh("env " & MesaEgl & " " & getHomeDir() / ".local/bin/mazzy-shell")

# ------------------------------------------------------------ сохранение с задержкой
proc flush(data: pointer): gboolean {.cdecl.} =
  C.saveId = 0
  save(C.cfg)
  case C.saveSec
  of "parallax": discard send("wallpaper", "reload")
  of "switcher": discard send("switcher", "reload")
  of "effects":
    if effectsCallHypr(seatKind()): applyEffects(C.cfg["effects"])
  else: discard
  if C.saveCb != nil: C.saveCb()
  0

proc changed(sec: string, cb: proc() = nil) =
  ## не пишем файл на каждый тик спина — 250 мс после последнего изменения
  if C.saveId != 0: discard g_source_remove(C.saveId)
  C.saveSec = sec; C.saveCb = cb
  C.saveId = g_timeout_add(250, flush, nil)

# ------------------------------------------------------------ конструкторы рядов
proc group(title: string, desc = ""): GObj =
  result = adw_preferences_group_new()
  adw_preferences_group_set_title(result, title.cstring)
  if desc.len > 0: adw_preferences_group_set_description(result, desc.cstring)

proc page(groups: varargs[GObj]): GObj =
  result = adw_preferences_page_new()
  for g in groups: adw_preferences_page_add(result, g)

proc headed(title, desc, icon: string, groups: varargs[GObj]): GObj =
  result = page(groups)
  adw_preferences_page_set_title(result, title.cstring)
  if desc.len > 0: adw_preferences_page_set_description(result, desc.cstring)
  if icon.len > 0: adw_preferences_page_set_icon_name(result, icon.cstring)

proc onSwitch(obj: GObj, pspec, data: pointer) {.cdecl.} =
  let rc = cast[RowCtx](data)
  C.cfg[rc.sec][rc.key] = %(adw_switch_row_get_active(rc.row) != 0)
  changed(rc.sec, rc.onChange)

proc switch(g: GObj, sec, key, title: string, sub = "", onChange: proc() = nil) =
  let r = adw_switch_row_new()
  adw_preferences_row_set_title(r, title.cstring); adw_action_row_set_subtitle(r, sub.cstring)
  adw_switch_row_set_active(r, (if C.cfg[sec][key].getBool: 1 else: 0))
  let rc = RowCtx(sec: sec, key: key, row: r, onChange: onChange); C.keep.add rc
  connect(r, "notify::active", onSwitch, cast[pointer](rc))   # после установки значения
  adw_preferences_group_add(g, r)

proc onSpin(obj: GObj, pspec, data: pointer) {.cdecl.} =
  let rc = cast[RowCtx](data)
  let v = adw_spin_row_get_value(rc.row)
  C.cfg[rc.sec][rc.key] = (if rc.digits > 0: %round(v, rc.digits) else: %int(v))
  changed(rc.sec, rc.onChange)

proc spin(g: GObj, sec, key, title: string, lo, hi, step: float, sub = "", digits = 0) =
  let cur = C.cfg[sec][key].getFloat(C.cfg[sec][key].getInt.float)
  let adj = gtk_adjustment_new(cur, lo, hi, step, step * 5, 0)
  let r = adw_spin_row_new(adj, 1, digits.cuint)
  adw_preferences_row_set_title(r, title.cstring); adw_action_row_set_subtitle(r, sub.cstring)
  let rc = RowCtx(sec: sec, key: key, digits: digits, isSpin: true, row: r); C.keep.add rc
  connect(r, "notify::value", onSpin, cast[pointer](rc))
  adw_preferences_group_add(g, r)

proc onClick(btn: GObj, data: pointer) {.cdecl.} = cast[RowCtx](data).onChange()

proc button(label: string, cb: proc(), style = ""): GObj =
  result = gtk_button_new_with_label(label.cstring)
  gtk_widget_set_valign(result, GTK_ALIGN_CENTER)
  if style.len > 0: gtk_widget_add_css_class(result, style.cstring)
  let rc = RowCtx(onChange: cb); C.keep.add rc
  connect(result, "clicked", onClick, cast[pointer](rc))

proc gtk_css_provider_new(): GObj {.importc, header: "<adwaita.h>".}
proc gtk_css_provider_load_from_string(p: GObj, data: cstring) {.importc, header: "<adwaita.h>".}
proc gtk_style_context_add_provider_for_display(display, provider: GObj, priority: cuint) {.importc, header: "<adwaita.h>".}
proc gdk_display_get_default(): GObj {.importc, header: "<adwaita.h>".}
proc adw_style_manager_get_default(): GObj {.importc, header: "<adwaita.h>".}
proc adw_style_manager_set_color_scheme(m: GObj, scheme: cint) {.importc, header: "<adwaita.h>".}
proc gtk_entry_new(): GObj {.importc, header: "<adwaita.h>".}
proc gtk_entry_set_placeholder_text(e: GObj, t: cstring) {.importc, header: "<adwaita.h>".}
proc gtk_editable_get_text(e: GObj): cstring {.importc, header: "<adwaita.h>".}
proc gtk_editable_set_text(e: GObj, t: cstring) {.importc, header: "<adwaita.h>".}
proc gtk_widget_get_first_child(w: GObj): GObj {.importc, header: "<adwaita.h>".}
proc gtk_widget_get_next_sibling(w: GObj): GObj {.importc, header: "<adwaita.h>".}
proc gtk_box_remove(b, c: GObj) {.importc, header: "<adwaita.h>".}
proc gtk_widget_set_margin_top(w: GObj, m: cint) {.importc, header: "<adwaita.h>".}
proc gtk_widget_set_margin_start(w: GObj, m: cint) {.importc, header: "<adwaita.h>".}
proc gtk_widget_set_margin_end(w: GObj, m: cint) {.importc, header: "<adwaita.h>".}

proc facePalette(style: string): string =
  ## Три бумаги. Окно настроек читает стиль при открытии, живые панели — сразу из файла.
  case style
  of "ink":
    """
@define-color window_bg_color #12161c;
@define-color window_fg_color #e6eef6;
@define-color view_bg_color #1a212b;
@define-color view_fg_color #e6eef6;
@define-color sidebar_bg_color #0e1218;
@define-color sidebar_fg_color #e6eef6;
@define-color headerbar_bg_color #0e1218;
@define-color headerbar_fg_color #e6eef6;
@define-color card_bg_color #243040;
@define-color card_fg_color #e6eef6;
@define-color accent_bg_color #9ec8eb;
@define-color accent_fg_color #101820;
@define-color dialog_bg_color #12161c;
@define-color dialog_fg_color #e6eef6;
label { color: #e6eef6; }
.subtitle, .dim-label { color: #b7c6d6; }
entry { background-color: #243040; color: #e6eef6; }
button { background-color: #314056; color: #e6eef6; }
"""
  of "dawn":
    """
@define-color window_bg_color #2e241c;
@define-color window_fg_color #f8f1e6;
@define-color view_bg_color #3a2d22;
@define-color view_fg_color #f8f1e6;
@define-color sidebar_bg_color #261c16;
@define-color sidebar_fg_color #f8f1e6;
@define-color headerbar_bg_color #261c16;
@define-color headerbar_fg_color #f8f1e6;
@define-color card_bg_color #4a382c;
@define-color card_fg_color #f8f1e6;
@define-color accent_bg_color #f2b861;
@define-color accent_fg_color #261c16;
@define-color dialog_bg_color #2e241c;
@define-color dialog_fg_color #f8f1e6;
label { color: #f8f1e6; }
.subtitle, .dim-label { color: #e4d2bc; }
entry { background-color: #4a382c; color: #f8f1e6; }
button { background-color: #5c4636; color: #f8f1e6; }
"""
  else:
    """
@define-color window_bg_color #1b1713;
@define-color window_fg_color #f6f0e6;
@define-color view_bg_color #241f1a;
@define-color view_fg_color #f6f0e6;
@define-color sidebar_bg_color #16130f;
@define-color sidebar_fg_color #f6f0e6;
@define-color headerbar_bg_color #16130f;
@define-color headerbar_fg_color #f6f0e6;
@define-color card_bg_color #2c261f;
@define-color card_fg_color #f6f0e6;
@define-color accent_bg_color #e0b86a;
@define-color accent_fg_color #1b1713;
@define-color dialog_bg_color #1b1713;
@define-color dialog_fg_color #f6f0e6;
label { color: #f6f0e6; }
.subtitle, .dim-label { color: #d7c8b0; }
entry { background-color: #2c261f; color: #f6f0e6; }
button { background-color: #3a3228; color: #f6f0e6; }
stacksidebar image, row image { -gtk-icon-size: 16px; }
"""

proc applyFaceCss() =
  ## Светлая бумага Adwaita делала подписи нечитаемыми. Палитра — из chrome.style.
  adw_style_manager_set_color_scheme(adw_style_manager_get_default(), 4)
  let css = gtk_css_provider_new()
  let text = facePalette(chromeStyle(C.cfg)) & "stacksidebar image, row image { -gtk-icon-size: 16px; }\n"
  gtk_css_provider_load_from_string(css, text.cstring)
  gtk_style_context_add_provider_for_display(gdk_display_get_default(), css, 800)

proc buttonRow(g: GObj, title, sub, label: string, cb: proc(), style = ""): GObj =
  result = adw_action_row_new()
  adw_preferences_row_set_title(result, title.cstring); adw_action_row_set_subtitle(result, sub.cstring)
  let b = button(label, cb, style)
  adw_action_row_add_suffix(result, b); adw_action_row_set_activatable_widget(result, b)
  adw_preferences_group_add(g, result)

# ------------------------------------------------------------ страницы
proc pageParallax(): GObj =
  let g = group("Обои с параллаксом", "mazzy-shell рисует картинку из ~/.config/mazzy/wallpaper чуть крупнее экрана и сдвигает её от мыши и рабочего стола")
  switch(g, "parallax", "enabled", "Включить", "Запускает/останавливает демон", proc() =
    if C.cfg["parallax"]["enabled"].getBool: startDaemon("wallpaper"); notify("Параллакс включён")
    else: discard send("wallpaper", "quit"); notify("Параллакс выключен"))
  spin(g, "parallax", "mouse_px", "Сила от мыши", 0, 80, 2, "пикселей сдвига к краю экрана (0 — выкл)")
  spin(g, "parallax", "workspace_px", "Сдвиг на рабочий стол", 0, 200, 4, "пикселей на каждый стол")
  spin(g, "parallax", "zoom", "Увеличение картинки", 1.0, 1.4, 0.01, "запас под сдвиг; больше — сильнее ощущение глубины", 2)
  spin(g, "parallax", "smooth", "Плавность", 1, 15, 0.5, "меньше — мягче и медленнее", 1)
  let g2 = group("Обои")
  discard buttonRow(g2, "Следующие обои", "Файлы в ~/Pictures/Wallpapers", "Сменить", proc() = sh("mazzy-ctl wallpaper next"))
  discard buttonRow(g2, "Обновить картинку", "Перечитать файл обоев", "Обновить", proc() = sh("mazzy-ctl wallpaper reload"))
  headed("Обои", "Параллакс и картинка рабочего стола", "preferences-desktop-wallpaper-symbolic", g, g2)

proc showSwitcher(data: pointer): gboolean {.cdecl.} = (discard send("switcher", "next"); 0)

proc pageSwitcher(): GObj =
  let g = group("3D-карусель окон (⌘ Tab / Alt Tab)", "Изменения применяются к следующему открытию")
  spin(g, "switcher", "tilt", "Наклон боковых карточек", 0, 80, 2, "градусов")
  spin(g, "switcher", "depth", "Глубина", 0, 1200, 10, "насколько боковые уходят вдаль")
  spin(g, "switcher", "spacing", "Расстояние между карточками", 50, 800, 10)
  spin(g, "switcher", "center_gap", "Зазор вокруг выбранной", 0, 800, 10)
  spin(g, "switcher", "card_w", "Ширина карточки", 240, 1600, 20)
  spin(g, "switcher", "card_h", "Высота карточки", 160, 1000, 20)
  spin(g, "switcher", "mouse_parallax", "Параллакс от мыши", 0, 200, 5, "смещение карусели за курсором")
  spin(g, "switcher", "dim", "Затемнение фона", 0, 0.9, 0.05, "", 2)
  switch(g, "switcher", "reflection", "Отражение на «полу»")
  switch(g, "switcher", "glow", "Свечение за каруселью")
  let g2 = group("Проверка")
  discard buttonRow(g2, "Открыть карусель", "то же, что ⌘ Tab", "Показать", proc() =
    startDaemon("switcher"); discard g_timeout_add(600, showSwitcher, nil))
  headed("Окна", "3D-карусель по ⌘ Tab и Alt Tab", "view-grid-symbolic", g, g2)

proc pageEffects(): GObj =
  if not effectsCallHypr(seatKind()):
    let note = group("Эффекты этого сеанса",
      "Блюр, тени и анимации пишет Hyprland. На Mango эта страница их не применяет и не вызывает hyprctl.")
    return headed("Эффекты", "На Mango блюр и анимации отсюда не переключаются.",
                  "applications-graphics-symbolic", note)
  let g = group("Блюр и стекло", "Intel HD 4600: держи размер×проходы небольшими")
  switch(g, "effects", "blur", "Блюр за окнами и панелями")
  spin(g, "effects", "blur_size", "Размер блюра", 1, 12, 1)
  spin(g, "effects", "blur_passes", "Проходов", 1, 4, 1)
  let g2 = group("Окна")
  spin(g2, "effects", "rounding", "Скругление углов", 0, 30, 1)
  spin(g2, "effects", "gaps_in", "Зазор между окнами", 0, 30, 1)
  spin(g2, "effects", "gaps_out", "Зазор до края экрана", 0, 60, 1)
  switch(g2, "effects", "shadow", "Тени окон")
  spin(g2, "effects", "inactive_opacity", "Прозрачность неактивных", 0.5, 1.0, 0.02, "", 2)
  spin(g2, "effects", "dim_inactive", "Затемнение неактивных", 0.0, 0.5, 0.02, "0 — выкл", 2)
  let g3 = group("Анимации")
  switch(g3, "effects", "animations", "Анимации Hyprland")
  headed("Эффекты", "Блюр, скругление и анимации. Композитор не перезагружается.", "applications-graphics-symbolic", g, g2, g3)

proc refreshStatus(data: pointer): gboolean {.cdecl.} =
  ## статус демонов — по событию (показ страницы, после перезапуска), без постоянного таймера
  for n, r in C.statusRows:
    adw_action_row_set_subtitle(r, (if daemonRunning(n): "работает" else: "не запущен").cstring)
  0

proc reset() =
  save(newJObject()); C.cfg = load()
  for rc in C.keep:   # обновить виджеты; их notify-сигналы перепишут файл теми же дефолтами (debounce)
    if rc.key.len == 0: continue
    let v = C.cfg[rc.sec][rc.key]
    if rc.isSpin: adw_spin_row_set_value(rc.row, v.getFloat(v.getInt.float))
    else: adw_switch_row_set_active(rc.row, (if v.getBool: 1 else: 0))
  discard send("wallpaper", "reload"); discard send("switcher", "reload")
  if effectsCallHypr(seatKind()): applyEffects(C.cfg["effects"])
  notify("Настройки сброшены к значениям по умолчанию")

proc pageLaunch(): GObj =
  let g = group("Демон mazzy-shell", "Nim + Mojo, GLES2 — обои, верхняя панель, док и карусель")
  for (name, title) in [("wallpaper", "Обои с параллаксом"), ("switcher", "3D-переключатель окон")]:
    let r = adw_action_row_new()
    adw_preferences_row_set_title(r, title.cstring)
    adw_preferences_group_add(g, r); C.statusRows[name] = r
  discard buttonRow(g, "Обновить значки дока", "перечитать файл дока. Окно оболочки не закрывается", "Обновить", proc() =
    sh("mazzy-ctl wallpaper pins")
    notify("Значки дока обновлены. Оболочка не закрывалась.")
    discard g_timeout_add(800, refreshStatus, nil))
  discard refreshStatus(nil)
  let g2 = group("Другие настройки")
  discard buttonRow(g2, "Лаунчер", "Тот же, что Alt+Space", "Открыть", proc() = sh("fuzzel"))
  discard buttonRow(g2, "Системные настройки", "GNOME: сеть, звук, принтеры, пользователи", "Открыть", proc() = sh("env XDG_CURRENT_DESKTOP=GNOME gnome-control-center"))
  discard buttonRow(g2, "Док", "Показать или спрятать нижнюю полку", "Переключить", proc() =
    sh("mazzy-ctl wallpaper dock"); notify("Док переключён"))
  discard buttonRow(g2, "Обновить оболочку", "Обои и значки дока. Композитор не перезагружается.", "Обновить", proc() =
    sh("mazzy-ctl wallpaper reload"); notify("Оболочка обновлена"))
  let g3 = group("Сброс")
  discard buttonRow(g3, "Сбросить настройки MAZZY", "к значениям по умолчанию", "Сбросить", reset, "destructive-action")
  headed("Службы", "Демоны окружения и сброс этих настроек", "system-run-symbolic", g, g2, g3)


# ------------------------------------------------------------ звук и Bluetooth
## Вся логика — в system/mazzy-bt-audio.sh (ставится как mazzy-bt-audio): страница только читает
## машинный вывод `raw-*` и вызывает команды. Обновление — при показе страницы и после действий,
## без таймеров (спека settings-app). Длинные операции (подключение, проба SCO) идут фоном.
const BtBin = "/usr/local/bin/mazzy-bt-audio"

proc btOutPath(): string = getEnv("XDG_RUNTIME_DIR", "/tmp") / "mazzy-bt-ui.out"

var btCache: Table[string, seq[string]]

proc btRawPath(): string = getEnv("XDG_RUNTIME_DIR", "/tmp") / "mazzy-bt-ui.raw"

proc btLoadCache(): bool =
  ## разбор файла с выводом `mazzy-bt-audio raw-all`: секции «#devices/#sinks/#sources/#adapter»
  var txt: string
  try: txt = readFile(btRawPath())
  except OSError, IOError: return false
  if txt.len == 0: return false
  btCache.clear()
  var cur = ""
  for l in txt.splitLines:
    if l.startsWith("#"): cur = l[1 .. ^1]; btCache[cur] = @[]
    elif l.len > 0 and cur.len > 0: btCache[cur].add l
  true

proc btRaw(args: string): seq[string] =
  ## Строки машинного вывода mazzy-bt-audio (разделитель «|»); пустой seq, если скрипт не установлен.
  let (o, code) = cmdOut(BtBin & " " & args)
  if code != 0: return @[]
  for l in o.splitLines:
    if l.len > 0: result.add l

proc stripAnsi(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\e':
      while i < s.len and s[i] != 'm': inc i
      inc i
    else:
      result.add s[i]; inc i

proc fillAudio()
proc btRefresh(delayMs: cuint = 900)

proc btDone(data: pointer): gboolean {.cdecl.} =
  ## показать результат фоновой команды и перестроить страницу
  var last = ""
  try:
    for l in readFile(btOutPath()).splitLines:
      let t = stripAnsi(l).strip
      if t.len > 0 and (t.startsWith("✔") or t.startsWith("✘") or t.startsWith("·")): last = t
  except OSError, IOError: discard
  if last.len > 0: notify(last)
  btRefresh(600)
  0

proc btReload(data: pointer): gboolean {.cdecl.} =
  if btLoadCache(): fillAudio()
  0

proc btRefresh(delayMs: cuint) =
  ## Сбор данных занимает 0.4–1 с (bluetoothctl под нагрузкой), поэтому никогда не делаем его в UI-треде:
  ## пишем вывод в файл фоновым процессом и перестраиваем страницу по таймеру.
  sh(BtBin & " raw-all > " & btRawPath() & ".tmp && mv -f " & btRawPath() & ".tmp " & btRawPath())
  discard g_timeout_add(delayMs, btReload, nil)

proc btAsync(args, toast: string, delayMs: cuint) =
  sh(BtBin & " " & args & " >" & btOutPath() & " 2>&1")
  notify(toast)
  discard g_timeout_add(delayMs, btDone, nil)

proc onCombo(obj: GObj, pspec, data: pointer) {.cdecl.} =
  if C.audioFilling: return
  cast[RowCtx](data).onChange()

proc audioDeviceRows(g: GObj) =
  let modes = ["auto", "a2dp", "headset"]
  var any = false
  for line in btCache.getOrDefault("devices"):
    let f = line.split('|')
    if f.len < 8: continue
    any = true
    let (mac, name, conn, mode, active, avail, hs, batt) = (f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7])
    let paired = f.len < 9 or f[8] == "yes"
    let devHci = if f.len > 9: f[9] else: ""
    let r = adw_action_row_new()
    adw_preferences_row_set_title(r, markupEscape(name).cstring)
    var sub: seq[string]
    if not paired: sub.add "не спарено"
    else: sub.add(if conn == "yes": "подключено" else: "не подключено")
    if batt.len > 0: sub.add "батарея " & batt & "%"
    if conn == "yes" and active.len > 0: sub.add "профиль " & active
    # при нескольких адаптерах важно видеть, на каком устройство спарено: подключение
    # автоматически переключит адаптер на нужный
    if devHci.len > 0 and btCache.getOrDefault("adapters").len > 1:
      var label = devHci
      for a in btCache.getOrDefault("adapters"):
        let af = a.split('|')
        if af.len > 2 and af[0] == devHci: label = af[2]
      sub.add "адаптер: " & label
    adw_action_row_set_subtitle(r, sub.join(" · ").cstring)
    let m = mac
    let b = button(if not paired: "Спарить" elif conn == "yes": "Отключить" else: "Подключить", proc() =
      if not paired: btAsync("pair " & m, "Сопряжение: держи кнопку на наушниках…", 45000)
      elif conn == "yes": btAsync("disconnect " & m, "Отключаю…", 3000)
      else: btAsync("connect " & m, "Подключаю…", 17000))
    adw_action_row_add_suffix(r, b); adw_preferences_group_add(g, r)

    if conn == "yes" and paired:
      let combo = adw_combo_row_new()
      adw_preferences_row_set_title(combo, "Режим звука")
      adw_action_row_set_subtitle(combo,
        (if hs != "yes": "у устройства нет профиля гарнитуры — микрофона не будет"
         elif C.scoBroken: "микрофон наушников недоступен: адаптер не отдаёт голосовой канал (SCO)"
         else: "стерео и микрофон одновременно невозможны на Bluetooth 4.0").cstring)
      let model = gtk_string_list_new(nil)
      for it in ["Авто (микрофон по запросу)", "Стерео (A2DP)", "Гарнитура (микрофон)"]:
        gtk_string_list_append(model, it.cstring)
      adw_combo_row_set_model(combo, model)
      adw_combo_row_set_selected(combo, cuint(max(0, modes.find(mode))))
      if hs != "yes" or not avail.contains("headset-head-unit"):
        gtk_widget_set_sensitive(combo, 0)
      let rc = RowCtx(row: combo, onChange: proc() = discard)
      rc.onChange = proc() =
        let want = modes[int(adw_combo_row_get_selected(rc.row))]
        btAsync("profile " & want & " " & m, "Переключаю режим…", 6000)
      C.keep.add rc
      connect(combo, "notify::selected", onCombo, cast[pointer](rc))
      adw_preferences_group_add(g, combo)
  if not any:
    let r = adw_action_row_new()
    adw_preferences_row_set_title(r, "Наушники не найдены")
    adw_action_row_set_subtitle(r, "включи на них режим сопряжения и нажми «Искать»")
    adw_preferences_group_add(g, r)
  discard buttonRow(g, "Искать наушники", "12 секунд поиска; держи на наушниках кнопку сопряжения",
    "Искать", proc() = btAsync("raw-scan 12", "Ищу наушники 12 с…", 15000))

proc audioNodeRows(g: GObj, kind: string) =
  ## строки от mazzy-bt-audio: key|описание|выбрано|доступно|подсказка.
  ## key — node:<узел> | port:<узел>:<порт> | bt:<MAC> (последний переключает наушники в гарнитуру)
  for line in btCache.getOrDefault(kind):
    let f = line.split('|')
    if f.len < 3: continue
    let key = f[0]
    let desc = f[1]
    let cur = f[2] == "yes"
    let avail = f.len < 4 or f[3] == "yes"
    let hint = if f.len > 4: f[4] else: ""
    let r = adw_action_row_new()
    adw_preferences_row_set_title(r, markupEscape(desc).cstring)
    var sub: seq[string]
    if cur: sub.add "по умолчанию"
    if not avail: sub.add "недоступно"
    if hint.len > 0: sub.add hint
    adw_action_row_set_subtitle(r, markupEscape(sub.join(" · ")).cstring)
    if cur:
      gtk_widget_add_css_class(r, "success")
    else:
      let cmd = (if kind == "sinks": "out " else: "in ") & key
      let long = key.startsWith("bt:") or key.startsWith("conn:")
      let toast = if key.startsWith("conn:"): "Подключаю наушники…"
                  elif key.startsWith("bt:"): "Переключаю в гарнитуру…"
                  else: "Переключаю…"
      let b = button((if key.startsWith("conn:"): "Подключить" else: "Выбрать"), proc() =
        btAsync(cmd, toast, (if key.startsWith("conn:"): 20000 elif long: 9000 else: 1500)))
      if not avail and not long: gtk_widget_set_sensitive(b, 0)
      adw_action_row_add_suffix(r, b); adw_action_row_set_activatable_widget(r, b)
    adw_preferences_group_add(g, r)

proc audioAdapterChoice(g: GObj) =
  ## hciN|MAC|имя|powered|current — адаптеров может быть несколько (встроенный и USB-донгл),
  ## пары BlueZ у каждого свои, поэтому смена адаптера требует повторного сопряжения
  let rows = btCache.getOrDefault("adapters")
  if rows.len < 3: return   # строка режима + минимум два адаптера
  var mode = "auto"
  for line in rows:
    let f = line.split('|')
    if f.len == 2 and f[0] == "mode": mode = f[1]
  # строка автоматического выбора: вставленный донгл сам становится основным
  block:
    let r = adw_action_row_new()
    adw_preferences_row_set_title(r, "Выбирать автоматически")
    adw_action_row_set_subtitle(r,
      (if mode == "auto": "включено · вставленный донгл становится основным"
       else: "сейчас адаптер закреплён вручную").cstring)
    if mode == "auto":
      gtk_widget_add_css_class(r, "success")
    else:
      let b = button("Включить", proc() = btAsync("adapter auto", "Включаю автовыбор…", 6000))
      adw_action_row_add_suffix(r, b); adw_action_row_set_activatable_widget(r, b)
    adw_preferences_group_add(g, r)
  for line in rows:
    let f = line.split('|')
    if f.len < 5: continue
    let (hci, mac, name, powered, cur) = (f[0], f[1], f[2], f[3], f[4])
    let r = adw_action_row_new()
    adw_preferences_row_set_title(r, markupEscape(name).cstring)
    var sub: seq[string] = @[hci & " · " & mac]
    if cur == "yes": sub.add "используется"
    if powered != "yes": sub.add "выключен"
    adw_action_row_set_subtitle(r, sub.join(" · ").cstring)
    if cur == "yes":
      gtk_widget_add_css_class(r, "success")
      if mode == "auto": sub.add "выбран автоматически"
      adw_action_row_set_subtitle(r, sub.join(" · ").cstring)
    else:
      let h = hci
      let b = button("Закрепить", proc() = btAsync("adapter " & h, "Переключаю адаптер…", 6000))
      adw_action_row_add_suffix(r, b); adw_action_row_set_activatable_widget(r, b)
    adw_preferences_group_add(g, r)

proc onResetAnswer(src, res, data: pointer) {.cdecl.} =
  if $adw_alert_dialog_choose_finish(src, res) == "reset":
    btAsync("", "Сбрасываю чип, Wi-Fi вернётся через ~10 с…", 25000)
    sh("pkexec /usr/local/sbin/mt7630e-bt-reset.sh chip >" & btOutPath() & " 2>&1")

proc askChipReset() =
  let d = adw_alert_dialog_new("Полный сброс радиочипа?",
    "Wi-Fi пропадёт примерно на 10 секунд, VPN переподключится. Нужно только при мёртвом ACL-канале.")
  adw_alert_dialog_add_response(d, "cancel", "Отмена")
  adw_alert_dialog_add_response(d, "reset", "Сбросить")
  adw_alert_dialog_set_response_appearance(d, "reset", ADW_RESPONSE_DESTRUCTIVE)
  adw_alert_dialog_set_default_response(d, "cancel")
  adw_alert_dialog_choose(d, C.win, nil, cast[pointer](onResetAnswer), nil)

proc audioAdapterRows(g: GObj) =
  let adapter = btCache.getOrDefault("adapter")
  let f = if adapter.len > 0: adapter[0].split('|') else: @[]
  let r = adw_action_row_new()
  if f.len >= 3:
    adw_preferences_row_set_title(r, ("Адаптер MT7630E: hci0 " & (if f[0] == "yes": "UP" else: "DOWN")).cstring)
    var sub = "ACL " & f[1]
    if f[2].len > 0: sub.add "  ·  последний сброс чипа " & f[2]
    adw_action_row_set_subtitle(r, sub.cstring)
    if f[1].startsWith("dead"): gtk_widget_add_css_class(r, "error")
  else:
    adw_preferences_row_set_title(r, "Адаптер MT7630E")
    adw_action_row_set_subtitle(r, "mazzy-bt-audio не установлен — запусти install.sh")
  adw_preferences_group_add(g, r)
  discard buttonRow(g, "Починить", "сброс чипа только при подтверждённом мёртвом ACL", "Починить", proc() =
    btAsync("", "Проверяю адаптер…", 15000)
    sh("pkexec /usr/local/sbin/mt7630e-bt-reset.sh auto >" & btOutPath() & " 2>&1"))
  discard buttonRow(g, "Полный сброс чипа", "Wi-Fi пропадёт на ~10 с", "Сбросить", askChipReset, "destructive-action")

proc addAudioGroup(title, desc: string, fill: proc(g: GObj)) =
  let gr = group(title, desc)
  fill(gr)
  C.audioGroups.add gr
  adw_preferences_page_add(C.audioPage, gr)

proc fillAudio() =
  C.audioFilling = true
  C.scoBroken = false
  try:
    # состояние BT-аудио лежит в XDG-state: в ~/.config/mazzy нельзя — это симлинк в репозиторий
    for l in readFile(getEnv("XDG_STATE_HOME", getHomeDir() / ".local/state") / "mazzy/bt-audio.conf").splitLines:
      if l.strip.startsWith("sco") and l.contains("broken"): C.scoBroken = true
  except OSError, IOError: discard
  for g in C.audioGroups: adw_preferences_page_remove(C.audioPage, g)
  C.audioGroups = @[]
  addAudioGroup("Адаптер Bluetooth",
    "Пары у каждого адаптера свои: после смены наушники нужно спарить заново",
    audioAdapterChoice)
  addAudioGroup("Bluetooth-наушники",
    "Подключение обратно — дело самих наушников: ноутбук не опрашивает эфир, чтобы не тратить батарею",
    audioDeviceRows)
  addAudioGroup("Выход", "Динамики, разъём наушников, Bluetooth", proc(g: GObj) = audioNodeRows(g, "sinks"))
  addAudioGroup("Микрофон",
    "Встроенный, разъём и микрофоны наушников; выбор гарнитурного переводит наушники в режим гарнитуры",
    proc(g: GObj) =
      let src = wpctlVolume(cmdOut("wpctl get-volume @DEFAULT_AUDIO_SOURCE@").output)
      if src.pct >= 0:
        discard buttonRow(g, "Выключатель",
          if src.muted: "Микрофон выключен" else: "Микрофон " & $src.pct & "%",
          if src.muted: "Включить" else: "Выключить",
          proc() =
            sh("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle")
            notify("Микрофон переключён"))
      audioNodeRows(g, "sources"))
  addAudioGroup("Адаптер", "", audioAdapterRows)
  C.audioFilling = false

proc pageAudio(): GObj =
  C.audioPage = adw_preferences_page_new()
  adw_preferences_page_set_title(C.audioPage, "Звук".cstring)
  adw_preferences_page_set_description(C.audioPage, "Выход, микрофон и Bluetooth-наушники".cstring)
  adw_preferences_page_set_icon_name(C.audioPage, "audio-speakers-symbolic".cstring)
  discard btLoadCache()   # прошлый снимок, если есть — окно открывается мгновенно
  fillAudio()
  btRefresh()
  C.audioPage

# ------------------------------------------------------------ шрифты
proc giface(key: string): string =
  let (outp, code) = cmdOut("gsettings get org.gnome.desktop.interface " & key)
  if code != 0: return ""
  outp.strip(chars = Whitespace + {'\'', '"'})

proc familyOf(spec: string): string =
  let parts = spec.splitWhitespace
  if parts.len > 1 and parts[^1].len > 0 and parts[^1][0] in {'0'..'9'}:
    parts[0 .. ^2].join(" ")
  else:
    spec

proc rewritePrefix(path, prefix, newline: string): bool =
  ## Меняет первую строку с префиксом. false — файла нет или строка уже такая.
  if not fileExists(path): return false
  let raw = readFile(path)
  var lines = raw.splitLines
  var hit = false
  for i, line in lines.mpairs:
    if line.startsWith(prefix):
      if line == newline: return false
      line = newline
      hit = true
      break
  if not hit: return false
  var text = lines.join("\n")
  if raw.endsWith("\n"): text.add '\n'
  writeFile(path, text)
  true

proc applyFont(kind, spec: string) =
  ## GTK и файлы оболочки. Hyprland не перечитывается.
  let home = getHomeDir()
  let fam = familyOf(spec)
  case kind
  of "ui":
    sh("gsettings set org.gnome.desktop.interface font-name '" & spec & "'")
    discard rewritePrefix(home / ".config/gtk-3.0/settings.ini", "gtk-font-name=", "gtk-font-name=" & spec)
    discard rewritePrefix(home / ".config/gtk-4.0/settings.ini", "gtk-font-name=", "gtk-font-name=" & spec)
    let stack = if fam == "Noto Sans": "\"Noto Sans\", Inter, sans-serif" else: "Inter, \"Noto Sans\", sans-serif"
    discard rewritePrefix(home / ".config/waybar/style.css", "  font-family:", "  font-family: " & stack & ";")
    let fuzPath = home / ".config/fuzzel/fuzzel.ini"
    var fuzCurrent = ""
    if fileExists(fuzPath):
      for line in lines(fuzPath):
        if line.startsWith("font="):
          fuzCurrent = line
          break
    discard rewritePrefix(fuzPath, "font=", fuzzelFontLine(fuzCurrent, fam))
    discard rewritePrefix(home / ".config/mako/config", "font=", "font=" & fam & " 11")
    discard rewritePrefix(home / ".config/swaylock/config", "font=", "font=" & fam)
    notify("Шрифт интерфейса: " & fam)
  of "doc":
    sh("gsettings set org.gnome.desktop.interface document-font-name '" & spec & "'")
    notify("Шрифт документов: " & fam)
  of "mono":
    sh("gsettings set org.gnome.desktop.interface monospace-font-name '" & spec & "'")
    if rewritePrefix(home / ".config/kitty/kitty.conf", "font_family", "font_family      " & fam):
      sh("pidof kitty >/dev/null 2>&1 && kill -USR1 $(pidof kitty) || true")
    notify("Моноширинный шрифт: " & fam)
  else: discard

proc onFont(obj: GObj, pspec, data: pointer) {.cdecl.} =
  cast[RowCtx](data).onChange()

proc fontRow(g: GObj, title, sub, kind: string, choices: seq[string], current: string) =
  var opts = choices
  if current.len > 0 and current notin opts: opts.insert(current, 0)
  let combo = adw_combo_row_new()
  adw_preferences_row_set_title(combo, title.cstring)
  adw_action_row_set_subtitle(combo, sub.cstring)
  let model = gtk_string_list_new(nil)
  for it in opts: gtk_string_list_append(model, it.cstring)
  adw_combo_row_set_model(combo, model)
  var sel = 0
  for i, it in opts:
    if it == current: sel = i
  adw_combo_row_set_selected(combo, sel.cuint)
  let frozen = opts
  let which = kind
  let rc = RowCtx(row: combo)
  rc.onChange = proc() =
    let i = int(adw_combo_row_get_selected(rc.row))
    if i >= 0 and i < frozen.len: applyFont(which, frozen[i])
  C.keep.add rc
  connect(combo, "notify::selected", onFont, cast[pointer](rc))
  adw_preferences_group_add(g, combo)

proc pageFonts(): GObj =
  let g = group("Шрифты",
    "Интерфейс — Inter, документы — Noto Sans, терминал — JetBrains Mono. Смена не перезагружает композитор.")
  fontRow(g, "Интерфейс", "Панели, настройки, лаунчер", "ui",
    @["Inter 10.5", "Noto Sans 11", "Inter Display 11"], giface("font-name"))
  fontRow(g, "Документы", "Текст в приложениях GTK", "doc",
    @["Noto Sans 11", "Inter 11", "Inter 10.5"], giface("document-font-name"))
  fontRow(g, "Терминал", "Kitty и моноширинный шрифт GTK", "mono",
    @["JetBrains Mono 11", "Noto Sans Mono 11", "JetBrains Mono 12"], giface("monospace-font-name"))
  headed("Шрифты", "Интерфейс, документы и терминал. Композитор не перезагружается.", "font-x-generic-symbolic", g)

# ------------------------------------------------------------ система
proc openPanel(panel: string) =
  sh("env XDG_CURRENT_DESKTOP=GNOME gnome-control-center " & panel)

proc panelRow(g: GObj, title, sub, panel: string) =
  let id = panel
  discard buttonRow(g, title, sub, "Открыть", proc() = openPanel(id))

proc runQuick(id: string) =
  ## Те же команды, что на странице «Система». Композитор не перечитывается.
  case id
  of "audio": gtk_stack_set_visible_child_name(C.stack, "audio")
  of "bright-down", "bright-up":
    let lamp = readBacklight()
    if lamp.dev.len == 0 or lamp.pct < 0:
      notify("Подсветка не найдена")
    else:
      let pct = pctClamp(lamp.pct + (if id == "bright-up": 10 else: -10))
      let cmd = backlightCommand(lamp.dev, pct)
      if cmd.len == 0: notify("Подсветка не найдена")
      else:
        sh(cmd)
        notify("Яркость " & $pct & "%")
  of "wifi":
    sh("if nmcli -g WIFI radio | grep -q enabled; then nmcli radio wifi off; else nmcli radio wifi on; fi")
    notify("Wi-Fi переключён")
  of "bluetooth":
    sh("rfkill toggle bluetooth"); notify("Bluetooth переключён")
  of "night":
    let has = findExe("wlsunset").len > 0
    let running = has and cmdOut("pgrep -x wlsunset").exitCode == 0
    let plan = nightLightPlan(has, running)
    if plan.cmd.len > 0: sh(plan.cmd)
    notify(plan.note)
  of "dnd":
    sh("makoctl mode -t do-not-disturb"); notify("Уведомления переключены")
  of "apps": sh("fuzzel")
  of "display": openPanel("display")
  of "power": openPanel("power")
  else: discard

proc clickQuick(id: string): proc() =
  proc() = runQuick(id)

proc fireScale(data: pointer): gboolean {.cdecl.} =
  let rc = cast[RowCtx](data)
  rc.timer = 0
  if rc.onChange != nil: rc.onChange()
  0

proc onScale(obj: GObj, data: pointer) {.cdecl.} =
  let rc = cast[RowCtx](data)
  rc.pending = int(gtk_range_get_value(obj))
  if rc.timer != 0: discard g_source_remove(rc.timer)
  rc.timer = g_timeout_add(70, fireScale, data)

proc scaleRow(g: GObj, title, sub: string, value: int, apply: proc(v: int)) =
  ## Ползунок 0..100. Команда уходит после короткой паузы, не на каждый пиксель.
  let row = adw_action_row_new()
  adw_preferences_row_set_title(row, title.cstring)
  adw_action_row_set_subtitle(row, sub.cstring)
  let scale = gtk_scale_new_with_range(0, 0, 100, 1)
  gtk_widget_set_size_request(scale, 200, 28)
  gtk_range_set_value(scale, value.cdouble)
  let rc = RowCtx(row: scale)
  rc.onChange = proc() = apply(rc.pending)
  C.keep.add rc
  connect(scale, "value-changed", onScale, cast[pointer](rc))
  adw_action_row_add_suffix(row, scale)
  adw_preferences_group_add(g, row)

proc pagePanel(): GObj =
  let g = group("Быстрые кнопки", "Звук и яркость — ползунок. Остальное переключается сразу. Погода и загрузка процессора здесь не рисуются.")
  let heard = wpctlVolume(cmdOut("wpctl get-volume @DEFAULT_AUDIO_SINK@").output)
  let volNow = if heard.pct < 0: 0 else: pctClamp(heard.pct)
  scaleRow(g, "Звук", "Громкость выхода. Щелчок по значку на панели открывает тот же ползунок.", volNow,
    proc(v: int) =
      sh("wpctl set-mute @DEFAULT_AUDIO_SINK@ 0; wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ " & $v & "%"))
  discard buttonRow(g, "Другой выход", "Следующее устройство вывода", "Переключить", proc() =
    let rows = parseSinks(cmdOut("wpctl status").output)
    if rows.len < 2:
      notify("Других выходов нет")
      return
    let nxt = nextSink(rows)
    sh("wpctl set-default " & nxt.id)
    notify(nxt.name))
  let lamp = readBacklight()
  let brightNow = if lamp.pct < 0: 0 else: lamp.pct
  let dev = lamp.dev
  scaleRow(g, "Яркость", "Подсветка экрана через сессию. На панели — крупный лист со ступенями 10, 40, 70 и 100.", brightNow,
    proc(v: int) =
      let cmd = backlightCommand(dev, v)
      if cmd.len == 0: notify("Подсветка не найдена")
      else: sh(cmd))
  let src = wpctlVolume(cmdOut("wpctl get-volume @DEFAULT_AUDIO_SOURCE@").output)
  if src.pct >= 0:
    let micOn = not src.muted
    discard buttonRow(g, "Микрофон",
      if micOn: "Сейчас " & $src.pct & "%. На панели тот же выключатель." else: "Сейчас выключен. На панели тот же выключатель.",
      if micOn: "Выключить" else: "Включить",
      proc() =
        sh("wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle")
        notify("Микрофон переключён"))
  for pid in ProfileIds:
    let id = pid
    discard buttonRow(g, profileLabel(id), "Тот же профиль, что на панели. Сон и выключение сюда не входят.", "Включить",
      proc() =
        sh("powerprofilesctl set " & id)
        notify(profileLabel(id)))
  let today = calendarLines(now().local.year, ord(now().local.month), now().local.monthday, ord(now().local.weekday))
  if today.title.len > 0:
    discard buttonRow(g, "Дата", today.title & ", " & today.sub, "Показать",
      proc() = notify(today.title & " · " & today.sub))
  let vpnNow = vpnActive(cmdOut("nmcli -t -f TYPE,STATE connection show --active").output)
  discard buttonRow(g, "VPN", if vpnNow: "Туннель активен. На панели есть подпись vpn." else: "Туннеля нет. Подпись vpn на панели не рисуется.",
    "Сети", proc() = openPanel("network"))
  for item in quickCatalog():
    if item.id in ["audio", "bright-down", "bright-up"]: continue
    let id = item.id
    let row = adw_action_row_new()
    adw_preferences_row_set_title(row, item.title.cstring)
    adw_action_row_set_subtitle(row, item.detail.cstring)
    if item.icon.len > 0:
      adw_action_row_add_prefix(row, gtk_image_new_from_icon_name(item.icon.cstring))
    let label = if id in ["display", "power", "apps"]: "Открыть" else: "Нажать"
    let b = button(label, clickQuick(id), "")
    adw_action_row_add_suffix(row, b)
    adw_action_row_set_activatable_widget(row, b)
    adw_preferences_group_add(g, row)
  let later = group("Дальше", "Меню группирует управление и приложения. Лист сессии на панели спрашивает ещё раз перед сном, выходом и выключением. Эта страница их не вызывает.")
  headed("Панель", "Ползунки звука и яркости. Живой композитор отсюда не перезагружается.", "view-app-grid-symbolic", g, later)

proc prefixedLine(path, prefix: string): string =
  if not fileExists(path): return ""
  for line in readFile(path).splitLines:
    let t = line.strip
    if t.startsWith(prefix):
      return t[prefix.len .. ^1].strip(chars = {' ', '"'})
  ""

proc replaceContaining(path, needle, newline: string): bool =
  if not fileExists(path): return false
  let raw = readFile(path)
  var lines = raw.splitLines
  var hit = false
  for i, line in lines.mpairs:
    if needle in line:
      if line == newline: return false
      line = newline
      hit = true
      break
  if not hit: return false
  var text = lines.join("\n")
  if raw.endsWith("\n"): text.add '\n'
  writeFile(path, text)
  true

proc savedLang(): string =
  let home = getHomeDir()
  let f = home / ".config/mazzy/locale"
  if fileExists(f):
    for line in readFile(f).splitLines:
      if line.startsWith("export LANG=") or line.startsWith("LANG="):
        return if "en_US" in line: "en" else: "ru"
  "ru"

proc loadKeyboard() =
  if localeUi == nil:
    localeUi = LocaleUi(lang: "ru", layout: "us,ru", switchKey: "grp:win_space_toggle", capsShift: true)
  let layout = prefixedLine(getHomeDir() / ".config/hypr/conf/input.conf", "kb_layout =")
  localeUi.layout = if layout == "ru,us": "ru,us" else: "us,ru"
  localeUi.switchKey = "grp:win_space_toggle"
  localeUi.capsShift = false
  let opts = prefixedLine(getHomeDir() / ".config/hypr/conf/input.conf", "kb_options =")
  for part in opts.split(','):
    let p = part.strip
    if p in ["grp:win_space_toggle", "grp:alt_shift_toggle", "grp:caps_toggle", "grp:shifts_toggle"]:
      localeUi.switchKey = p
    elif p == "caps:escape_shifted_capslock":
      localeUi.capsShift = true
  localeUi.lang = savedLang()

proc refreshLocaleStatus() =
  if localeUi == nil or localeUi.status == nil: return
  let session = getEnv("LANG", "—")
  let shell = if localeUi.lang == "en": "English" else: "русский"
  let next = if localeUi.lang == "en": "en_US.UTF-8" else: "ru_RU.UTF-8"
  var text = "Оболочка: " & shell & "  ·  следующий вход: " & next & "  ·  эта сессия: " & session
  if not session.startsWith(if localeUi.lang == "en": "en" else: "ru"):
    text.add ". Полный переход — после выхода"
  adw_action_row_set_subtitle(localeUi.status, text.cstring)

proc switchTitle(key: string): string =
  case key
  of "grp:alt_shift_toggle": "Alt+Shift"
  of "grp:caps_toggle": "Caps Lock"
  of "grp:shifts_toggle": "оба Shift"
  else: "Win+Space"

proc kbOptions(switchKey: string, capsShift: bool): string =
  result = switchKey
  if capsShift and switchKey != "grp:caps_toggle":
    result.add ",caps:escape_shifted_capslock"

proc hyprStr(opt: string): string =
  for line in hyprctl("getoption", opt).splitLines:
    if line.startsWith("str:"):
      return line[4 .. ^1].strip

proc applyLocale(ui: string): string =
  ## Оболочка и следующий вход. Уже запущенные программы остаются на языке сессии.
  let code = if ui == "en": "en" else: "ru"
  let loc = if code == "en": "en_US.UTF-8" else: "ru_RU.UTF-8"
  let home = getHomeDir()
  createDir(home / ".config/mazzy")
  writeFile(home / ".config/mazzy/locale",
    "# Язык Mazzy. Меняется в настройках, страница «Язык и ввод».\n" &
    "export LANG=" & loc & "\n" &
    "export LC_MESSAGES=" & loc & "\n" &
    "export LC_TIME=" & loc & "\n")
  discard rewritePrefix(home / ".config/mango/config.toml", "LANG = ", "LANG = \"" & loc & "\"")
  discard rewritePrefix(home / ".config/mango/config.toml", "LC_MESSAGES = ", "LC_MESSAGES = \"" & loc & "\"")
  discard rewritePrefix(home / ".config/mango/config.toml", "LC_TIME = ", "LC_TIME = \"" & loc & "\"")
  let uid = cmdOut("id -u").output.strip
  var greet = false
  if uid.len > 0 and uid.allCharsInSet(Digits):
    let a = cmdOut("busctl call org.freedesktop.Accounts /org/freedesktop/Accounts/User" & uid &
      " org.freedesktop.Accounts.User SetLanguage s " & loc)
    let b = cmdOut("busctl call org.freedesktop.Accounts /org/freedesktop/Accounts/User" & uid &
      " org.freedesktop.Accounts.User SetFormatsLocale s " & loc)
    greet = a.exitCode == 0 and b.exitCode == 0
  if localeUi != nil: localeUi.lang = code
  refreshLocaleStatus()
  let name = if code == "en": "English" else: "русский"
  result = "Язык следующего входа: " & name & "."
  if greet: result.add " Экран входа тоже на этом языке."
  else: result.add " Экран входа не принял язык."
  let session = getEnv("LANG", "")
  if session.len > 0 and not session.startsWith(if code == "en": "en" else: "ru"):
    result.add " Уже открытые программы сменятся после выхода."

proc applyKeyboard(layout, switchKey: string, capsShift: bool): string =
  ## Живой Hyprland — только keyword. Полный reload сюда не входит.
  let lay = if layout == "ru,us": "ru,us" else: "us,ru"
  let sw = if switchKey in ["grp:win_space_toggle", "grp:alt_shift_toggle", "grp:caps_toggle", "grp:shifts_toggle"]: switchKey
           else: "grp:win_space_toggle"
  let opts = kbOptions(sw, capsShift)
  let home = getHomeDir()
  discard rewritePrefix(home / ".config/hypr/conf/input.conf", "    kb_layout = ", "    kb_layout = " & lay)
  discard rewritePrefix(home / ".config/hypr/conf/input.conf", "    kb_options = ", "    kb_options = " & opts)
  discard rewritePrefix(home / ".config/mango/config.toml", "xkb_rules_layout = ", "xkb_rules_layout = \"" & lay & "\"")
  discard rewritePrefix(home / ".config/mango/config.toml", "xkb_rules_options = ", "xkb_rules_options = \"" & opts & "\"")
  discard rewritePrefix(home / ".config/sway-dux/config", "    xkb_layout ", "    xkb_layout " & lay)
  discard rewritePrefix(home / ".config/sway-dux/config", "    xkb_options ", "    xkb_options " & opts)
  discard replaceContaining(home / ".config/hypr/conf/binds.conf", "input.conf: grp:",
    "# " & switchTitle(sw) & " меняет раскладку через xkb (input.conf: " & sw & ").")
  let a = hyprctl("keyword", "input:kb_layout", lay)
  let b = hyprctl("keyword", "input:kb_options", opts)
  let mango = seatReloadConfig()
  let src = if lay == "ru,us": "[('xkb', 'ru'), ('xkb', 'us')]" else: "[('xkb', 'us'), ('xkb', 'ru')]"
  var parts = newSeq[string]()
  for p in opts.split(','):
    let t = p.strip
    if t.len > 0: parts.add t
  if "grp_led:scroll" notin parts: parts.add "grp_led:scroll"
  let xkb = "['" & parts.join("', '") & "']"
  discard cmdOut("gsettings set org.gnome.desktop.input-sources sources \"" & src & "\"")
  discard cmdOut("gsettings set org.gnome.desktop.input-sources xkb-options \"" & xkb & "\"")
  if localeUi != nil:
    localeUi.layout = lay
    localeUi.switchKey = sw
    localeUi.capsShift = capsShift
  let how = if lay == "ru,us": "сначала русский" else: "сначала английский"
  if a == "ok" and b == "ok":
    "Раскладка: " & how & ", переключение " & switchTitle(sw) & "."
  elif mango:
    "Раскладка записана в Mango (" & how & ", " & switchTitle(sw) & ")."
  else:
    "Сохранено для следующего входа (" & how & ", " & switchTitle(sw) & "). Сейчас клавиатура не сменилась."

proc syncCapsRow() =
  if localeUi == nil or localeUi.capsRow == nil: return
  gtk_widget_set_sensitive(localeUi.capsRow, if localeUi.switchKey == "grp:caps_toggle": 0 else: 1)

proc onLocaleCaps(obj: GObj, pspec, data: pointer) {.cdecl.} =
  if localeUi == nil or not localeUi.ready: return
  localeUi.capsShift = adw_switch_row_get_active(cast[RowCtx](data).row) != 0
  notify(applyKeyboard(localeUi.layout, localeUi.switchKey, localeUi.capsShift))

proc choiceRow(g: GObj, title, sub: string, labels, codes: seq[string], current: string, onPick: proc(code: string)) =
  let frozen = codes
  let pick = onPick
  var sel = 0
  for i, c in codes:
    if c == current: sel = i
  let combo = adw_combo_row_new()
  adw_preferences_row_set_title(combo, title.cstring)
  adw_action_row_set_subtitle(combo, sub.cstring)
  let model = gtk_string_list_new(nil)
  for it in labels: gtk_string_list_append(model, it.cstring)
  adw_combo_row_set_model(combo, model)
  adw_combo_row_set_selected(combo, sel.cuint)
  let rc = RowCtx(row: combo)
  rc.onChange = proc() =
    if localeUi == nil or not localeUi.ready: return
    let i = int(adw_combo_row_get_selected(rc.row))
    if i >= 0 and i < frozen.len: pick(frozen[i])
  C.keep.add rc
  connect(combo, "notify::selected", onFont, cast[pointer](rc))
  adw_preferences_group_add(g, combo)

proc pageLanguage(): GObj =
  loadKeyboard()
  localeUi.ready = false
  let g = group("Язык интерфейса")
  localeUi.status = adw_action_row_new()
  adw_preferences_row_set_title(localeUi.status, "Сейчас".cstring)
  adw_preferences_group_add(g, localeUi.status)
  refreshLocaleStatus()
  choiceRow(g, "Язык", "Бар, лаунчер и центр управления",
    @["Русский", "English"], @["ru", "en"], localeUi.lang,
    proc(code: string) =
      notify(applyLocale(code)))
  let live = hyprStr("input:kb_layout")
  var kdesc = "Английский и русский. Клавиша срабатывает сразу, композитор не перезагружается."
  if live.len > 0: kdesc = "Сейчас на клавиатуре: " & live & ". " & kdesc
  let k = group("Раскладка", kdesc)
  choiceRow(k, "Порядок", "Какой язык идёт первым",
    @["Сначала английский", "Сначала русский"], @["us,ru", "ru,us"], localeUi.layout,
    proc(code: string) =
      localeUi.layout = code
      notify(applyKeyboard(localeUi.layout, localeUi.switchKey, localeUi.capsShift)))
  choiceRow(k, "Переключение", "Между английским и русским",
    @["Win + Space", "Alt + Shift", "Caps Lock", "Оба Shift"],
    @["grp:win_space_toggle", "grp:alt_shift_toggle", "grp:caps_toggle", "grp:shifts_toggle"],
    localeUi.switchKey,
    proc(code: string) =
      localeUi.switchKey = code
      syncCapsRow()
      notify(applyKeyboard(localeUi.layout, localeUi.switchKey, localeUi.capsShift)))
  localeUi.capsRow = adw_switch_row_new()
  adw_preferences_row_set_title(localeUi.capsRow, "Caps Lock с Shift".cstring)
  adw_action_row_set_subtitle(localeUi.capsRow, "С Shift — заглавные, без Shift — Esc".cstring)
  adw_switch_row_set_active(localeUi.capsRow, if localeUi.capsShift: 1 else: 0)
  let caps = RowCtx(row: localeUi.capsRow)
  C.keep.add caps
  connect(localeUi.capsRow, "notify::active", onLocaleCaps, cast[pointer](caps))
  adw_preferences_group_add(k, localeUi.capsRow)
  syncCapsRow()
  let more = group("Форматы и дополнительные раскладки", "То, чего нет в двух языках выше")
  panelRow(more, "Клавиатура", "Повтор клавиш и другие раскладки", "keyboard")
  panelRow(more, "Регион и форматы", "Числа, дата, первый день недели", "system region")
  panelRow(more, "Дата и время", "Часовой пояс", "system datetime")
  localeUi.ready = true
  headed("Язык и ввод",
    "Оболочка меняется сразу. Открытые программы подхватят язык при следующем запуске. Следующий вход в Mazzy, Mango и Dux берёт этот выбор. Это окно остаётся на русском.",
    "preferences-desktop-locale-symbolic", g, k, more)

proc pageSystem(): GObj =
  ## Управление машиной. Композитор не перечитывается.
  let who = cmdOut("hostname").output.strip & " · " & cmdOut("uname -r").output.strip
  let g = group("Экран и питание", "Яркость, ночной свет и профиль этой машины")
  discard buttonRow(g, "Яркость ниже", "Шаг 10% подсветки", "−10%", proc() = runQuick("bright-down"))
  discard buttonRow(g, "Яркость выше", "Шаг 10% подсветки", "+10%", proc() = runQuick("bright-up"))
  discard buttonRow(g, "Ночной свет", "Тёплый экран вечером. Без пакета wlsunset кнопка только сообщает.", "Переключить", proc() =
    let has = findExe("wlsunset").len > 0
    let running = has and cmdOut("pgrep -x wlsunset").exitCode == 0
    let plan = nightLightPlan(has, running)
    if plan.cmd.len > 0: sh(plan.cmd)
    notify(plan.note))
  discard buttonRow(g, "Не беспокоить", "Новые тосты скрыты, история остаётся", "Переключить", proc() =
    sh("makoctl mode -t do-not-disturb"); notify("Уведомления переключены"))
  discard buttonRow(g, "Экономия энергии", "power-saver", "Включить", proc() =
    sh("powerprofilesctl set power-saver"); notify("Профиль: экономия"))
  discard buttonRow(g, "Баланс", "balanced", "Включить", proc() =
    sh("powerprofilesctl set balanced"); notify("Профиль: баланс"))
  discard buttonRow(g, "Производительность", "performance", "Включить", proc() =
    sh("powerprofilesctl set performance"); notify("Профиль: производительность"))
  let bat = batteryReport()
  let batSub = if bat.pct < 0: "Батарея не найдена"
               elif bat.extra.len > 0: $bat.pct & "% · " & bat.status & " · " & bat.extra
               else: $bat.pct & "% · " & bat.status
  discard buttonRow(g, "Батарея", batSub, "Показать", proc() = notify(batSub))
  let net = group("Связь")
  discard buttonRow(net, "Wi-Fi", "Включить или выключить радио", "Переключить", proc() =
    sh("if nmcli -g WIFI radio | grep -q enabled; then nmcli radio wifi off; else nmcli radio wifi on; fi")
    notify("Wi-Fi переключён"))
  discard buttonRow(net, "Bluetooth", "Адаптер", "Переключить", proc() =
    sh("rfkill toggle bluetooth"); notify("Bluetooth переключён"))
  let vpnNow = vpnActive(cmdOut("nmcli -t -f TYPE,STATE connection show --active").output)
  discard buttonRow(net, "VPN", if vpnNow: "Туннель активен" else: "Туннеля нет", "Сети",
    proc() = openPanel("network"))
  let gnome = group("Как в Ubuntu", "Те же разделы, что у GNOME Settings")
  panelRow(gnome, "Wi-Fi", "Сети и пароли", "wifi")
  panelRow(gnome, "Сеть", "Провод, VPN, прокси", "network")
  panelRow(gnome, "Bluetooth", "Устройства", "bluetooth")
  panelRow(gnome, "Экран", "Разрешение и масштаб", "display")
  panelRow(gnome, "Звук", "Ввод и вывод", "sound")
  panelRow(gnome, "Питание", "Сон и крышка", "power")
  panelRow(gnome, "Клавиатура", "Повтор и дополнительные раскладки. us/ru — на странице «Язык и ввод»", "keyboard")
  panelRow(gnome, "Мышь и тачпад", "Скорость и жесты", "mouse")
  panelRow(gnome, "Принтеры", "Очереди печати", "printers")
  panelRow(gnome, "Уведомления", "Баннеры приложений", "notifications")
  panelRow(gnome, "Приложения", "Приложения по умолчанию", "applications")
  panelRow(gnome, "Специальные возможности", "Масштаб, указатель, клавиатура", "universal-access")
  panelRow(gnome, "Конфиденциальность", "Экран, микрофон, камера", "privacy")
  panelRow(gnome, "Пользователи", "Учётные записи", "system users")
  panelRow(gnome, "Регион и форматы", "Числа, дата, первый день недели", "system region")
  panelRow(gnome, "Дата и время", "Часовой пояс", "system datetime")
  panelRow(gnome, "О системе", "Имя машины и версия", "system about")
  let about = group("Эта машина", who)
  headed("Система", "Экран, сеть и разделы как в Ubuntu", "preferences-system-symbolic", g, net, gnome, about)

# ------------------------------------------------------------ хоткеи
proc fillBinds()

proc onKey(ctl: GObj, keyval, keycode, state: cuint, data: pointer): gboolean {.cdecl.} =
  let name = $gdk_keyval_name(keyval)
  if name in ["Super_L", "Super_R", "Shift_L", "Shift_R", "Alt_L", "Alt_R", "Control_L", "Control_R", "Meta_L", "Meta_R"]:
    return 1
  if name == "Escape": adw_dialog_close(C.dialog); return 1
  var mods: seq[string]
  if (state and GDK_SUPER_MASK) != 0: mods.add "$mod"
  if (state and GDK_SHIFT_MASK) != 0: mods.add "SHIFT"
  if (state and GDK_ALT_MASK) != 0: mods.add "ALT"
  if (state and GDK_CONTROL_MASK) != 0: mods.add "CTRL"
  # буквы/цифры — по имени (Hyprland ищет их во всех раскладках), остальное — по коду, чтобы работало в RU
  let n = $gdk_keyval_name(gdk_keyval_to_lower(keyval))
  var key: string
  if n.len == 1 and n[0].isAlphaNumeric: key = (if n[0].isAlphaAscii: n.toUpperAscii else: n)
  elif n in ["Left", "Right", "Up", "Down", "Return", "Tab", "Print"] or n.startsWith("XF86") or
       (n.len > 1 and n[0] == 'F' and n[1 .. ^1].allCharsInSet(Digits)): key = n
  elif n == "space": key = "Space"
  else: key = "code:" & $keycode
  let err = writeBind(C.dialogLine, mods.join(" "), key)
  notify(if err.len > 0: "Ошибка конфига: " & err[0 ..< min(80, err.len)] else: "Сочетание сохранено для следующего входа")
  fillBinds()
  adw_dialog_close(C.dialog)
  1

proc captureBind(lineno: int, title: string) =
  let d = adw_dialog_new()
  adw_dialog_set_title(d, "Новое сочетание"); adw_dialog_set_content_width(d, 420)
  let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)
  gtk_widget_set_margin_top(box, 24); gtk_widget_set_margin_bottom(box, 24)
  gtk_widget_set_margin_start(box, 24); gtk_widget_set_margin_end(box, 24)
  let l1 = gtk_label_new(title.cstring); gtk_widget_add_css_class(l1, "title-3"); gtk_box_append(box, l1)
  let l2 = gtk_label_new("Нажми клавиши…  (Esc — отмена)"); gtk_widget_add_css_class(l2, "dim-label"); gtk_box_append(box, l2)
  adw_dialog_set_child(d, box)
  let kc = gtk_event_controller_key_new()
  connect(kc, "key-pressed", onKey)
  gtk_widget_add_controller(d, kc)
  C.dialog = d; C.dialogLine = lineno
  adw_dialog_present(d, C.win)

proc fillBinds() =
  for g in C.bindGroups: adw_preferences_page_remove(C.bindsPage, g)
  C.bindGroups = @[]
  var groups: Table[string, GObj]
  for b in parseBinds():
    if not groups.hasKey(b.section):
      let g = group(b.section); groups[b.section] = g; C.bindGroups.add g; adw_preferences_page_add(C.bindsPage, g)
    let r = adw_action_row_new()
    let title = describe(b)
    adw_preferences_row_set_title(r, markupEscape(title).cstring); adw_action_row_set_subtitle(r, markupEscape(b.action).cstring)
    let ln = b.lineno
    let btn = button(comboLabel(b.mods, b.key), proc() = captureBind(ln, title), "flat")
    if b.kind == "bindm" or b.key.startsWith("mouse"): gtk_widget_set_sensitive(btn, 0)
    adw_action_row_add_suffix(r, btn); adw_preferences_group_add(groups[b.section], r)

proc onWidgetSwitch(obj: GObj, pspec, data: pointer) {.cdecl.} =
  let rc = cast[RowCtx](data)
  if not C.cfg.hasKey("chrome") or C.cfg["chrome"].kind != JObject:
    C.cfg["chrome"] = newJObject()
  if not C.cfg["chrome"].hasKey("widgets") or C.cfg["chrome"]["widgets"].kind != JObject:
    C.cfg["chrome"]["widgets"] = newJObject()
  C.cfg["chrome"]["widgets"][rc.key] = %(adw_switch_row_get_active(rc.row) != 0)
  changed("chrome", nil)

proc widgetSwitch(g: GObj, id: string) =
  let meta = widgetMeta(id)
  if meta.title.len == 0: return
  let r = adw_switch_row_new()
  adw_preferences_row_set_title(r, meta.title.cstring)
  adw_action_row_set_subtitle(r, meta.sample.cstring)
  adw_switch_row_set_active(r, if chromeWidget(C.cfg, id): 1 else: 0)
  let rc = RowCtx(sec: "chrome", key: id, row: r)
  C.keep.add rc
  connect(r, "notify::active", onWidgetSwitch, cast[pointer](rc))
  adw_preferences_group_add(g, r)

proc dockFile(): string = getHomeDir() / ".config/mazzy/dock"

proc readDockPins(): seq[string] =
  if not fileExists(dockFile()): return
  for line in readFile(dockFile()).splitLines:
    let t = line.strip
    if t.len > 0 and not t.startsWith("#"): result.add t

proc writeDockPins(ids: seq[string]) =
  writeFile(dockFile(), ids.join("\n") & "\n")
  sh("mazzy-ctl wallpaper pins")

proc storeOrder(ids: seq[string]) =
  var arr = newJArray()
  for id in ids:
    if id in widgetRightIds(): arr.add %id
  if not C.cfg.hasKey("chrome") or C.cfg["chrome"].kind != JObject:
    C.cfg["chrome"] = newJObject()
  C.cfg["chrome"]["order"] = arr
  changed("chrome")

proc pageFace(): GObj =
  let paper = group("Бумага и подписи", "Панели, меню и док берут плотность и один из трёх стилей. Подписи прячут слова, значки остаются.")
  switch(paper, "chrome", "labels", "Подписи", "Слова у значков панели и одно имя в доке под курсором")
  spin(paper, "chrome", "dismiss_ms", "Закрытие листа", 0, 3000, 100,
    "Миллисекунды после ухода курсора. 0 — лист закрывает только щелчок снаружи.")
  spin(paper, "chrome", "opacity", "Плотность панелей", 40, 100, 5,
    "40 — прозрачнее, 100 — сплошная бумага бара, дока и листов.")
  for id in ["paper", "ink", "dawn"]:
    let pick = id
    discard buttonRow(paper, styleTitle(pick), "Цвета бара, дока и листов", "Включить", proc() =
      if not C.cfg.hasKey("chrome") or C.cfg["chrome"].kind != JObject:
        C.cfg["chrome"] = newJObject()
      C.cfg["chrome"]["style"] = %pick
      changed("chrome")
      notify("Стиль: " & styleTitle(pick)))
  for id in ["time", "date", "hands"]:
    let pick = id
    discard buttonRow(paper, clockModeTitle(pick), "Часы на панели. Лист часов открывает календарь и сессию.", "Включить", proc() =
      if not C.cfg.hasKey("chrome") or C.cfg["chrome"].kind != JObject:
        C.cfg["chrome"] = newJObject()
      C.cfg["chrome"]["clock"] = %pick
      changed("chrome")
      notify(clockModeTitle(pick)))
  result = adw_preferences_page_new()
  adw_preferences_page_add(result, paper)
  let catalogs = [
    ("Панель", "Часы, звук, сеть и соседние чипы. Пустое чтение не рисуется."),
    ("Службы", "Только если команда ответила. Буфер по умолчанию выключен."),
    ("Система", "Сессия спрашивает подтверждение. Масштаб только читается."),
  ]
  for item in catalogs:
    let g = group(item[0], item[1])
    for id in widgetIds():
      if widgetMeta(id).group == item[0]: widgetSwitch(g, id)
    adw_preferences_page_add(result, g)
  let orderG = group("Порядок справа", "Столы и часы остаются на местах. Кнопки пишут порядок, оболочка перечитывает файл.")
  for id in widgetRightIds():
    let wid = id
    let title = widgetMeta(wid).title
    let row = adw_action_row_new()
    adw_preferences_row_set_title(row, title.cstring)
    adw_action_row_set_subtitle(row, "Правый ряд панели".cstring)
    let toCenter = button("К центру", proc() =
      storeOrder(orderMove(chromeOrder(C.cfg), wid, 1))
      notify(title & " к центру"))
    let toEdge = button("К краю", proc() =
      storeOrder(orderMove(chromeOrder(C.cfg), wid, -1))
      notify(title & " к краю"))
    adw_action_row_add_suffix(row, toCenter)
    adw_action_row_add_suffix(row, toEdge)
    adw_preferences_group_add(orderG, row)
  adw_preferences_page_add(result, orderG)
  let pins = group("Закрепы", "Снятие и добавление пишут файл дока. Композитор не перечитывается.")
  for id in readDockPins():
    let pin = id
    discard buttonRow(pins, pin, "Имя из файла дока", "Снять", proc() =
      var left: seq[string]
      for cur in readDockPins():
        if cur != pin: left.add cur
      writeDockPins(left)
      notify("Закреп снят"))
  let entry = gtk_entry_new()
  gtk_entry_set_placeholder_text(entry, "имя.desktop")
  let add = button("Добавить", proc() =
    let name = ($gtk_editable_get_text(entry)).strip
    if name.len == 0: return
    var ids = readDockPins()
    if name notin ids and ids.len < DockPinCap: ids.add name
    writeDockPins(ids)
    gtk_editable_set_text(entry, "")
    notify("Закреп записан"))
  let row = adw_action_row_new()
  adw_preferences_row_set_title(row, "Новый закреп".cstring)
  adw_action_row_set_subtitle(row, "Короткое имя файла без пути".cstring)
  adw_action_row_add_suffix(row, entry)
  adw_action_row_add_suffix(row, add)
  adw_preferences_group_add(pins, row)
  adw_preferences_page_add(result, pins)
  let nightNote = nightLightPlan(findExe("wlsunset").len > 0, false).note
  let night = group("Ночной свет", nightNote)
  discard buttonRow(night, "Температура", "Ползунка нет, пока пакет не установлен", "Проверить", proc() =
    let running = findExe("wlsunset").len > 0 and cmdOut("pgrep -x wlsunset").exitCode == 0
    notify(nightLightPlan(findExe("wlsunset").len > 0, running).note))
  adw_preferences_page_add(result, night)
  adw_preferences_page_set_title(result, "Оформление".cstring)
  adw_preferences_page_set_description(result, "Каталог своих виджетов с примером. Из сети ничего не скачивается.".cstring)
  adw_preferences_page_set_icon_name(result, "preferences-desktop-theme-symbolic".cstring)

type SearchUi = ref object
  entry, hits: GObj

var searchUi: SearchUi

proc settingsPages(): seq[tuple[name, title: string]] =
  @[
    ("search", "Поиск"),
    ("face", "Оформление"),
    ("panel", "Панель"),
    ("language", "Язык"),
    ("system", "Система"),
    ("fonts", "Шрифты"),
    ("audio", "Звук"),
    ("parallax", "Обои"),
    ("switcher", "Окна"),
    ("effects", "Эффекты"),
    ("binds", "Клавиши"),
    ("launch", "Службы"),
  ]

proc refillSearch() =
  if searchUi == nil or searchUi.hits == nil: return
  var child = gtk_widget_get_first_child(searchUi.hits)
  while child != nil:
    let nxt = gtk_widget_get_next_sibling(child)
    gtk_box_remove(searchUi.hits, child)
    child = nxt
  let q = ($gtk_editable_get_text(searchUi.entry)).strip.toLowerAscii
  for page in settingsPages():
    if q.len > 0 and q notin page.title.toLowerAscii and q notin page.name: continue
    let id = page.name
    let b = button(page.title, proc() = gtk_stack_set_visible_child_name(C.stack, id.cstring))
    gtk_widget_set_margin_start(b, 12)
    gtk_widget_set_margin_end(b, 12)
    gtk_box_append(searchUi.hits, b)

proc onSearchChanged(obj: GObj, data: pointer) {.cdecl.} =
  refillSearch()

proc pageSearch(): GObj =
  let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)
  searchUi = SearchUi(entry: gtk_entry_new(), hits: gtk_box_new(GTK_ORIENTATION_VERTICAL, 6))
  gtk_entry_set_placeholder_text(searchUi.entry, "Страница")
  gtk_widget_set_margin_top(searchUi.entry, 12)
  gtk_widget_set_margin_start(searchUi.entry, 12)
  gtk_widget_set_margin_end(searchUi.entry, 12)
  gtk_box_append(box, searchUi.entry)
  gtk_box_append(box, searchUi.hits)
  connect(searchUi.entry, "changed", onSearchChanged)
  refillSearch()
  box

proc pageBinds(): GObj =
  C.bindsPage = adw_preferences_page_new()
  adw_preferences_page_set_title(C.bindsPage, "Клавиши".cstring)
  adw_preferences_page_set_description(C.bindsPage, "Новое сочетание записывается в файл и заработает на следующем входе.".cstring)
  adw_preferences_page_set_icon_name(C.bindsPage, "input-keyboard-symbolic".cstring)
  adw_preferences_page_add(C.bindsPage, group("Горячие клавиши", "Нажми на сочетание, чтобы записать новое. Файл conf/binds.conf. Композитор сейчас не перечитывается."))
  fillBinds()
  C.bindsPage

# ------------------------------------------------------------ окно
proc onPageShown(obj: GObj, pspec, data: pointer) {.cdecl.} =
  case $gtk_stack_get_visible_child_name(C.stack)
  of "launch": discard refreshStatus(nil)
  of "audio": btRefresh(700)
  else: discard

proc addPage(child: GObj, name, title, icon: string) =
  let p = gtk_stack_add_titled(C.stack, child, name.cstring, title.cstring)
  if icon.len > 0: gtk_stack_page_set_icon_name(p, icon.cstring)

proc buildWindow(app: GObj) =
  C.win = adw_application_window_new(app)
  gtk_window_set_title(C.win, "Настройки Mazzy"); gtk_window_set_default_size(C.win, 960, 720)
  let tb = adw_toolbar_view_new(); adw_toolbar_view_add_top_bar(tb, adw_header_bar_new())
  C.toast = adw_toast_overlay_new(); adw_application_window_set_content(C.win, C.toast); adw_toast_overlay_set_child(C.toast, tb)
  let split = adw_navigation_split_view_new(); adw_toolbar_view_set_content(tb, split)
  C.stack = gtk_stack_new(); gtk_stack_set_transition_type(C.stack, GTK_STACK_TRANSITION_TYPE_CROSSFADE)
  let side = gtk_stack_sidebar_new(); gtk_stack_sidebar_set_stack(side, C.stack)
  adw_navigation_split_view_set_sidebar(split, adw_navigation_page_new(side, "Настройки"))
  adw_navigation_split_view_set_content(split, adw_navigation_page_new(C.stack, "Раздел"))
  adw_navigation_split_view_set_min_sidebar_width(split, 236)
  template tick(name: string) =
    when defined(mzdebug): stderr.writeLine name & " t=" & $int(epochTime() * 1000 mod 100000)
  tick "frame"
  addPage(pageSearch(), "search", "Поиск", "system-search-symbolic"); tick "search"
  addPage(pageFace(), "face", "Оформление", "preferences-desktop-theme-symbolic"); tick "face"
  addPage(pagePanel(), "panel", "Панель", "view-app-grid-symbolic"); tick "panel"
  addPage(pageLanguage(), "language", "Язык и ввод", "preferences-desktop-locale-symbolic"); tick "language"
  addPage(pageSystem(), "system", "Система", "preferences-system-symbolic"); tick "system"
  addPage(pageFonts(), "fonts", "Шрифты", "font-x-generic-symbolic"); tick "fonts"
  addPage(pageAudio(), "audio", "Звук", "audio-speakers-symbolic"); tick "audio"
  addPage(pageParallax(), "parallax", "Обои", "preferences-desktop-wallpaper-symbolic"); tick "parallax"
  addPage(pageSwitcher(), "switcher", "Окна", "view-grid-symbolic"); tick "switcher"
  addPage(pageEffects(), "effects", "Эффекты", "applications-graphics-symbolic"); tick "effects"
  addPage(pageBinds(), "binds", "Клавиши", "input-keyboard-symbolic"); tick "binds"
  addPage(pageLaunch(), "launch", "Службы", "system-run-symbolic"); tick "launch"
  connect(C.stack, "notify::visible-child", onPageShown)
  # `mazzy-settings --page audio` — открыть сразу нужную страницу (например из панели Noctalia)
  for i in 1 .. paramCount():
    if paramStr(i) == "--page" and i < paramCount():
      gtk_stack_set_visible_child_name(C.stack, paramStr(i + 1).cstring)

proc onActivate(app: GObj, data: pointer) {.cdecl.} =
  when defined(mzdebug): stderr.writeLine "activate t=" & $int(epochTime() * 1000 mod 100000)
  let w = gtk_application_get_active_window(app)
  if w == nil: buildWindow(app)
  gtk_window_present(C.win)
  when defined(mzdebug): stderr.writeLine "presented t=" & $int(epochTime() * 1000 mod 100000)

proc fastGtkInit() =
  ## Старт ≈0.7 с уходил на тему иконок: GTK4 берёт её через settings-portal (Papirus-Dark) и уже в gtk_init
  ## запускает поток, который парсит icon-theme.cache Papirus (3 МБ, ~300 мс); окну хватает 3 символических
  ## иконок из Adwaita. Поэтому на время gtk_init: без портала (GDK_DEBUG=no-portals) и копия settings.ini
  ## пользователя с gtk-icon-theme-name=Adwaita в XDG_RUNTIME_DIR. После — окружение восстанавливается,
  ## чтобы дочерние процессы (noctalia, gnome-control-center, hyprctl) получили обычное.
  let tmpCfg = getEnv("XDG_RUNTIME_DIR", "/tmp") / "mazzy-gtk"
  var ini: seq[string]
  try: ini = readFile(getHomeDir() / ".config/gtk-4.0/settings.ini").split("\n")
  except OSError, IOError: ini = @["[Settings]"]
  ini.keepItIf(not it.startsWith("gtk-icon-theme-name"))
  ini.insert("gtk-icon-theme-name=Adwaita", 1)
  let oldHome = getEnv("XDG_CONFIG_HOME"); let oldDbg = getEnv("GDK_DEBUG")
  try:
    createDir(tmpCfg / "gtk-4.0")
    writeFile(tmpCfg / "gtk-4.0/settings.ini", ini.join("\n"))
    putEnv("XDG_CONFIG_HOME", tmpCfg)
  except OSError, IOError: discard
  putEnv("GDK_DEBUG", "no-portals")
  gtk_init()
  discard gtk_settings_get_default()   # settings.ini читается лениво — форсируем, пока подменён XDG_CONFIG_HOME
  if oldHome.len > 0: putEnv("XDG_CONFIG_HOME", oldHome) else: delEnv("XDG_CONFIG_HOME")
  if oldDbg.len > 0: putEnv("GDK_DEBUG", oldDbg) else: delEnv("GDK_DEBUG")

proc main() =
  when defined(mzdebug): stderr.writeLine "main t=" & $int(epochTime() * 1000 mod 100000)
  signal(SIGCHLD, SIG_IGN)   # дочерние sh (noctalia, gnome-control-center…) не остаются зомби
  if paramCount() >= 2 and paramStr(1) == "--set-lang":
    echo applyLocale(paramStr(2))
    return
  if paramCount() >= 4 and paramStr(1) == "--set-layout":
    echo applyKeyboard(paramStr(2), paramStr(3), paramStr(4) == "1")
    return
  C = Ctx(cfg: load())
  fastGtkInit()
  applyFaceCss()
  when defined(mzdebug): stderr.writeLine "gtk_init t=" & $int(epochTime() * 1000 mod 100000)
  let app = adw_application_new("dev.mazzy.settings", G_APPLICATION_DEFAULT_FLAGS)
  connect(app, "activate", onActivate)
  when defined(mzdebug): stderr.writeLine "app t=" & $int(epochTime() * 1000 mod 100000)
  quit(g_application_run(app, 0, nil))

main()
