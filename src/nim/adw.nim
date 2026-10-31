## Минимальные биндинги GTK4 + libadwaita для mazzy-settings: только то, что нужно окну настроек.
## Все объекты — `pointer` (void* в C совместим с любым GtkWidget* без приведений).
{.passC: staticExec("pkg-config --cflags libadwaita-1").}
{.passL: staticExec("pkg-config --libs libadwaita-1").}

const H = "<adwaita.h>"

type
  GObj* = pointer
  GCallback* = pointer
  gboolean* = cint
  # обработчики сигналов
  NotifyCb* = proc(obj: GObj, pspec: pointer, data: pointer) {.cdecl.}
  ClickedCb* = proc(btn: GObj, data: pointer) {.cdecl.}
  ActivateCb* = proc(app: GObj, data: pointer) {.cdecl.}
  KeyCb* = proc(ctl: GObj, keyval, keycode: cuint, state: cuint, data: pointer): gboolean {.cdecl.}
  TimeoutCb* = proc(data: pointer): gboolean {.cdecl.}

const
  G_APPLICATION_DEFAULT_FLAGS* = 0'u32
  GTK_ALIGN_CENTER* = 3'i32
  GTK_ORIENTATION_VERTICAL* = 1'i32
  GTK_STACK_TRANSITION_TYPE_CROSSFADE* = 1'i32
  GDK_SHIFT_MASK* = 1'u32 shl 0
  GDK_CONTROL_MASK* = 1'u32 shl 2
  GDK_ALT_MASK* = 1'u32 shl 3
  GDK_SUPER_MASK* = 1'u32 shl 26
  ADW_RESPONSE_DESTRUCTIVE* = 2'i32

# --- GLib / GObject
proc g_signal_connect_data*(obj: GObj, sig: cstring, cb: GCallback, data: pointer, notify: pointer, flags: cint): culong {.importc, header: H.}
proc g_timeout_add*(ms: cuint, cb: TimeoutCb, data: pointer): cuint {.importc, header: H.}
proc g_source_remove*(id: cuint): gboolean {.importc, header: H.}
proc g_markup_escape_text*(s: cstring, len: int): cstring {.importc, header: H.}
proc g_free*(p: pointer) {.importc, header: H.}
proc g_application_run*(app: GObj, argc: cint, argv: pointer): cint {.importc, header: H.}
proc gtk_application_get_active_window*(app: GObj): GObj {.importc, header: H.}

template connect*(obj: GObj, sig: string, cb: typed, data: pointer = nil) =
  discard g_signal_connect_data(obj, sig.cstring, cast[GCallback](cb), data, nil, 0)

# --- Adw application / window
proc adw_application_new*(id: cstring, flags: uint32): GObj {.importc, header: H.}
proc adw_application_window_new*(app: GObj): GObj {.importc, header: H.}
proc adw_application_window_set_content*(w, child: GObj) {.importc, header: H.}
proc gtk_window_set_title*(w: GObj, t: cstring) {.importc, header: H.}
proc gtk_window_set_default_size*(w: GObj, width, height: cint) {.importc, header: H.}
proc gtk_window_present*(w: GObj) {.importc, header: H.}

# --- контейнеры
proc adw_toolbar_view_new*(): GObj {.importc, header: H.}
proc adw_toolbar_view_add_top_bar*(v, bar: GObj) {.importc, header: H.}
proc adw_toolbar_view_set_content*(v, c: GObj) {.importc, header: H.}
proc adw_header_bar_new*(): GObj {.importc, header: H.}
proc adw_toast_overlay_new*(): GObj {.importc, header: H.}
proc adw_toast_overlay_set_child*(o, c: GObj) {.importc, header: H.}
proc adw_toast_overlay_add_toast*(o, t: GObj) {.importc, header: H.}
proc adw_toast_new*(title: cstring): GObj {.importc, header: H.}
proc adw_toast_set_timeout*(t: GObj, sec: cuint) {.importc, header: H.}
proc adw_navigation_split_view_new*(): GObj {.importc, header: H.}
proc adw_navigation_split_view_set_sidebar*(v, p: GObj) {.importc, header: H.}
proc adw_navigation_split_view_set_content*(v, p: GObj) {.importc, header: H.}
proc adw_navigation_split_view_set_min_sidebar_width*(v: GObj, w: cdouble) {.importc, header: H.}
proc adw_navigation_page_new*(child: GObj, title: cstring): GObj {.importc, header: H.}
proc gtk_stack_new*(): GObj {.importc, header: H.}
proc gtk_stack_set_transition_type*(s: GObj, t: cint) {.importc, header: H.}
proc gtk_stack_add_titled*(s, child: GObj, name, title: cstring): GObj {.importc, header: H, discardable.}
proc gtk_stack_page_set_icon_name*(page: GObj, name: cstring) {.importc, header: H.}
proc gtk_stack_get_visible_child_name*(s: GObj): cstring {.importc, header: H.}
proc gtk_stack_set_visible_child_name*(s: GObj, name: cstring) {.importc, header: H.}
proc gtk_stack_sidebar_new*(): GObj {.importc, header: H.}
proc gtk_stack_sidebar_set_stack*(sb, s: GObj) {.importc, header: H.}
proc gtk_box_new*(orient: cint, spacing: cint): GObj {.importc, header: H.}
proc gtk_scale_new_with_range*(orient: cint, min, max, step: cdouble): GObj {.importc, header: H.}
proc gtk_range_set_value*(r: GObj, v: cdouble) {.importc, header: H.}
proc gtk_range_get_value*(r: GObj): cdouble {.importc, header: H.}
proc gtk_widget_set_size_request*(w: GObj, width, height: cint) {.importc, header: H.}
proc gtk_box_append*(b, c: GObj) {.importc, header: H.}
proc gtk_label_new*(s: cstring): GObj {.importc, header: H.}

# --- preferences
proc adw_preferences_page_new*(): GObj {.importc, header: H.}
proc adw_preferences_page_add*(p, g: GObj) {.importc, header: H.}
proc adw_preferences_page_remove*(p, g: GObj) {.importc, header: H.}
proc adw_preferences_page_set_title*(p: GObj, t: cstring) {.importc, header: H.}
proc adw_preferences_page_set_description*(p: GObj, t: cstring) {.importc, header: H.}
proc adw_preferences_page_set_icon_name*(p: GObj, t: cstring) {.importc, header: H.}
proc adw_preferences_group_new*(): GObj {.importc, header: H.}
proc adw_preferences_group_set_title*(g: GObj, t: cstring) {.importc, header: H.}
proc adw_preferences_group_set_description*(g: GObj, t: cstring) {.importc, header: H.}
proc adw_preferences_group_add*(g, c: GObj) {.importc, header: H.}
proc adw_preferences_row_set_title*(r: GObj, t: cstring) {.importc, header: H.}
proc adw_action_row_new*(): GObj {.importc, header: H.}
proc adw_action_row_add_prefix*(row, widget: GObj) {.importc, header: H.}
proc gtk_image_new_from_icon_name*(name: cstring): GObj {.importc, header: H.}
proc adw_action_row_set_subtitle*(r: GObj, t: cstring) {.importc, header: H.}
proc adw_action_row_add_suffix*(r, w: GObj) {.importc, header: H.}
proc adw_action_row_set_activatable_widget*(r, w: GObj) {.importc, header: H.}
proc adw_switch_row_new*(): GObj {.importc, header: H.}
proc adw_switch_row_set_active*(r: GObj, a: gboolean) {.importc, header: H.}
proc adw_switch_row_get_active*(r: GObj): gboolean {.importc, header: H.}
proc gtk_adjustment_new*(value, lower, upper, step, page, pageSize: cdouble): GObj {.importc, header: H.}
proc adw_spin_row_new*(adj: GObj, climb: cdouble, digits: cuint): GObj {.importc, header: H.}
proc adw_spin_row_get_value*(r: GObj): cdouble {.importc, header: H.}
proc adw_spin_row_set_value*(r: GObj, v: cdouble) {.importc, header: H.}
proc adw_combo_row_new*(): GObj {.importc, header: H.}
proc adw_combo_row_set_model*(r, model: GObj) {.importc, header: H.}
proc adw_combo_row_set_selected*(r: GObj, pos: cuint) {.importc, header: H.}
proc adw_combo_row_get_selected*(r: GObj): cuint {.importc, header: H.}
proc gtk_string_list_new*(strings: pointer): GObj {.importc, header: H.}
proc gtk_string_list_append*(l: GObj, s: cstring) {.importc, header: H.}

# --- виджеты
proc gtk_button_new_with_label*(l: cstring): GObj {.importc, header: H.}
proc gtk_button_set_label*(b: GObj, l: cstring) {.importc, header: H.}
proc gtk_widget_set_valign*(w: GObj, a: cint) {.importc, header: H.}
proc gtk_widget_add_css_class*(w: GObj, c: cstring) {.importc, header: H.}
proc gtk_widget_set_sensitive*(w: GObj, s: gboolean) {.importc, header: H.}
proc gtk_widget_set_margin_top*(w: GObj, m: cint) {.importc, header: H.}
proc gtk_widget_set_margin_bottom*(w: GObj, m: cint) {.importc, header: H.}
proc gtk_widget_set_margin_start*(w: GObj, m: cint) {.importc, header: H.}
proc gtk_widget_set_margin_end*(w: GObj, m: cint) {.importc, header: H.}
proc gtk_widget_add_controller*(w, c: GObj) {.importc, header: H.}

# --- подтверждение необратимого действия (сброс чипа роняет Wi-Fi)
proc adw_alert_dialog_new*(heading, body: cstring): GObj {.importc, header: H.}
proc adw_alert_dialog_add_response*(d: GObj, id, label: cstring) {.importc, header: H.}
proc adw_alert_dialog_set_response_appearance*(d: GObj, id: cstring, appearance: cint) {.importc, header: H.}
proc adw_alert_dialog_set_default_response*(d: GObj, id: cstring) {.importc, header: H.}
proc adw_alert_dialog_choose*(d, parent, cancellable: GObj, cb: pointer, data: pointer) {.importc, header: H.}
proc adw_alert_dialog_choose_finish*(d, res: GObj): cstring {.importc, header: H.}

# --- диалог перехвата хоткея
proc adw_dialog_new*(): GObj {.importc, header: H.}
proc adw_dialog_set_title*(d: GObj, t: cstring) {.importc, header: H.}
proc adw_dialog_set_content_width*(d: GObj, w: cint) {.importc, header: H.}
proc adw_dialog_set_child*(d, c: GObj) {.importc, header: H.}
proc adw_dialog_present*(d, parent: GObj) {.importc, header: H.}
proc adw_dialog_close*(d: GObj): gboolean {.importc, header: H, discardable.}
proc gtk_event_controller_key_new*(): GObj {.importc, header: H.}
proc gdk_keyval_name*(k: cuint): cstring {.importc, header: H.}
proc gdk_keyval_to_lower*(k: cuint): cuint {.importc, header: H.}

proc markupEscape*(s: string): string =
  ## g_markup_escape_text → Nim string
  let c = g_markup_escape_text(s.cstring, -1)
  result = $c
  g_free(c)

# --- тема иконок: Papirus (~50k имён) GTK разбирает ~0.4 с на каждую загрузку; окну настроек хватает Adwaita
proc gdk_display_get_default*(): GObj {.importc, header: H.}
proc gtk_icon_theme_get_for_display*(d: GObj): GObj {.importc, header: H.}
proc gtk_icon_theme_set_theme_name*(t: GObj, name: cstring) {.importc, header: H.}
proc gtk_settings_get_default*(): GObj {.importc, header: H.}
proc g_object_set*(obj: GObj, prop: cstring, val: cstring, term: pointer) {.importc, header: H, varargs.}
proc gtk_init*() {.importc, header: H.}
