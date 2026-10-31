## Биндинги к wayland-client, wayland-egl, EGL, GLES2, xkbcommon и wlr-layer-shell.
## Только то, что нужно mazzy-shell. Всё через importc + системные заголовки.

{.passC: "-I" & currentSourcePath()[0 .. ^8] & "/gen".}
{.passL: "-lwayland-client -lwayland-egl -lEGL -lGLESv2 -lxkbcommon".}
{.passC: "-DWL_EGL_PLATFORM -Wno-incompatible-pointer-types -Wno-int-conversion -Wno-discarded-qualifiers".}
{.compile: "gen/wlr-layer-shell-unstable-v1-protocol.c".}
{.compile: "gen/xdg-shell-protocol.c".}
{.compile: "gen/hyprland-toplevel-export-v1-protocol.c".}
{.compile: "gen/ext-image-copy-capture-v1-protocol.c".}
{.compile: "gen/ext-image-capture-source-v1-protocol.c".}
{.compile: "gen/ext-foreign-toplevel-list-v1-protocol.c".}
# Сгенерированный код ссылается на zwlr_foreign_toplevel_handle_v1_interface (запрос v2, нами не используется —
# менеджер биндится версией 1); XML wlr-foreign-toplevel в системе нет, поэтому заглушка интерфейса.
{.emit: """
#include <wayland-client-core.h>
const struct wl_interface zwlr_foreign_toplevel_handle_v1_interface = { "zwlr_foreign_toplevel_handle_v1", 3, 0, NULL, 0, NULL };
""".}

const
  WlH = "<wayland-client.h>"
  LsH = "wlr-layer-shell-unstable-v1-client-protocol.h"
  TeH = "hyprland-toplevel-export-v1-client-protocol.h"
  EglH = "<EGL/egl.h>"
  GlH = "<GLES2/gl2.h>"
  XkbH = "<xkbcommon/xkbcommon.h>"

type
  wl_display* {.importc: "struct wl_display", header: WlH, incompleteStruct.} = object
  wl_registry* {.importc: "struct wl_registry", header: WlH, incompleteStruct.} = object
  wl_compositor* {.importc: "struct wl_compositor", header: WlH, incompleteStruct.} = object
  wl_surface* {.importc: "struct wl_surface", header: WlH, incompleteStruct.} = object
  wl_seat* {.importc: "struct wl_seat", header: WlH, incompleteStruct.} = object
  wl_keyboard* {.importc: "struct wl_keyboard", header: WlH, incompleteStruct.} = object
  wl_pointer* {.importc: "struct wl_pointer", header: WlH, incompleteStruct.} = object
  wl_output* {.importc: "struct wl_output", header: WlH, incompleteStruct.} = object
  wl_callback* {.importc: "struct wl_callback", header: WlH, incompleteStruct.} = object
  wl_region* {.importc: "struct wl_region", header: WlH, incompleteStruct.} = object
  wl_proxy* {.importc: "struct wl_proxy", header: WlH, incompleteStruct.} = object
  wl_interface* {.importc: "struct wl_interface", header: WlH, incompleteStruct.} = object
  wl_array* {.importc: "struct wl_array", header: WlH.} = object
    size*, alloc*: csize_t
    data*: pointer
  wl_egl_window* {.importc: "struct wl_egl_window", header: "<wayland-egl.h>", incompleteStruct.} = object
  zwlr_layer_shell_v1* {.importc: "struct zwlr_layer_shell_v1", header: LsH, incompleteStruct.} = object
  zwlr_layer_surface_v1* {.importc: "struct zwlr_layer_surface_v1", header: LsH, incompleteStruct.} = object
  wl_shm* {.importc: "struct wl_shm", header: WlH, incompleteStruct.} = object
  wl_shm_pool* {.importc: "struct wl_shm_pool", header: WlH, incompleteStruct.} = object
  wl_buffer* {.importc: "struct wl_buffer", header: WlH, incompleteStruct.} = object
  hyprland_toplevel_export_manager_v1* {.importc: "struct hyprland_toplevel_export_manager_v1", header: TeH, incompleteStruct.} = object
  hyprland_toplevel_export_frame_v1* {.importc: "struct hyprland_toplevel_export_frame_v1", header: TeH, incompleteStruct.} = object

  # Слушатели — по раскладке C-структур из заголовков.
  wl_registry_listener* = object
    global*: proc(data: pointer, reg: ptr wl_registry, name: uint32, iface: cstring, version: uint32) {.cdecl.}
    global_remove*: proc(data: pointer, reg: ptr wl_registry, name: uint32) {.cdecl.}
  wl_callback_listener* = object
    done*: proc(data: pointer, cb: ptr wl_callback, time: uint32) {.cdecl.}
  wl_seat_listener* = object
    capabilities*: proc(data: pointer, seat: ptr wl_seat, caps: uint32) {.cdecl.}
    name*: proc(data: pointer, seat: ptr wl_seat, name: cstring) {.cdecl.}
  wl_keyboard_listener* = object
    keymap*: proc(data: pointer, kb: ptr wl_keyboard, format: uint32, fd: int32, size: uint32) {.cdecl.}
    enter*: proc(data: pointer, kb: ptr wl_keyboard, serial: uint32, surface: ptr wl_surface, keys: ptr wl_array) {.cdecl.}
    leave*: proc(data: pointer, kb: ptr wl_keyboard, serial: uint32, surface: ptr wl_surface) {.cdecl.}
    key*: proc(data: pointer, kb: ptr wl_keyboard, serial, time, key, state: uint32) {.cdecl.}
    modifiers*: proc(data: pointer, kb: ptr wl_keyboard, serial, depressed, latched, locked, group: uint32) {.cdecl.}
    repeat_info*: proc(data: pointer, kb: ptr wl_keyboard, rate, delay: int32) {.cdecl.}
  wl_pointer_listener* = object
    enter*: proc(data: pointer, p: ptr wl_pointer, serial: uint32, surface: ptr wl_surface, sx, sy: int32) {.cdecl.}
    leave*: proc(data: pointer, p: ptr wl_pointer, serial: uint32, surface: ptr wl_surface) {.cdecl.}
    motion*: proc(data: pointer, p: ptr wl_pointer, time: uint32, sx, sy: int32) {.cdecl.}
    button*: proc(data: pointer, p: ptr wl_pointer, serial, time, button, state: uint32) {.cdecl.}
    axis*: proc(data: pointer, p: ptr wl_pointer, time, axis: uint32, value: int32) {.cdecl.}
    frame*: proc(data: pointer, p: ptr wl_pointer) {.cdecl.}
    axis_source*: proc(data: pointer, p: ptr wl_pointer, source: uint32) {.cdecl.}
    axis_stop*: proc(data: pointer, p: ptr wl_pointer, time, axis: uint32) {.cdecl.}
    axis_discrete*: proc(data: pointer, p: ptr wl_pointer, axis: uint32, discrete: int32) {.cdecl.}
    axis_value120*: proc(data: pointer, p: ptr wl_pointer, axis: uint32, v: int32) {.cdecl.}
    axis_relative_direction*: proc(data: pointer, p: ptr wl_pointer, axis, dir: uint32) {.cdecl.}
  zwlr_layer_surface_v1_listener* = object
    configure*: proc(data: pointer, s: ptr zwlr_layer_surface_v1, serial, w, h: uint32) {.cdecl.}
    closed*: proc(data: pointer, s: ptr zwlr_layer_surface_v1) {.cdecl.}
  hyprland_toplevel_export_frame_v1_listener* = object
    buffer*: proc(data: pointer, f: ptr hyprland_toplevel_export_frame_v1, format, w, h, stride: uint32) {.cdecl.}
    damage*: proc(data: pointer, f: ptr hyprland_toplevel_export_frame_v1, x, y, w, h: uint32) {.cdecl.}
    flags*: proc(data: pointer, f: ptr hyprland_toplevel_export_frame_v1, flags: uint32) {.cdecl.}
    ready*: proc(data: pointer, f: ptr hyprland_toplevel_export_frame_v1, secHi, secLo, nsec: uint32) {.cdecl.}
    failed*: proc(data: pointer, f: ptr hyprland_toplevel_export_frame_v1) {.cdecl.}
    linux_dmabuf*: proc(data: pointer, f: ptr hyprland_toplevel_export_frame_v1, format, w, h: uint32) {.cdecl.}
    buffer_done*: proc(data: pointer, f: ptr hyprland_toplevel_export_frame_v1) {.cdecl.}

var
  wl_compositor_interface* {.importc, header: WlH.}: wl_interface
  wl_seat_interface* {.importc, header: WlH.}: wl_interface
  wl_output_interface* {.importc, header: WlH.}: wl_interface
  zwlr_layer_shell_v1_interface* {.importc, header: LsH.}: wl_interface
  wl_shm_interface* {.importc, header: WlH.}: wl_interface
  hyprland_toplevel_export_manager_v1_interface* {.importc, header: TeH.}: wl_interface

proc wl_display_connect*(name: cstring): ptr wl_display {.importc, header: WlH.}
proc wl_display_disconnect*(d: ptr wl_display) {.importc, header: WlH.}
proc wl_display_get_fd*(d: ptr wl_display): cint {.importc, header: WlH.}
proc wl_display_dispatch*(d: ptr wl_display): cint {.importc, header: WlH.}
proc wl_display_dispatch_pending*(d: ptr wl_display): cint {.importc, header: WlH.}
proc wl_display_roundtrip*(d: ptr wl_display): cint {.importc, header: WlH.}
proc wl_display_flush*(d: ptr wl_display): cint {.importc, header: WlH.}
proc wl_display_prepare_read*(d: ptr wl_display): cint {.importc, header: WlH.}
proc wl_display_read_events*(d: ptr wl_display): cint {.importc, header: WlH.}
proc wl_display_cancel_read*(d: ptr wl_display) {.importc, header: WlH.}
proc wl_display_get_registry*(d: ptr wl_display): ptr wl_registry {.importc, header: WlH.}
proc wl_registry_add_listener*(r: ptr wl_registry, l: ptr wl_registry_listener, data: pointer): cint {.importc, header: WlH.}
proc wl_registry_bind*(r: ptr wl_registry, name: uint32, iface: ptr wl_interface, version: uint32): pointer {.importc, header: WlH.}
proc wl_compositor_create_surface*(c: ptr wl_compositor): ptr wl_surface {.importc, header: WlH.}
proc wl_compositor_create_region*(c: ptr wl_compositor): ptr wl_region {.importc, header: WlH.}
proc wl_region_add*(r: ptr wl_region, x, y, w, h: int32) {.importc, header: WlH.}
proc wl_region_destroy*(r: ptr wl_region) {.importc, header: WlH.}
proc wl_surface_set_input_region*(s: ptr wl_surface, r: ptr wl_region) {.importc, header: WlH.}
proc wl_surface_commit*(s: ptr wl_surface) {.importc, header: WlH.}
proc wl_surface_destroy*(s: ptr wl_surface) {.importc, header: WlH.}
proc wl_surface_frame*(s: ptr wl_surface): ptr wl_callback {.importc, header: WlH.}
proc wl_surface_set_buffer_scale*(s: ptr wl_surface, scale: int32) {.importc, header: WlH.}
proc wl_callback_add_listener*(c: ptr wl_callback, l: ptr wl_callback_listener, data: pointer): cint {.importc, header: WlH.}
proc wl_callback_destroy*(c: ptr wl_callback) {.importc, header: WlH.}
proc wl_seat_add_listener*(s: ptr wl_seat, l: ptr wl_seat_listener, data: pointer): cint {.importc, header: WlH.}
proc wl_seat_get_keyboard*(s: ptr wl_seat): ptr wl_keyboard {.importc, header: WlH.}
proc wl_seat_get_pointer*(s: ptr wl_seat): ptr wl_pointer {.importc, header: WlH.}
proc wl_keyboard_add_listener*(k: ptr wl_keyboard, l: ptr wl_keyboard_listener, data: pointer): cint {.importc, header: WlH.}
proc wl_pointer_add_listener*(p: ptr wl_pointer, l: ptr wl_pointer_listener, data: pointer): cint {.importc, header: WlH.}
proc wl_egl_window_create*(s: ptr wl_surface, w, h: cint): ptr wl_egl_window {.importc, header: "<wayland-egl.h>".}
proc wl_egl_window_resize*(w: ptr wl_egl_window, width, height, dx, dy: cint) {.importc, header: "<wayland-egl.h>".}
proc wl_egl_window_destroy*(w: ptr wl_egl_window) {.importc, header: "<wayland-egl.h>".}

const
  WL_SEAT_CAPABILITY_POINTER* = 1'u32
  WL_SEAT_CAPABILITY_KEYBOARD* = 2'u32
  WL_POINTER_BUTTON_STATE_PRESSED* = 1'u32
  WL_KEYBOARD_KEY_STATE_PRESSED* = 1'u32
  BTN_LEFT* = 0x110'u32
  BTN_RIGHT* = 0x111'u32

# --- layer shell
const
  ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND* = 0'u32
  ZWLR_LAYER_SHELL_V1_LAYER_TOP* = 2'u32
  ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY* = 3'u32
  ZWLR_ANCHOR_TOP* = 1'u32
  ZWLR_ANCHOR_BOTTOM* = 2'u32
  ZWLR_ANCHOR_LEFT* = 4'u32
  ZWLR_ANCHOR_RIGHT* = 8'u32
  ZWLR_ANCHOR_ALL* = 15'u32
  ZWLR_KB_NONE* = 0'u32
  ZWLR_KB_EXCLUSIVE* = 1'u32
proc zwlr_layer_shell_v1_get_layer_surface*(sh: ptr zwlr_layer_shell_v1, s: ptr wl_surface, o: ptr wl_output, layer: uint32, ns: cstring): ptr zwlr_layer_surface_v1 {.importc, header: LsH.}
proc zwlr_layer_surface_v1_add_listener*(s: ptr zwlr_layer_surface_v1, l: ptr zwlr_layer_surface_v1_listener, data: pointer): cint {.importc, header: LsH.}
proc zwlr_layer_surface_v1_set_size*(s: ptr zwlr_layer_surface_v1, w, h: uint32) {.importc, header: LsH.}
proc zwlr_layer_surface_v1_set_margin*(s: ptr zwlr_layer_surface_v1, top, right, bottom, left: int32) {.importc, header: LsH.}
proc zwlr_layer_surface_v1_set_anchor*(s: ptr zwlr_layer_surface_v1, a: uint32) {.importc, header: LsH.}
proc zwlr_layer_surface_v1_set_exclusive_zone*(s: ptr zwlr_layer_surface_v1, z: int32) {.importc, header: LsH.}
proc zwlr_layer_surface_v1_set_keyboard_interactivity*(s: ptr zwlr_layer_surface_v1, k: uint32) {.importc, header: LsH.}
proc zwlr_layer_surface_v1_ack_configure*(s: ptr zwlr_layer_surface_v1, serial: uint32) {.importc, header: LsH.}
proc zwlr_layer_surface_v1_destroy*(s: ptr zwlr_layer_surface_v1) {.importc, header: LsH.}

# --- wl_shm / wl_buffer
const
  WL_SHM_FORMAT_ARGB8888* = 0'u32
  WL_SHM_FORMAT_XRGB8888* = 1'u32
proc wl_shm_create_pool*(s: ptr wl_shm, fd: int32, size: int32): ptr wl_shm_pool {.importc, header: WlH.}
proc wl_shm_pool_resize*(p: ptr wl_shm_pool, size: int32) {.importc, header: WlH.}
proc wl_shm_pool_create_buffer*(p: ptr wl_shm_pool, offset, w, h, stride: int32, format: uint32): ptr wl_buffer {.importc, header: WlH.}
proc wl_shm_pool_destroy*(p: ptr wl_shm_pool) {.importc, header: WlH.}
proc wl_buffer_destroy*(b: ptr wl_buffer) {.importc, header: WlH.}

# --- hyprland-toplevel-export: снимок окна по адресу (младшие 32 бита адреса Hyprland)
const HYPRLAND_TOPLEVEL_EXPORT_FRAME_V1_FLAGS_Y_INVERT* = 1'u32
proc hyprland_toplevel_export_manager_v1_capture_toplevel*(m: ptr hyprland_toplevel_export_manager_v1, overlayCursor: int32, handle: uint32): ptr hyprland_toplevel_export_frame_v1 {.importc, header: TeH.}
proc hyprland_toplevel_export_manager_v1_destroy*(m: ptr hyprland_toplevel_export_manager_v1) {.importc, header: TeH.}
proc hyprland_toplevel_export_frame_v1_add_listener*(f: ptr hyprland_toplevel_export_frame_v1, l: ptr hyprland_toplevel_export_frame_v1_listener, data: pointer): cint {.importc, header: TeH.}
proc hyprland_toplevel_export_frame_v1_copy*(f: ptr hyprland_toplevel_export_frame_v1, b: ptr wl_buffer, ignoreDamage: int32) {.importc, header: TeH.}
proc hyprland_toplevel_export_frame_v1_destroy*(f: ptr hyprland_toplevel_export_frame_v1) {.importc, header: TeH.}

# --- Mango: снимок самого окна (ext-image-copy-capture), не прямоугольника экрана
const
  CopyH = "ext-image-copy-capture-v1-client-protocol.h"
  SrcH = "ext-image-capture-source-v1-client-protocol.h"
  TopH = "ext-foreign-toplevel-list-v1-client-protocol.h"

type
  ext_image_copy_capture_manager_v1* {.importc: "struct ext_image_copy_capture_manager_v1", header: CopyH, incompleteStruct.} = object
  ext_image_copy_capture_session_v1* {.importc: "struct ext_image_copy_capture_session_v1", header: CopyH, incompleteStruct.} = object
  ext_image_copy_capture_frame_v1* {.importc: "struct ext_image_copy_capture_frame_v1", header: CopyH, incompleteStruct.} = object
  ext_image_capture_source_v1* {.importc: "struct ext_image_capture_source_v1", header: SrcH, incompleteStruct.} = object
  ext_foreign_toplevel_image_capture_source_manager_v1* {.importc: "struct ext_foreign_toplevel_image_capture_source_manager_v1", header: SrcH, incompleteStruct.} = object
  ext_foreign_toplevel_list_v1* {.importc: "struct ext_foreign_toplevel_list_v1", header: TopH, incompleteStruct.} = object
  ext_foreign_toplevel_handle_v1* {.importc: "struct ext_foreign_toplevel_handle_v1", header: TopH, incompleteStruct.} = object
  ext_image_copy_capture_session_v1_listener* = object
    buffer_size*: proc(data: pointer, s: ptr ext_image_copy_capture_session_v1, w, h: uint32) {.cdecl.}
    shm_format*: proc(data: pointer, s: ptr ext_image_copy_capture_session_v1, format: uint32) {.cdecl.}
    dmabuf_device*: proc(data: pointer, s: ptr ext_image_copy_capture_session_v1, device: ptr wl_array) {.cdecl.}
    dmabuf_format*: proc(data: pointer, s: ptr ext_image_copy_capture_session_v1, format: uint32, modifiers: ptr wl_array) {.cdecl.}
    done*: proc(data: pointer, s: ptr ext_image_copy_capture_session_v1) {.cdecl.}
    stopped*: proc(data: pointer, s: ptr ext_image_copy_capture_session_v1) {.cdecl.}
  ext_image_copy_capture_frame_v1_listener* = object
    transform*: proc(data: pointer, f: ptr ext_image_copy_capture_frame_v1, transform: uint32) {.cdecl.}
    damage*: proc(data: pointer, f: ptr ext_image_copy_capture_frame_v1, x, y, w, h: int32) {.cdecl.}
    presentation_time*: proc(data: pointer, f: ptr ext_image_copy_capture_frame_v1, secHi, secLo, nsec: uint32) {.cdecl.}
    ready*: proc(data: pointer, f: ptr ext_image_copy_capture_frame_v1) {.cdecl.}
    failed*: proc(data: pointer, f: ptr ext_image_copy_capture_frame_v1, reason: uint32) {.cdecl.}
  ext_foreign_toplevel_list_v1_listener* = object
    toplevel*: proc(data: pointer, list: ptr ext_foreign_toplevel_list_v1, handle: ptr ext_foreign_toplevel_handle_v1) {.cdecl.}
    finished*: proc(data: pointer, list: ptr ext_foreign_toplevel_list_v1) {.cdecl.}
  ext_foreign_toplevel_handle_v1_listener* = object
    closed*: proc(data: pointer, h: ptr ext_foreign_toplevel_handle_v1) {.cdecl.}
    done*: proc(data: pointer, h: ptr ext_foreign_toplevel_handle_v1) {.cdecl.}
    title*: proc(data: pointer, h: ptr ext_foreign_toplevel_handle_v1, title: cstring) {.cdecl.}
    app_id*: proc(data: pointer, h: ptr ext_foreign_toplevel_handle_v1, appId: cstring) {.cdecl.}
    identifier*: proc(data: pointer, h: ptr ext_foreign_toplevel_handle_v1, ident: cstring) {.cdecl.}

var
  ext_image_copy_capture_manager_v1_interface* {.importc, header: CopyH.}: wl_interface
  ext_foreign_toplevel_image_capture_source_manager_v1_interface* {.importc, header: SrcH.}: wl_interface
  ext_foreign_toplevel_list_v1_interface* {.importc, header: TopH.}: wl_interface

proc ext_image_copy_capture_manager_v1_create_session*(m: ptr ext_image_copy_capture_manager_v1, source: ptr ext_image_capture_source_v1, options: uint32): ptr ext_image_copy_capture_session_v1 {.importc, header: CopyH.}
proc ext_image_copy_capture_session_v1_add_listener*(s: ptr ext_image_copy_capture_session_v1, l: ptr ext_image_copy_capture_session_v1_listener, data: pointer): cint {.importc, header: CopyH.}
proc ext_image_copy_capture_session_v1_create_frame*(s: ptr ext_image_copy_capture_session_v1): ptr ext_image_copy_capture_frame_v1 {.importc, header: CopyH.}
proc ext_image_copy_capture_session_v1_destroy*(s: ptr ext_image_copy_capture_session_v1) {.importc, header: CopyH.}
proc ext_image_copy_capture_frame_v1_add_listener*(f: ptr ext_image_copy_capture_frame_v1, l: ptr ext_image_copy_capture_frame_v1_listener, data: pointer): cint {.importc, header: CopyH.}
proc ext_image_copy_capture_frame_v1_destroy*(f: ptr ext_image_copy_capture_frame_v1) {.importc, header: CopyH.}
proc ext_image_copy_capture_frame_v1_attach_buffer*(f: ptr ext_image_copy_capture_frame_v1, b: ptr wl_buffer) {.importc, header: CopyH.}
proc ext_image_copy_capture_frame_v1_damage_buffer*(f: ptr ext_image_copy_capture_frame_v1, x, y, w, h: int32) {.importc, header: CopyH.}
proc ext_image_copy_capture_frame_v1_capture*(f: ptr ext_image_copy_capture_frame_v1) {.importc, header: CopyH.}
proc ext_image_capture_source_v1_destroy*(s: ptr ext_image_capture_source_v1) {.importc, header: SrcH.}
proc ext_foreign_toplevel_image_capture_source_manager_v1_create_source*(m: ptr ext_foreign_toplevel_image_capture_source_manager_v1, handle: ptr ext_foreign_toplevel_handle_v1): ptr ext_image_capture_source_v1 {.importc, header: SrcH.}
proc ext_foreign_toplevel_list_v1_add_listener*(list: ptr ext_foreign_toplevel_list_v1, l: ptr ext_foreign_toplevel_list_v1_listener, data: pointer): cint {.importc, header: TopH.}
proc ext_foreign_toplevel_list_v1_destroy*(list: ptr ext_foreign_toplevel_list_v1) {.importc, header: TopH.}
proc ext_foreign_toplevel_handle_v1_add_listener*(h: ptr ext_foreign_toplevel_handle_v1, l: ptr ext_foreign_toplevel_handle_v1_listener, data: pointer): cint {.importc, header: TopH.}
proc ext_foreign_toplevel_handle_v1_destroy*(h: ptr ext_foreign_toplevel_handle_v1) {.importc, header: TopH.}

# --- EGL
type
  EGLDisplay* = pointer
  EGLConfig* = pointer
  EGLContext* = pointer
  EGLSurface* = pointer
  EGLint* = int32
const
  EGL_NONE* = 0x3038'i32
  EGL_SURFACE_TYPE* = 0x3033'i32
  EGL_WINDOW_BIT* = 0x0004'i32
  EGL_RENDERABLE_TYPE* = 0x3040'i32
  EGL_OPENGL_ES2_BIT* = 0x0004'i32
  EGL_RED_SIZE* = 0x3024'i32
  EGL_GREEN_SIZE* = 0x3023'i32
  EGL_BLUE_SIZE* = 0x3022'i32
  EGL_ALPHA_SIZE* = 0x3021'i32
  EGL_CONTEXT_CLIENT_VERSION* = 0x3098'i32
  EGL_OPENGL_ES_API* = 0x30A0'u32
  EGL_PLATFORM_WAYLAND_KHR* = 0x31D8'u32
proc eglGetPlatformDisplay*(platform: uint32, native: pointer, attribs: pointer): EGLDisplay {.importc, header: EglH.}
proc eglInitialize*(d: EGLDisplay, major, minor: ptr EGLint): uint32 {.importc, header: EglH.}
proc eglBindAPI*(api: uint32): uint32 {.importc, header: EglH.}
proc eglChooseConfig*(d: EGLDisplay, attribs: ptr EGLint, configs: ptr EGLConfig, size: EGLint, num: ptr EGLint): uint32 {.importc, header: EglH.}
proc eglCreateContext*(d: EGLDisplay, c: EGLConfig, share: EGLContext, attribs: ptr EGLint): EGLContext {.importc, header: EglH.}
proc eglCreateWindowSurface*(d: EGLDisplay, c: EGLConfig, win: pointer, attribs: ptr EGLint): EGLSurface {.importc, header: EglH.}
proc eglDestroySurface*(d: EGLDisplay, s: EGLSurface): uint32 {.importc, header: EglH.}
proc eglMakeCurrent*(d: EGLDisplay, draw, read: EGLSurface, c: EGLContext): uint32 {.importc, header: EglH.}
proc eglSwapBuffers*(d: EGLDisplay, s: EGLSurface): uint32 {.importc, header: EglH.}
proc eglSwapInterval*(d: EGLDisplay, i: EGLint): uint32 {.importc, header: EglH.}
proc eglGetError*(): EGLint {.importc, header: EglH.}

# --- GLES2
type
  GLuint* = uint32
  GLint* = int32
  GLenum* = uint32
  GLsizei* = int32
  GLfloatT* = float32
const
  GL_TEXTURE_2D* = 0x0DE1'u32
  GL_TEXTURE0* = 0x84C0'u32
  GL_RGBA* = 0x1908'u32
  GL_RGB* = 0x1907'u32
  GL_UNSIGNED_BYTE* = 0x1401'u32
  GL_TEXTURE_MIN_FILTER* = 0x2801'u32
  GL_TEXTURE_MAG_FILTER* = 0x2800'u32
  GL_TEXTURE_WRAP_S* = 0x2802'u32
  GL_TEXTURE_WRAP_T* = 0x2803'u32
  GL_LINEAR* = 0x2601'u32
  GL_LINEAR_MIPMAP_LINEAR* = 0x2703'u32
  GL_CLAMP_TO_EDGE* = 0x812F'u32
  GL_VERTEX_SHADER* = 0x8B31'u32
  GL_FRAGMENT_SHADER* = 0x8B30'u32
  GL_COMPILE_STATUS* = 0x8B81'u32
  GL_LINK_STATUS* = 0x8B82'u32
  GL_ARRAY_BUFFER* = 0x8892'u32
  GL_STATIC_DRAW* = 0x88E4'u32
  GL_FLOAT* = 0x1406'u32
  GL_TRIANGLE_STRIP* = 0x0005'u32
  GL_COLOR_BUFFER_BIT* = 0x00004000'u32
  GL_BLEND* = 0x0BE2'u32
  GL_ONE* = 1'u32
  GL_ONE_MINUS_SRC_ALPHA* = 0x0303'u32
  GL_UNPACK_ALIGNMENT* = 0x0CF5'u32
  GL_FALSE* = 0'u8
proc glClearColor*(r, g, b, a: GLfloatT) {.importc, header: GlH.}
proc glClear*(mask: GLenum) {.importc, header: GlH.}
proc glViewport*(x, y: GLint, w, h: GLsizei) {.importc, header: GlH.}
proc glEnable*(cap: GLenum) {.importc, header: GlH.}
proc glDisable*(cap: GLenum) {.importc, header: GlH.}
proc glBlendFunc*(s, d: GLenum) {.importc, header: GlH.}
proc glPixelStorei*(p: GLenum, v: GLint) {.importc, header: GlH.}
proc glGenTextures*(n: GLsizei, t: ptr GLuint) {.importc, header: GlH.}
proc glDeleteTextures*(n: GLsizei, t: ptr GLuint) {.importc, header: GlH.}
proc glBindTexture*(target: GLenum, t: GLuint) {.importc, header: GlH.}
proc glActiveTexture*(t: GLenum) {.importc, header: GlH.}
proc glTexImage2D*(target: GLenum, level, ifmt: GLint, w, h: GLsizei, border: GLint, fmt, typ: GLenum, data: pointer) {.importc, header: GlH.}
proc glTexParameteri*(target, pname: GLenum, v: GLint) {.importc, header: GlH.}
proc glGenerateMipmap*(target: GLenum) {.importc, header: GlH.}
proc glCreateShader*(t: GLenum): GLuint {.importc, header: GlH.}
proc glShaderSource*(s: GLuint, n: GLsizei, src: ptr cstring, len: ptr GLint) {.importc, header: GlH.}
proc glCompileShader*(s: GLuint) {.importc, header: GlH.}
proc glGetShaderiv*(s: GLuint, p: GLenum, v: ptr GLint) {.importc, header: GlH.}
proc glGetShaderInfoLog*(s: GLuint, max: GLsizei, len: ptr GLsizei, log: cstring) {.importc, header: GlH.}
proc glCreateProgram*(): GLuint {.importc, header: GlH.}
proc glAttachShader*(p, s: GLuint) {.importc, header: GlH.}
proc glLinkProgram*(p: GLuint) {.importc, header: GlH.}
proc glGetProgramiv*(p: GLuint, pn: GLenum, v: ptr GLint) {.importc, header: GlH.}
proc glGetProgramInfoLog*(p: GLuint, max: GLsizei, len: ptr GLsizei, log: cstring) {.importc, header: GlH.}
proc glUseProgram*(p: GLuint) {.importc, header: GlH.}
proc glGetAttribLocation*(p: GLuint, n: cstring): GLint {.importc, header: GlH.}
proc glGetUniformLocation*(p: GLuint, n: cstring): GLint {.importc, header: GlH.}
proc glUniform1i*(l: GLint, v: GLint) {.importc, header: GlH.}
proc glUniform1f*(l: GLint, v: GLfloatT) {.importc, header: GlH.}
proc glUniform2f*(l: GLint, a, b: GLfloatT) {.importc, header: GlH.}
proc glUniform4f*(l: GLint, a, b, c, d: GLfloatT) {.importc, header: GlH.}
proc glUniformMatrix4fv*(l: GLint, n: GLsizei, transpose: uint8, v: ptr GLfloatT) {.importc, header: GlH.}
proc glGenBuffers*(n: GLsizei, b: ptr GLuint) {.importc, header: GlH.}
proc glBindBuffer*(t: GLenum, b: GLuint) {.importc, header: GlH.}
proc glBufferData*(t: GLenum, size: int, data: pointer, usage: GLenum) {.importc, header: GlH.}
proc glEnableVertexAttribArray*(i: GLuint) {.importc, header: GlH.}
proc glVertexAttribPointer*(i: GLuint, size: GLint, t: GLenum, norm: uint8, stride: GLsizei, p: pointer) {.importc, header: GlH.}
proc glDrawArrays*(mode: GLenum, first: GLint, count: GLsizei) {.importc, header: GlH.}
proc glFinish*() {.importc, header: GlH.}

# --- xkbcommon
type
  xkb_context* {.importc: "struct xkb_context", header: XkbH, incompleteStruct.} = object
  xkb_keymap* {.importc: "struct xkb_keymap", header: XkbH, incompleteStruct.} = object
  xkb_state* {.importc: "struct xkb_state", header: XkbH, incompleteStruct.} = object
const
  XKB_CONTEXT_NO_FLAGS* = 0'i32
  XKB_KEYMAP_FORMAT_TEXT_V1* = 1'i32
  XKB_KEYMAP_COMPILE_NO_FLAGS* = 0'i32
  XKB_KEY_Tab* = 0xff09'u32
  XKB_KEY_ISO_Left_Tab* = 0xfe20'u32
  XKB_KEY_Escape* = 0xff1b'u32
  XKB_KEY_Return* = 0xff0d'u32
  XKB_KEY_KP_Enter* = 0xff8d'u32
  XKB_KEY_space* = 0x020'u32
  XKB_KEY_Left* = 0xff51'u32
  XKB_KEY_Up* = 0xff52'u32
  XKB_KEY_Right* = 0xff53'u32
  XKB_KEY_Down* = 0xff54'u32
  XKB_KEY_Super_L* = 0xffeb'u32
  XKB_KEY_Super_R* = 0xffec'u32
  XKB_KEY_Alt_L* = 0xffe9'u32
  XKB_KEY_Alt_R* = 0xffea'u32
  XKB_KEY_q* = 0x071'u32
  XKB_KEY_w* = 0x077'u32
proc xkb_context_new*(flags: int32): ptr xkb_context {.importc, header: XkbH.}
proc xkb_keymap_new_from_string*(c: ptr xkb_context, s: cstring, format, flags: int32): ptr xkb_keymap {.importc, header: XkbH.}
proc xkb_keymap_unref*(k: ptr xkb_keymap) {.importc, header: XkbH.}
proc xkb_state_new*(k: ptr xkb_keymap): ptr xkb_state {.importc, header: XkbH.}
proc xkb_state_unref*(s: ptr xkb_state) {.importc, header: XkbH.}
proc xkb_state_key_get_one_sym*(s: ptr xkb_state, key: uint32): uint32 {.importc, header: XkbH.}
proc xkb_state_update_mask*(s: ptr xkb_state, dep, lat, loc, l0, l1, l2: uint32): int32 {.importc, header: XkbH.}
proc xkb_state_mod_name_is_active*(s: ptr xkb_state, name: cstring, typ: int32): int32 {.importc, header: XkbH.}
const XKB_STATE_MODS_EFFECTIVE* = 8'i32
