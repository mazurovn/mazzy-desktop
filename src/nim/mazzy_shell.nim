## mazzy-shell — демон MAZZY_VO на Nim: обои с параллаксом (слой background),
## верхняя панель, док и 3D-карусель. Рендер GLES2, математика — libmazzy_mojo.
## Столы, фокус и закрытие окон идут через seat: Hyprland IPC или сокет Mango.
import std/[os, json, math, posix, strutils, times, osproc, tables, net, algorithm, sequtils]
import posix/inotify
import wl, gfx, hypr, mazzy_common, seat, sni

const MojoDir {.strdefine.}: string = ""
{.passL: "-L" & MojoDir & " -lmazzy_mojo -Wl,-rpath," & MojoDir.}
proc mz_layout_cards(n: int32, pos, spacing, centerGap, tilt, depth, parX, mousePar: float32, res: ptr float32) {.importc, cdecl.}
proc mz_smooth(cur, target, dt, k: float32): float32 {.importc, cdecl.}
proc mz_bgra_to_rgba_fit(src: ptr uint8, w, h, stride: int32, dst: ptr uint8, k, flip: int32) {.importc, cdecl.}

# ------------------------------------------------------------------ конфиг
type Cfg = object
  parEnabled: bool
  mousePx, wsPx, zoom, smooth, mouseHz: float
  tilt, depth, spacing, centerGap, cardW, cardH, mousePar, dim: float
  reflection, glow: bool

proc loadCfg(): Cfg =
  ## Дефолты и файл — из общего модуля mazzy_common (один источник правды с mazzy-settings).
  let j = load()
  let p = j["parallax"]; let s = j["switcher"]
  template f(node: JsonNode, key: string): float = node[key].getFloat(node[key].getInt.float)
  result = Cfg(parEnabled: p["enabled"].getBool, mousePx: f(p, "mouse_px"), wsPx: f(p, "workspace_px"),
               zoom: f(p, "zoom"), smooth: f(p, "smooth"), mouseHz: f(p, "mouse_hz"),
               tilt: f(s, "tilt"), depth: f(s, "depth"), spacing: f(s, "spacing"), centerGap: f(s, "center_gap"),
               cardW: f(s, "card_w"), cardH: f(s, "card_h"), mousePar: f(s, "mouse_parallax"), dim: f(s, "dim"),
               reflection: s["reflection"].getBool, glow: s["glow"].getBool)

# ------------------------------------------------------------------ состояние
type
  Surf = object
    ns: string
    surface: ptr wl_surface
    layer: ptr zwlr_layer_surface_v1
    eglWin: ptr wl_egl_window
    eglSurf: EGLSurface
    w, h: int
    configured, frameQueued, visible: bool

  Capture = object
    ## Один кадр в полёте: Hyprland export или одна сессия ext-image-copy-capture.
    frame: ptr hyprland_toplevel_export_frame_v1
    buf: ptr wl_buffer
    address: string
    w, h, stride: int
    fmt: uint32
    flip, drop: bool
    mode: int
    source: ptr ext_image_capture_source_v1
    session: ptr ext_image_copy_capture_session_v1
    copyFrame: ptr ext_image_copy_capture_frame_v1
    haveSize, sawDone, fmtArgb, fmtXrgb: bool

  TopRec = ref object
    ## Ручка foreign toplevel. GC_ref держит её, пока композитор не прислал closed:
    ## указатель в listener ARC не видит.
    handle: ptr ext_foreign_toplevel_handle_v1
    ident: string
    dead, dropped: bool

  Pin = object
    id, label: string
    icon, mark, nameTex: Tex

  MenuRow = object
    kind: int
    id, title, hint, iconPath: string
    on: bool
    tex, hintTex, icon: Tex

  App = object
    display: ptr wl_display
    registry: ptr wl_registry
    compositor: ptr wl_compositor
    shell: ptr zwlr_layer_shell_v1
    seat: ptr wl_seat
    shm: ptr wl_shm
    exportMgr: ptr hyprland_toplevel_export_manager_v1
    copyMgr: ptr ext_image_copy_capture_manager_v1
    topSrcMgr: ptr ext_foreign_toplevel_image_capture_source_manager_v1
    topList: ptr ext_foreign_toplevel_list_v1
    topById: Table[string, TopRec]
    keyboard: ptr wl_keyboard
    pointer: ptr wl_pointer
    egl: EGLDisplay
    eglCtx: EGLContext
    eglCfg: EGLConfig
    gfx: Gfx
    cfg: Cfg
    screenW, screenH: int
    # xkb
    xkb: ptr xkb_context
    keymap: ptr xkb_keymap
    xkbState: ptr xkb_state
    # обои
    wall: Surf
    wallTex, wallOld: Tex
    wallPath: string
    fadeT0: float
    tx, ty, gx, gy, wsOff, mx, my: float32
    # карусель
    sw: Surf
    wins: seq[Win]
    thumbs: Table[string, Tex]
    thumbTime: Table[string, float]
    pos, target: float32
    alpha, alphaTarget: float32
    parX, parY, mouseX, mouseY: float32
    hover: int
    titleTex, subTex: Tex
    titleFor: int
    lastFrame, lastWall, wallDue: float
    activeAddr: string
    captureAt: float
    capDeadline: float
    thumbLogged, copyNoted: bool
    # захват превью: очередь адресов, один кадр в полёте, общий shm-пул на memfd
    capQueue: seq[string]
    cap: Capture
    shmFd: cint
    shmPool: ptr wl_shm_pool
    shmMem: pointer
    shmSize: int
    lastMousePoll: float
    mouseIdle: int          # подряд опросов без движения мыши → опрос реже (2 Гц)
    inoFd: cint             # inotify на ~/.config/mazzy (обои и док)
    evBuf: string
    # своя панель и док. Noctalia сюда не входит.
    bar, dock: Surf
    hitSurf: ptr wl_surface
    hitX, hitY: float32
    wsId: int
    logoTex, clockTex, volTex, batTex, netTex: Tex
    volIcon, netIcon, batIcon, ctlIcon: Tex
    volIconFor, netIconFor, batIconFor, ctlIconFor: string
    clockFor, volFor, batFor, netFor: string
    volX, volW, batX, batW, netX, netW, ctlX, ctlW, brX, brW: float32
    brIcon, brTex: Tex
    brIconFor, brFor: string
    volScrollAt, brScrollAt: float
    sheet: Surf
    sheetKind, sheetPct: int
    sheetMuted, sheetDrag, sheetFail: bool
    sheetApplyAt: float
    sheetKey, sheetName, sheetDev, sheetNextId: string
    sheetTitle, sheetValue, sheetSub, sheetChip, sheetChip2: Tex
    sheetPreset: array[4, Tex]
    presetX: array[4, float32]
    trackX, trackY, trackW, trackH: float32
    chipX, chipY, chipW, chipH, chip2X, chip2W: float32
    trayTex: seq[Tex]
    trayX: array[6, float32]
    trayN, trayGen: int
    pinLive: seq[bool]
    numTex: array[DeskCount, Tex]
    occupied: array[DeskCount, bool]
    deskScrollAt: float
    pins: seq[Pin]
    extras: seq[Pin]
    barHot, dockHot: int
    statusAt: float
    micIcon, micTex, profIcon, profTex, vpnIcon, vpnTex: Tex
    micIconFor, micFor, profIconFor, profFor, profRaw, vpnFor: string
    micX, micW, profX, profW, vpnX, vpnW, clockX, clockW: float32
    osd: Surf
    osdUntil: float
    osdKind, osdPct: int
    osdMuted: bool
    osdTex: Tex
    osdFor: string
    menuIds, menuNames: seq[string]
    menuTex: seq[Tex]
    menuAll: Tex
    sheetLine: string
    face: Table[string, bool]
    faceLabels: bool
    faceOpacity: int
    faceStyle: string
    faceClock: string
    faceOrder: seq[string]
    clockH, clockM: int
    clockStamp: string
    cpuIdle, cpuTotal, netRx, netTx: int64
    cpuArmed, netArmed: bool
    perfAt: float
    editOn: bool
    editPick: string
    menuQuery: string
    menuTab: int
    menuRows: seq[MenuRow]
    listLines: seq[string]
    listTex: seq[Tex]
    chipKey: array[12, string]
    chipFor: array[12, string]
    chipIconFor: array[12, string]
    chipIcon: array[12, Tex]
    chipTex: array[12, Tex]
    moreX: array[12, float32]
    moreW: array[12, float32]
    dockSlot: float32
    dockCap: Tex
    dockCapFor: string
    scrim: Surf
    dismissMs: int
    leaveAt: float
    powerArm: string
    layoutFor: string
    layoutX, layoutW: float32
    layoutTex, layoutIcon: Tex
    clipHist: seq[string]
    clipSeen: string

const
  cmNone = 0
  cmHypr = 1
  cmCopy = 2
  thumbLong = 640
  thumbFresh = 1.2
  capWait = 1.5

var
  A: App
  topListListener: ext_foreign_toplevel_list_v1_listener
  topHandleListener: ext_foreign_toplevel_handle_v1_listener
  sessListener: ext_image_copy_capture_session_v1_listener
  copyFrameListener: ext_image_copy_capture_frame_v1_listener

proc now(): float = epochTime()

# ------------------------------------------------------------------ wayland: registry
proc onGlobal(data: pointer, reg: ptr wl_registry, name: uint32, iface: cstring, version: uint32) {.cdecl.} =
  let s = $iface
  if s == "wl_compositor": A.compositor = cast[ptr wl_compositor](wl_registry_bind(reg, name, addr wl_compositor_interface, 4))
  elif s == "zwlr_layer_shell_v1": A.shell = cast[ptr zwlr_layer_shell_v1](wl_registry_bind(reg, name, addr zwlr_layer_shell_v1_interface, min(version, 4'u32)))
  elif s == "wl_seat" and A.seat == nil: A.seat = cast[ptr wl_seat](wl_registry_bind(reg, name, addr wl_seat_interface, 5))
  elif s == "wl_shm": A.shm = cast[ptr wl_shm](wl_registry_bind(reg, name, addr wl_shm_interface, 1))
  elif s == "hyprland_toplevel_export_manager_v1":
    A.exportMgr = cast[ptr hyprland_toplevel_export_manager_v1](wl_registry_bind(reg, name, addr hyprland_toplevel_export_manager_v1_interface, 1))
  elif s == "ext_image_copy_capture_manager_v1":
    A.copyMgr = cast[ptr ext_image_copy_capture_manager_v1](wl_registry_bind(reg, name, addr ext_image_copy_capture_manager_v1_interface, 1))
  elif s == "ext_foreign_toplevel_image_capture_source_manager_v1":
    A.topSrcMgr = cast[ptr ext_foreign_toplevel_image_capture_source_manager_v1](wl_registry_bind(reg, name, addr ext_foreign_toplevel_image_capture_source_manager_v1_interface, 1))
  elif s == "ext_foreign_toplevel_list_v1" and A.topList == nil:
    A.topList = cast[ptr ext_foreign_toplevel_list_v1](wl_registry_bind(reg, name, addr ext_foreign_toplevel_list_v1_interface, 1))
    discard ext_foreign_toplevel_list_v1_add_listener(A.topList, addr topListListener, nil)
proc onGlobalRemove(data: pointer, reg: ptr wl_registry, name: uint32) {.cdecl.} = discard
var regListener = wl_registry_listener(global: onGlobal, global_remove: onGlobalRemove)

# ------------------------------------------------------------------ поверхности
proc render(s: var Surf)
proc requestFrame(s: var Surf)

proc onFrame(data: pointer, cb: ptr wl_callback, time: uint32) {.cdecl.} =
  wl_callback_destroy(cb)
  let s = cast[ptr Surf](data)
  s.frameQueued = false
  if s.visible: render(s[])
var frameListener = wl_callback_listener(done: onFrame)

proc requestFrame(s: var Surf) =
  if s.frameQueued or not s.configured: return
  s.frameQueued = true
  let cb = wl_surface_frame(s.surface)
  discard wl_callback_add_listener(cb, addr frameListener, addr s)
  wl_surface_commit(s.surface)

proc onConfigure(data: pointer, ls: ptr zwlr_layer_surface_v1, serial, w, h: uint32) {.cdecl.} =
  let s = cast[ptr Surf](data)
  zwlr_layer_surface_v1_ack_configure(ls, serial)
  if w > 0 and h > 0:
    s.w = w.int; s.h = h.int
    # Бар и док узкие. Размер экрана берут только полноэкранные слои.
    if s.ns == "mazzy-wallpaper" or s.ns == "mazzy-switcher":
      A.screenW = s.w; A.screenH = s.h
    if s.eglWin != nil: wl_egl_window_resize(s.eglWin, w.cint, h.cint, 0, 0)
  if not s.configured:
    s.configured = true
    s.eglWin = wl_egl_window_create(s.surface, s.w.cint, s.h.cint)
    s.eglSurf = eglCreateWindowSurface(A.egl, A.eglCfg, s.eglWin, nil)
  s.visible = true
  render(s[])
proc onClosed(data: pointer, ls: ptr zwlr_layer_surface_v1) {.cdecl.} =
  cast[ptr Surf](data).visible = false
var layerListener = zwlr_layer_surface_v1_listener(configure: onConfigure, closed: onClosed)

proc createSurf(s: var Surf, ns: string, layer: uint32, kb: uint32, input: bool,
                anchor: uint32 = ZWLR_ANCHOR_ALL, zone: int32 = -1, reqW: uint32 = 0, reqH: uint32 = 0,
                marginBottom: int32 = 0, marginTop: int32 = 0, marginRight: int32 = 0,
                marginLeft: int32 = 0) =
  s.ns = ns
  s.surface = wl_compositor_create_surface(A.compositor)
  if not input:
    let r = wl_compositor_create_region(A.compositor)   # пустой регион — клики проходят сквозь
    wl_surface_set_input_region(s.surface, r); wl_region_destroy(r)
  s.layer = zwlr_layer_shell_v1_get_layer_surface(A.shell, s.surface, nil, layer, ns.cstring)
  zwlr_layer_surface_v1_set_anchor(s.layer, anchor)
  zwlr_layer_surface_v1_set_exclusive_zone(s.layer, zone)
  zwlr_layer_surface_v1_set_keyboard_interactivity(s.layer, kb)
  zwlr_layer_surface_v1_set_size(s.layer, reqW, reqH)
  if marginBottom != 0 or marginTop != 0 or marginRight != 0 or marginLeft != 0:
    zwlr_layer_surface_v1_set_margin(s.layer, marginTop, marginRight, marginBottom, marginLeft)
  discard zwlr_layer_surface_v1_add_listener(s.layer, addr layerListener, addr s)
  s.configured = false; s.frameQueued = false
  wl_surface_commit(s.surface)

proc destroySurf(s: var Surf) =
  if s.layer == nil: return
  if s.eglSurf != nil: discard eglDestroySurface(A.egl, s.eglSurf); s.eglSurf = nil
  if s.eglWin != nil: wl_egl_window_destroy(s.eglWin); s.eglWin = nil
  zwlr_layer_surface_v1_destroy(s.layer); s.layer = nil
  wl_surface_destroy(s.surface); s.surface = nil
  s.configured = false; s.visible = false; s.frameQueued = false

# ------------------------------------------------------------------ картинки
{.passC: staticExec("pkg-config --cflags gdk-pixbuf-2.0").}
{.passL: staticExec("pkg-config --libs gdk-pixbuf-2.0").}
type GdkPixbuf {.importc: "GdkPixbuf", header: "<gdk-pixbuf/gdk-pixbuf.h>", incompleteStruct.} = object
proc gdk_pixbuf_new_from_file(f: cstring, err: pointer): ptr GdkPixbuf {.importc, header: "<gdk-pixbuf/gdk-pixbuf.h>".}
proc gdk_pixbuf_apply_embedded_orientation(p: ptr GdkPixbuf): ptr GdkPixbuf {.importc, header: "<gdk-pixbuf/gdk-pixbuf.h>".}
proc gdk_pixbuf_get_width(p: ptr GdkPixbuf): cint {.importc, header: "<gdk-pixbuf/gdk-pixbuf.h>".}
proc gdk_pixbuf_get_height(p: ptr GdkPixbuf): cint {.importc, header: "<gdk-pixbuf/gdk-pixbuf.h>".}
proc gdk_pixbuf_get_rowstride(p: ptr GdkPixbuf): cint {.importc, header: "<gdk-pixbuf/gdk-pixbuf.h>".}
proc gdk_pixbuf_get_n_channels(p: ptr GdkPixbuf): cint {.importc, header: "<gdk-pixbuf/gdk-pixbuf.h>".}
proc gdk_pixbuf_get_pixels(p: ptr GdkPixbuf): ptr UncheckedArray[uint8] {.importc, header: "<gdk-pixbuf/gdk-pixbuf.h>".}
proc g_object_unref2(o: pointer) {.importc: "g_object_unref", header: "<glib-object.h>".}

proc loadImageTex(path: string): Tex =
  var pb = gdk_pixbuf_new_from_file(path.cstring, nil)
  if pb == nil: return
  let pb2 = gdk_pixbuf_apply_embedded_orientation(pb)
  if pb2 != nil: g_object_unref2(pb); pb = pb2
  let w = gdk_pixbuf_get_width(pb).int; let h = gdk_pixbuf_get_height(pb).int
  let stride = gdk_pixbuf_get_rowstride(pb).int; let nc = gdk_pixbuf_get_n_channels(pb).int
  if nc < 3 or w < 1 or h < 1:
    g_object_unref2(pb); return
  let px = gdk_pixbuf_get_pixels(pb)
  if nc >= 4:
    var buf = newSeq[uint8](w * h * 4)
    for y in 0 ..< h:
      for x in 0 ..< w:
        let s = y * stride + x * nc
        let d = (y * w + x) * 4
        let a = px[s + 3].int
        buf[d] = uint8((px[s].int * a) div 255)
        buf[d + 1] = uint8((px[s + 1].int * a) div 255)
        buf[d + 2] = uint8((px[s + 2].int * a) div 255)
        buf[d + 3] = px[s + 3]
    result = newTex(w, h, GL_RGBA, addr buf[0], mip = true)
  else:
    var buf = newSeq[uint8](w * h * 3)
    for y in 0 ..< h:
      for x in 0 ..< w:
        let s = y * stride + x * nc; let d = (y * w + x) * 3
        buf[d] = px[s]; buf[d + 1] = px[s + 1]; buf[d + 2] = px[s + 2]
    result = newTex(w, h, GL_RGB, addr buf[0], mip = true)
  g_object_unref2(pb)

# ------------------------------------------------------------------ превью окон
## Hyprland: hyprland_toplevel_export. Mango: один кадр ext-image-copy-capture
## с источника foreign toplevel (окно, не прямоугольник экрана). Сессия живёт
## один кадр: повторный кадр той же сессии может ждать изменения содержимого.
## Пока карусель закрыта, путь Mango не снимает. Прогрев по фокусу — только Hyprland.
proc memfd_create(name: cstring, flags: cuint): cint {.importc, header: "<sys/mman.h>".}
proc requestFrameSw()
proc pumpCapture()
proc finishCapture()
proc scheduleThumbs(prefer: int)

proc releaseThumbPool() =
  ## Полноразмерный shm нужен только на время кадра. Миниатюра уже в текстуре.
  if A.cap.mode != cmNone: return
  if A.shmPool != nil:
    wl_shm_pool_destroy(A.shmPool)
    A.shmPool = nil
  if A.shmMem != nil:
    discard munmap(A.shmMem, A.shmSize)
    A.shmMem = nil
  if A.shmFd >= 0:
    discard close(A.shmFd)
    A.shmFd = -1
  A.shmSize = 0

proc ensurePool(size: int): bool =
  if size < 1 or A.shm == nil: return false
  if A.shmPool != nil and A.shmMem != nil and size <= A.shmSize: return true
  if A.shmPool == nil:
    A.shmFd = memfd_create("mazzy-thumbs", 1)   # MFD_CLOEXEC
    if A.shmFd < 0: return false
    if ftruncate(A.shmFd, size.Off) != 0:
      discard close(A.shmFd); A.shmFd = -1; return false
    A.shmMem = mmap(nil, size, PROT_READ or PROT_WRITE, MAP_SHARED, A.shmFd, 0)
    if A.shmMem == MAP_FAILED:
      A.shmMem = nil
      discard close(A.shmFd); A.shmFd = -1; return false
    A.shmPool = wl_shm_create_pool(A.shm, A.shmFd, size.int32)
    if A.shmPool == nil:
      discard munmap(A.shmMem, size); A.shmMem = nil
      discard close(A.shmFd); A.shmFd = -1; return false
  else:
    if A.shmMem != nil: discard munmap(A.shmMem, A.shmSize)
    A.shmMem = nil
    if ftruncate(A.shmFd, size.Off) != 0: return false
    A.shmMem = mmap(nil, size, PROT_READ or PROT_WRITE, MAP_SHARED, A.shmFd, 0)
    if A.shmMem == MAP_FAILED:
      A.shmMem = nil; return false
    wl_shm_pool_resize(A.shmPool, size.int32)
  A.shmSize = size
  true

proc takeTop(data: pointer): TopRec =
  ## Присваивание cast в --mm:arc делает incRef. Конец let снимает его.
  ## Внешний GC_ref, поставленный при создании, этот вызов не трогает.
  if data == nil: return
  result = cast[TopRec](data)

proc capIdOf(address: string): string =
  for w in A.wins:
    if w.address == address: return w.capId

proc dropTop(rec: TopRec) =
  if rec == nil or rec.dropped: return
  rec.dropped = true
  if rec.ident.len > 0 and rec.ident in A.topById and A.topById[rec.ident] == rec:
    A.topById.del(rec.ident)
  if rec.handle != nil:
    ext_foreign_toplevel_handle_v1_destroy(rec.handle)
    rec.handle = nil
  GC_unref(rec)

proc buryDead() =
  var dead: seq[TopRec] = @[]
  for id, rec in A.topById:
    if rec.dead: dead.add rec
  for rec in dead: dropTop(rec)

proc finishCapture() =
  A.capDeadline = 0
  if A.cap.buf != nil: wl_buffer_destroy(A.cap.buf)
  if A.cap.frame != nil: hyprland_toplevel_export_frame_v1_destroy(A.cap.frame)
  if A.cap.copyFrame != nil: ext_image_copy_capture_frame_v1_destroy(A.cap.copyFrame)
  if A.cap.session != nil: ext_image_copy_capture_session_v1_destroy(A.cap.session)
  if A.cap.source != nil: ext_image_capture_source_v1_destroy(A.cap.source)
  A.cap = Capture()
  buryDead()
  if A.sw.layer == nil: releaseThumbPool()

proc evictThumbs(keep: string) =
  while A.thumbs.len > 6:
    var oldest = ""
    var t0 = 1.0e100
    for a in A.thumbs.keys:
      if a == keep: continue
      let t = A.thumbTime.getOrDefault(a, 0.0)
      if oldest.len == 0 or t < t0:
        t0 = t; oldest = a
    if oldest.len == 0: break
    A.thumbs[oldest].free()
    A.thumbs.del(oldest)
    A.thumbTime.del(oldest)

proc storeThumb() =
  if A.cap.drop or A.cap.w < 40 or A.cap.h < 40 or A.shmMem == nil: return
  let k = thumbScale(A.cap.w, A.cap.h, thumbLong)
  let dw = A.cap.w div k
  let dh = A.cap.h div k
  if dw < 1 or dh < 1: return
  var px = newSeq[uint8](dw * dh * 4)
  mz_bgra_to_rgba_fit(cast[ptr uint8](A.shmMem), A.cap.w.int32, A.cap.h.int32, A.cap.stride.int32,
                      addr px[0], k.int32, (if A.cap.flip: 1'i32 else: 0))
  if A.wall.eglSurf != nil:
    discard eglMakeCurrent(A.egl, A.wall.eglSurf, A.wall.eglSurf, A.eglCtx)
  let tex = newTex(dw, dh, GL_RGBA, addr px[0])
  if tex.id == 0: return
  let address = A.cap.address
  if A.thumbs.hasKey(address): A.thumbs[address].free()
  else: evictThumbs(address)
  A.thumbs[address] = tex
  A.thumbTime[address] = now()
  if not A.thumbLogged:
    A.thumbLogged = true
    stderr.writeLine "mazzy-shell: превью карусели " & $dw & "x" & $dh
  requestFrameSw()

proc onCapBuffer(data: pointer, f: ptr hyprland_toplevel_export_frame_v1, format, w, h, stride: uint32) {.cdecl.} =
  if f != A.cap.frame: return
  A.cap.fmt = format; A.cap.w = w.int; A.cap.h = h.int; A.cap.stride = stride.int
proc onCapDamage(data: pointer, f: ptr hyprland_toplevel_export_frame_v1, x, y, w, h: uint32) {.cdecl.} = discard
proc onCapFlags(data: pointer, f: ptr hyprland_toplevel_export_frame_v1, flags: uint32) {.cdecl.} =
  if f != A.cap.frame: return
  A.cap.flip = (flags and HYPRLAND_TOPLEVEL_EXPORT_FRAME_V1_FLAGS_Y_INVERT) != 0
proc onCapDmabuf(data: pointer, f: ptr hyprland_toplevel_export_frame_v1, format, w, h: uint32) {.cdecl.} = discard
proc onCapBufferDone(data: pointer, f: ptr hyprland_toplevel_export_frame_v1) {.cdecl.} =
  if f != A.cap.frame: return
  if A.cap.w < 1 or A.cap.h < 1 or A.cap.drop or not shmBytesOk(A.cap.w, A.cap.h):
    finishCapture(); pumpCapture(); return
  if A.cap.stride < A.cap.w * 4 or A.cap.stride.int64 * A.cap.h.int64 > 12_000_000:
    finishCapture(); pumpCapture(); return
  if not ensurePool(A.cap.stride * A.cap.h):
    finishCapture(); pumpCapture(); return
  A.cap.buf = wl_shm_pool_create_buffer(A.shmPool, 0, A.cap.w.int32, A.cap.h.int32, A.cap.stride.int32, A.cap.fmt)
  if A.cap.buf == nil:
    finishCapture(); pumpCapture(); return
  hyprland_toplevel_export_frame_v1_copy(f, A.cap.buf, 1)
proc onCapReady(data: pointer, f: ptr hyprland_toplevel_export_frame_v1, secHi, secLo, nsec: uint32) {.cdecl.} =
  if f != A.cap.frame: return
  storeThumb()
  finishCapture(); pumpCapture()
proc onCapFailed(data: pointer, f: ptr hyprland_toplevel_export_frame_v1) {.cdecl.} =
  if f != A.cap.frame: return
  finishCapture(); pumpCapture()
var capListener = hyprland_toplevel_export_frame_v1_listener(buffer: onCapBuffer, damage: onCapDamage, flags: onCapFlags,
                                                            ready: onCapReady, failed: onCapFailed, linux_dmabuf: onCapDmabuf,
                                                            buffer_done: onCapBufferDone)

proc onSessSize(data: pointer, s: ptr ext_image_copy_capture_session_v1, w, h: uint32) {.cdecl.} =
  if s != A.cap.session: return
  A.cap.w = w.int; A.cap.h = h.int; A.cap.haveSize = true
proc onSessFmt(data: pointer, s: ptr ext_image_copy_capture_session_v1, format: uint32) {.cdecl.} =
  if s != A.cap.session: return
  if format == WL_SHM_FORMAT_ARGB8888: A.cap.fmtArgb = true
  elif format == WL_SHM_FORMAT_XRGB8888: A.cap.fmtXrgb = true
proc onSessDev(data: pointer, s: ptr ext_image_copy_capture_session_v1, device: ptr wl_array) {.cdecl.} = discard
proc onSessDma(data: pointer, s: ptr ext_image_copy_capture_session_v1, format: uint32, modifiers: ptr wl_array) {.cdecl.} = discard
proc onSessDone(data: pointer, s: ptr ext_image_copy_capture_session_v1) {.cdecl.} =
  if s != A.cap.session or A.cap.copyFrame != nil: return
  if A.cap.drop or not A.cap.haveSize or not shmBytesOk(A.cap.w, A.cap.h):
    finishCapture(); pumpCapture(); return
  if A.cap.fmtArgb: A.cap.fmt = WL_SHM_FORMAT_ARGB8888
  elif A.cap.fmtXrgb: A.cap.fmt = WL_SHM_FORMAT_XRGB8888
  elif not A.cap.sawDone:
    # Mango дописывает BGR-форматы вторым проходом constraints.
    A.cap.sawDone = true
    return
  else:
    finishCapture(); pumpCapture(); return
  A.cap.stride = A.cap.w * 4
  if not ensurePool(A.cap.stride * A.cap.h):
    finishCapture(); pumpCapture(); return
  A.cap.buf = wl_shm_pool_create_buffer(A.shmPool, 0, A.cap.w.int32, A.cap.h.int32, A.cap.stride.int32, A.cap.fmt)
  if A.cap.buf == nil:
    finishCapture(); pumpCapture(); return
  A.cap.copyFrame = ext_image_copy_capture_session_v1_create_frame(A.cap.session)
  if A.cap.copyFrame == nil:
    finishCapture(); pumpCapture(); return
  discard ext_image_copy_capture_frame_v1_add_listener(A.cap.copyFrame, addr copyFrameListener, nil)
  ext_image_copy_capture_frame_v1_attach_buffer(A.cap.copyFrame, A.cap.buf)
  ext_image_copy_capture_frame_v1_damage_buffer(A.cap.copyFrame, 0, 0, A.cap.w.int32, A.cap.h.int32)
  ext_image_copy_capture_frame_v1_capture(A.cap.copyFrame)
proc onSessStopped(data: pointer, s: ptr ext_image_copy_capture_session_v1) {.cdecl.} =
  if s != A.cap.session: return
  finishCapture(); pumpCapture()

proc onCopyTransform(data: pointer, f: ptr ext_image_copy_capture_frame_v1, transform: uint32) {.cdecl.} =
  if f != A.cap.copyFrame: return
  A.cap.flip = transform == 4'u32
proc onCopyDamage(data: pointer, f: ptr ext_image_copy_capture_frame_v1, x, y, w, h: int32) {.cdecl.} = discard
proc onCopyTime(data: pointer, f: ptr ext_image_copy_capture_frame_v1, secHi, secLo, nsec: uint32) {.cdecl.} = discard
proc onCopyReady(data: pointer, f: ptr ext_image_copy_capture_frame_v1) {.cdecl.} =
  if f != A.cap.copyFrame: return
  storeThumb()
  finishCapture(); pumpCapture()
proc onCopyFailed(data: pointer, f: ptr ext_image_copy_capture_frame_v1, reason: uint32) {.cdecl.} =
  if f != A.cap.copyFrame: return
  finishCapture(); pumpCapture()

proc onTopClosed(data: pointer, h: ptr ext_foreign_toplevel_handle_v1) {.cdecl.} =
  let rec = takeTop(data)
  if rec == nil: return
  if A.cap.mode == cmCopy and rec.ident.len > 0 and capIdOf(A.cap.address) == rec.ident:
    rec.dead = true
    return
  dropTop(rec)
proc onTopDone(data: pointer, h: ptr ext_foreign_toplevel_handle_v1) {.cdecl.} = discard
proc onTopTitle(data: pointer, h: ptr ext_foreign_toplevel_handle_v1, title: cstring) {.cdecl.} = discard
proc onTopApp(data: pointer, h: ptr ext_foreign_toplevel_handle_v1, appId: cstring) {.cdecl.} = discard
proc onTopIdent(data: pointer, h: ptr ext_foreign_toplevel_handle_v1, ident: cstring) {.cdecl.} =
  let rec = takeTop(data)
  if rec == nil or ident == nil: return
  rec.ident = $ident
  if rec.ident.len == 0: return
  A.topById[rec.ident] = rec
proc onTopToplevel(data: pointer, list: ptr ext_foreign_toplevel_list_v1, handle: ptr ext_foreign_toplevel_handle_v1) {.cdecl.} =
  if handle == nil: return
  var rec = TopRec(handle: handle)
  GC_ref(rec)
  discard ext_foreign_toplevel_handle_v1_add_listener(handle, addr topHandleListener, cast[pointer](rec))
proc onTopFinished(data: pointer, list: ptr ext_foreign_toplevel_list_v1) {.cdecl.} =
  if A.topList != nil:
    ext_foreign_toplevel_list_v1_destroy(A.topList)
    A.topList = nil

topListListener = ext_foreign_toplevel_list_v1_listener(toplevel: onTopToplevel, finished: onTopFinished)
topHandleListener = ext_foreign_toplevel_handle_v1_listener(closed: onTopClosed, done: onTopDone, title: onTopTitle,
                                                           app_id: onTopApp, identifier: onTopIdent)
sessListener = ext_image_copy_capture_session_v1_listener(buffer_size: onSessSize, shm_format: onSessFmt,
                                                         dmabuf_device: onSessDev, dmabuf_format: onSessDma,
                                                         done: onSessDone, stopped: onSessStopped)
copyFrameListener = ext_image_copy_capture_frame_v1_listener(transform: onCopyTransform, damage: onCopyDamage,
                                                            presentation_time: onCopyTime, ready: onCopyReady,
                                                            failed: onCopyFailed)

proc pumpCapture() =
  ## Один кадр за раз. Адрес, который нельзя снять, пропускается циклом.
  while A.cap.mode == cmNone and A.capQueue.len > 0:
    let a = A.capQueue[0]
    A.capQueue.delete(0)
    if A.exportMgr != nil:
      let parsed = lowHandle(a)
      if not parsed.ok: continue
      A.cap = Capture(address: a, mode: cmHypr)
      A.cap.frame = hyprland_toplevel_export_manager_v1_capture_toplevel(A.exportMgr, 0, parsed.handle)
      if A.cap.frame == nil:
        A.cap = Capture(); continue
      discard hyprland_toplevel_export_frame_v1_add_listener(A.cap.frame, addr capListener, nil)
      A.thumbTime[a] = now()
      A.capDeadline = now() + capWait
      return
    if A.copyMgr != nil and A.topSrcMgr != nil:
      let id = capIdOf(a)
      if id.len == 0 or id notin A.topById: continue
      let rec = A.topById[id]
      if rec.handle == nil or rec.dropped: continue
      A.cap = Capture(address: a, mode: cmCopy)
      A.cap.source = ext_foreign_toplevel_image_capture_source_manager_v1_create_source(A.topSrcMgr, rec.handle)
      if A.cap.source == nil:
        A.cap = Capture(); continue
      A.cap.session = ext_image_copy_capture_manager_v1_create_session(A.copyMgr, A.cap.source, 0)
      if A.cap.session == nil:
        ext_image_capture_source_v1_destroy(A.cap.source)
        A.cap = Capture(); continue
      discard ext_image_copy_capture_session_v1_add_listener(A.cap.session, addr sessListener, nil)
      A.thumbTime[a] = now()
      A.capDeadline = now() + capWait
      return
    A.capQueue.setLen(0)
    return

proc enqueueCapture(a: string) =
  ## Прогрев после фокуса. На Mango exportMgr пуст, и этот путь ничего не снимает.
  if A.exportMgr == nil or a.len == 0 or a in A.capQueue or (A.cap.mode != cmNone and A.cap.address == a): return
  if A.thumbTime.getOrDefault(a, 0) > now() - 0.3: return
  A.capQueue.add a
  pumpCapture()

proc scheduleThumbs(prefer: int) =
  ## Очередь заменяется целиком: быстрая смена не копит промежуточные окна.
  let n = A.wins.len
  A.capQueue.setLen(0)
  let budget = captureBudget(n)
  if budget == 0: return
  let fresh = now() - thumbFresh
  var seen = 0
  for i in captureOrder(n, prefer):
    if seen >= budget: break
    inc seen
    let w = A.wins[i]
    if w.address.len == 0: continue
    if A.exportMgr == nil and (w.capId.len == 0 or w.capId notin A.topById): continue
    if A.cap.mode != cmNone and A.cap.address == w.address: continue
    if A.thumbTime.getOrDefault(w.address, 0.0) > fresh: continue
    A.capQueue.add w.address
  pumpCapture()

proc noteThumbs() =
  if A.copyNoted or A.exportMgr != nil or A.copyMgr == nil: return
  A.copyNoted = true
  var hit = 0
  for w in A.wins:
    if w.capId.len > 0 and w.capId in A.topById: inc hit
  stderr.writeLine "mazzy-shell: превью окон " & $hit & "/" & $A.wins.len & " метки=" & $A.topById.len

proc forgetWindow(a: string) =
  ## Окно закрыто: убрать из очереди, отбросить кадр в полёте, освободить превью.
  A.capQueue.keepItIf(it != a)
  if A.cap.address == a: A.cap.drop = true
  if A.thumbs.hasKey(a): A.thumbs[a].free(); A.thumbs.del(a)
  A.thumbTime.del(a)

# ------------------------------------------------------------------ рендер: обои
proc drawWall(tex: Tex, alpha: float32) =
  if tex.id == 0: return
  let w = A.wall.w.float32; let h = A.wall.h.float32
  let z = A.cfg.zoom.float32
  let s = max(w * z / tex.w.float32, h * z / tex.h.float32)
  let dw = tex.w.float32 * s; let dh = tex.h.float32 * s
  var p = params()
  p.tex = tex.id; p.alpha = alpha; p.size = (dw, dh)
  # орто: центр экрана 0,0 → NDC
  var m = identity()
  m[0] = 2 / w; m[5] = -2 / h
  p.mvp = m.mul(translate(-A.tx, -A.ty, 0))
  A.gfx.draw(p)

proc renderWall() =
  discard eglMakeCurrent(A.egl, A.wall.eglSurf, A.wall.eglSurf, A.eglCtx)
  glViewport(0, 0, A.wall.w.GLsizei, A.wall.h.GLsizei)
  glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT)
  glUseProgram(A.gfx.prog)
  if A.wallOld.id != 0:
    let a = min(1.0, (now() - A.fadeT0) / 0.9).float32
    drawWall(A.wallOld, 1); drawWall(A.wallTex, a)
    if a >= 1: A.wallOld.free()
  else:
    drawWall(A.wallTex, 1)
  discard eglSwapBuffers(A.egl, A.wall.eglSurf)

proc wallTick(dt: float32): bool =
  ## true — ещё движется
  A.gx = A.wsOff + A.mx * A.cfg.mousePx.float32
  A.gy = A.my * A.cfg.mousePx.float32 * 0.6
  A.tx = mz_smooth(A.tx, A.gx, dt, A.cfg.smooth.float32)
  A.ty = mz_smooth(A.ty, A.gy, dt, A.cfg.smooth.float32)
  result = abs(A.gx - A.tx) > 1 or abs(A.gy - A.ty) > 1 or A.wallOld.id != 0   # порог 1 px: короче хвост

# ------------------------------------------------------------------ рендер: карусель
proc cardMvp(x, y, z, ang: float32, cw, ch: float32): Mat4 =
  let w = A.sw.w.float32; let h = A.sw.h.float32
  let f = 1400'f32
  var proj = perspectivePx(w, h, f)
  var m = proj.mul(translate(0, 0, -f))
  m = m.mul(translate(x, y - 30 + A.parY * 30, z))
  m = m.mul(rotateY(ang))
  result = m

proc renderSwitcher() =
  discard eglMakeCurrent(A.egl, A.sw.eglSurf, A.sw.eglSurf, A.eglCtx)
  let w = A.sw.w.float32; let h = A.sw.h.float32
  glViewport(0, 0, A.sw.w.GLsizei, A.sw.h.GLsizei)
  glClearColor(0, 0, 0, 0); glClear(GL_COLOR_BUFFER_BIT)
  glUseProgram(A.gfx.prog)
  let a = A.alpha
  var ortho = identity(); ortho[0] = 2 / w; ortho[5] = -2 / h
  # затемнение
  var p = params()
  p.mode = 1; p.color = (0.02'f32, 0.03'f32, 0.05'f32, A.cfg.dim.float32 * a); p.size = (w, h); p.mvp = ortho
  A.gfx.draw(p)
  # свечение
  if A.cfg.glow:
    p = params(); p.mode = 3; p.color = (0.45'f32, 0.55'f32, 0.9'f32, 0.18'f32 * a); p.size = (1400'f32, 520'f32)
    p.mvp = ortho.mul(translate(A.parX * 25, 40 + A.parY * 12, 0)); A.gfx.draw(p)
  let n = A.wins.len
  if n == 0: return
  var lay = newSeq[float32](n * 4)
  mz_layout_cards(n.int32, A.pos, A.cfg.spacing.float32, A.cfg.centerGap.float32, A.cfg.tilt.float32,
                  A.cfg.depth.float32, A.parX, A.cfg.mousePar.float32, addr lay[0])
  # порядок: дальние → ближние
  var order = newSeq[int]()
  for i in 0 ..< n: order.add i
  order.sort(proc(x, y: int): int = cmp(abs(y.float32 - A.pos), abs(x.float32 - A.pos)))
  for i in order:
    let ad = abs(i.float32 - A.pos)
    if ad > 6: continue
    let x = lay[i*4]; let z = lay[i*4+1]; let ang = lay[i*4+2]; let dim = lay[i*4+3]
    let win = A.wins[i]
    var tex: GLuint = 0
    var tw = max(1, win.w); var th = max(1, win.h)
    if A.thumbs.hasKey(win.address):
      let t = A.thumbs[win.address]; tex = t.id; tw = t.w; th = t.h   # пропорции — по кадру композитора
    let sc = min(A.cfg.cardW / tw.float, A.cfg.cardH / th.float).float32
    let cw = tw.float32 * sc; let ch = th.float32 * sc
    let base = cardMvp(x, 0, z, ang, cw, ch)
    # тень
    p = params(); p.mode = 2; p.color = (0'f32, 0'f32, 0'f32, 0.55'f32 * a); p.size = (cw + 80, ch + 80); p.radius = 40
    p.mvp = base.mul(translate(0, 18, -1)); A.gfx.draw(p)
    # карточка
    p = params(); p.tex = tex; p.size = (cw, ch); p.radius = 16; p.dim = dim; p.alpha = a
    if tex == 0: p.mode = 1; p.color = (0.13'f32, 0.14'f32, 0.18'f32, 1'f32)
    p.border = (if ad < 0.5: 2'f32 else: 1'f32)
    p.borderColor = (1'f32, 1'f32, 1'f32, (if ad < 0.5: 0.85'f32 elif i == A.hover: 0.5'f32 else: 0.22'f32) * a)
    p.mvp = base; A.gfx.draw(p)
    # отражение
    if A.cfg.reflection and ad < 2.5 and tex != 0:
      p = params(); p.tex = tex; p.mode = 4; p.flip = 1; p.size = (cw, ch * 0.35'f32); p.radius = 16; p.dim = dim
      p.alpha = 0.18'f32 * a * (1 - ad / 2.5)
      p.mvp = base.mul(translate(0, ch / 2 + 6 + ch * 0.175'f32, 0)); A.gfx.draw(p)
  # подпись
  let sel = ((A.target.int mod n) + n) mod n
  if A.titleFor != sel or A.titleTex.id == 0:
    A.titleTex.free(); A.subTex.free()
    let t = if A.wins[sel].title.len > 0: A.wins[sel].title else: A.wins[sel].class
    A.titleTex = textTex(t, "Inter Semi-Bold 15", 900)
    A.subTex = textTex(A.wins[sel].class & "   ·   стол " & A.wins[sel].ws, "Inter 11", 900, 0.6)
    A.titleFor = sel
  let ty = (-30 + A.cfg.cardH / 2 + 44).float32
  p = params(); p.tex = A.titleTex.id; p.size = (A.titleTex.w.float32, A.titleTex.h.float32); p.alpha = a
  p.mvp = ortho.mul(translate(0, ty + A.titleTex.h.float32 / 2, 0)); A.gfx.draw(p)
  p = params(); p.tex = A.subTex.id; p.size = (A.subTex.w.float32, A.subTex.h.float32); p.alpha = a
  p.mvp = ortho.mul(translate(0, ty + A.titleTex.h.float32 + 8 + A.subTex.h.float32 / 2, 0)); A.gfx.draw(p)

proc orthoPx(w, h: float32): Mat4 =
  result = identity()
  result[0] = 2 / w
  result[5] = -2 / h

proc putBox(x, y, bw, bh, surfW, surfH: float32, tex: Tex, radius: float32, mode: int32,
            color: (float32, float32, float32, float32)) =
  var p = params()
  p.tex = tex.id
  p.mode = mode
  p.color = color
  p.size = (bw, bh)
  p.radius = radius
  p.mvp = orthoPx(surfW, surfH).mul(translate(-surfW / 2 + x + bw / 2, -surfH / 2 + y + bh / 2, 0))
  A.gfx.draw(p)

proc spawn(args: seq[string]) =
  ## Не poDaemon: posix_spawn без wait оставляет зомби. SIGCHLD не глушим.
  if args.len == 0: return
  try:
    discard detachSpawn(args)
  except OSError, CatchableError:
    discard

proc openSettings(page: string) =
  spawn(@[getHomeDir() / ".local/bin/mazzy-settings", "--page", page])

proc hitStatus(x, bx, bw: float32): bool =
  bw > 8 and x >= bx - 6 and x < bx + bw + 6

proc showOsd(kind, pct: int, muted: bool) =
  ## Крупная подпись на время изменения. Пустая строка не рисуется.
  let text = osdText(kind, pct, muted)
  if text.len == 0: return
  A.osdKind = kind
  A.osdPct = pctClamp(pct)
  A.osdMuted = muted
  A.osdUntil = now() + 1.4
  if text != A.osdFor:
    A.osdFor = text
    A.osdTex.free()
    A.osdTex = textTex(text, "Inter Semi-Bold 22", 280)
  if A.osd.layer == nil:
    createSurf(A.osd, "mazzy-osd", ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, ZWLR_KB_NONE, false,
               0, 0, 320, 84)
  elif A.osd.configured:
    requestFrame(A.osd)

proc bumpVolume(up: bool) =
  let t = now()
  if t - A.volScrollAt < 0.12: return
  A.volScrollAt = t
  if up:
    spawn(@["wpctl", "set-volume", "-l", "1", "@DEFAULT_AUDIO_SINK@", "5%+"])
  else:
    spawn(@["wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%-"])
  let heard = volumeParts(A.volFor)
  if A.sheetKind == 1 and not A.sheetDrag:
    A.sheetPct = pctClamp(A.sheetPct + (if up: 5 else: -5))
    A.sheetKey = ""
    if A.sheet.layer != nil: requestFrame(A.sheet)
    showOsd(1, A.sheetPct, A.sheetMuted)
  elif heard.muted:
    showOsd(1, 0, true)
  elif heard.pct >= 0:
    showOsd(1, pctClamp(heard.pct + (if up: 5 else: -5)), false)
  A.statusAt = 0

proc applyBacklight(dev: string, pct: int): bool =
  ## Ждём короткий ответ logind. setsid здесь не нужен: код brightnessctl молча терялся.
  let cmd = backlightCommand(dev, pct)
  if cmd.len == 0: return false
  let args = backlightBusArgs(dev, backlightAbs(pct, backlightMax(dev)))
  try:
    let p = startProcess(args[0], args = args[1 .. ^1], options = {poUsePath, poStdErrToStdOut})
    try:
      result = waitForExit(p, 1000) == 0
    finally:
      close(p)
  except CatchableError:
    result = false
  if result: return
  try:
    let p = startProcess("brightnessctl", args = ["-d", dev, "set", $pctClamp(pct) & "%"],
                         options = {poUsePath, poStdErrToStdOut})
    try:
      result = waitForExit(p, 1000) == 0
    finally:
      close(p)
  except CatchableError:
    result = false

proc noteBright(ok: bool) =
  A.sheetFail = not ok
  if not ok: A.sheetName = "Нет права на подсветку"
  elif A.sheetName == "Нет права на подсветку": A.sheetName = "Экран"
  A.sheetKey = ""

proc bumpBright(up: bool) =
  let t = now()
  if t - A.brScrollAt < 0.12: return
  A.brScrollAt = t
  let lamp = readBacklight()
  if lamp.dev.len == 0 or lamp.pct < 0: return
  let pct = pctClamp(lamp.pct + (if up: 5 else: -5))
  let ok = applyBacklight(lamp.dev, pct)
  A.brFor = ""
  if A.sheetKind == 2 and not A.sheetDrag:
    A.sheetPct = if ok: pct else: lamp.pct
    noteBright(ok)
    if A.sheet.layer != nil: requestFrame(A.sheet)
  if ok: showOsd(2, pct, false)
  A.statusAt = 0

proc shortLabel(s: string, n = 28): string =
  clipRunes(s, n)

proc reloadFace()
proc dockResize()
proc dockNow(): tuple[slot, icon, body, zone, row: int]
proc writeChrome(labels: bool, widgetId: string, widgetOn, touchWidget: bool,
                 touchOrder = false, order: seq[string] = @[], opacity = -1, style = "")
proc writeClockMode(mode: string)
proc previewOpacity(x: float32)
proc commitOpacity()
proc refreshChips()
proc faceOn(id: string): bool =
  if A.face.hasKey(id): A.face[id] else: widgetDefault(id)

proc menuKinds(): seq[int] =
  for r in A.menuRows: result.add r.kind

proc menuSheetH(): int =
  menuSheetHeight(menuKinds(), menuWide)

proc menuRowAt(x, y: float32): int =
  let wide = if A.sheet.w > 40: A.sheet.w else: menuWide
  menuHit(int(x), int(y), menuBoxes(menuKinds(), wide))

proc loadMenu()
proc readMedia(): string

proc loadSheet() =
  if A.sheetKind == 1:
    let (vout, vcode) = execCmdEx("wpctl get-volume @DEFAULT_AUDIO_SINK@", options = {poUsePath})
    let heard = if vcode == 0: wpctlVolume(vout) else: (pct: -1, muted: false)
    A.sheetPct = if heard.pct < 0: 0 else: pctClamp(heard.pct)
    A.sheetMuted = heard.muted
    let (outp, code) = execCmdEx("wpctl status", options = {poUsePath})
    let rows = if code == 0: parseSinks(outp) else: @[]
    A.sheetName = "Выход"
    A.sheetDev = ""
    A.sheetNextId = ""
    for row in rows:
      if row.current:
        A.sheetName = row.name
        A.sheetDev = row.id
    if rows.len > 1:
      let nxt = nextSink(rows)
      if nxt.id != A.sheetDev: A.sheetNextId = nxt.id
    A.sheetLine = ""
  elif A.sheetKind == 2:
    let lamp = readBacklight()
    A.sheetPct = if lamp.pct < 0: 0 else: lamp.pct
    A.sheetDev = lamp.dev
    A.sheetMuted = false
    A.sheetName = if lamp.dev.len == 0: "Нет подсветки" else: "Экран"
    A.sheetNextId = ""
    A.sheetLine = ""
  elif A.sheetKind == 3:
    let t = getTime().local
    let cal = calendarLines(t.year, ord(t.month), t.monthday, ord(t.weekday))
    A.sheetName = if cal.title.len == 0: "Дата" else: cal.title
    A.sheetLine = cal.sub
    A.sheetDev = ""
    A.sheetNextId = ""
    A.sheetMuted = false
    A.sheetPct = 0
  elif A.sheetKind == 4:
    let (outp, code) = execCmdEx("powerprofilesctl get", options = {poUsePath})
    let raw = if code == 0: outp.strip else: ""
    A.sheetDev = raw
    A.profRaw = raw
    A.sheetName = profileLabel(raw)
    if A.sheetName.len == 0: A.sheetName = "Нет профиля"
    A.sheetLine = "Профиль процессора. Сон — в листе сессии"
    A.sheetNextId = ""
    A.sheetMuted = false
  elif A.sheetKind == 6:
    let (outp, code) = execCmdEx("timeout 2 nmcli -t -f IN-USE,SSID,SIGNAL device wifi list", options = {poUsePath})
    A.listLines.setLen(0)
    if code == 0:
      for row in wifiRows(outp):
        if row.signal >= 0: A.listLines.add(row.ssid & "  " & $row.signal)
        else: A.listLines.add(row.ssid)
    A.sheetName = "Сети"
    A.sheetLine = if A.listLines.len == 0: "Список не прочитан" else: "Сигнал числом, без делений"
    A.sheetDev = ""
    A.sheetNextId = ""
    A.sheetMuted = false
  elif A.sheetKind == 7:
    let (outp, code) = execCmdEx("wpctl get-volume @DEFAULT_AUDIO_SOURCE@", options = {poUsePath})
    let heard = if code == 0: wpctlVolume(outp) else: (pct: -1, muted: false)
    A.listLines.setLen(0)
    if heard.pct >= 0:
      A.listLines.add(if heard.muted: "микрофон выключен" else: "микрофон " & $heard.pct & "%")
    else:
      A.listLines.add("микрофон не прочитан")
    A.listLines.add("камера не читалась")
    A.listLines.add("захват экрана не читался")
    A.sheetName = "Доступ"
    A.sheetLine = "Только то, что команда вернула"
    A.sheetDev = ""
    A.sheetNextId = ""
    A.sheetMuted = false
  elif A.sheetKind == 8:
    A.listLines.setLen(0)
    for line in A.clipHist: A.listLines.add line
    A.sheetName = "Буфер"
    A.sheetLine = if A.listLines.len == 0: "Записей нет" else: "Только после включения виджета"
    A.sheetDev = ""
    A.sheetNextId = ""
    A.sheetMuted = false
  elif A.sheetKind == 9:
    let (outp, code) = execCmdEx("timeout 1 makoctl list", options = {poUsePath})
    A.listLines.setLen(0)
    if code == 0:
      for line in notifyLines(outp, 6): A.listLines.add line
    A.sheetName = "Уведомления"
    if code != 0: A.sheetLine = "mako не ответил"
    elif A.listLines.len == 0: A.sheetLine = "Сейчас пусто"
    else: A.sheetLine = "Текущие, не история"
    A.sheetDev = ""
    A.sheetNextId = ""
    A.sheetMuted = false
  elif A.sheetKind == 10:
    A.listLines.setLen(0)
    A.sheetName = "Сессия"
    A.sheetLine = "Второй щелчок: сон, выход, выключение"
    A.sheetDev = ""
    A.powerArm = ""
    A.sheetNextId = ""
    A.sheetMuted = false
    A.sheetPct = 0
  elif A.sheetKind == 11:
    let line = readMedia()
    A.listLines.setLen(0)
    A.sheetName = if line.len == 0: "Нет плеера" else: shortLabel(line, 36)
    A.sheetLine = if line.len == 0: "playerctl не видит плеер" else: "Назад, пауза, дальше"
    A.sheetDev = if line.len == 0: "" else: "on"
    A.sheetNextId = ""
    A.sheetMuted = false
    A.sheetPct = 0
  else:
    loadMenu()
    A.sheetName = "Меню"
    A.sheetLine = if A.menuQuery.len == 0: "поиск" else: A.menuQuery
    A.sheetDev = ""
    A.sheetNextId = ""
    A.sheetMuted = false
  A.sheetKey = ""

proc applySheet(pct: int, force: bool) =
  A.sheetPct = pctClamp(pct)
  A.sheetKey = ""
  if A.sheet.layer != nil: requestFrame(A.sheet)
  let t = now()
  if not force and t - A.sheetApplyAt < 0.08: return
  A.sheetApplyAt = t
  if A.sheetKind == 1:
    if A.sheetMuted:
      spawn(@["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "0"])
      A.sheetMuted = false
    spawn(@["wpctl", "set-volume", "-l", "1", "@DEFAULT_AUDIO_SINK@", $A.sheetPct & "%"])
    A.volFor = ""
    showOsd(1, A.sheetPct, false)
  elif A.sheetKind == 2 and A.sheetDev.len > 0:
    let ok = applyBacklight(A.sheetDev, A.sheetPct)
    noteBright(ok)
    if not ok: A.sheetPct = readBacklight().pct
    if A.sheetPct < 0: A.sheetPct = 0
    A.brFor = ""
    if ok: showOsd(2, A.sheetPct, false)
  A.statusAt = 0

proc closeSheet() =
  A.sheetDrag = false
  A.leaveAt = 0
  A.powerArm = ""
  A.menuQuery = ""
  A.sheetKind = 0
  if A.sheet.layer != nil: destroySurf(A.sheet)
  if A.scrim.layer != nil: destroySurf(A.scrim)

proc openScrim() =
  if A.scrim.layer != nil: destroySurf(A.scrim)
  createSurf(A.scrim, "mazzy-scrim", ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, ZWLR_KB_NONE, true,
             ZWLR_ANCHOR_ALL, 0, 0, 0)

proc recentPath(): string =
  getEnv("XDG_STATE_HOME", getHomeDir() / ".local/state") / "mazzy" / "recent"

proc rememberLaunch(id: string) =
  var ids: seq[string]
  try:
    for line in readFile(recentPath()).splitLines:
      let t = line.strip
      if t.len > 0 and t != id: ids.add t
  except CatchableError, OSError:
    discard
  var next = @[id]
  for old in ids:
    if next.len >= 6: break
    next.add old
  try:
    createDir(recentPath().splitPath.head)
    writeFile(recentPath(), next.join("\n") & "\n")
  except CatchableError, OSError:
    discard

proc freeMenuRows() =
  for r in A.menuRows.mitems:
    r.tex.free()
    r.hintTex.free()
    r.icon.free()
  A.menuRows.setLen(0)

proc pushMenu(kind: int, id, title, iconPath, hint: string, on: bool) =
  A.menuRows.add MenuRow(kind: kind, id: id, title: title, iconPath: iconPath, hint: hint, on: on)

proc chipText(key: string): string =
  for i, k in A.chipKey:
    if k == key and A.chipFor[i].len > 0: return A.chipFor[i]
  ""

proc readBt(): string =
  let have = chipText("bluetooth")
  if have.len > 0: return have
  let (outp, code) = execCmdEx("timeout 1 rfkill list bluetooth", options = {poUsePath})
  if code != 0: return ""
  let st = rfkillSoft(outp, "bluetooth")
  if st < 0: ""
  elif st == 1: "bt выкл"
  else: "bt"

proc readDnd(): string =
  let have = chipText("dnd")
  if have.len > 0: return have
  if findExe("makoctl").len == 0: return ""
  let (outp, code) = execCmdEx("timeout 1 makoctl mode", options = {poUsePath})
  if code != 0: return ""
  let mode = dndOn(outp)
  if mode < 0: ""
  elif mode == 1: "тихо"
  else: "уведом"

proc readMedia(): string =
  let have = chipText("media")
  if have.len > 0: return have
  if findExe("playerctl").len == 0: return ""
  let (outp, code) = execCmdEx("timeout 1 playerctl metadata --format '{{artist}} - {{title}}'", options = {poUsePath})
  if code != 0: "" else: mediaLine(outp)

proc menuGlyph(id, hint: string): string =
  let name = case id
    of "volume":
      if A.volIconFor.len > 0: A.volIconFor else: volumeIconName(40, false)
    of "brightness": brightIconName()
    of "network":
      if A.netIconFor.len > 0: A.netIconFor else: networkIconName(A.netFor == "сеть")
    of "bluetooth":
      if "выкл" in hint: "bluetooth-disabled-symbolic" else: "bluetooth-active-symbolic"
    of "mic": micIconName("выкл" in hint)
    of "profile":
      if A.profIconFor.len > 0: A.profIconFor else: profileIconName("balanced")
    of "dnd":
      if "тихо" in hint: "notifications-disabled-symbolic" else: "notifications-symbolic"
    of "media": "media-playback-start-symbolic"
    of "media-prev": "media-skip-backward-symbolic"
    of "media-next": "media-skip-forward-symbolic"
    of "edit", "edit-reset": "document-edit-symbolic"
    of "edit-center": "go-previous-symbolic"
    of "edit-edge": "go-next-symbolic"
    of "style": "preferences-color-symbolic"
    of "fade": "view-restore-symbolic"
    of "battery":
      if A.batIconFor.len > 0: A.batIconFor else: batteryIconName(50, false)
    of "vpn": "network-vpn-symbolic"
    of "notify": "notifications-symbolic"
    of "shot": "camera-photo-symbolic"
    of "clip": "edit-paste-symbolic"
    of "session": "system-lock-screen-symbolic"
    of "settings": "preferences-system-symbolic"
    of "labels": "insert-text-symbolic"
    of "privacy": "security-high-symbolic"
    of "all": "system-search-symbolic"
    of "desks": "preferences-desktop-workspace-symbolic"
    of "clock": "preferences-system-time-symbolic"
    of "layout": "input-keyboard-symbolic"
    of "tray": "view-grid-symbolic"
    of "load", "cpu": "utilities-system-monitor-symbolic"
    of "mem": "drive-harddisk-symbolic"
    of "netio": "network-transmit-receive-symbolic"
    of "scale": "preferences-desktop-display-symbolic"
    else: ""
  if name.len == 0: "" else: themeIcon(name)

proc widgetLive(id: string): string =
  case id
  of "volume": A.volFor
  of "brightness": A.brFor
  of "battery": A.batFor
  of "network": A.netFor
  of "mic": A.micFor
  of "profile": A.profFor
  of "vpn": A.vpnFor
  of "layout": A.layoutFor
  of "clock": A.clockFor
  of "desks":
    if A.wsId > 0: "стол " & $A.wsId else: ""
  of "tray":
    if A.trayTex.len > 0: $A.trayTex.len else: ""
  of "dnd", "bluetooth", "media", "load", "cpu", "mem", "netio", "shot", "clip", "session", "scale":
    chipText(id)
  else: ""

proc fitMenuSheet() =
  if A.sheet.layer == nil or A.sheetKind != 5: return
  let h = uint32(menuSheetH())
  let w = uint32(menuWide)
  if A.sheet.w == int(w) and A.sheet.h == int(h): return
  zwlr_layer_surface_v1_set_size(A.sheet.layer, w, h)
  wl_surface_commit(A.sheet.surface)

proc fitRows() =
  var slots: seq[MenuSlot]
  for r in A.menuRows: slots.add MenuSlot(kind: r.kind, id: r.id)
  let kept = menuFit(slots, menuWide, 920)
  if kept.len == A.menuRows.len: return
  var take = newSeq[bool](A.menuRows.len)
  var k = 0
  for i, r in A.menuRows:
    if k < kept.len and r.kind == kept[k].kind and r.id == kept[k].id:
      take[i] = true
      inc k
  if k != kept.len: return
  var next: seq[MenuRow]
  for i, r in A.menuRows.mpairs:
    if take[i]: next.add r
    else:
      r.tex.free()
      r.hintTex.free()
      r.icon.free()
  A.menuRows = next

proc loadControl() =
  let status = menuStatusLine(A.layoutFor, getEnv("USER"))
  if status.len > 0:
    pushMenu(mkHead, "", status, "", "", false)
  pushMenu(mkHead, "", "Сейчас", "", "", false)
  var live: MenuLive
  live.volume = A.volFor
  live.brightness = A.brFor
  live.network = A.netFor
  live.bluetooth = readBt()
  live.mic = A.micFor
  live.profile = A.profFor
  live.dnd = readDnd()
  live.media = readMedia()
  live.battery = A.batFor
  live.vpn = A.vpnFor
  live.notify = findExe("makoctl").len > 0
  live.session = true
  live.shot = findExe("grim").len > 0
  live.clip = faceOn("clip")
  var band = false
  for tile in controlTiles(live):
    if tile.id in ["media-prev", "media", "media-next"]:
      if not band:
        pushMenu(mkHead, "", "Плеер", "", "", false)
        band = true
      pushMenu(mkBand, tile.id, tile.title, menuGlyph(tile.id, tile.hint), "", false)
    else:
      pushMenu(mkTile, tile.id, tile.title, menuGlyph(tile.id, tile.hint), tile.hint, tileHot(tile.id, tile.hint))
  pushMenu(mkHead, "", "Оболочка", "", "", false)
  let lab = if A.faceLabels: "Подписи: вкл" else: "Подписи: выкл"
  pushMenu(mkAct, "style", "Стиль: " & styleTitle(A.faceStyle), menuGlyph("style", ""), "", false)
  pushMenu(mkSlide, "fade", "Плотность " & $A.faceOpacity & "%", menuGlyph("fade", ""), "", false)
  pushMenu(mkAct, "settings", "Настройки", menuGlyph("settings", ""), "", false)
  pushMenu(mkAct, "labels", lab, menuGlyph("labels", ""), "", A.faceLabels)
  pushMenu(mkAct, "privacy", "Доступ", menuGlyph("privacy", ""), "", false)

proc loadApps(q: string) =
  var recentRows: seq[MenuPick]
  try:
    for line in readFile(recentPath()).splitLines:
      let id = line.strip
      if id.len == 0: continue
      let df = findDesktopFile(id, desktopSearchDirs())
      if df.len == 0: continue
      let text = try: readFile(df) except CatchableError, OSError: ""
      let title = desktopValue(text, "Name")
      if title.len == 0: continue
      if q.len > 0 and q notin foldSearch(title): continue
      var icon = appIconPath(desktopValue(text, "Icon"), iconSearchRoots())
      if icon.len == 0: icon = themeIcon(desktopValue(text, "Icon"))
      recentRows.add MenuPick(id: id, name: title, icon: icon, group: "Недавние")
      if recentRows.len >= 4: break
  except CatchableError, OSError:
    discard
  if recentRows.len > 0:
    pushMenu(mkHead, "", "Недавние", "", "", false)
    for row in recentRows:
      pushMenu(mkApp, row.id, row.name, row.icon, "", false)
  var rows: seq[MenuPick]
  var seen: seq[string]
  for d in desktopSearchDirs():
    for kind, path in walkDir(d):
      if kind != pcFile or not path.endsWith(".desktop"): continue
      let text = try: readFile(path)
                 except IOError, OSError: continue
      if desktopValue(text, "NoDisplay").toLowerAscii == "true": continue
      if desktopValue(text, "Hidden").toLowerAscii == "true": continue
      let name = desktopValue(text, "Name")
      if name.len == 0: continue
      var id = path.splitPath.tail
      if id.endsWith(".desktop"): id = id[0 .. ^9]
      if id.len == 0 or id in seen: continue
      seen.add id
      let iconName = desktopValue(text, "Icon")
      var icon = appIconPath(iconName, iconSearchRoots())
      if icon.len == 0: icon = themeIcon(iconName)
      rows.add MenuPick(id: id, name: name, icon: icon, group: menuGroupOf(desktopValue(text, "Categories")))
  rows.sort(proc(a, b: MenuPick): int = cmp(a.group, b.group))
  var shown = 0
  let cap = menuAppCap(q)
  var lastGroup = ""
  var headerAt = -1
  for row in rows:
    if q.len > 0 and q notin foldSearch(row.name) and q notin foldSearch(row.group): continue
    if shown >= cap: break
    if row.group != lastGroup:
      if headerAt >= 0 and headerAt == A.menuRows.len - 1 and A.menuRows[headerAt].kind == mkHead:
        discard A.menuRows.pop()
      pushMenu(mkHead, "", row.group, "", "", false)
      headerAt = A.menuRows.len - 1
      lastGroup = row.group
    pushMenu(mkApp, row.id, row.name, row.icon, "", false)
    shown += 1
  if shown == 0 and recentRows.len == 0:
    pushMenu(mkHead, "", "Ничего не найдено", "", "", false)
  pushMenu(mkAct, "all", "Все приложения", menuGlyph("all", ""), "", false)

proc loadWidgets(q: string) =
  let editing = if A.editOn: "Правка: вкл" else: "Правка: выкл"
  pushMenu(mkAct, "edit", editing, menuGlyph("edit", ""), "", A.editOn)
  if A.editOn:
    pushMenu(mkAct, "edit-center", "К центру", menuGlyph("edit-center", ""), "", false)
    pushMenu(mkAct, "edit-edge", "К краю", menuGlyph("edit-edge", ""), "", false)
    pushMenu(mkAct, "edit-reset", "Порядок сначала", menuGlyph("edit-reset", ""), "", false)
    pushMenu(mkHead, "", "Столы и часы остаются", "", "", false)
    var nEdit = 0
    for i, id in A.faceOrder:
      let meta = widgetMeta(id)
      if meta.title.len == 0: continue
      if q.len > 0 and q notin foldSearch(meta.title): continue
      let mark = $(i + 1) & " · " & widgetMark(faceOn(id), widgetLive(id))
      pushMenu(mkWidget, id, meta.title, menuGlyph(id, ""), mark, id == A.editPick)
      nEdit += 1
    if nEdit == 0:
      pushMenu(mkHead, "", "Нет таких виджетов", "", "", false)
    return
  var n = 0
  for group in ["Панель", "Службы", "Система"]:
    var ids: seq[string]
    for id in widgetIds():
      let meta = widgetMeta(id)
      if meta.group != group or meta.title.len == 0: continue
      if q.len > 0 and q notin foldSearch(meta.title) and q notin foldSearch(group): continue
      ids.add id
    if ids.len == 0: continue
    pushMenu(mkHead, "", group, "", "", false)
    for id in ids:
      let meta = widgetMeta(id)
      let on = faceOn(id)
      pushMenu(mkWidget, id, meta.title, menuGlyph(id, ""), widgetMark(on, widgetLive(id)), on)
      n += 1
  if n == 0:
    pushMenu(mkHead, "", "Нет таких виджетов", "", "", false)

proc loadMenu() =
  freeMenuRows()
  let rawQ = A.menuQuery.strip
  let q = foldSearch(rawQ)
  let tab = if rawQ.len > 0 and A.menuTab != 2: 1 else: A.menuTab
  pushMenu(mkTab, "tab:0", "Управление", "", "", tab == 0)
  pushMenu(mkTab, "tab:1", "Приложения", "", "", tab == 1)
  pushMenu(mkTab, "tab:2", "Виджеты", "", "", tab == 2)
  let searchTitle = if rawQ.len == 0: "Поиск" else: rawQ
  pushMenu(mkSearch, "search", searchTitle, "", "", false)
  if tab == 2: loadWidgets(q)
  elif tab == 1: loadApps(q)
  else: loadControl()
  fitRows()
  if A.sheet.layer != nil and A.sheetKind == 5: fitMenuSheet()

proc openSheet(kind: int) =
  if A.sheet.layer != nil and A.sheetKind == kind:
    closeSheet()
    return
  if A.sheet.layer != nil: destroySurf(A.sheet)
  if A.scrim.layer != nil: destroySurf(A.scrim)
  A.sheetKind = kind
  A.sheetDrag = false
  A.leaveAt = 0
  A.powerArm = ""
  A.sheetFail = false
  loadSheet()
  openScrim()
  let corner = ZWLR_ANCHOR_TOP or ZWLR_ANCHOR_RIGHT
  if kind == 2:
    createSurf(A.sheet, "mazzy-sheet", ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, ZWLR_KB_NONE, true,
               corner, 0, 360, 228, 0, 44, 12)
  elif kind == 3:
    createSurf(A.sheet, "mazzy-sheet", ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, ZWLR_KB_NONE, true,
               ZWLR_ANCHOR_TOP, 0, uint32(clockSheetW()), uint32(clockSheetH()), 0, 44)
  elif kind == 4:
    createSurf(A.sheet, "mazzy-sheet", ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, ZWLR_KB_NONE, true,
               corner, 0, 300, 230, 0, 44, 12)
  elif kind == 5:
    createSurf(A.sheet, "mazzy-sheet", ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, ZWLR_KB_EXCLUSIVE, true,
               ZWLR_ANCHOR_TOP or ZWLR_ANCHOR_LEFT, 0, uint32(menuWide), uint32(menuSheetH()), 0, 44, 0, 12)
  elif kind == 10:
    createSurf(A.sheet, "mazzy-sheet", ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, ZWLR_KB_NONE, true,
               corner, 0, 440, 268, 0, 44, 12)
  elif kind == 11:
    createSurf(A.sheet, "mazzy-sheet", ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, ZWLR_KB_NONE, true,
               corner, 0, 420, 210, 0, 44, 12)
  elif kind == 6 or kind == 7 or kind == 8 or kind == 9:
    let rows = max(1, A.listLines.len)
    let h = uint32(min(520, 72 + rows * 28))
    createSurf(A.sheet, "mazzy-sheet", ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, ZWLR_KB_NONE, true,
               ZWLR_ANCHOR_TOP or ZWLR_ANCHOR_RIGHT, 0, 360, h, 0, 44, 12)
  else:
    createSurf(A.sheet, "mazzy-sheet", ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, ZWLR_KB_NONE, true,
               corner, 0, 304, 176, 0, 44, 12)

proc openMenu(which: int) =
  ## 0 — управление, 1 — приложения, 2 — виджеты. Тот же раздел второй раз закрывает лист.
  let tab = if which in 0 .. 2: which else: 0
  if A.sheet.layer != nil and A.sheetKind == 5 and A.menuTab == tab and A.menuQuery.len == 0:
    closeSheet()
    return
  A.menuTab = tab
  A.menuQuery = ""
  if A.sheet.layer != nil and A.sheetKind == 5:
    loadMenu()
    A.sheetKey = ""
    requestFrame(A.sheet)
    return
  openSheet(5)

proc setProfile(id: string) =
  if id notin ProfileIds: return
  spawn(@["powerprofilesctl", "set", id])
  A.profRaw = id
  A.profFor = ""
  A.sheetDev = id
  A.sheetName = profileLabel(id)
  A.sheetKey = ""
  A.statusAt = 0
  requestFrame(A.bar)
  if A.sheet.layer != nil: requestFrame(A.sheet)

proc sheetStep(delta: int) =
  applySheet(A.sheetPct + delta, true)

proc sheetToggleMute() =
  spawn(@["wpctl", "set-mute", "@DEFAULT_AUDIO_SINK@", "toggle"])
  A.sheetMuted = not A.sheetMuted
  A.sheetKey = ""
  A.volFor = ""
  A.statusAt = 0
  if A.sheet.layer != nil: requestFrame(A.sheet)

proc sheetNextOutput() =
  if A.sheetNextId.len == 0: return
  spawn(@["wpctl", "set-default", A.sheetNextId])
  loadSheet()
  if A.sheet.layer != nil: requestFrame(A.sheet)

proc layoutBright(w: float32)

proc onSheet(x, y, bx, by, bw, bh: float32): bool =
  bw > 4 and bh > 4 and x >= bx and x < bx + bw and y >= by and y < by + bh

proc powerPress(id: string) =
  let step = powerStep(A.powerArm, id)
  if not step.fire:
    A.powerArm = step.arm
    A.sheetDev = step.arm
    A.sheetLine = "Ещё раз, чтобы подтвердить"
    A.sheetKey = ""
    if A.sheet.layer != nil: requestFrame(A.sheet)
    return
  let gate = sessionAct(id, getEnv("XDG_SESSION_ID"))
  if not gate.go:
    A.powerArm = ""
    A.sheetDev = ""
    A.sheetLine = if gate.note.len > 0: gate.note else: "Команда не запущена"
    A.sheetKey = ""
    if A.sheet.layer != nil: requestFrame(A.sheet)
    return
  let act = id
  closeSheet()
  case act
  of "lock":
    spawn(@["swaylock", "-f", "-i", getHomeDir() / "Pictures/Wallpapers/mazzy-09-lab.jpg"])
  of "logout":
    let sid = getEnv("XDG_SESSION_ID")
    if sid.len > 0: spawn(@["loginctl", "terminate-session", sid])
  of "sleep":
    spawn(@["systemctl", "suspend"])
  of "off":
    spawn(@["systemctl", "poweroff"])
  else: discard

proc sheetPress(x, y: float32, down: bool) =
  if A.sheetKind == 11:
    if down: return
    if A.sheetDev.len == 0: return
    let w = A.sheet.w.float32
    const cmds = ["previous", "play-pause", "next"]
    for i, cmd in cmds:
      let ry = 72'f32 + i.float32 * 44
      if onSheet(x, y, 16, ry, w - 32, 40):
        spawn(@["playerctl", cmd])
        A.statusAt = 0
        return
    return
  if A.sheetKind == 10:
    if down: return
    const ids = ["lock", "logout", "sleep", "off"]
    let w = A.sheet.w.float32
    for i, id in ids:
      let ry = 72'f32 + i.float32 * 44
      if onSheet(x, y, 16, ry, w - 32, 40):
        powerPress(id)
        return
    return
  if A.sheetKind == 3:
    if down: return
    let id = dashIdAt(x, y, A.sheet.w.float32)
    if id in ["time", "date", "hands"]:
      writeClockMode(id)
      loadSheet()
      A.sheetKey = ""
      requestFrame(A.sheet)
      requestFrame(A.bar)
    elif id == "settings":
      closeSheet()
      openSettings("face")
    elif id in ["lock", "logout", "sleep", "off"]:
      powerPress(id)
    return
  if A.sheetKind >= 6:
    return
  if A.sheetKind == 4:
    if down: return
    let w = A.sheet.w.float32
    for i, id in ProfileIds:
      let ry = 78'f32 + i.float32 * 48
      if onSheet(x, y, 16, ry, w - 32, 40):
        setProfile(id)
        return
    return
  if A.sheetKind == 5:
    if not down and A.sheetDrag:
      A.sheetDrag = false
      previewOpacity(x)
      commitOpacity()
      return
    let hit = menuRowAt(x, y)
    if hit >= 0 and hit < A.menuRows.len and A.menuRows[hit].kind == mkSlide:
      let boxes = menuBoxes(menuKinds(), if A.sheet.w > 40: A.sheet.w else: menuWide)
      if hit < boxes.len:
        A.trackX = boxes[hit].x.float32 + 12
        A.trackW = max(20'f32, boxes[hit].w.float32 - 24)
      if down:
        A.sheetDrag = true
        previewOpacity(x)
        return
      previewOpacity(x)
      commitOpacity()
      return
    if down: return
    if hit < 0 or hit >= A.menuRows.len: return
    let row = A.menuRows[hit]
    if row.kind == mkHead or row.kind == mkSearch: return
    let tab = menuTabOf(row.id)
    if tab >= 0:
      A.menuTab = tab
      A.menuQuery = ""
      loadMenu()
      A.sheetKey = ""
      requestFrame(A.sheet)
      return
    case row.id
    of "settings":
      closeSheet()
      openSettings("face")
    of "labels":
      writeChrome(not A.faceLabels, "", false, false)
      loadMenu()
      A.sheetKey = ""
      requestFrame(A.sheet)
    of "style":
      writeChrome(A.faceLabels, "", false, false, style = styleCycle(A.faceStyle))
      loadMenu()
      A.sheetKey = ""
      requestFrame(A.sheet)
    of "fade":
      discard
    of "edit":
      A.editOn = not A.editOn
      if A.editOn and A.editPick.len == 0 and A.faceOrder.len > 0:
        A.editPick = A.faceOrder[0]
      loadMenu()
      A.sheetKey = ""
      requestFrame(A.bar)
      requestFrame(A.sheet)
    of "edit-center", "edit-edge":
      if A.editPick.len == 0: return
      let dir = if row.id == "edit-center": 1 else: -1
      let next = orderMove(A.faceOrder, A.editPick, dir)
      writeChrome(A.faceLabels, "", false, false, true, next)
      loadMenu()
      A.sheetKey = ""
      requestFrame(A.sheet)
    of "edit-reset":
      writeChrome(A.faceLabels, "", false, false, true, widgetRightIds())
      loadMenu()
      A.sheetKey = ""
      requestFrame(A.sheet)
    of "media-prev":
      spawn(@["playerctl", "previous"])
      A.statusAt = 0
    of "media-next":
      spawn(@["playerctl", "next"])
      A.statusAt = 0
    of "media":
      spawn(@["playerctl", "play-pause"])
      A.statusAt = 0
    of "privacy":
      openSheet(7)
    of "volume":
      openSheet(1)
    of "brightness":
      openSheet(2)
    of "network":
      openSheet(6)
    of "profile":
      openSheet(4)
    of "notify":
      openSheet(9)
    of "session":
      openSheet(10)
    of "clip":
      openSheet(8)
    of "battery", "vpn":
      closeSheet()
      openSettings("system")
    of "bluetooth":
      spawn(@["rfkill", "toggle", "bluetooth"])
      let next = flipBtHint(row.hint)
      if next.len > 0:
        A.menuRows[hit].hint = next
        A.menuRows[hit].on = tileHot("bluetooth", next)
        A.menuRows[hit].iconPath = menuGlyph("bluetooth", next)
        A.sheetKey = ""
        requestFrame(A.sheet)
      A.statusAt = 0
    of "dnd":
      spawn(@["makoctl", "mode", "-t", "do-not-disturb"])
      let next = flipDndHint(row.hint)
      if next.len > 0:
        A.menuRows[hit].hint = next
        A.menuRows[hit].on = tileHot("dnd", next)
        A.menuRows[hit].iconPath = menuGlyph("dnd", next)
        A.sheetKey = ""
        requestFrame(A.sheet)
      A.statusAt = 0
    of "mic":
      spawn(@["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"])
      A.micFor = ""
      A.micIconFor = ""
      let next = flipMicHint(row.hint)
      if next.len > 0:
        A.menuRows[hit].hint = next
        A.menuRows[hit].on = tileHot("mic", next)
        A.menuRows[hit].iconPath = menuGlyph("mic", next)
        A.sheetKey = ""
        requestFrame(A.sheet)
      A.statusAt = 0
    of "shot":
      let dir = getHomeDir() / "Pictures"
      createDir(dir)
      let name = "mazzy-" & format(getTime().local, "yyyyMMdd-HHmmss") & ".png"
      spawn(@["grim", dir / name])
      closeSheet()
    of "all":
      closeSheet()
      spawn(@["fuzzel"])
    else:
      if row.kind == mkWidget:
        if A.editOn and row.id in widgetRightIds():
          A.editPick = row.id
          loadMenu()
          A.sheetKey = ""
          requestFrame(A.bar)
          requestFrame(A.sheet)
        else:
          writeChrome(A.faceLabels, row.id, not faceOn(row.id), true)
          loadMenu()
          A.sheetKey = ""
          requestFrame(A.sheet)
      elif row.kind == mkApp and row.id.len > 0:
        let id = row.id
        closeSheet()
        rememberLaunch(id)
        spawn(@["gtk-launch", id])
    return
  let onTrack = onSheet(x, y, A.trackX - 8, A.trackY - 10, A.trackW + 16, A.trackH + 20)
  if down:
    if onTrack:
      A.sheetDrag = true
      applySheet(sliderPct(x, A.trackX, A.trackW), false)
    return
  let dragged = A.sheetDrag
  A.sheetDrag = false
  if dragged or onTrack:
    applySheet(sliderPct(x, A.trackX, A.trackW), true)
    return
  if A.sheetKind == 2:
    layoutBright(A.sheet.w.float32)
    for i in 0 .. 3:
      if onSheet(x, y, A.presetX[i], A.chipY, A.chipW, A.chipH):
        applySheet(BrightPresets[i], true)
        return
  elif onSheet(x, y, A.chipX, A.chipY, A.chipW, A.chipH):
    sheetToggleMute()
  elif onSheet(x, y, A.chip2X, A.chipY, A.chip2W, A.chipH):
    sheetNextOutput()

proc paintChrome(s: var Surf, body: proc(), clearA: float32 = 1,
                  clearC: (float32, float32, float32) = (0.11'f32, 0.09'f32, 0.08'f32))

proc layoutBright(w: float32) =
  A.trackX = 18
  A.trackW = w - 36
  A.trackY = 96
  A.trackH = 36
  A.chipY = 156
  A.chipH = 52
  let gap = 10'f32
  A.chipW = (w - 32 - gap * 3) / 4
  for i in 0 .. 3:
    A.presetX[i] = 16 + i.float32 * (A.chipW + gap)

proc paintSheetText() =
  let chip1 = if A.sheetKind == 1: (if A.sheetMuted: "Включить" else: "Выключить") else: ""
  let chip2 = if A.sheetKind == 1: (if A.sheetNextId.len == 0: "Один выход" else: "Другой выход") else: ""
  var key = $A.sheetKind & "|" & $A.sheetPct & "|" & $A.sheetMuted & "|" & $A.sheetFail & "|" &
    A.sheetName & "|" & A.sheetLine & "|" & A.sheetDev & "|" & chip1 & "|" & chip2
  if A.sheetKind == 5:
    for r in A.menuRows: key.add "|" & r.id & r.title & r.hint & $r.on
  elif A.sheetKind == 3:
    let t = getTime().local
    key.add "|" & clockCaption("time", t.hour, t.minute, t.monthday, ord(t.month))
    key.add "|" & A.faceClock & "|" & A.powerArm
  elif A.sheetKind >= 6:
    key.add "|" & A.listLines.join("|")
  if key == A.sheetKey: return
  A.sheetKey = key
  A.sheetTitle.free(); A.sheetValue.free(); A.sheetSub.free(); A.sheetChip.free(); A.sheetChip2.free()
  for i in 0 .. 3: A.sheetPreset[i].free()
  for t in A.menuTex.mitems: t.free()
  A.menuAll.free()
  for r in A.menuRows.mitems:
    r.tex.free()
    r.hintTex.free()
    r.icon.free()
  for t in A.listTex.mitems: t.free()
  A.listTex.setLen(0)
  let title = case A.sheetKind
    of 1: "Звук"
    of 2: "Яркость"
    of 3: ""
    of 4: "Питание"
    of 5: ""
    of 6: "Сети"
    of 7: "Доступ"
    of 8: "Буфер"
    of 9: "Уведомления"
    of 10: "Сессия"
    of 11: "Медиа"
    else: ""
  var titleText = title
  if A.sheetKind == 3:
    let t = getTime().local
    titleText = clockCaption("time", t.hour, t.minute, t.monthday, ord(t.month))
  if titleText.len > 0:
    let face = if A.sheetKind == 3: "Inter Semi-Bold 28" else: "Inter Semi-Bold 16"
    let wide = if A.sheetKind == 3: 420 else: 220
    A.sheetTitle = textTex(titleText, face, wide)
  if A.sheetKind == 2:
    A.sheetValue = textTex($A.sheetPct & "%", "Inter Semi-Bold 22", 110)
  elif A.sheetKind == 1:
    A.sheetValue = textTex($A.sheetPct & "%", "Inter 13", 70)
  if A.sheetKind == 3:
    let dateLine = if A.sheetName.len > 0 and A.sheetLine.len > 0: A.sheetName & "  ·  " & A.sheetLine
                   elif A.sheetName.len > 0: A.sheetName
                   else: A.sheetLine
    A.sheetSub = textTex(dateLine, "Inter 14", 420, 0.85)
  elif A.sheetKind == 10:
    A.sheetSub = textTex(A.sheetLine, "Inter 12", 400, 0.75)
  elif A.sheetKind == 4:
    A.sheetSub = textTex(A.sheetLine, "Inter 12", 280, 0.75)
  else:
    let sub = if A.sheetFail: "Нет права на подсветку"
              elif A.sheetKind >= 6: shortLabel(A.sheetLine, 42)
              else: shortLabel(A.sheetName)
    A.sheetSub = textTex(sub, "Inter 12", 300, 0.75)
  if A.sheetKind == 1:
    A.sheetChip = textTex(chip1, "Inter 12", 120)
    A.sheetChip2 = textTex(chip2, "Inter 12", 120)
  elif A.sheetKind == 2:
    for i, p in BrightPresets:
      A.sheetPreset[i] = textTex($p & "%", "Inter 14", 80)
  elif A.sheetKind == 10:
    const ids = ["lock", "logout", "sleep", "off"]
    const names = ["Заблокировать", "Выйти", "Сон", "Выключить"]
    for i, id in ids:
      let label = if A.powerArm == id: "Ещё раз: " & names[i] else: names[i]
      A.sheetPreset[i] = textTex(label, "Inter 14", 380)
  elif A.sheetKind == 3:
    A.sheetPreset[0] = textTex("Время", "Inter 13", 120)
    A.sheetPreset[1] = textTex("С датой", "Inter 13", 120)
    A.sheetPreset[2] = textTex("Стрелки", "Inter 13", 120)
    A.sheetPreset[3] = textTex("Настройки", "Inter 13", 140)
    for name in ["пн", "вт", "ср", "чт", "пт", "сб", "вс"]:
      A.listTex.add textTex(name, "Inter 11", 48, 0.7)
    for d in 1 .. 31:
      A.listTex.add textTex($d, "Inter 12", 40)
    const names = ["Заблокировать", "Выйти", "Сон", "Выключить"]
    const ids = ["lock", "logout", "sleep", "off"]
    for i, id in ids:
      let label = if A.powerArm == id: "Ещё раз: " & names[i] else: names[i]
      A.listTex.add textTex(label, "Inter 14", 380)
  elif A.sheetKind == 11 and A.sheetDev.len > 0:
    const names = ["Назад", "Пауза", "Дальше"]
    for i, name in names:
      A.sheetPreset[i] = textTex(name, "Inter 14", 360)
  elif A.sheetKind == 4:
    for i, id in ProfileIds:
      A.sheetPreset[i] = textTex(profileLabel(id), "Inter 14", 180)
  elif A.sheetKind == 5:
    let boxes = menuBoxes(menuKinds(), menuWide)
    for i, r in A.menuRows.mpairs:
      let bw = if i < boxes.len: boxes[i].w else: 160
      if r.kind == mkHead:
        r.tex = textTex(r.title, "Inter Semi-Bold 11", max(8, bw), 1.0, 0)
      elif r.kind == mkTab:
        r.tex = textTex(r.title, "Inter Semi-Bold 13", max(8, bw))
      elif r.kind == mkSearch:
        r.tex = textTex(r.title, "Inter 13", max(8, bw - 24), 0.85, 0)
      elif r.kind == mkTile:
        let tw = max(8, bw - 48)
        r.tex = textTex(r.title, "Inter Semi-Bold 13", tw, 1.0, 0)
        if r.hint.len > 0:
          r.hintTex = textTex(shortLabel(r.hint, 24), "Inter 11", tw, 0.7, 0)
        if r.iconPath.len > 0: r.icon = loadImageTex(r.iconPath)
      elif r.kind == mkWidget:
        r.tex = textTex(r.title, "Inter 13", 200, 1.0, 0)
        if r.hint.len > 0:
          r.hintTex = textTex(shortLabel(r.hint, 28), "Inter 12", 210, 0.8, 2)
        if r.iconPath.len > 0: r.icon = loadImageTex(r.iconPath)
      else:
        r.tex = textTex(shortLabel(r.title, 40), "Inter 13", max(8, bw - 52), 1.0, 0)
        if r.iconPath.len > 0: r.icon = loadImageTex(r.iconPath)
  elif A.sheetKind >= 6:
    for line in A.listLines:
      A.listTex.add textTex(shortLabel(line, 34), "Inter 13", 320)

proc renderSheet() =
  let look = chromeInk(if A.faceStyle.len == 0: "paper" else: A.faceStyle)
  let dens = if A.faceOpacity <= 0: 1'f32 else: A.faceOpacity.float32 / 100
  paintChrome(A.sheet, proc() =
    let w = A.sheet.w.float32
    let h = A.sheet.h.float32
    let paper = (look.paperR, look.paperG, look.paperB, dens)
    let ink = (look.inkR, look.inkG, look.inkB, 1'f32)
    let plate = (look.plateR, look.plateG, look.plateB, dens)
    let track = (look.trackR, look.trackG, look.trackB, dens)
    let sel = (look.goldR * 0.46'f32, look.goldG * 0.42'f32, look.goldB * 0.36'f32, dens)
    putBox(0, 0, w, h, w, h, Tex(), 18, 1, paper)
    paintSheetText()
    if A.sheetTitle.id != 0:
      putBox(16, 14, A.sheetTitle.w.float32, A.sheetTitle.h.float32, w, h, A.sheetTitle, 0, 0, ink)
    if A.sheetValue.id != 0 and A.sheetKind == 3:
      putBox(16, 52, A.sheetValue.w.float32, A.sheetValue.h.float32, w, h, A.sheetValue, 0, 0,
             (1'f32, 1'f32, 1'f32, 1'f32))
    elif A.sheetValue.id != 0 and A.sheetKind <= 2:
      putBox(w - 16 - A.sheetValue.w.float32, 16, A.sheetValue.w.float32, A.sheetValue.h.float32, w, h,
             A.sheetValue, 0, 0, (1'f32, 1'f32, 1'f32, 1'f32))
    if A.sheetSub.id != 0 and A.sheetKind == 3:
      putBox(16, 72, A.sheetSub.w.float32, A.sheetSub.h.float32, w, h, A.sheetSub, 0, 0, ink)
    elif A.sheetSub.id != 0 and A.sheetKind != 3:
      putBox(16, 46, A.sheetSub.w.float32, A.sheetSub.h.float32, w, h, A.sheetSub, 0, 0,
             (1'f32, 1'f32, 1'f32, 1'f32))
    let gold = (look.goldR, look.goldG, look.goldB, if A.sheetMuted: 0.55'f32 else: 1'f32)
    if A.sheetKind == 3:
      let tnow = getTime().local
      let grid = monthGrid(tnow.year, ord(tnow.month), tnow.monthday)
      let geo = calendarGeom(w)
      let headInk = (look.inkR * 0.72'f32, look.inkG * 0.72'f32, look.inkB * 0.72'f32, 1'f32)
      for b in clockDashBoxes(w):
        let on = b.id == A.faceClock or b.id == A.powerArm
        let col = if on: sel else: plate
        putBox(b.x, b.y, b.w, b.h, w, h, Tex(), 12, 1, col)
        var tx = Tex()
        if b.id == "time": tx = A.sheetPreset[0]
        elif b.id == "date": tx = A.sheetPreset[1]
        elif b.id == "hands": tx = A.sheetPreset[2]
        elif b.id == "settings": tx = A.sheetPreset[3]
        elif b.id == "lock" and A.listTex.len > 38: tx = A.listTex[38]
        elif b.id == "logout" and A.listTex.len > 39: tx = A.listTex[39]
        elif b.id == "sleep" and A.listTex.len > 40: tx = A.listTex[40]
        elif b.id == "off" and A.listTex.len > 41: tx = A.listTex[41]
        if tx.id != 0:
          let tw = tx.w.float32
          let th = tx.h.float32
          putBox(b.x + (b.w - tw) / 2, b.y + (b.h - th) / 2, tw, th, w, h, tx, 0, 5, ink)
      putBox(28, 100, w - 56, 2, w, h, Tex(), 1, 1, (look.goldR, look.goldG, look.goldB, 0.9'f32))
      putBox(28, 380, w - 56, 2, w, h, Tex(), 1, 1, (look.goldR, look.goldG, look.goldB, 0.55'f32))
      if grid.cells.len == 42 and A.listTex.len >= 38:
        for i in 0 .. 6:
          let tx = A.listTex[i]
          if tx.id != 0:
            let tw = tx.w.float32
            putBox(geo.x + i.float32 * geo.cw + (geo.cw - tw) / 2, geo.y, tw, tx.h.float32, w, h, tx, 0, 5, headInk)
        for i, cell in grid.cells:
          if cell notin 1 .. 31: continue
          let tx = A.listTex[6 + cell]
          if tx.id == 0: continue
          let col = (i mod 7).float32
          let row = (i div 7).float32
          let cx = geo.x + col * geo.cw
          let cy = geo.y + 22 + row * geo.ch
          if cell == tnow.monthday:
            putBox(cx + 6, cy - 2, geo.cw - 12, geo.ch - 2, w, h, Tex(), 8, 1, sel)
          let tw = tx.w.float32
          putBox(cx + (geo.cw - tw) / 2, cy, tw, tx.h.float32, w, h, tx, 0, 5, ink)
    elif A.sheetKind == 4:
      for i in 0 .. 2:
        let ry = 78'f32 + i.float32 * 48
        let on = A.sheetDev == ProfileIds[i]
        let col = if on: sel else: plate
        putBox(16, ry, w - 32, 40, w, h, Tex(), 12, 1, col)
        let tx = A.sheetPreset[i]
        if tx.id != 0:
          putBox(16, ry + 10, w - 32, tx.h.float32, w, h, tx, 0, 0, (1'f32, 1'f32, 1'f32, 1'f32))
    elif A.sheetKind == 10:
      const ids = ["lock", "logout", "sleep", "off"]
      for i, id in ids:
        let ry = 72'f32 + i.float32 * 44
        let on = A.powerArm == id
        let col = if on: sel else: plate
        putBox(16, ry, w - 32, 40, w, h, Tex(), 12, 1, col)
        let tx = A.sheetPreset[i]
        if tx.id != 0:
          putBox(28, ry + 10, tx.w.float32, tx.h.float32, w, h, tx, 0, 0, ink)
    elif A.sheetKind == 11:
      if A.sheetDev.len > 0:
        for i in 0 .. 2:
          let ry = 72'f32 + i.float32 * 44
          putBox(16, ry, w - 32, 40, w, h, Tex(), 12, 1, plate)
          let tx = A.sheetPreset[i]
          if tx.id != 0:
            putBox(28, ry + 10, tx.w.float32, tx.h.float32, w, h, tx, 0, 0, ink)
    elif A.sheetKind >= 6:
      var ly = 72'f32
      for tx in A.listTex:
        if tx.id != 0:
          putBox(16, ly, tx.w.float32, tx.h.float32, w, h, tx, 0, 0, ink)
        ly += 28
    elif A.sheetKind == 5:
      let boxes = menuBoxes(menuKinds(), if A.sheet.w > 40: A.sheet.w else: menuWide)
      let cream = ink
      let goldInk = (look.goldR, look.goldG, look.goldB, 1'f32)
      let dimInk = (look.inkR * 0.82'f32, look.inkG * 0.78'f32, look.inkB * 0.72'f32, 1'f32)
      for i, r in A.menuRows:
        if i >= boxes.len: break
        let x = boxes[i].x.float32
        let y = boxes[i].y.float32
        let bw = boxes[i].w.float32
        let bh = boxes[i].h.float32
        if r.kind == mkHead:
          if r.tex.id != 0:
            putBox(x, y + 4, r.tex.w.float32, r.tex.h.float32, w, h, r.tex, 0, 5, goldInk)
          continue
        if r.kind == mkTab:
          let col = if r.on: sel else: plate
          putBox(x, y, bw, bh, w, h, Tex(), 12, 1, col)
          if r.tex.id != 0:
            putBox(x, y + (bh - r.tex.h.float32) / 2, bw, r.tex.h.float32, w, h, r.tex, 0, 5, cream)
          continue
        if r.kind == mkSearch:
          putBox(x, y, bw, bh, w, h, Tex(), 12, 1, track)
          if r.tex.id != 0:
            putBox(x + 14, y + (bh - r.tex.h.float32) / 2, r.tex.w.float32, r.tex.h.float32,
                   w, h, r.tex, 0, 5, dimInk)
          continue
        if r.kind == mkSlide:
          putBox(x, y, bw, bh, w, h, Tex(), 14, 1, plate)
          if r.tex.id != 0:
            putBox(x + 12, y + 6, r.tex.w.float32, r.tex.h.float32, w, h, r.tex, 0, 5, cream)
          let ty = y + bh - 16
          let tw = max(20'f32, bw - 24)
          putBox(x + 12, ty, tw, 8, w, h, Tex(), 4, 1, track)
          var span = (A.faceOpacity - 40).float32 / 60
          if span < 0: span = 0
          if span > 1: span = 1
          let fillW = max(8'f32, tw * span)
          putBox(x + 12, ty, fillW, 8, w, h, Tex(), 4, 1, gold)
          let knob = 16'f32
          var kx = x + 12 + fillW - knob / 2
          let kmin = x + 12
          let kmax = x + 12 + tw - knob
          if kx < kmin: kx = kmin
          if kx > kmax: kx = kmax
          putBox(kx, ty - 4, knob, knob, w, h, Tex(), knob / 2, 1, gold)
          continue
        let hot = r.on and (r.kind == mkTile or r.kind == mkWidget or r.kind == mkAct)
        let col = if hot: sel else: plate
        putBox(x, y, bw, bh, w, h, Tex(), 14, 1, col)
        let side = if r.kind == mkTile: 22'f32 else: 18'f32
        let ix = x + 10
        let iy = y + (bh - side) / 2
        if r.icon.id != 0:
          let mode: int32 = if "symbolic" in r.iconPath: 5 else: 0
          let icol = if mode == 5: cream else: (1'f32, 1'f32, 1'f32, 1'f32)
          putBox(ix, iy, side, side, w, h, r.icon, 4, mode, icol)
        elif r.kind == mkApp:
          putBox(ix, iy, side, side, w, h, Tex(), 4, 1, sel)
        let tx = if r.icon.id != 0 or r.kind == mkApp: ix + side + 8 else: x + 12
        if r.kind == mkTile and r.hintTex.id != 0:
          if r.tex.id != 0:
            putBox(tx, y + 8, r.tex.w.float32, r.tex.h.float32, w, h, r.tex, 0, 5, cream)
          putBox(tx, y + 30, r.hintTex.w.float32, r.hintTex.h.float32, w, h, r.hintTex, 0, 5, dimInk)
        elif r.kind == mkWidget and r.hintTex.id != 0:
          if r.tex.id != 0:
            putBox(tx, y + (bh - r.tex.h.float32) / 2, r.tex.w.float32, r.tex.h.float32, w, h,
                   r.tex, 0, 5, cream)
          let hw = r.hintTex.w.float32
          let mark = if r.on: goldInk else: dimInk
          putBox(x + bw - hw - 10, y + (bh - r.hintTex.h.float32) / 2, hw, r.hintTex.h.float32,
                 w, h, r.hintTex, 0, 5, mark)
        elif r.tex.id != 0:
          putBox(tx, y + (bh - r.tex.h.float32) / 2, r.tex.w.float32, r.tex.h.float32, w, h,
                 r.tex, 0, 5, cream)
    elif A.sheetKind == 2:
      layoutBright(w)
      putBox(A.trackX, A.trackY, A.trackW, A.trackH, w, h, Tex(), 16, 1, track)
      let fill = max(A.trackH, A.trackW * A.sheetPct.float32 / 100)
      putBox(A.trackX, A.trackY, fill, A.trackH, w, h, Tex(), 16, 1, gold)
      for i in 0 .. 3:
        let on = A.sheetPct == BrightPresets[i]
        let col = if on: sel else: plate
        putBox(A.presetX[i], A.chipY, A.chipW, A.chipH, w, h, Tex(), 14, 1, col)
        let tx = A.sheetPreset[i]
        if tx.id != 0:
          putBox(A.presetX[i], A.chipY + 16, A.chipW, tx.h.float32, w, h, tx, 0, 0,
                 (1'f32, 1'f32, 1'f32, 1'f32))
    elif A.sheetKind == 1:
      A.trackX = 18
      A.trackW = w - 36
      A.trackY = 78
      A.trackH = 18
      putBox(A.trackX, A.trackY, A.trackW, A.trackH, w, h, Tex(), 9, 1, track)
      let fill = max(18'f32, A.trackW * A.sheetPct.float32 / 100)
      putBox(A.trackX, A.trackY, fill, A.trackH, w, h, Tex(), 9, 1, gold)
      A.chipY = 114
      A.chipH = 40
      A.chipX = 16
      A.chipW = (w - 44) / 2
      A.chip2X = A.chipX + A.chipW + 12
      A.chip2W = A.chipW
      putBox(A.chipX, A.chipY, A.chipW, A.chipH, w, h, Tex(), 12, 1, plate)
      putBox(A.chip2X, A.chipY, A.chip2W, A.chipH, w, h, Tex(), 12, 1, plate)
      if A.sheetChip.id != 0:
        putBox(A.chipX, A.chipY + 10, A.chipW, A.sheetChip.h.float32, w, h, A.sheetChip, 0, 0,
               (1'f32, 1'f32, 1'f32, 1'f32))
      if A.sheetChip2.id != 0:
        putBox(A.chip2X, A.chipY + 10, A.chip2W, A.sheetChip2.h.float32, w, h, A.sheetChip2, 0, 0,
               (1'f32, 1'f32, 1'f32, 1'f32))
  , 0)

proc desktopField(path, key: string): string =
  try: desktopValue(readFile(path), key)
  except IOError, OSError: ""

proc loadPins() =
  for i in 0 ..< A.pins.len:
    A.pins[i].icon.free()
    A.pins[i].mark.free()
    A.pins[i].nameTex.free()
  A.pins.setLen(0)
  A.pinLive.setLen(0)
  let path = getHomeDir() / ".config/mazzy/dock"
  let dirs = desktopSearchDirs()
  let roots = iconSearchRoots()
  try:
    for line in lines(path):
      let id = line.strip
      if id.len == 0 or id.startsWith("#") or A.pins.len >= DockPinCap: continue
      var pin = Pin(id: id, label: id)
      let df = findDesktopFile(id, dirs)
      if df.len > 0:
        let name = desktopField(df, "Name")
        if name.len > 0: pin.label = name
        let iconName = desktopField(df, "Icon")
        var icon = appIconPath(iconName, roots)
        if icon.len == 0: icon = themeIcon(iconName)
        if icon.len > 0: pin.icon = loadImageTex(icon)
      A.pins.add pin
  except IOError, OSError:
    discard

proc wallpaperPath(): string =
  let cfg = getHomeDir() / ".config/mazzy/wallpaper"
  try:
    for line in lines(cfg):
      let t = line.strip
      if t.len > 0 and not t.startsWith("#"): return expandHome(t)
  except IOError, OSError:
    discard
  for name in ["mazzy-09-lab.jpg", "mazzy-01-hall.jpg"]:
    let p = getHomeDir() / "Pictures/Wallpapers" / name
    if fileExists(p): return p

proc batteryLabel(): string =
  let b = batteryReport()
  if b.pct < 0: return "—"
  var s = $b.pct & "%"
  if b.status == "Charging": s.add '+'
  if b.extra.len > 0:
    s.add ' '
    s.add b.extra
  s

proc volumeLabel(): string =
  let (outp, code) = execCmdEx("wpctl get-volume @DEFAULT_AUDIO_SINK@", options = {poUsePath})
  if code != 0: return ""
  var pct = -1
  for w in outp.splitWhitespace:
    try:
      let f = parseFloat(w)
      if f >= 0 and f <= 1.5: pct = int(f * 100)
    except ValueError:
      discard
  if pct < 0: return ""
  if "MUTED" in outp: "звук выкл" else: "звук " & $pct & "%"

proc paintChrome(s: var Surf, body: proc(), clearA: float32,
                  clearC: (float32, float32, float32)) =
  if not s.configured or s.eglSurf == nil: return
  discard eglMakeCurrent(A.egl, s.eglSurf, s.eglSurf, A.eglCtx)
  glViewport(0, 0, s.w.GLsizei, s.h.GLsizei)
  # Композитор ждёт предумноженную альфу. Обычный clear без умножения светлеет на прозрачности.
  glClearColor(clearC[0] * clearA, clearC[1] * clearA, clearC[2] * clearA, clearA)
  glClear(GL_COLOR_BUFFER_BIT)
  body()
  discard eglSwapBuffers(A.egl, s.eglSurf)

proc paintGlyph(tex: Tex, x, y, side, surfW, surfH: float32,
                tint: (float32, float32, float32, float32) = (0.93'f32, 0.88'f32, 0.80'f32, 1'f32)) =
  ## Символический значок темы тёмный. Режим 5 красит его альфой, не чёрным цветом файла.
  if tex.id == 0:
    putBox(x + 4, y + 4, side - 8, side - 8, surfW, surfH, Tex(), 3, 1, tint)
  else:
    putBox(x, y, side, side, surfW, surfH, tex, 2, 5, tint)

proc putHand(cx, cy, length, thick, ang, surfW, surfH: float32,
             color: (float32, float32, float32, float32)) =
  let rad = ang * PI / 180'f32
  let dx = sin(rad) * (length / 2)
  let dy = -cos(rad) * (length / 2)
  var p = params()
  p.mode = 1
  p.color = color
  p.size = (thick, length)
  p.radius = thick / 2
  p.mvp = orthoPx(surfW, surfH).mul(
    translate(-surfW / 2 + cx + dx, -surfH / 2 + cy + dy, 0)).mul(rotateZ(ang))
  A.gfx.draw(p)

proc renderBar() =
  let look = chromeInk(if A.faceStyle.len == 0: "paper" else: A.faceStyle)
  let dens = if A.faceOpacity <= 0: 1'f32 else: A.faceOpacity.float32 / 100
  paintChrome(A.bar, proc() =
    let w = A.bar.w.float32
    let h = A.bar.h.float32
    let gold = (look.goldR, look.goldG, look.goldB, 1'f32)
    let idle = (look.idleR, look.idleG, look.idleB, 1'f32)
    let hot = (look.hotR, look.hotG, look.hotB, 1'f32)
    let ink = (look.inkR, look.inkG, look.inkB, 1'f32)
    let plate = (look.plateR, look.plateG, look.plateB, 1'f32)
    let inkDark = (look.darkR, look.darkG, look.darkB, 1'f32)
    if A.logoTex.id != 0:
      putBox(8, (h - 28) / 2, 28, 28, w, h, A.logoTex, 8, 0, (1'f32, 1'f32, 1'f32, 1'f32))
    elif A.barHot == 0:
      putBox(8, (h - 28) / 2, 28, 28, w, h, Tex(), 8, 1, hot)
    if faceOn("desks"):
      for i in 0 ..< DeskCount:
        let x = 46'f32 + i.float32 * 32
        let cw = 26'f32
        let ch = 20'f32
        let y = (h - ch) / 2
        let on = A.wsId == i + 1
        let col = if on: gold elif A.barHot == i + 1: hot else: idle
        putBox(x, y, cw, ch, w, h, Tex(), 10, 1, col)
        if A.occupied[i] and not on:
          putBox(x + 11, y + ch - 4, 4, 3, w, h, Tex(), 1, 1, gold)
        let nt = A.numTex[i]
        if nt.id != 0:
          let numCol = if on: inkDark else: ink
          putBox(x, (h - nt.h.float32) / 2 - 1, cw, nt.h.float32, w, h, nt, 0, 5, numCol)
    A.clockX = 0
    A.clockW = 0
    if faceOn("clock") and A.faceClock == "hands":
      let side = 28'f32
      A.clockW = side + 8
      A.clockX = w / 2 - A.clockW / 2
      let cx = A.clockX + A.clockW / 2
      let cy = h / 2
      putBox(cx - side / 2, cy - side / 2, side, side, w, h, Tex(), side / 2, 1, idle)
      let hourAng = (A.clockH mod 12).float32 * 30 + A.clockM.float32 * 0.5
      let minAng = A.clockM.float32 * 6
      putHand(cx, cy, 8, 2.2, hourAng, w, h, ink)
      putHand(cx, cy, 11, 1.4, minAng, w, h, gold)
      putBox(cx - 1.5, cy - 1.5, 3, 3, w, h, Tex(), 2, 1, gold)
    elif faceOn("clock") and A.clockTex.id != 0:
      A.clockW = max(72'f32, A.clockTex.w.float32 + 16)
      A.clockX = w / 2 - A.clockW / 2
      putBox(A.clockX, (h - A.clockTex.h.float32) / 2, A.clockW, A.clockTex.h.float32, w, h, A.clockTex, 0, 0,
             (1'f32, 1'f32, 1'f32, 1'f32))
    var right = w - 12
    A.batX = 0; A.batW = 0; A.volX = 0; A.volW = 0; A.netX = 0; A.netW = 0; A.ctlX = 0; A.ctlW = 0
    A.brX = 0; A.brW = 0; A.micX = 0; A.micW = 0; A.profX = 0; A.profW = 0; A.vpnX = 0; A.vpnW = 0
    template placeStatus(iconTex, labelTex: Tex, hotId: int, outX, outW: untyped, forceLabel: bool) =
      let wantLabel = if labelTex.id == 0: 0'f32 elif forceLabel or A.faceLabels: labelTex.w.float32 else: 0'f32
      let iconS = 18'f32
      var labelW = wantLabel
      var gap = if labelW > 0: 4'f32 else: 0'f32
      var cluster = iconS + gap + labelW
      if right - cluster < A.clockX + A.clockW + 8 and labelW > 0:
        labelW = 0
        gap = 0
        cluster = iconS
      if right - cluster < A.clockX + A.clockW + 8:
        outX = 0
        outW = 0
      else:
        right -= cluster
        outX = right
        outW = cluster
        if A.barHot == hotId:
          putBox(right - 4, (h - 24) / 2, cluster + 8, 24, w, h, Tex(), 8, 1, hot)
        paintGlyph(iconTex, right, (h - iconS) / 2, iconS, w, h, ink)
        if labelW > 0:
          putBox(right + iconS + gap, (h - labelTex.h.float32) / 2, labelW, labelTex.h.float32,
                 w, h, labelTex, 0, 0, ink)
        right -= 8
    template markPick(id: string, x, bw: float32) =
      if A.editOn and A.editPick == id and bw > 0:
        putBox(x, h - 5, bw, 2, w, h, Tex(), 1, 1, gold)
    A.layoutX = 0
    A.layoutW = 0
    A.trayN = 0
    for i in 0 ..< A.chipKey.len:
      A.moreX[i] = 0
      A.moreW[i] = 0
    let order = if A.faceOrder.len == 0: widgetRightIds() else: A.faceOrder
    # Процессор, память и канал не влезают справа от часов: справа уже ряд значков.
    # Их ряд — между столами и часами, в том же порядке, что и меню.
    var lane = 46'f32 + DeskCount.float32 * 32 + 14
    let laneStop = if A.clockX > lane: A.clockX - 12 else: w * 0.46'f32
    var laneBoxes: seq[tuple[ci: int, id: string, cluster, labelW: float32]]
    var laneSpan = 0'f32
    for id in order:
      if id notin ["cpu", "mem", "netio"]: continue
      var ci = -1
      for i, k in A.chipKey:
        if k == id: ci = i
      if ci < 0 or not faceOn(id) or A.chipFor[ci].len == 0 or A.chipTex[ci].id == 0: continue
      let labelW = A.chipTex[ci].w.float32
      let cluster = 18'f32 + 4 + labelW
      if lane + laneSpan + cluster > laneStop: continue
      laneBoxes.add (ci, id, cluster, labelW)
      laneSpan += cluster + 8
    if laneBoxes.len > 0:
      laneSpan -= 8
      putBox(lane - 8, (h - 28) / 2, laneSpan + 16, 28, w, h, Tex(), 12, 1, plate)
      var x = lane
      for box in laneBoxes:
        A.moreX[box.ci] = x
        A.moreW[box.ci] = box.cluster
        if A.barHot == 40 + box.ci:
          putBox(x - 4, (h - 24) / 2, box.cluster + 8, 24, w, h, Tex(), 8, 1, hot)
        paintGlyph(A.chipIcon[box.ci], x, (h - 18) / 2, 18, w, h, ink)
        let tx = A.chipTex[box.ci]
        putBox(x + 22, (h - tx.h.float32) / 2, box.labelW, tx.h.float32, w, h, tx, 0, 0, ink)
        markPick(box.id, x, box.cluster)
        x += box.cluster + 8
    for id in order:
      case id
      of "battery":
        if faceOn("battery"):
          placeStatus(A.batIcon, A.batTex, 21, A.batX, A.batW, false)
          markPick(id, A.batX, A.batW)
      of "layout":
        if faceOn("layout") and A.layoutTex.id != 0:
          let lw = A.layoutTex.w.float32
          let cluster = 20'f32 + lw
          if right - cluster >= A.clockX + A.clockW + 8:
            right -= cluster
            A.layoutX = right
            A.layoutW = cluster
            if A.barHot == 29:
              putBox(right - 4, (h - 24) / 2, cluster + 8, 24, w, h, Tex(), 8, 1, hot)
            paintGlyph(A.layoutIcon, right, (h - 16) / 2, 16, w, h, ink)
            putBox(right + 18, (h - A.layoutTex.h.float32) / 2, lw, A.layoutTex.h.float32, w, h,
                   A.layoutTex, 0, 5, ink)
            right -= 8
            markPick(id, A.layoutX, A.layoutW)
      of "volume":
        if faceOn("volume"):
          placeStatus(A.volIcon, A.volTex, 20, A.volX, A.volW, false)
          markPick(id, A.volX, A.volW)
      of "mic":
        if faceOn("mic") and A.micFor.len > 0:
          placeStatus(A.micIcon, A.micTex, 25, A.micX, A.micW, false)
          markPick(id, A.micX, A.micW)
      of "brightness":
        if faceOn("brightness"):
          placeStatus(A.brIcon, A.brTex, 24, A.brX, A.brW, false)
          markPick(id, A.brX, A.brW)
      of "network":
        if faceOn("network"):
          placeStatus(A.netIcon, A.netTex, 22, A.netX, A.netW, false)
          markPick(id, A.netX, A.netW)
      of "vpn":
        if faceOn("vpn") and A.vpnFor.len > 0:
          placeStatus(A.vpnIcon, A.vpnTex, 27, A.vpnX, A.vpnW, false)
          markPick(id, A.vpnX, A.vpnW)
      of "profile":
        if faceOn("profile") and A.profFor.len > 0:
          placeStatus(A.profIcon, A.profTex, 26, A.profX, A.profW, false)
          markPick(id, A.profX, A.profW)
      of "dnd", "bluetooth", "media", "load", "shot", "clip", "session", "scale":
        var ci = -1
        for i, k in A.chipKey:
          if k == id: ci = i
        if ci >= 0 and faceOn(id) and A.chipFor[ci].len > 0:
          let force = id == "load"
          placeStatus(A.chipIcon[ci], A.chipTex[ci], 40 + ci, A.moreX[ci], A.moreW[ci], force)
          markPick(id, A.moreX[ci], A.moreW[ci])
      of "tray":
        let slots = min(6, A.trayTex.len)
        if faceOn("tray") and slots > 0 and right - slots.float32 * 22 > w / 2 + 48:
          A.trayN = slots
          for i in countdown(slots - 1, 0):
            right -= 22
            A.trayX[i] = right
            if A.barHot == 30 + i:
              putBox(right - 2, (h - 24) / 2, 26, 24, w, h, Tex(), 8, 1, hot)
            let tex = A.trayTex[i]
            if tex.id != 0:
              putBox(right + 2, (h - 18) / 2, 18, 18, w, h, tex, 4, 0, (1'f32, 1'f32, 1'f32, 1'f32))
            else:
              putBox(right + 6, (h - 8) / 2, 8, 8, w, h, Tex(), 4, 1, gold)
          right -= 8
          markPick(id, A.trayX[0], slots.float32 * 22)
      else: discard
    right -= 28
    A.ctlX = right
    A.ctlW = 28
    if A.barHot == 23:
      putBox(right - 2, (h - 26) / 2, 32, 26, w, h, Tex(), 8, 1, hot)
    paintGlyph(A.ctlIcon, right + 4, (h - 20) / 2, 20, w, h, ink)
  , dens, (look.paperR, look.paperG, look.paperB))

proc renderDock() =
  let look = chromeInk(if A.faceStyle.len == 0: "paper" else: A.faceStyle)
  let dens = if A.faceOpacity <= 0: 1'f32 else: A.faceOpacity.float32 / 100
  paintChrome(A.dock, proc() =
    let w = A.dock.w.float32
    let h = A.dock.h.float32
    let m = dockNow()
    let slot = m.slot.float32
    let icon = m.icon.float32
    A.dockSlot = slot
    let paper = (look.paperR, look.paperG, look.paperB, dens)
    let gold = (look.goldR, look.goldG, look.goldB, 1'f32)
    let ink = (look.inkR, look.inkG, look.inkB, 1'f32)
    let hover = (look.goldR, look.goldG, look.goldB, 0.28'f32)
    putBox(4, 2, w - 8, h - 6, w, h, Tex(), 22, 1, paper)
    putBox(22, 5, w - 44, 2, w, h, Tex(), 1, 1, (look.goldR, look.goldG, look.goldB, dens))
    let n = 1 + A.pins.len
    let start = max(8'f32, (w - n.float32 * slot) / 2)
    let y = if A.extras.len > 0: 8'f32 else: max(8'f32, (h - icon - (if A.faceLabels: 16'f32 else: 6'f32)) / 2)
    template drawIcon(x, yy: float32, tex: Tex, hot: bool) =
      let grow = if hot: 4'f32 else: 0'f32
      let side = icon + grow
      let ox = x + (slot - side) / 2
      if hot:
        putBox(ox, yy - grow / 2, side, side, w, h, Tex(), 12, 1, hover)
      if tex.id != 0:
        putBox(ox, yy - grow / 2, side, side, w, h, tex, 10, 0, (1'f32, 1'f32, 1'f32, 1'f32))
      else:
        putBox(ox, yy - grow / 2, side, side, w, h, Tex(), 10, 1, (0.28'f32, 0.24'f32, 0.18'f32, 1'f32))
    if A.logoTex.id != 0:
      drawIcon(start, y, A.logoTex, A.dockHot == 0)
    else:
      drawIcon(start, y, Tex(), A.dockHot == 0)
    for i in 0 ..< A.pins.len:
      let x = start + (i + 1).float32 * slot
      if A.pins[i].icon.id != 0:
        drawIcon(x, y, A.pins[i].icon, A.dockHot == i + 1)
      else:
        drawIcon(x, y, Tex(), A.dockHot == i + 1)
        if A.pins[i].mark.id == 0:
          let letter = if A.pins[i].label.len > 0: firstRune(A.pins[i].label) else: "?"
          A.pins[i].mark = textTex(letter, "Inter Semi-Bold 13", 32)
        let tx = A.pins[i].mark
        if tx.id != 0:
          putBox(x, y + 8, slot, tx.h.float32, w, h, tx, 0, 5, ink)
      if i < A.pinLive.len and A.pinLive[i]:
        putBox(x + slot / 2 - 2, y + icon + 2, 4, 4, w, h, Tex(), 2, 1, gold)
    if A.faceLabels and A.dockHot >= 0:
      var name = "Меню"
      if A.dockHot > 0 and A.dockHot - 1 < A.pins.len: name = A.pins[A.dockHot - 1].label
      name = clipRunes(name, 28)
      if name != A.dockCapFor:
        A.dockCapFor = name
        A.dockCap.free()
        if name.len > 0: A.dockCap = textTex(name, "Inter 11", max(40, int(w) - 24))
      if A.dockCap.id != 0:
        putBox(12, h - 20, w - 24, A.dockCap.h.float32, w, h, A.dockCap, 0, 5, ink)
    if A.extras.len > 0:
      let y2 = m.row.float32
      let start2 = max(8'f32, (w - A.extras.len.float32 * slot) / 2)
      for i in 0 ..< A.extras.len:
        let x = start2 + i.float32 * slot
        drawIcon(x, y2, Tex(), false)
        if A.extras[i].mark.id == 0:
          let letter = if A.extras[i].label.len > 0: firstRune(A.extras[i].label) else: "?"
          A.extras[i].mark = textTex(letter, "Inter Semi-Bold 13", 32)
        let tx = A.extras[i].mark
        if tx.id != 0:
          putBox(x, y2 + 8, slot, tx.h.float32, w, h, tx, 0, 5, ink)
        putBox(x + slot / 2 - 2, y2 + icon + 2, 4, 4, w, h, Tex(), 2, 1, gold)
  , 0)

proc refreshStatus() =
  let t = getTime().local
  let mode = if A.faceClock.len == 0: "time" else: A.faceClock
  let cap = clockCaption(mode, t.hour, t.minute, t.monthday, ord(t.month))
  let stamp = mode & "|" & cap & "|" & $t.hour & "|" & $t.minute
  A.clockH = t.hour
  A.clockM = t.minute
  if stamp != A.clockStamp:
    A.clockStamp = stamp
    A.clockFor = cap
    A.clockTex.free()
    if cap.len > 0: A.clockTex = textTex(cap, "Inter Semi-Bold 13", 220)
    requestFrame(A.bar)
  if A.sheet.layer != nil and A.sheetKind == 3:
    A.sheetKey = ""
    requestFrame(A.sheet)
  let vol = volumeLabel()
  if vol != A.volFor:
    A.volFor = vol
    A.volTex.free()
    if vol.len > 0: A.volTex = textTex(vol, "Inter 12", 110, 0.85)
    requestFrame(A.bar)
  let bat = batteryLabel()
  if bat != A.batFor:
    A.batFor = bat
    A.batTex.free()
    A.batTex = textTex(bat, "Inter 12", 64, 0.85)
    requestFrame(A.bar)
  let occ = seatOccupied()
  if occ != A.occupied:
    A.occupied = occ
    requestFrame(A.bar)
  let volState = volumeParts(vol)
  let volName = volumeIconName(volState.pct, volState.muted)
  if volName != A.volIconFor:
    A.volIconFor = volName
    A.volIcon.free()
    let path = themeIcon(volName)
    if path.len > 0: A.volIcon = loadImageTex(path)
    requestFrame(A.bar)
  let batState = batteryParts(bat)
  let batName = batteryIconName(batState.pct, batState.charging)
  if batName != A.batIconFor:
    A.batIconFor = batName
    A.batIcon.free()
    let path = themeIcon(batName)
    if path.len > 0: A.batIcon = loadImageTex(path)
    requestFrame(A.bar)
  let online = linkUp("/sys/class/net")
  let netLabel = netShort(online)
  if netLabel != A.netFor:
    A.netFor = netLabel
    A.netTex.free()
    A.netTex = textTex(netLabel, "Inter 12", 72, 0.85)
    requestFrame(A.bar)
  let netName = networkIconName(online)
  if netName != A.netIconFor:
    A.netIconFor = netName
    A.netIcon.free()
    let netPath = themeIcon(netName)
    if netPath.len > 0: A.netIcon = loadImageTex(netPath)
    requestFrame(A.bar)
  var live = newSeq[bool](A.pins.len)
  var nextExtra: seq[Pin]
  var seenExtra: seq[string]
  for w in seatClients():
    if w.class.len == 0: continue
    var hit = false
    for i, pin in A.pins:
      if pinRuns(pin.id, w.class):
        live[i] = true
        hit = true
    if hit: continue
    let key = w.class.toLowerAscii
    if key in seenExtra: continue
    seenExtra.add key
    nextExtra.add Pin(id: w.address, label: w.class)
    if nextExtra.len >= 8: break
  if live != A.pinLive:
    A.pinLive = live
    requestFrame(A.dock)
  var extraSame = nextExtra.len == A.extras.len
  if extraSame:
    for i in 0 ..< nextExtra.len:
      if nextExtra[i].id != A.extras[i].id or nextExtra[i].label != A.extras[i].label:
        extraSame = false
        break
  if not extraSame:
    for e in A.extras.mitems:
      e.mark.free()
      e.nameTex.free()
    A.extras = nextExtra
    dockResize()
    requestFrame(A.dock)
  let (mout, mcode) = execCmdEx("wpctl get-volume @DEFAULT_AUDIO_SOURCE@", options = {poUsePath})
  let mheard = if mcode == 0: wpctlVolume(mout) else: (pct: -1, muted: false)
  let mic = micLabel(mheard.pct, mheard.muted, mcode == 0 and mheard.pct >= 0)
  if mic != A.micFor:
    A.micFor = mic
    A.micTex.free()
    if mic.len > 0: A.micTex = textTex(mic, "Inter 12", 96, 0.85)
    requestFrame(A.bar)
  let micName = if mic.len == 0: "" else: micIconName(mheard.muted)
  if micName != A.micIconFor:
    A.micIconFor = micName
    A.micIcon.free()
    if micName.len > 0:
      let micPath = themeIcon(micName)
      if micPath.len > 0: A.micIcon = loadImageTex(micPath)
    requestFrame(A.bar)
  let (pout, pcode) = execCmdEx("powerprofilesctl get", options = {poUsePath})
  let raw = if pcode == 0: pout.strip else: ""
  A.profRaw = raw
  let plab = profileLabel(raw)
  if plab != A.profFor:
    A.profFor = plab
    A.profTex.free()
    if plab.len > 0: A.profTex = textTex(plab, "Inter 12", 88, 0.85)
    requestFrame(A.bar)
  let pname = profileIconName(raw)
  if pname != A.profIconFor:
    A.profIconFor = pname
    A.profIcon.free()
    if pname.len > 0:
      let profPath = themeIcon(pname)
      if profPath.len > 0: A.profIcon = loadImageTex(profPath)
    requestFrame(A.bar)
  if A.sheetKind == 4 and A.sheet.layer != nil and raw.len > 0 and raw != A.sheetDev:
    A.sheetDev = raw
    A.sheetName = if plab.len == 0: "Нет профиля" else: plab
    A.sheetKey = ""
    requestFrame(A.sheet)
  let (nout, ncode) = execCmdEx("nmcli -t -f TYPE,STATE connection show --active", options = {poUsePath})
  let vpn = if ncode == 0 and vpnActive(nout): "vpn" else: ""
  if vpn != A.vpnFor:
    A.vpnFor = vpn
    A.vpnTex.free()
    A.vpnIcon.free()
    if vpn.len > 0:
      A.vpnTex = textTex(vpn, "Inter 12", 48, 0.85)
      let vpnPath = themeIcon("network-vpn-symbolic")
      if vpnPath.len > 0: A.vpnIcon = loadImageTex(vpnPath)
    requestFrame(A.bar)
  let lamp = readBacklight()
  let brLabel = if lamp.pct < 0: "" else: $lamp.pct & "%"
  if brLabel != A.brFor:
    A.brFor = brLabel
    A.brTex.free()
    if brLabel.len > 0: A.brTex = textTex(brLabel, "Inter 12", 48, 0.85)
    requestFrame(A.bar)
  if A.sheet.layer != nil and not A.sheetDrag:
    if A.sheetKind == 1:
      let st = volumeParts(vol)
      var changed = false
      if st.muted != A.sheetMuted:
        A.sheetMuted = st.muted
        changed = true
      if not st.muted and st.pct >= 0 and pctClamp(st.pct) != A.sheetPct:
        A.sheetPct = pctClamp(st.pct)
        changed = true
      if changed:
        A.sheetKey = ""
        requestFrame(A.sheet)
    elif A.sheetKind == 2 and lamp.pct >= 0 and lamp.pct != A.sheetPct:
      A.sheetPct = lamp.pct
      A.sheetKey = ""
      requestFrame(A.sheet)
  let lay = seatLayoutRead()
  if lay.ok:
    let mark = layoutMark(lay.name)
    if mark != A.layoutFor:
      A.layoutFor = mark
      A.layoutTex.free()
      if mark.len > 0: A.layoutTex = textTex(mark, "Inter Semi-Bold 12", 36)
      requestFrame(A.bar)
  refreshChips()

proc setChip(i: int, key, label, iconName: string) =
  A.chipKey[i] = key
  if label != A.chipFor[i]:
    A.chipFor[i] = label
    A.chipTex[i].free()
    if label.len > 0: A.chipTex[i] = textTex(shortLabel(label, 18), "Inter 12", 120, 0.9)
    requestFrame(A.bar)
  if iconName != A.chipIconFor[i]:
    A.chipIconFor[i] = iconName
    A.chipIcon[i].free()
    if iconName.len > 0:
      let path = themeIcon(iconName)
      if path.len > 0: A.chipIcon[i] = loadImageTex(path)
    requestFrame(A.bar)

proc refreshChips() =
  if faceOn("dnd"):
    let (outp, code) = execCmdEx("timeout 1 makoctl mode", options = {poUsePath})
    let mode = if code == 0: dndOn(outp) else: -1
    if mode < 0: setChip(0, "dnd", "", "")
    elif mode == 1: setChip(0, "dnd", "тихо", "notifications-disabled-symbolic")
    else: setChip(0, "dnd", "уведом", "notifications-symbolic")
  else: setChip(0, "dnd", "", "")
  if faceOn("bluetooth"):
    let (outp, code) = execCmdEx("timeout 1 rfkill list bluetooth", options = {poUsePath})
    let st = if code == 0: rfkillSoft(outp, "bluetooth") else: -1
    if st < 0: setChip(1, "bluetooth", "", "")
    elif st == 1: setChip(1, "bluetooth", "bt выкл", "bluetooth-disabled-symbolic")
    else: setChip(1, "bluetooth", "bt", "bluetooth-active-symbolic")
  else: setChip(1, "bluetooth", "", "")
  if faceOn("media") and findExe("playerctl").len > 0:
    let (outp, code) = execCmdEx("timeout 1 playerctl metadata --format '{{artist}} - {{title}}'", options = {poUsePath})
    let line = if code == 0: mediaLine(outp) else: ""
    if line.len == 0: setChip(2, "media", "", "")
    else: setChip(2, "media", line, "media-playback-start-symbolic")
  else: setChip(2, "media", "", "")
  if faceOn("load"):
    let text = try: readFile("/proc/loadavg") except CatchableError, OSError: ""
    setChip(3, "load", loadLabel(text), "utilities-system-monitor-symbolic")
  else: setChip(3, "load", "", "")
  let stat = try: readFile("/proc/stat") except CatchableError, OSError: ""
  let sample = cpuSample(stat)
  let pct = if A.cpuArmed: cpuPct(A.cpuIdle, A.cpuTotal, sample.idle, sample.total) else: -1
  if sample.total > 0:
    A.cpuIdle = sample.idle
    A.cpuTotal = sample.total
    A.cpuArmed = true
  if faceOn("cpu"): setChip(8, "cpu", cpuLabel(pct), "utilities-system-monitor-symbolic")
  else: setChip(8, "cpu", "", "")
  let mem = try: readFile("/proc/meminfo") except CatchableError, OSError: ""
  if faceOn("mem"): setChip(9, "mem", memLabel(mem), "drive-harddisk-symbolic")
  else: setChip(9, "mem", "", "")
  let dev = try: readFile("/proc/net/dev") except CatchableError, OSError: ""
  let nb = netBytes(dev)
  let tnow = now()
  let dt = if A.perfAt > 0: tnow - A.perfAt else: 0'f64
  var rate = ""
  if A.netArmed:
    rate = netLabel(A.netRx, A.netTx, nb.rx, nb.tx, dt)
  if nb.rx >= 0:
    A.netRx = nb.rx
    A.netTx = nb.tx
    A.netArmed = true
    A.perfAt = tnow
  if faceOn("netio"): setChip(10, "netio", rate, "network-transmit-receive-symbolic")
  else: setChip(10, "netio", "", "")
  if faceOn("shot") and findExe("grim").len > 0:
    setChip(4, "shot", "снимок", "camera-photo-symbolic")
  else: setChip(4, "shot", "", "")
  if faceOn("clip") and findExe("wl-paste").len > 0:
    let (outp, code) = execCmdEx("timeout 1 wl-paste -n", options = {poUsePath})
    if code == 0:
      let line = outp.strip
      if A.clipSeen.len == 0: A.clipSeen = line
      elif line != A.clipSeen and line.len > 0:
        A.clipSeen = line
        A.clipHist = clipPush(A.clipHist, line, 8)
    if A.clipHist.len == 0: setChip(5, "clip", "", "")
    else: setChip(5, "clip", "буфер", "edit-paste-symbolic")
  else: setChip(5, "clip", "", "")
  if faceOn("session"): setChip(6, "session", "сессия", "system-lock-screen-symbolic")
  else: setChip(6, "session", "", "")
  if faceOn("scale"):
    var scale = -1
    try:
      for line in readFile(getHomeDir() / ".config/hypr/conf/monitors.conf").splitLines:
        let n = monitorScale(line)
        if n > 0:
          scale = n
          break
    except CatchableError, OSError:
      scale = -1
    if scale < 0: setChip(7, "scale", "", "")
    else: setChip(7, "scale", "×" & $scale, "preferences-desktop-display-symbolic")
  else: setChip(7, "scale", "", "")

proc refreshTray() =
  A.trayGen = sniGeneration()
  for i in 0 ..< A.trayTex.len: A.trayTex[i].free()
  A.trayTex.setLen(0)
  if not sniOwned():
    requestFrame(A.bar)
    return
  for i in 0 ..< min(6, sniCount()):
    let path = themeIcon(sniIcon(i))
    if path.len > 0: A.trayTex.add loadImageTex(path)
    else: A.trayTex.add Tex()
  requestFrame(A.bar)

proc dockNow(): tuple[slot, icon, body, zone, row: int] =
  dockMetrics(A.extras.len, A.faceLabels)

proc openDock() =
  if A.dock.layer != nil: return
  let m = dockNow()
  A.dockSlot = m.slot.float32
  let dw = uint32(dockSpan(1 + A.pins.len, m.slot, 16, 1200))
  createSurf(A.dock, "mazzy-dock", ZWLR_LAYER_SHELL_V1_LAYER_TOP, ZWLR_KB_NONE, true,
             ZWLR_ANCHOR_BOTTOM, int32(m.zone), dw, uint32(m.body), 8)

proc dockResize() =
  if A.dock.layer == nil: return
  let m = dockNow()
  A.dockSlot = m.slot.float32
  let dw = uint32(dockSpan(1 + A.pins.len, m.slot, 16, 1200))
  let dh = uint32(m.body)
  if A.dock.w == int(dw) and A.dock.h == int(dh): return
  zwlr_layer_surface_v1_set_exclusive_zone(A.dock.layer, int32(m.zone))
  zwlr_layer_surface_v1_set_size(A.dock.layer, dw, dh)
  wl_surface_commit(A.dock.surface)

proc reloadFace() =
  let cfg = load()
  A.faceLabels = chromeLabels(cfg)
  A.dismissMs = chromeDismiss(cfg)
  A.faceOpacity = chromeOpacity(cfg)
  A.faceStyle = chromeStyle(cfg)
  A.faceClock = chromeClock(cfg)
  A.faceOrder = chromeOrder(cfg)
  if A.editPick.len > 0 and A.editPick notin A.faceOrder:
    A.editPick = ""
  A.face = initTable[string, bool]()
  for id in widgetIds():
    A.face[id] = chromeWidget(cfg, id)

proc writeChrome(labels: bool, widgetId: string, widgetOn, touchWidget: bool,
                 touchOrder: bool, order: seq[string], opacity: int, style: string) =
  var cfg = load()
  if not cfg.hasKey("chrome") or cfg["chrome"].kind != JObject:
    cfg["chrome"] = newJObject()
  if touchWidget:
    if not cfg["chrome"].hasKey("widgets") or cfg["chrome"]["widgets"].kind != JObject:
      cfg["chrome"]["widgets"] = newJObject()
    cfg["chrome"]["widgets"][widgetId] = %widgetOn
  else:
    cfg["chrome"]["labels"] = %labels
  if touchOrder:
    var arr = newJArray()
    for id in order:
      if id in widgetRightIds(): arr.add newJString(id)
    cfg["chrome"]["order"] = arr
  if opacity >= 0:
    var v = opacity
    if v < 40: v = 40
    if v > 100: v = 100
    cfg["chrome"]["opacity"] = %v
  if style.len > 0:
    let s = if style in ["paper", "ink", "dawn"]: style else: "paper"
    cfg["chrome"]["style"] = %s
  save(cfg)
  reloadFace()
  dockResize()
  requestFrame(A.bar)
  if A.dock.layer != nil: requestFrame(A.dock)
  if A.sheet.layer != nil: requestFrame(A.sheet)

proc previewOpacity(x: float32) =
  let pct = opacityAt(x, A.trackX, A.trackW)
  if pct == A.faceOpacity: return
  A.faceOpacity = pct
  for i, r in A.menuRows.mpairs:
    if r.kind != mkSlide: continue
    r.title = "Плотность " & $pct & "%"
    r.tex.free()
    r.tex = textTex(r.title, "Inter 13", 220, 1.0, 0)
    break
  requestFrame(A.bar)
  if A.dock.layer != nil: requestFrame(A.dock)
  if A.sheet.layer != nil: requestFrame(A.sheet)

proc commitOpacity() =
  writeChrome(A.faceLabels, "", false, false, opacity = A.faceOpacity)
  if A.sheetKind == 5:
    loadMenu()
    A.sheetKey = ""
    requestFrame(A.sheet)

proc writeClockMode(mode: string) =
  let m = if mode in ["time", "date", "hands"]: mode else: "time"
  var cfg = load()
  if not cfg.hasKey("chrome") or cfg["chrome"].kind != JObject:
    cfg["chrome"] = newJObject()
  cfg["chrome"]["clock"] = %m
  save(cfg)
  reloadFace()
  A.clockStamp = ""
  refreshStatus()
  requestFrame(A.bar)
  if A.dock.layer != nil: requestFrame(A.dock)
  if A.sheet.layer != nil: requestFrame(A.sheet)

proc chromeStart() =
  let top = ZWLR_ANCHOR_TOP or ZWLR_ANCHOR_LEFT or ZWLR_ANCHOR_RIGHT
  reloadFace()
  loadPins()
  if A.bar.layer == nil:
    createSurf(A.bar, "mazzy-bar", ZWLR_LAYER_SHELL_V1_LAYER_TOP, ZWLR_KB_NONE, true, top, 36, 0, 36)
  openDock()
  if A.logoTex.id == 0:
    A.logoTex = loadImageTex(getHomeDir() / ".local/share/icons/hicolor/256x256/apps/mazzy.png")
  if A.numTex[0].id == 0:
    for i in 0 ..< DeskCount:
      A.numTex[i] = textTex($(i + 1), "Inter Semi-Bold 12", 28)
  A.wsId = seatActiveWorkspace()
  if A.ctlIconFor.len == 0:
    A.ctlIconFor = controlsIconName()
    let path = themeIcon(A.ctlIconFor)
    if path.len > 0: A.ctlIcon = loadImageTex(path)
  if A.brIconFor.len == 0:
    A.brIconFor = brightIconName()
    let path = themeIcon(A.brIconFor)
    if path.len > 0: A.brIcon = loadImageTex(path)
  if A.layoutIcon.id == 0:
    let path = themeIcon("input-keyboard-symbolic")
    if path.len > 0: A.layoutIcon = loadImageTex(path)
  A.barHot = -1
  A.dockHot = -1
  refreshStatus()

proc dockToggle() =
  if A.dock.layer == nil:
    openDock()
  else:
    destroySurf(A.dock)

proc chipAt(x: float32): int =
  if x >= 46 and x < 46 + DeskCount.float32 * 32:
    let i = int((x - 46) / 32) + 1
    if i in 1 .. DeskCount: return i
  0

proc trayAt(x: float32): int =
  for i in 0 ..< A.trayN:
    if x >= A.trayX[i] and x < A.trayX[i] + 22: return i
  -1

proc toggleMic() =
  spawn(@["wpctl", "set-mute", "@DEFAULT_AUDIO_SOURCE@", "toggle"])
  A.micFor = ""
  A.micIconFor = ""
  A.statusAt = 0

proc extraAt(x: float32): int =
  for i in 0 ..< A.chipKey.len:
    if hitStatus(x, A.moreX[i], A.moreW[i]): return i
  -1

proc barClick(x: float32) =
  let tray = trayAt(x)
  if tray >= 0:
    closeSheet()
    sniActivate(tray, int(x), int(A.hitY))
    return
  if hitStatus(x, A.ctlX, A.ctlW):
    openMenu(0)
    return
  if hitStatus(x, A.layoutX, A.layoutW):
    seatLayoutCycle()
    A.layoutFor = ""
    refreshStatus()
    return
  if hitStatus(x, A.volX, A.volW):
    openSheet(1)
    return
  if hitStatus(x, A.brX, A.brW):
    openSheet(2)
    return
  if hitStatus(x, A.micX, A.micW):
    closeSheet()
    toggleMic()
    return
  if hitStatus(x, A.profX, A.profW):
    openSheet(4)
    return
  if hitStatus(x, A.vpnX, A.vpnW):
    closeSheet()
    openSettings("system")
    return
  let extra = extraAt(x)
  if extra >= 0:
    case A.chipKey[extra]
    of "dnd":
      spawn(@["makoctl", "mode", "-t", "do-not-disturb"])
      A.statusAt = 0
    of "bluetooth":
      spawn(@["rfkill", "toggle", "bluetooth"])
      A.statusAt = 0
    of "media":
      openMenu(0)
    of "shot":
      let dir = getHomeDir() / "Pictures"
      createDir(dir)
      let name = "mazzy-" & format(getTime().local, "yyyyMMdd-HHmmss") & ".png"
      spawn(@["grim", dir / name])
    of "clip":
      openSheet(8)
    of "session":
      openSheet(10)
    else: discard
    return
  if hitStatus(x, A.clockX, A.clockW):
    openSheet(3)
    return
  if x < 44:
    openMenu(1)
    return
  closeSheet()
  if hitStatus(x, A.netX, A.netW):
    openSheet(6)
    return
  if hitStatus(x, A.batX, A.batW):
    openSettings("system")
    return
  let i = chipAt(x)
  if i > 0:
    A.wsId = i
    seatView(i)
    requestFrame(A.bar)

proc barTake(x: float32) =
  ## Правая кнопка на чипе уносит сфокусированное окно на этот стол.
  let i = chipAt(x)
  if i > 0:
    A.wsId = i
    seatTake(i)
    requestFrame(A.bar)

proc dockClick(x, y: float32) =
  let m = dockNow()
  let slot = m.slot.float32
  if A.extras.len > 0 and y >= m.row.float32:
    let start2 = max(8'f32, (A.dock.w.float32 - A.extras.len.float32 * slot) / 2)
    if x < start2: return
    let j = int((x - start2) / slot)
    if j >= 0 and j < A.extras.len and A.extras[j].id.len > 0:
      seatFocus(Win(address: A.extras[j].id, class: A.extras[j].label))
    return
  let n = 1 + A.pins.len
  let start = max(8'f32, (A.dock.w.float32 - n.float32 * slot) / 2)
  if x < start: return
  let i = int((x - start) / slot)
  if i == 0: openMenu(1)
  elif i - 1 < A.pins.len: spawn(@["gtk-launch", A.pins[i - 1].id])

proc barHotAt(x: float32): int =
  let extra = extraAt(x)
  if extra >= 0: return 40 + extra
  if hitStatus(x, A.ctlX, A.ctlW): return 23
  if hitStatus(x, A.volX, A.volW): return 20
  if hitStatus(x, A.brX, A.brW): return 24
  if hitStatus(x, A.micX, A.micW): return 25
  if hitStatus(x, A.profX, A.profW): return 26
  if hitStatus(x, A.vpnX, A.vpnW): return 27
  if hitStatus(x, A.netX, A.netW): return 22
  if hitStatus(x, A.batX, A.batW): return 21
  if hitStatus(x, A.clockX, A.clockW): return 28
  if hitStatus(x, A.layoutX, A.layoutW): return 29
  if x < 44: return 0
  let tray = trayAt(x)
  if tray >= 0: return 30 + tray
  let chip = chipAt(x)
  if chip > 0: return chip
  -1

proc dockHotAt(x: float32): int =
  let slot = if A.dockSlot > 0: A.dockSlot else: dockNow().slot.float32
  let n = 1 + A.pins.len
  let start = max(8'f32, (A.dock.w.float32 - n.float32 * slot) / 2)
  if x < start: return -1
  let i = int((x - start) / slot)
  if i < 0 or i > A.pins.len: -1 else: i

proc swTick(dt: float32): bool =
  A.pos = mz_smooth(A.pos, A.target, dt, 14)
  A.alpha = mz_smooth(A.alpha, A.alphaTarget, dt, 10)
  A.parX = mz_smooth(A.parX, A.mouseX - 0.5, dt, 6)
  A.parY = mz_smooth(A.parY, A.mouseY - 0.5, dt, 6)
  result = abs(A.pos - A.target) > 0.002 or abs(A.alpha - A.alphaTarget) > 0.004 or
           abs(A.parX - (A.mouseX - 0.5)) > 0.002 or abs(A.parY - (A.mouseY - 0.5)) > 0.002

proc renderScrim() =
  paintChrome(A.scrim, proc() =
    let w = A.scrim.w.float32
    let h = A.scrim.h.float32
    putBox(0, 0, w, h, w, h, Tex(), 0, 1, (0'f32, 0'f32, 0'f32, 0.16'f32))
  , 0)

proc renderOsd() =
  let look = chromeInk(if A.faceStyle.len == 0: "paper" else: A.faceStyle)
  let dens = if A.faceOpacity <= 0: 1'f32 else: A.faceOpacity.float32 / 100
  paintChrome(A.osd, proc() =
    let w = A.osd.w.float32
    let h = A.osd.h.float32
    putBox(8, 8, w - 16, h - 16, w, h, Tex(), 18, 1,
           (look.plateR, look.plateG, look.plateB, dens))
    if A.osdTex.id != 0:
      putBox((w - A.osdTex.w.float32) / 2, (h - A.osdTex.h.float32) / 2,
             A.osdTex.w.float32, A.osdTex.h.float32, w, h, A.osdTex, 0, 0,
             (1'f32, 1'f32, 1'f32, 1'f32))
  , 0)

proc render(s: var Surf) =
  if not s.configured or not s.visible: return
  let t = now()
  let dt = if A.lastFrame == 0: 0.016'f32 else: min(0.08, t - A.lastFrame).float32
  if s.ns == "mazzy-wallpaper":
    # обои — не чаще 30 fps: ранний кадр откладывается таймером главного цикла, без commit
    # (любой commit заставляет Hyprland делать проход рендера; при 60 fps он тратил 10–20 % CPU на параллакс)
    if t - A.lastWall < 0.031: A.wallDue = A.lastWall + 0.033; return
    let wdt = if A.lastWall == 0: 0.033'f32 else: min(0.1, t - A.lastWall).float32
    let moving = wallTick(wdt)
    renderWall()
    A.lastWall = t
    if moving: requestFrame(s)
  elif s.ns == "mazzy-bar":
    renderBar()
  elif s.ns == "mazzy-dock":
    renderDock()
  elif s.ns == "mazzy-sheet":
    renderSheet()
  elif s.ns == "mazzy-scrim":
    renderScrim()
  elif s.ns == "mazzy-osd":
    renderOsd()
  else:
    let moving = swTick(dt)
    renderSwitcher()
    discard eglSwapBuffers(A.egl, s.eglSurf)
    if A.alphaTarget == 0 and A.alpha < 0.02:
      destroySurf(A.sw)
      if A.cap.mode == cmNone: releaseThumbPool()
    elif moving: requestFrame(s)
  A.lastFrame = t

# ------------------------------------------------------------------ карусель: логика
proc requestFrameSw() = requestFrame(A.sw)

proc swMove(d: int) =
  let n = A.wins.len
  if n == 0: return
  A.target = (((A.target.int + d) mod n + n) mod n).float32
  # Раскладка линейная: сдвиг pos на n ставил выбранную карточку не в центр.
  A.titleFor = -1
  scheduleThumbs(((A.target.int mod n) + n) mod n)
  requestFrame(A.sw)

proc swShow(d: int) =
  if A.sw.layer != nil and A.alphaTarget > 0:
    swMove(d); return
  A.wins = seatClients()
  if A.wins.len == 0: return
  A.pos = 0; A.target = 0; A.alpha = 0; A.alphaTarget = 1; A.parX = 0; A.parY = 0
  A.mouseX = 0.5; A.mouseY = 0.5; A.hover = -1; A.titleFor = -1
  if A.sw.layer == nil: createSurf(A.sw, "mazzy-switcher", ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY, ZWLR_KB_EXCLUSIVE, true)
  noteThumbs()
  if A.wins.len > 1: swMove(d)
  else: scheduleThumbs(0)

proc swHide() =
  if A.sw.layer == nil: return
  A.alphaTarget = 0
  requestFrame(A.sw)

proc swSelect() =
  if A.sw.layer == nil or A.alphaTarget == 0: return
  if A.wins.len > 0:
    let w = A.wins[((A.target.int mod A.wins.len) + A.wins.len) mod A.wins.len]
    seatFocus(w)
  swHide()

proc swCloseSelected() =
  if A.wins.len == 0: return
  let i = ((A.target.int mod A.wins.len) + A.wins.len) mod A.wins.len
  seatClose(A.wins[i].address)
  A.wins.delete(i)
  if A.wins.len == 0: swHide()
  else: A.target = (i mod A.wins.len).float32; A.pos = A.target; A.titleFor = -1; requestFrame(A.sw)

proc cardAt(x, y: float32): int =
  ## хит-тест по проекции центров
  let n = A.wins.len
  if n == 0: return -1
  var lay = newSeq[float32](n * 4)
  mz_layout_cards(n.int32, A.pos, A.cfg.spacing.float32, A.cfg.centerGap.float32, A.cfg.tilt.float32,
                  A.cfg.depth.float32, A.parX, A.cfg.mousePar.float32, addr lay[0])
  var best = -1; var bd = 1e9'f32
  for i in 0 ..< n:
    let cx = lay[i*4]; let z = lay[i*4+1]
    let s = 1400'f32 / (1400'f32 - z)
    let win = A.wins[i]
    var tw = max(1, win.w).float32
    var th = max(1, win.h).float32
    if A.thumbs.hasKey(win.address):
      let t = A.thumbs[win.address]
      if t.w > 0 and t.h > 0: tw = t.w.float32; th = t.h.float32
    let fit = min(A.cfg.cardW.float32 / tw, A.cfg.cardH.float32 / th)
    let sx = A.sw.w.float32 / 2 + cx * s; let sy = A.sw.h.float32 / 2 - 30
    let hw = tw * fit / 2 * s; let hh = th * fit / 2 * s
    if abs(x - sx) < hw and abs(y - sy) < hh and abs(z) < bd: best = i; bd = abs(z)
  best

# ------------------------------------------------------------------ ввод
proc onKeymap(data: pointer, kb: ptr wl_keyboard, format: uint32, fd: int32, size: uint32) {.cdecl.} =
  let m = mmap(nil, size.int, PROT_READ, MAP_PRIVATE, fd, 0)
  if m != MAP_FAILED:
    if A.xkbState != nil: xkb_state_unref(A.xkbState)
    if A.keymap != nil: xkb_keymap_unref(A.keymap)
    A.keymap = xkb_keymap_new_from_string(A.xkb, cast[cstring](m), XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS)
    if A.keymap != nil: A.xkbState = xkb_state_new(A.keymap)
    discard munmap(m, size.int)
  discard close(fd)
proc onKbEnter(data: pointer, kb: ptr wl_keyboard, serial: uint32, surface: ptr wl_surface, keys: ptr wl_array) {.cdecl.} = discard
proc onKbLeave(data: pointer, kb: ptr wl_keyboard, serial: uint32, surface: ptr wl_surface) {.cdecl.} = discard
proc xkb_state_key_get_utf8(state: ptr xkb_state, keycode: uint32, buffer: cstring, size: int): cint {.importc, header: "<xkbcommon/xkbcommon.h>".}

proc menuType(sym, key: uint32) =
  const backSpace = 0xff08'u32
  if sym == XKB_KEY_Escape:
    closeSheet()
    return
  if sym == XKB_KEY_Return or sym == XKB_KEY_KP_Enter:
    var slots: seq[MenuSlot]
    for r in A.menuRows: slots.add MenuSlot(kind: r.kind, id: r.id)
    let id = menuReturnId(A.menuQuery, slots)
    if id.len > 0:
      closeSheet()
      rememberLaunch(id)
      spawn(@["gtk-launch", id])
    return
  if sym == backSpace:
    if A.menuQuery.len > 0:
      var i = A.menuQuery.len - 1
      while i > 0 and (int(A.menuQuery[i]) and 0b1100_0000) == 0b1000_0000: dec i
      A.menuQuery.setLen(i)
  else:
    if A.menuQuery.len >= 24: return
    var buf = newString(8)
    let n = xkb_state_key_get_utf8(A.xkbState, key + 8, buf.cstring, buf.len)
    if n <= 0: return
    let ch = buf[0 ..< n]
    if ch.len == 0 or ch[0] < ' ': return
    A.menuQuery.add ch
    if A.menuTab != 2: A.menuTab = 1
  loadMenu()
  A.sheetLine = if A.menuQuery.len == 0: "Поиск" else: A.menuQuery
  A.sheetKey = ""
  requestFrame(A.sheet)

proc onKey(data: pointer, kb: ptr wl_keyboard, serial, time, key, state: uint32) {.cdecl.} =
  if A.xkbState == nil: return
  let sym = xkb_state_key_get_one_sym(A.xkbState, key + 8)
  if state == WL_KEYBOARD_KEY_STATE_PRESSED and A.sheetKind == 5 and A.sheet.layer != nil:
    menuType(sym, key)
    return
  if A.sw.layer == nil: return
  if state == WL_KEYBOARD_KEY_STATE_PRESSED:
    let shift = xkb_state_mod_name_is_active(A.xkbState, "Shift", XKB_STATE_MODS_EFFECTIVE) > 0
    let super = xkb_state_mod_name_is_active(A.xkbState, "Mod4", XKB_STATE_MODS_EFFECTIVE) > 0
    case sym
    of XKB_KEY_Tab, XKB_KEY_Right, XKB_KEY_Down: swMove(if shift: -1 else: 1)
    of XKB_KEY_ISO_Left_Tab, XKB_KEY_Left, XKB_KEY_Up: swMove(-1)
    of XKB_KEY_Return, XKB_KEY_KP_Enter, XKB_KEY_space: swSelect()
    of XKB_KEY_Escape: swHide()
    of XKB_KEY_q, XKB_KEY_w:
      if super: swCloseSelected()
    else: discard
  else:
    if sym in [XKB_KEY_Super_L, XKB_KEY_Super_R, XKB_KEY_Alt_L, XKB_KEY_Alt_R]: swSelect()
proc onModifiers(data: pointer, kb: ptr wl_keyboard, serial, dep, lat, loc, group: uint32) {.cdecl.} =
  if A.xkbState != nil: discard xkb_state_update_mask(A.xkbState, dep, lat, loc, 0, 0, group)
proc onRepeat(data: pointer, kb: ptr wl_keyboard, rate, delay: int32) {.cdecl.} = discard
var kbListener = wl_keyboard_listener(keymap: onKeymap, enter: onKbEnter, leave: onKbLeave, key: onKey, modifiers: onModifiers, repeat_info: onRepeat)

proc onPtrEnter(data: pointer, p: ptr wl_pointer, serial: uint32, surface: ptr wl_surface, sx, sy: int32) {.cdecl.} =
  A.hitSurf = surface
  A.hitX = sx.float32 / 256
  A.hitY = sy.float32 / 256
  if surface == A.sheet.surface: A.leaveAt = 0
proc onPtrLeave(data: pointer, p: ptr wl_pointer, serial: uint32, surface: ptr wl_surface) {.cdecl.} =
  if A.hitSurf == surface: A.hitSurf = nil
  if A.bar.surface == surface: A.barHot = -1; requestFrame(A.bar)
  if A.dock.surface == surface: A.dockHot = -1; A.dockCapFor = ""; requestFrame(A.dock)
  if A.sheet.surface == surface:
    if A.sheetDrag:
      A.sheetDrag = false
      if A.sheetKind == 5: commitOpacity()
      else: applySheet(A.sheetPct, true)
    elif A.dismissMs > 0:
      A.leaveAt = now()
proc onPtrMotion(data: pointer, p: ptr wl_pointer, time: uint32, sx, sy: int32) {.cdecl.} =
  let x = sx.float32 / 256
  let y = sy.float32 / 256
  A.hitX = x
  A.hitY = y
  if A.hitSurf == A.sw.surface and A.sw.layer != nil:
    A.mouseX = x / max(1, A.sw.w).float32
    A.mouseY = y / max(1, A.sw.h).float32
    A.hover = cardAt(x, y)
    requestFrame(A.sw)
  elif A.hitSurf == A.bar.surface:
    let hot = barHotAt(x)
    if hot != A.barHot: A.barHot = hot; requestFrame(A.bar)
  elif A.hitSurf == A.sheet.surface and A.sheetDrag:
    if A.sheetKind == 5: previewOpacity(x)
    else: applySheet(sliderPct(x, A.trackX, A.trackW), false)
  elif A.hitSurf == A.dock.surface:
    let hot = dockHotAt(x)
    if hot != A.dockHot: A.dockHot = hot; requestFrame(A.dock)
proc bumpDesk(delta: int) =
  let t = now()
  if t - A.deskScrollAt < 0.12: return
  A.deskScrollAt = t
  var id = A.wsId + delta
  if id < 1: id = 1
  if id > DeskCount: id = DeskCount
  if id == A.wsId: return
  A.wsId = id
  seatView(id)
  requestFrame(A.bar)

proc onPtrButton(data: pointer, p: ptr wl_pointer, serial, time, button, state: uint32) {.cdecl.} =
  if A.hitSurf == A.scrim.surface and button == BTN_LEFT and state == 0:
    if not A.sheetDrag: closeSheet()
    return
  if A.hitSurf == A.sheet.surface and button == BTN_LEFT:
    sheetPress(A.hitX, A.hitY, state != 0)
    return
  if state != 0: return
  if button != BTN_LEFT and button != BTN_RIGHT: return
  if A.hitSurf == A.sw.surface and A.sw.layer != nil and button == BTN_LEFT:
    let i = A.hover
    if i >= 0 and A.wins.len > 0:
      if i == ((A.target.int mod A.wins.len) + A.wins.len) mod A.wins.len: swSelect()
      else: A.target = i.float32; A.titleFor = -1; requestFrame(A.sw)
  elif A.hitSurf == A.bar.surface:
    if button == BTN_RIGHT: barTake(A.hitX)
    else: barClick(A.hitX)
  elif A.hitSurf == A.dock.surface and button == BTN_LEFT:
    dockClick(A.hitX, A.hitY)
proc onPtrAxis(data: pointer, p: ptr wl_pointer, time, axis: uint32, value: int32) {.cdecl.} =
  if A.hitSurf == A.sw.surface and A.sw.layer != nil:
    if value > 0: swMove(1) elif value < 0: swMove(-1)
    return
  if axis != 0: return
  if A.hitSurf == A.bar.surface and chipAt(A.hitX) > 0:
    if value > 0: bumpDesk(1)
    elif value < 0: bumpDesk(-1)
    return
  if A.hitSurf == A.sheet.surface:
    if A.sheetKind == 1:
      if value < 0: bumpVolume(true) elif value > 0: bumpVolume(false)
    elif A.sheetKind == 2:
      if value < 0: bumpBright(true) elif value > 0: bumpBright(false)
    return
  if A.hitSurf == A.bar.surface and hitStatus(A.hitX, A.volX, A.volW):
    if value < 0: bumpVolume(true)
    elif value > 0: bumpVolume(false)
    return
  if A.hitSurf == A.bar.surface and hitStatus(A.hitX, A.brX, A.brW):
    if value < 0: bumpBright(true)
    elif value > 0: bumpBright(false)
proc onPtrFrame(data: pointer, p: ptr wl_pointer) {.cdecl.} = discard
proc onPtrSource(data: pointer, p: ptr wl_pointer, s: uint32) {.cdecl.} = discard
proc onPtrStop(data: pointer, p: ptr wl_pointer, t, a: uint32) {.cdecl.} = discard
proc onPtrDiscrete(data: pointer, p: ptr wl_pointer, a: uint32, d: int32) {.cdecl.} = discard
proc onPtr120(data: pointer, p: ptr wl_pointer, a: uint32, v: int32) {.cdecl.} = discard
proc onPtrDir(data: pointer, p: ptr wl_pointer, a, d: uint32) {.cdecl.} = discard
var ptrListener = wl_pointer_listener(enter: onPtrEnter, leave: onPtrLeave, motion: onPtrMotion, button: onPtrButton, axis: onPtrAxis,
                                      frame: onPtrFrame, axis_source: onPtrSource, axis_stop: onPtrStop, axis_discrete: onPtrDiscrete,
                                      axis_value120: onPtr120, axis_relative_direction: onPtrDir)

proc onSeatCaps(data: pointer, seat: ptr wl_seat, caps: uint32) {.cdecl.} =
  if (caps and WL_SEAT_CAPABILITY_KEYBOARD) != 0 and A.keyboard == nil:
    A.keyboard = wl_seat_get_keyboard(seat); discard wl_keyboard_add_listener(A.keyboard, addr kbListener, nil)
  if (caps and WL_SEAT_CAPABILITY_POINTER) != 0 and A.pointer == nil:
    A.pointer = wl_seat_get_pointer(seat); discard wl_pointer_add_listener(A.pointer, addr ptrListener, nil)
proc onSeatName(data: pointer, seat: ptr wl_seat, name: cstring) {.cdecl.} = discard
var seatListener = wl_seat_listener(capabilities: onSeatCaps, name: onSeatName)

# ------------------------------------------------------------------ обои: логика
proc wallReload()

proc nextWallpaper() =
  var files: seq[string]
  let dir = getHomeDir() / "Pictures/Wallpapers"
  try:
    for kind, name in walkDir(dir):
      if kind == pcFile and name.endsWith(".jpg"): files.add name
  except OSError:
    return
  files.sort()
  if files.len == 0: return
  var i = 0
  for n, f in files:
    if f == A.wallPath: i = (n + 1) mod files.len
  let pick = files[i]
  try:
    createDir(getHomeDir() / ".config/mazzy")
    writeFile(getHomeDir() / ".config/mazzy/wallpaper", pick & "\n")
  except IOError, OSError:
    discard
  wallReload()

proc wallReload() =
  if A.wall.layer == nil: return
  var p = wallpaperPath()
  if p == "": return
  if not fileExists(p) or p == A.wallPath: return
  discard eglMakeCurrent(A.egl, A.wall.eglSurf, A.wall.eglSurf, A.eglCtx)
  let t = loadImageTex(p)
  if t.id == 0: return
  if A.wallTex.id != 0: A.wallOld.free(); A.wallOld = A.wallTex; A.fadeT0 = now()
  A.wallTex = t; A.wallPath = p
  requestFrame(A.wall)

proc wallStart() =
  if A.wall.layer != nil: return
  createSurf(A.wall, "mazzy-wallpaper", ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND, ZWLR_KB_NONE, false)
  A.wallPath = ""
  A.wsOff = ((seatActiveWorkspace() - 3).float * A.cfg.wsPx).float32

proc wallStop() =
  if A.wall.layer == nil: return
  destroySurf(A.wall); A.wallTex.free(); A.wallOld.free(); A.wallPath = ""

proc pollMouse() =
  if A.wall.layer == nil or A.screenW == 0: return
  let (x, y) = seatCursor()
  let mx = clamp((x / A.screenW.float - 0.5) * 2, -1, 1).float32
  let my = clamp((y / A.screenH.float - 0.5) * 2, -1, 1).float32
  if abs(mx - A.mx) > 0.01 or abs(my - A.my) > 0.01:
    A.mx = mx; A.my = my; A.mouseIdle = 0; requestFrame(A.wall)
  elif A.mouseIdle < 100: inc A.mouseIdle

proc mousePollPeriod(): float =
  ## мышь стоит ≥ 2 с → 2 Гц (IPC к Hyprland — работа и в его процессе тоже), при движении — mouse_hz
  let hz = max(1.0, A.cfg.mouseHz)
  if A.mouseIdle.float >= 2 * hz: 0.5 else: 1 / hz

# ------------------------------------------------------------------ управляющие сокеты
proc listenUnix(path: string): SocketHandle =
  discard tryRemoveFile(path)
  var s = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  s.bindUnix(path); s.listen()
  GC_ref(s)
  s.getFd()

proc readCmd(fd: SocketHandle): string =
  var addrLen: SockLen
  let c = posix.accept(fd, nil, addr addrLen)
  if c.cint < 0: return
  var buf = newString(256)
  let n = posix.read(c.cint, addr buf[0], 255)
  discard close(c.cint)
  if n > 0: buf[0 ..< n].strip() else: ""

proc handleSwitcher(cmd: string) =
  when defined(mzdebug):
    let t0 = now()
    defer: stderr.writeLine "cmd switcher: '" & cmd & "' " & $int((now() - t0) * 1000) & " ms t=" & $int(t0 * 1000 mod 100000)
  case cmd
  of "next": swShow(1)
  of "prev": swShow(-1)
  of "toggle": (if A.sw.layer != nil and A.alphaTarget > 0: swHide() else: swShow(1))
  of "select": swSelect()
  of "cancel": swHide()
  of "reload": A.cfg = loadCfg()
  else: discard

proc handleWallpaper(cmd: string) =
  case cmd
  of "reload":
    A.cfg = loadCfg()
    if A.cfg.parEnabled and A.wall.layer == nil: wallStart()
    wallReload(); requestFrame(A.wall)
  of "next": nextWallpaper()
  of "dock": dockToggle()
  of "pins":
    loadPins()
    if A.dock.layer == nil: openDock()
    else:
      dockResize()
      requestFrame(A.dock)
  of "start": (if A.wall.layer == nil: wallStart())
  of "quit", "stop": wallStop()
  of "sheet0": closeSheet()
  of "sheet1", "sheet2", "sheet5", "sheet10":
    if A.sheet.layer != nil: closeSheet()
    openSheet(parseInt(cmd[5 .. ^1]))
  else: discard

# ------------------------------------------------------------------ main
proc main() =
  A.cfg = loadCfg()
  A.hover = -1; A.titleFor = -1; A.shmFd = -1
  A.display = wl_display_connect(nil)
  if A.display == nil: quit("mazzy-shell: нет Wayland-дисплея", 1)
  A.registry = wl_display_get_registry(A.display)
  discard wl_registry_add_listener(A.registry, addr regListener, nil)
  discard wl_display_roundtrip(A.display)
  if A.compositor == nil or A.shell == nil: quit("mazzy-shell: нет wlr-layer-shell", 1)
  if not carouselCaptures(A.exportMgr != nil, A.copyMgr != nil and A.topSrcMgr != nil and A.topList != nil) or A.shm == nil:
    stderr.writeLine "mazzy-shell: карусель без превью"
  discard wl_seat_add_listener(A.seat, addr seatListener, nil)
  A.xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS)
  # EGL
  A.egl = eglGetPlatformDisplay(EGL_PLATFORM_WAYLAND_KHR, A.display, nil)
  var major, minor: EGLint
  if eglInitialize(A.egl, addr major, addr minor) == 0: quit("EGL init failed", 1)
  discard eglBindAPI(EGL_OPENGL_ES_API)
  var attrs = [EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
               EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE]
  var ncfg: EGLint
  discard eglChooseConfig(A.egl, addr attrs[0], addr A.eglCfg, 1, addr ncfg)
  var ctxAttrs = [EGL_CONTEXT_CLIENT_VERSION, 2'i32, EGL_NONE]
  A.eglCtx = eglCreateContext(A.egl, A.eglCfg, nil, addr ctxAttrs[0])
  # первая поверхность нужна, чтобы сделать контекст текущим и собрать шейдеры
  wallStart()
  discard wl_display_roundtrip(A.display)
  while not A.wall.configured: discard wl_display_dispatch(A.display)
  discard eglMakeCurrent(A.egl, A.wall.eglSurf, A.wall.eglSurf, A.eglCtx)
  discard eglSwapInterval(A.egl, 0)
  A.gfx = initGfx()
  if A.cfg.parEnabled: wallReload() else: wallStop()
  render(A.wall)
  chromeStart()
  if sniStart():
    discard sniWaitOwned(400)
  if sniOwned():
    stderr.writeLine "mazzy-shell: трей слушает org.kde.StatusNotifierWatcher"
  else:
    stderr.writeLine "mazzy-shell: имя org.kde.StatusNotifierWatcher не наше — значки трея не рисуем"
  discard wl_display_roundtrip(A.display)

  let rt = getEnv("XDG_RUNTIME_DIR", "/tmp")
  let swFd = listenUnix(rt / "mazzy-switcher.sock")
  let wpFd = listenUnix(rt / "mazzy-wallpaper.sock")
  var evFd: cint = -1
  try: evFd = seatEventsFd()
  except CatchableError, OSError: evFd = -1
  let wlFd = wl_display_get_fd(A.display)
  let mazzyCfg = getHomeDir() / ".config/mazzy"
  createDir(mazzyCfg)
  A.inoFd = cint(inotify_init1(O_NONBLOCK or O_CLOEXEC))
  if A.inoFd >= 0 and inotify_add_watch(A.inoFd, mazzyCfg.cstring, IN_CLOSE_WRITE or IN_MOVED_TO) < 0:
    discard close(A.inoFd); A.inoFd = -1
  var fds = [TPollfd(fd: wlFd, events: POLLIN), TPollfd(fd: swFd.cint, events: POLLIN),
             TPollfd(fd: wpFd.cint, events: POLLIN), TPollfd(fd: evFd, events: POLLIN),
             TPollfd(fd: (if A.inoFd >= 0: A.inoFd else: -1), events: POLLIN)]
  var lastReloadCheck = now()
  var lastEventTry = 0.0
  var wallCheckAt = 0.0        # отложенная проверка после inotify (Noctalia пишет файл несколько раз подряд)
  when defined(mzdebug): stderr.writeLine "fds wl=" & $wlFd & " sw=" & $swFd.cint & " wp=" & $wpFd.cint & " ev=" & $evFd
  while true:
    # правильный цикл libwayland: prepare_read → poll → read_events/cancel_read → dispatch_pending
    while wl_display_prepare_read(A.display) != 0:
      discard wl_display_dispatch_pending(A.display)
    discard wl_display_flush(A.display)
    let t = now()
    var timeout = 250
    if A.captureAt > 0: timeout = min(timeout, max(1, int((A.captureAt - t) * 1000)))
    if A.capDeadline > 0: timeout = min(timeout, max(1, int((A.capDeadline - t) * 1000)))
    if A.wallDue > 0: timeout = min(timeout, max(1, int((A.wallDue - t) * 1000)))
    if wallCheckAt > 0: timeout = min(timeout, max(1, int((wallCheckAt - t) * 1000)))
    if A.sheet.layer != nil and A.leaveAt > 0 and A.dismissMs > 0 and not A.sheetDrag:
      let leftMs = int((A.leaveAt + A.dismissMs.float / 1000.0 - t) * 1000)
      if leftMs <= 0: closeSheet()
      else: timeout = min(timeout, max(1, leftMs))
    let r = poll(addr fds[0], 5, timeout.cint)
    if r > 0 and (fds[0].revents and POLLIN) != 0: discard wl_display_read_events(A.display)
    else: wl_display_cancel_read(A.display)
    discard wl_display_dispatch_pending(A.display)
    if r > 0:
      if (fds[1].revents and POLLIN) != 0: handleSwitcher(readCmd(swFd))
      if (fds[2].revents and POLLIN) != 0: handleWallpaper(readCmd(wpFd))
      if (fds[3].revents and (POLLIN or POLLHUP or POLLERR)) != 0:
        if (fds[3].revents and POLLIN) != 0:
          for line in readLines(evFd, A.evBuf):
            let note = seatParseLine(line)
            if note.ws in 1 .. 20:
              A.wsId = note.ws
              A.wsOff = ((note.ws - 3).float * A.cfg.wsPx).float32
              let occ = seatOccupied()
              if occ != A.occupied: A.occupied = occ
              requestFrame(A.wall)
              requestFrame(A.bar)
            if note.focus.len > 0:
              A.activeAddr = note.focus
              A.captureAt = now() + 0.35
            elif note.ws != 0 and seatKind() == skMango:
              let a = seatFocusedAddress()
              if a.len > 0 and a != A.activeAddr:
                A.activeAddr = a
                A.captureAt = now() + 0.35
            if note.closed.len > 0:
              forgetWindow(note.closed)
              let occ = seatOccupied()
              if occ != A.occupied:
                A.occupied = occ
                requestFrame(A.bar)
        if (fds[3].revents and (POLLHUP or POLLERR)) != 0:
          discard close(evFd)
          A.evBuf = ""
          try:
            evFd = seatEventsFd()
            fds[3].fd = evFd
          except CatchableError, OSError:
            fds[3].fd = -1
      if (fds[4].revents and POLLIN) != 0:
        var buf: array[4096, char]
        while read(A.inoFd, addr buf[0], buf.len) > 0: discard
        wallCheckAt = now() + 0.3
    discard wl_display_dispatch_pending(A.display)
    let t2 = now()
    if A.wallDue > 0 and t2 >= A.wallDue:
      A.wallDue = 0; requestFrame(A.wall)
    if fds[3].fd < 0 and t2 - lastEventTry > 5:
      lastEventTry = t2
      try:
        evFd = seatEventsFd()
        fds[3].fd = evFd
      except CatchableError, OSError:
        discard
    if A.captureAt > 0 and t2 >= A.captureAt:
      A.captureAt = 0
      if A.exportMgr != nil: enqueueCapture(A.activeAddr)   # прогрев только Hyprland
    if A.cap.mode != cmNone and A.capDeadline > 0 and t2 >= A.capDeadline:
      A.cap.drop = true
      finishCapture()
      pumpCapture()
    if A.cfg.parEnabled and A.wall.layer != nil and t2 - A.lastMousePoll >= mousePollPeriod():
      A.lastMousePoll = t2; pollMouse()
    if wallCheckAt > 0 and t2 >= wallCheckAt:
      wallCheckAt = 0
      wallReload()
      reloadFace()
      loadPins()
      dockResize()
      requestFrame(A.bar)
      requestFrame(A.dock)
      if A.sheet.layer != nil: requestFrame(A.sheet)
    sniPump()
    if sniGeneration() != A.trayGen: refreshTray()
    if A.osd.layer != nil and A.osdUntil > 0 and t2 >= A.osdUntil:
      A.osdUntil = 0
      A.osdTex.free()
      A.osdFor = ""
      destroySurf(A.osd)
    if dismissDue(A.leaveAt, t2, A.dismissMs, A.sheetDrag) and A.sheet.layer != nil:
      closeSheet()
    if A.bar.layer != nil and t2 - A.statusAt >= 3:
      A.statusAt = t2
      refreshStatus()
    if t2 - lastReloadCheck > (if A.inoFd >= 0: 300.0 else: 20.0):   # с inotify — редкая страховка
      lastReloadCheck = t2; wallReload()

main()
