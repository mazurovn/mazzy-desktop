#!/bin/sh
# MAZZY: Bluetooth-аудио — подключение по событию и управление профилями/устройствами.
# Ставится как /usr/local/bin/mazzy-bt-audio (см. install.sh). Работает без root и без хардкода MAC:
# устройства берутся из BlueZ по профилю Audio Sink.
#
#   mazzy-bt-audio session|resume|after-reset|trigger   — автоматика (юнит mazzy-bt-audio.service)
#   mazzy-bt-audio connect|disconnect [MAC]             — с учётом «пользователь отключил вручную»
#   mazzy-bt-audio profile [auto|a2dp|headset] [MAC]    — режим: авто / стерео / гарнитура
#   mazzy-bt-audio out|in [номер|часть имени]           — выбрать выход / вход по умолчанию
#   mazzy-bt-audio adapter [hciN|MAC|имя|auto]          — какой Bluetooth-адаптер использовать
#       без аргумента — список; `auto` — выбирать самому (вставленный донгл становится основным)
#   mazzy-bt-audio pair [MAC]                           — найти и спарить наушники (с подтверждением кода)
#   mazzy-bt-audio devices|status                       — список устройств / состояние
#
# Почему не «подключать раз в минуту»: слепой `bluetoothctl connect` к выключенным наушникам занимает
# радио на 12 с и пишет `Host is down` в журнал. Обратное подключение — дело самих наушников
# (BlueZ [Policy] ReconnectAttempts). Ноутбук подключает только по событию. См. спеку bt-audio.
set -u
SYS_RUN=/run/mazzy-bt
USER_RUN="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/mazzy-bt"
# Состояние (выбранный адаптер, режимы профилей, вердикты SCO) содержит MAC-адреса устройств,
# а ~/.config/mazzy у MAZZY — симлинк в рабочее дерево публичного репозитория. Поэтому пишем
# в XDG-state, а старый файл из репозитория подхватываем один раз и удаляем.
CFG="${XDG_STATE_HOME:-$HOME/.local/state}/mazzy/bt-audio.conf"
LEGACY_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/mazzy/bt-audio.conf"
if [ ! -e "$CFG" ] && [ -f "$LEGACY_CFG" ]; then
  mkdir -p "$(dirname "$CFG")" && cp "$LEGACY_CFG" "$CFG" && rm -f "$LEGACY_CFG"
fi
WP_AUTOSWITCH=bluetooth.autoswitch-to-headset-profile

ok()  { printf '  \033[32m✔\033[0m %s\n' "$1"; }
bad() { printf '  \033[31m✘\033[0m %s\n' "$1"; }
inf() { printf '  · %s\n' "$1"; }
log() { [ "${MAZZY_BT_QUIET:-0}" = 1 ] || printf '%s\n' "$*"; }

us() { echo "$1" | tr ':' '_'; }

# --- Адаптеры ------------------------------------------------------------
# Адаптеров может быть несколько (встроенный MT7630E и USB-донгл), и номер hciN меняется при
# переподключении, поэтому выбранный адаптер храним по BD-адресу, а hciN резолвим каждый раз.
# Пары BlueZ живут отдельно у каждого адаптера — при смене адаптера наушники надо спарить заново.
adapter_mode() { cfg_raw adapter mode 2>/dev/null || echo auto; }
# Лучший адаптер: у кого голосовой канал заведомо сломан — в конец; из остальных выигрывает тот,
# что появился позже. Донгл при горячем подключении всегда получает номер больше встроенного,
# поэтому «вставил донгл — он главный» работает без привязки к вендору.
adapter_best() {
  hci_map | sort -r | while read -r h mac; do
    st=$(cfg_raw "adapter:$mac" sco 2>/dev/null || echo unknown)
    [ "$st" = broken ] && continue
    echo "$mac"; return
  done | head -1
  # все помечены broken — берём всё равно последний
  hci_map | sort -r | awk 'NR==1 {print $2}'
}
adapter_addr() {
  if [ "$(adapter_mode)" = pinned ]; then
    a=$(cfg_raw adapter use 2>/dev/null || true)
    # закреплённый адаптер вынули — не оставаться без Bluetooth
    [ -n "$a" ] && hci_map | grep -q " $a$" && { echo "$a"; return; }
  fi
  adapter_best | head -1
}
hci_map()      { hciconfig 2>/dev/null | awk '/^hci/{h=$1; sub(":","",h)} /BD Address/{print h, $3}'; }
adapter_hci()  {
  a=$(adapter_addr)
  if [ -n "$a" ]; then hci_map | awk -v a="$a" '$2==a {print $1; exit}'
  else hci_map | awk 'NR==1 {print $1; exit}'; fi
}
adapter_name() {
  h="$1"
  m=$(cat "/sys/class/bluetooth/$h/device/../manufacturer" 2>/dev/null)
  pr=$(cat "/sys/class/bluetooth/$h/device/../product" 2>/dev/null)
  echo "${m:+$m }${pr:-$h}"
}
adapter_powered() {
  busctl --system get-property org.bluez "/org/bluez/$1" org.bluez.Adapter1 Powered 2>/dev/null |
    grep -q true && echo yes || echo no
}
# "hciN|MAC|имя|powered|current"
adapters() {
  cur=$(adapter_addr); [ -n "$cur" ] || cur=$(hci_map | awk 'NR==1 {print $2}')
  hci_map | while read -r h mac; do
    printf '%s|%s|%s|%s|%s\n' "$h" "$mac" "$(adapter_name "$h")" "$(adapter_powered "$h")" \
      "$([ "$mac" = "$cur" ] && echo yes || echo no)"
  done
}
# Выбор адаптера: включаем нужный, остальные выключаем (иначе одноразовые вызовы bluetoothctl
# уходят в адаптер по умолчанию, а не в выбранный).
# Выбранный адаптер включаем, остальные выключаем. Нужно повторять при старте сессии и после
# перезапуска bluetoothd: политика [Policy] AutoEnable=true включает обратно все адаптеры.
adapter_apply() {
  a=$(adapter_addr); [ -n "$a" ] || return 0
  adapters | while IFS='|' read -r ah amac anm ap ac; do
    [ "$amac" = "$a" ] && v=true || v=false
    [ "$ap" = "$([ "$v" = true ] && echo yes || echo no)" ] && continue
    busctl --system set-property org.bluez "/org/bluez/$ah" org.bluez.Adapter1 Powered b $v >/dev/null 2>&1
  done
}

adapter_use() {
  want="$1"
  line=$(adapters | awk -F'|' -v w="$want" 'index($1,w)==1 || $2==w || index(tolower($3), tolower(w)) {print; exit}')
  [ -n "$line" ] || { bad "адаптер не найден: $want"; return 1; }
  h=$(echo "$line" | cut -d'|' -f1); mac=$(echo "$line" | cut -d'|' -f2); nm=$(echo "$line" | cut -d'|' -f3)
  cfg_kv_set adapter use "$mac"
  cfg_kv_set adapter mode pinned
  BT_TABLE=""
  adapter_apply
  sleep 1
  BT_TABLE=""
  ok "адаптер: $nm ($h, $mac)"
  n=$(bt_dev_table | awk -F'|' -v h="$h" '$8==h && $3=="yes" && $5=="yes" {c++} END {print c+0}')
  if [ "$n" = 0 ]; then
    inf "на этом адаптере нет спаренных наушников — их нужно спарить заново (кнопка до мигания),"
    inf "иначе звук пойдёт во встроенные динамики"
  fi
}
cmd_adapter() {
  case "${1:-}" in
    auto) cfg_kv_set adapter mode auto; BT_TABLE=""; adapter_apply
          ok "адаптер выбирается автоматически: $(adapter_hci) ($(adapter_name "$(adapter_hci)"))"
          inf "вставленный донгл становится основным сам"; return 0 ;;
    ?*)   adapter_use "$1"; return $? ;;
  esac
  echo "== Адаптеры Bluetooth  (режим выбора: $(adapter_mode))"
  adapters | while IFS='|' read -r h mac nm p c; do
    mark='  '; [ "$c" = yes ] && mark=' *'
    printf '%s %s  %s  %s%s\n' "$mark" "$h" "$nm" "$mac" "$([ "$p" = yes ] && echo "" || echo "  (выключен)")"
  done
  if [ "$(adapter_mode)" = pinned ]; then
    inf "закреплён вручную; вернуть автоматику: mazzy-bt-audio adapter auto"
  fi
  return 0
}

# Вывод bluetoothctl: снять ANSI-раскраску и приглашение вида «[Имя]> » в начале строки
clean_bt() { sed 's/\x1b\[[0-9;]*m//g; s/^\[[^]]*\][#>] *//; s/^[[:space:]]*\[[A-Z]*\] //' "$@"; }

# Команда bluetoothctl в контексте выбранного адаптера: одноразовый вызов уходит в адаптер
# по умолчанию, поэтому при явном выборе открываем сессию с `select <MAC>`.
btctl() {
  a=$(adapter_addr)
  if [ -z "$a" ]; then bluetoothctl "$@" 2>/dev/null; return; fi
  { printf 'select %s\n' "$a"; printf '%s\n' "$*"; echo quit; } | bluetoothctl 2>/dev/null | clean_bt
}

# --- BlueZ: чтение через D-Bus -------------------------------------------
# Читаем состояние одним вызовом GetManagedObjects (19 мс) вместо сессий bluetoothctl (~0.5 с каждая):
# заодно объекты лежат по путям /org/bluez/<hci>/dev_..., то есть выборка по адаптеру точная.
# bluetoothctl остаётся только для действий (pair/connect/scan) — там нужен агент и интерактив.
bt_objects() { busctl --system tree org.bluez --list 2>/dev/null; }

# MAC|Имя|paired|connected|audio|headset|батарея|hciN — устройства ВСЕХ адаптеров.
# Показывать только выбранный адаптер нельзя: пары живут у каждого адаптера свои, и при переключении
# на донгл наушники, спаренные со встроенным чипом, просто исчезали из списков (проверено 2026-09-23).
# Читаем plain-выводом busctl, а не `--json`: JSON-дамп всего дерева падает целиком
# («Failed to dump DBus message to JSON object»), стоит появиться BLE-устройству с ManufacturerData.
bt_dev_table() {
  [ -n "${BT_TABLE:-}" ] && { printf '%s\n' "$BT_TABLE"; return; }
  BT_TABLE=$(bt_objects | grep -E '^/org/bluez/hci[0-9]+/dev_[0-9A-F_]+$' | while read -r path; do
    dh=$(echo "$path" | sed -n 's|^/org/bluez/\(hci[0-9]*\)/.*|\1|p')
    out=$(busctl --system get-property org.bluez "$path" org.bluez.Device1 \
            Address Name Paired Connected Icon Class UUIDs 2>/dev/null) || continue
    [ -n "$out" ] || continue
    bat=$(busctl --system get-property org.bluez "$path" org.bluez.Battery1 Percentage 2>/dev/null |
          awk '{print $2}')
    echo "$out" | awk -v dh="$dh" -v bat="${bat:-}" '
      function unq(x) { gsub(/^"|"$/, "", x); return x }
      NR==1 { addr=unq($2) }
      NR==2 { $1=""; sub(/^ /,""); name=unq($0) }
      NR==3 { paired=($2=="true" ? "yes" : "no") }
      NR==4 { conn=($2=="true" ? "yes" : "no") }
      NR==5 { icon=unq($2) }
      NR==6 { cls=$2+0 }
      NR==7 { uuids=$0 }
      END {
        audio = (index(uuids, "0000110b-") || index(icon, "audio") ||
                 (int(cls/256) % 32 == 4)) ? "yes" : "no"
        hs = index(uuids, "0000111e-") ? "yes" : "no"
        if (addr != "") print addr "|" (name=="" ? addr : name) "|" paired "|" conn "|" audio "|" hs "|" bat "|" dh
      }'
  done)
  printf '%s\n' "$BT_TABLE"
}
dev_field() {
  bt_dev_table | awk -F'|' -v m="$1" -v n="$2" -v c="$(adapter_hci)" '
    $1==m && $8==c {print $n; found=1; exit}
    $1==m && !seen {seen=1; first=$n}
    END {if (!found) print first}'
}
# строки таблицы без дублей: у устройства, спаренного на двух адаптерах, берём текущий
bt_dev_unique() {
  bt_dev_table | awk -F'|' -v c="$(adapter_hci)" '
    { if (!($1 in best) || $8 == c) best[$1] = $0 }
    END { for (m in best) print best[m] }' | sort -t'|' -k2,2
}

# --- BlueZ ---------------------------------------------------------------
# Все спаренные устройства с профилем Audio Sink: "MAC|Имя". Без хардкода MAC.
audio_devices() {
  bt_dev_unique | awk -F'|' '$3=="yes" && $5=="yes" {print $1 "|" $2}'
}
# Одно и то же устройство может быть спарено на нескольких адаптерах — тогда выбираем текущий,
# иначе «Подключить» уводило систему на другой адаптер.
dev_adapter() {
  cur=$(adapter_hci)
  bt_dev_table | awk -F'|' -v m="$1" -v c="$cur" '
    $1==m && $8==c {print $8; found=1; exit}
    $1==m && !first {first=$8}
    END {if (!found) print first}'
}
name_of()      { dev_field "$1" 2; }
is_connected() { [ "$(dev_field "$1" 4)" = yes ]; }
has_headset()  { [ "$(dev_field "$1" 6)" = yes ]; }
battery_of()   { dev_field "$1" 7; }

# --- PipeWire ------------------------------------------------------------
pw_ready()   { pactl info >/dev/null 2>&1; }
# PipeWire называет узлы то с двоеточиями (bluez_output.3C:B0:...), то с подчёркиваниями (…3C_B0_…),
# в зависимости от версии и профиля — ищем обе формы.
node_of() {
  kind="$1"; mac="$2"
  pactl list "$kind" short 2>/dev/null |
    awk -v a="$3.$mac" -v b="$3.$(us "$mac")" 'index($2,a)==1 || index($2,b)==1 {print $2; exit}'
}
card_of()    { node_of cards   "$1" bluez_card; }
sink_of()    { node_of sinks   "$1" bluez_output; }
source_of()  { node_of sources "$1" bluez_input; }
# Профили карты устройства (строки вида "a2dp-sink" / "headset-head-unit").
profiles_of() {
  c=$(card_of "$1") || return 1
  [ -n "$c" ] || return 1
  pactl list cards 2>/dev/null | awk -v c="Name: $c" '
    $0 ~ c {inc=1} inc && /^\tProfiles:/ {p=1; next}
    p && /^\t\t[a-z0-9_-]+:/ {sub(/^\t\t/,""); sub(/:.*/,""); print}
    p && /^\tActive Profile:/ {exit}'
}
active_profile_of() {
  c=$(card_of "$1"); [ -n "$c" ] || return 1
  pactl list cards 2>/dev/null | awk -v c="Name: $c" '$0 ~ c {inc=1} inc && /^\tActive Profile:/ {sub(/^\tActive Profile: /,""); print; exit}'
}
headset_profile_of() {
  p=$(profiles_of "$1")
  echo "$p" | grep -qx 'headset-head-unit' && { echo headset-head-unit; return; }
  echo "$p" | grep -x 'headset-head-unit[a-z-]*' | head -1
}

# --- Конфиг выбора профиля (атомарная запись: temp + mv) -----------------
cfg_get() {
  [ -n "${CFG_DATA:-}" ] || { [ -r "$CFG" ] || { echo auto; return; }; CFG_DATA=$(cat "$CFG"); }
  echo "$CFG_DATA" | awk -v s="[$(us "$1")]" '
    $0==s {inc=1; next} /^\[/ {inc=0}
    inc && /^[[:space:]]*profile[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/,""); gsub(/[[:space:]]/,""); print; exit}' |
    grep -Ex 'auto|a2dp|headset' || echo auto
}
# Состояние голосового канала адаптера: ok | broken | unknown (секция [adapter], ключ sco).
# На MT7630E SCO часто не поднимается вовсе — тогда автопереключение в гарнитуру убивает и звук, и микрофон.
sco_state()     { cfg_raw "adapter:$(adapter_addr)" sco || cfg_raw adapter sco || echo unknown; }
sco_state_set() { cfg_kv_set "adapter:$(adapter_addr)" sco "$1"; }
# Отказать может и адаптер (MT7630E: -56 Invalid request code), и само устройство
# (на донгле у части гарнитур: -110/-112 — SCO-запрос уходит, ответа нет), поэтому помним и то, и другое.
sco_dev_state()     { cfg_raw "dev:$(us "$1")@$(adapter_addr)" sco || echo unknown; }
sco_dev_state_set() { cfg_kv_set "dev:$(us "$1")@$(adapter_addr)" sco "$2"; }
cfg_raw() {
  [ -r "$CFG" ] || return 1
  awk -v s="[$1]" -v k="$2" '
    $0==s {inc=1; next} /^\[/ {inc=0}
    inc && $1==k {sub(/^[^=]*=[[:space:]]*/,""); gsub(/[[:space:]]/,""); print; found=1; exit}
    END {exit !found}' "$CFG"
}
cfg_kv_set() {
  sec="[$1]"; key="$2"; val="$3"
  mkdir -p "$(dirname "$CFG")"
  tmp="$CFG.tmp.$$"
  # Заменяем ключ внутри секции, не трогая остальные её ключи (наивная фильтрация по строкам
  # осиротляла соседние ключи: секция уезжала в конец файла без них).
  { [ -r "$CFG" ] && cat "$CFG"; } | awk -v s="$sec" -v k="$key" -v v="$val" '
    BEGIN { insec=0; done=0 }
    /^\[/ {
      if (insec && !done) { print k " = " v; done=1 }
      insec = ($0 == s)
      print; next
    }
    { if (insec && $1 == k) { if (!done) { print k " = " v; done=1 }; next } print }
    END {
      if (insec && !done) { print k " = " v; done=1 }
      if (!done) { print s; print k " = " v }
    }' > "$tmp"
  mv -f "$tmp" "$CFG"
}

cfg_set() {
  sec="[$(us "$1")]"; val="$2"
  mkdir -p "$(dirname "$CFG")"
  tmp="$CFG.tmp.$$"
  { [ -r "$CFG" ] && awk -v s="$sec" '$0==s {skip=1; next} /^\[/ {skip=0} !skip' "$CFG"
    echo "$sec"; echo "profile = $val"; } > "$tmp"
  mv -f "$tmp" "$CFG"
}

# --- Маркеры состояния ---------------------------------------------------
manual_off_set()   { mkdir -p "$USER_RUN/manual-off"; : > "$USER_RUN/manual-off/$(us "$1")"; }
manual_off_clear() { rm -f "$USER_RUN/manual-off/$(us "$1")" 2>/dev/null; }
manual_off()       { [ -e "$USER_RUN/manual-off/$(us "$1")" ]; }

# --- Профили -------------------------------------------------------------
autoswitch_set() { wpctl settings --save "$WP_AUTOSWITCH" "$1" >/dev/null 2>&1; }
set_card_profile() {
  c=$(card_of "$1"); [ -n "$c" ] || { bad "карта устройства не найдена в PipeWire"; return 1; }
  pactl set-card-profile "$c" "$2" 2>/dev/null
}
# Применить выбранный (или сохранённый) профиль к устройству.
apply_profile() {
  mac="$1"; want="${2:-$(cfg_get "$1")}"
  avail=$(profiles_of "$mac")
  case "$want" in
    headset)
      hs=$(headset_profile_of "$mac")
      [ -n "$hs" ] || { bad "у устройства нет гарнитурного профиля (нет HFP/HSP)"; cfg_set "$mac" auto; return 1; }
      autoswitch_set false
      set_card_profile "$mac" "$hs" || { bad "не удалось переключить профиль"; return 1; }
      sleep 1
      if [ "${MAZZY_BT_NOPROBE:-0}" = 1 ] || sco_works "$mac"; then
        sco_state_set ok; sco_dev_state_set "$mac" ok
        ok "профиль: гарнитура ($hs), микрофон доступен"
      else
        sco_dev_state_set "$mac" broken
        # Вердикт адаптеру — только когда провалились минимум две разные пары наушников: одна
        # может отказывать сама (устройство заявляет HFP в SDP, но SCO не поднимает).
        nfail=$(grep -c "^\[dev:.*@$(adapter_addr)\]" "$CFG" 2>/dev/null || echo 0)
        if [ "${nfail:-0}" -ge 2 ] && [ "$(cfg_raw "adapter:$(adapter_addr)" sco 2>/dev/null)" != ok ]; then
          sco_state_set broken
        fi
        bad "гарнитура не работает: голосовой канал (SCO) не поднялся — молчали бы и звук, и микрофон"
        inf "отказать может и адаптер, и сами наушники; проверь вторую пару, чтобы отличить"
        inf "возвращаю стерео и выключаю автопереключение, чтобы микрофон приложения не глушил звук"
        cfg_set "$mac" auto; autoswitch_set false
        if profiles_of "$mac" | grep -qx a2dp-sink; then
          set_card_profile "$mac" a2dp-sink
        else
          # неудачная попытка HFP иногда роняет и A2DP-транспорт: профиль стерео исчезает из карты
          inf "стерео-профиль пропал — переподключаю устройство"
          reconnect_profiles "$mac" >/dev/null 2>&1
        fi
        return 1
      fi ;;
    a2dp)
      echo "$avail" | grep -qx a2dp-sink || { bad "профиль a2dp-sink недоступен — нужно переподключить устройство"; return 1; }
      autoswitch_set false; set_card_profile "$mac" a2dp-sink && ok "профиль: стерео (a2dp-sink)" ;;
    auto|*)
      # автопереключение включаем, только если голосовой канал адаптера реально проверен и работает:
      # иначе приложение, открывшее микрофон (например Firefox), переводит карту в HFP и глушит всё
      case "$(sco_state)" in
        ok) autoswitch_set true; sw="гарнитура по запросу микрофона" ;;
        broken) autoswitch_set false; sw="микрофон наушников недоступен: адаптер не отдаёт SCO" ;;
        *) autoswitch_set false; sw="микрофон не проверен — mazzy-bt-audio profile headset" ;;
      esac
      if echo "$avail" | grep -qx a2dp-sink; then
        set_card_profile "$mac" a2dp-sink && ok "профиль: авто — стерео; $sw"
      else
        inf "профиль: авто (a2dp пока недоступен); $sw"
      fi ;;
  esac
}

# Голосовой канал (SCO) на MT7630E работает не всегда: профиль переключается, транспорт падает
# («Failure in Bluetooth audio transport»), и тогда молчит не только микрофон, но и воспроизведение.
# Проверяем честно: открываем микрофон на 2 с и смотрим, растут ли SCO-пакеты адаптера.
sco_rx() { hciconfig "$(adapter_hci)" 2>/dev/null | grep -o 'sco:[0-9]*' | head -1 | cut -d: -f2; }
sco_works() {
  src=$(source_of "$1"); [ -n "$src" ] || return 1
  before=$(sco_rx)
  timeout 3 pw-record --target "$src" /dev/null >/dev/null 2>&1 &
  pid=$!
  sleep 2
  after=$(sco_rx)
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  [ "${after:-0}" -gt "${before:-0}" ]
}

# --- Подключение по событию ---------------------------------------------
# Нужно ли чинить устройство: подключено, но нет sink или пропал профиль стерео (гонка с WirePlumber).
needs_fix() {
  mac="$1"
  is_connected "$mac" || return 1
  [ -n "$(sink_of "$mac")" ] || return 0
  [ "$(cfg_get "$mac")" = headset ] && return 1
  profiles_of "$mac" | grep -qx a2dp-sink || return 0
  return 1
}
reconnect_profiles() {
  mac="$1"; nm=$(name_of "$mac")
  for t in 2 5 10; do
    btctl "disconnect $mac" >/dev/null 2>&1
    sleep 1
    timeout 12 bluetoothctl connect "$mac" >/dev/null 2>&1
    sleep "$t"
    if [ -n "$(sink_of "$mac")" ] && { [ "$(cfg_get "$mac")" = headset ] || profiles_of "$mac" | grep -qx a2dp-sink; }; then
      log "профили подняты: ${nm:-$mac}"; return 0
    fi
  done
  log "не удалось поднять профили: ${nm:-$mac}"; return 1
}

wait_pipewire() {
  i=0
  while [ $i -lt 20 ]; do
    pw_ready && { pactl list cards short >/dev/null 2>&1; return 0; }
    sleep 1; i=$((i + 1))
  done
  return 1
}

automation() {
  mode="$1"
  mkdir -p "$USER_RUN"
  adapter_apply
  wait_pipewire || { log "PipeWire не поднялся за 20 с — выходим"; return 1; }
  sleep 2   # эндпойнты BlueZ регистрируются сразу после старта WirePlumber

  # 1) Устройства, которые считаются подключёнными, но без рабочих профилей (гонка «Protocol not available»)
  audio_devices | while IFS='|' read -r mac name; do
    [ -n "$mac" ] || continue
    manual_off "$mac" && continue
    if needs_fix "$mac"; then
      log "чиню профили: $name"
      reconnect_profiles "$mac"
    fi
    is_connected "$mac" && apply_profile "$mac" >/dev/null 2>&1
  done

  # 2) После сна/сброса чипа — вернуть то, что было подключено до события
  case "$mode" in
    resume|after-reset)
      [ -r "$SYS_RUN/was-connected" ] || return 0
      while read -r mac; do
        [ -n "$mac" ] || continue
        manual_off "$mac" && continue
        is_connected "$mac" && continue
        timeout 12 bluetoothctl connect "$mac" >/dev/null 2>&1 &&
          { log "подключено после $mode: $(name_of "$mac")"; apply_profile "$mac" >/dev/null 2>&1; }
      done < "$SYS_RUN/was-connected"
      ;;
  esac
}

# --- Сопряжение ----------------------------------------------------------
# Наушники подтверждают сопряжение числовым кодом: bluetoothctl спрашивает «Confirm passkey … (yes/no)».
# Скормить «yes» заранее нельзя — вопрос появляется асинхронно, поэтому управляем сессией через FIFO
# и отвечаем ровно в момент запроса. Без этого сопряжение падает с org.bluez.Error.AuthenticationFailed.
scan_devices() {
  secs="${1:-12}"
  f=$(mktemp -u); l=$(mktemp); mkfifo "$f"
  bluetoothctl < "$f" > "$l" 2>&1 &
  bc=$!
  exec 3> "$f"
  a=$(adapter_addr); [ -n "$a" ] && printf 'select %s\n' "$a" >&3
  printf 'power on\nscan on\n' >&3
  sleep "$secs"
  printf 'scan off\nquit\n' >&3
  exec 3>&-
  wait $bc 2>/dev/null
  rm -f "$f" "$l"
}
pair_device() {
  mac="$1"
  f=$(mktemp -u); l=$(mktemp); mkfifo "$f"
  bluetoothctl < "$f" > "$l" 2>&1 &
  bc=$!
  exec 3> "$f"
  a=$(adapter_addr); [ -n "$a" ] && printf 'select %s\n' "$a" >&3
  printf 'power on\nscan on\n' >&3
  sleep 12
  printf 'pair %s\n' "$mac" >&3
  i=0
  while [ $i -lt 60 ]; do
    grep -q 'Confirm passkey' "$l" && { printf 'yes\n' >&3; break; }
    grep -qE 'Pairing successful|Failed to pair' "$l" && break
    sleep 0.5; i=$((i + 1))
  done
  sleep 8
  printf 'trust %s\nconnect %s\n' "$mac" "$mac" >&3
  sleep 14
  printf 'scan off\nquit\n' >&3
  exec 3>&-
  wait $bc 2>/dev/null
  res=$(grep -cE 'Pairing successful' "$l")
  err=$(grep -oE 'org\.bluez\.Error\.[A-Za-z]+' "$l" | tail -1)
  rm -f "$f" "$l"
  if is_connected "$mac"; then
    apply_profile "$mac" >/dev/null 2>&1
    ok "$(name_of "$mac") — спарены и подключены"; return 0
  fi
  [ "$res" -gt 0 ] && { ok "$(name_of "$mac") — спарены, но не подключились"; return 0; }
  bad "сопряжение не удалось${err:+: $err} — включи на наушниках режим сопряжения (кнопка до мигания)"
  return 1
}
# Аудиоустройства в эфире: спаренные и нет. "MAC|Имя|paired"
# Скан и опрос — в ОДНОЙ сессии: найденные, но не спаренные устройства BlueZ забывает вскоре после
# остановки поиска, и отдельный вызов `bluetoothctl devices` возвращал уже пустой список.
scan_audio() {
  secs="${1:-12}"
  f=$(mktemp -u); l=$(mktemp); mkfifo "$f"
  bluetoothctl < "$f" > "$l" 2>&1 &
  bc=$!
  exec 3> "$f"
  a=$(adapter_addr); [ -n "$a" ] && printf 'select %s\n' "$a" >&3
  printf 'power on\nscan on\n' >&3
  sleep "$secs"
  # Всё в ОДНОЙ сессии: объекты BlueZ для найденных, но не спаренных устройств живут считанные
  # секунды после остановки поиска, а на свежем адаптере у них ещё нет ни UUID, ни SDP.
  printf 'devices\n' >&3
  sleep 2
  macs=$(clean_bt "$l" | grep -oE '([0-9A-F]{2}:){5}[0-9A-F]{2}' | sort -u)
  for m in $macs; do printf 'info %s\n' "$m" >&3; done
  sleep 3
  printf 'scan off\nquit\n' >&3
  exec 3>&-
  wait $bc 2>/dev/null
  clean_bt "$l" | awk '
    function emit() {
      if (mac != "" && audio) print mac "|" (name == "" ? mac : name) "|" paired
      mac=""; name=""; audio=0; paired="no"
    }
    /^Device [0-9A-F:]{17} \(/ { emit(); mac=$2; next }
    /^\tName: /                { name=substr($0,8) }
    /UUID: Audio Sink/         { audio=1 }
    /Icon: audio-head/         { audio=1 }
    /^\tClass: 0x[0-9a-f]{4}04/ { audio=1 }   # major device class 4 = Audio/Video
    /^\tPaired: yes/           { paired="yes" }
    END { emit() }' | sort -u -t'|' -k1,1
  rm -f "$f" "$l"
}

cmd_pair() {
  mac="${1:-}"
  if [ -n "$mac" ]; then pair_device "$mac"; return $?; fi
  echo "Ищу наушники 12 с (включи на них режим сопряжения)…"
  list=$(scan_audio 12)
  [ -n "$list" ] || { bad "аудиоустройств в эфире не найдено"; return 1; }
  n=0
  echo "$list" | while IFS='|' read -r m nm pd; do
    n=$((n + 1)); printf '  %d) %s  %s  %s\n' "$n" "$nm" "$m" "$([ "$pd" = yes ] && echo "(уже спарено)")"
  done
  printf 'Номер наушников (Enter — отмена): '
  read -r sel
  [ -n "$sel" ] || return 1
  mac=$(echo "$list" | sed -n "${sel}p" | cut -d'|' -f1)
  [ -n "$mac" ] || { bad "неверный номер"; return 1; }
  pair_device "$mac"
}

# --- Выбор выхода/входа --------------------------------------------------
# Устройство в PipeWire — не то же, что «микрофон» для пользователя: у встроенной карты один источник
# с двумя портами (внутренний микрофон и микрофон в разъёме), а у наушников источник появляется только
# в гарнитурном профиле. Поэтому список строим из трёх видов строк:
#   node:<имя>            — обычный узел PipeWire
#   port:<узел>:<порт>    — порт карты (внутренний микрофон / разъём / динамики / наушники в разъёме)
#   bt:<MAC>              — микрофон Bluetooth-наушников; выбор переключает карту в гарнитуру (HFP)
# Формат строки: key|описание|выбрано(yes/no)|доступно(yes/no)|подсказка
default_sink()   { pactl info 2>/dev/null | sed -n 's/^Default Sink: //p'; }
default_source() { pactl info 2>/dev/null | sed -n 's/^Default Source: //p'; }

pw_nodes() {
  # kind = sinks | sources; монитор-источники пропускаем (у них в дампе лежат порты своего выхода —
  # если не сбросить состояние, они протекают в следующее устройство)
  pactl list "$1" 2>/dev/null | awk -v def="$2" '
    function ru(d) {
      if (d == "Internal Microphone") return "Встроенный микрофон"
      if (d == "Microphone")          return "Микрофон в разъёме"
      if (d == "Speakers")            return "Динамики"
      if (d == "Headphones")          return "Наушники в разъёме"
      if (d == "Digital Output (S/PDIF)") return "Цифровой выход (S/PDIF)"
      return d
    }
    function reset() { name = ""; desc = ""; active = ""; np = 0 }
    function flush(  i, label, cur) {
      if (name == "" || name ~ /\.monitor$/) { reset(); return }
      if (np <= 1) {
        cur = (name == def) ? "yes" : "no"
        printf "node:%s|%s|%s|yes|\n", name, (desc == "" ? name : desc), cur
      } else {
        for (i = 1; i <= np; i++) {
          cur = (name == def && pname[i] == active) ? "yes" : "no"
          label = (desc == "" ? name : desc) " — " ru(pdesc[i])
          printf "port:%s:%s|%s|%s|%s|%s\n", name, pname[i], label, cur, pavail[i], phint[i]
        }
      }
      reset()
    }
    /^(Sink|Source) #/ { flush() }
    /^\tName: /        { name = substr($0, 8) }
    /^\tDescription: / { desc = substr($0, 15) }
    /^\tActive Port: / { active = substr($0, 15) }
    /^\tPorts:/        { inp = 1; next }
    /^\t[^\t]/        { if ($0 !~ /^\tPorts:/) inp = 0 }
    inp && /^\t\t[a-z0-9:+_-]+: / {
      line = $0; sub(/^\t\t/, "", line)
      p = line; sub(/:.*/, "", p)
      d = line; sub(/^[^:]*: /, "", d); sub(/ \(type:.*/, "", d)
      np++; pname[np] = p; pdesc[np] = d
      if (line ~ /not available/) { pavail[np] = "no"; phint[np] = "разъём пуст" }
      else { pavail[np] = "yes"; phint[np] = "" }
    }
    END { flush() }'
}

# Микрофоны Bluetooth-наушников: если узла ещё нет, строка всё равно есть — выбор переключит в гарнитуру.
# devs  — строки raw_devices (mac|имя|подключено|режим|профиль|профили|гарнитура|батарея|спарено)
# srcs  — уже собранные строки источников (чтобы не звать pactl/bluetoothctl второй раз)
# Спаренные, но не подключённые наушники: их узлов в PipeWire нет, однако в списках они нужны —
# «подключить и выбрать» одним действием (иначе пользователь включает наушники и не находит их в списке).
bt_offline_rows() {
  devs="$1"; kind="$2"
  echo "$devs" | while IFS='|' read -r mac nm conn mode active avail hs batt paired dhci; do
    [ -n "$mac" ] || continue
    [ "$paired" = yes ] || continue
    [ "$conn" = no ] || continue
    [ "$kind" = sources ] && { [ "$hs" = yes ] || continue; }
    printf 'conn:%s|%s|no|yes|не подключено — подключить и выбрать\n' "$mac" "$nm"
  done
}

# Узел микрофона наушников может существовать (гарнитурный профиль активен), но молчать —
# если голосовой канал адаптера не работает, честно пишем это прямо в строке списка.
sco_note_sources() {
  [ "$(sco_state)" = broken ] || { cat; return; }
  awk -F'|' -v OFS='|' '{ if (index($1, "bluez_input") && $5 == "") $5 = "адаптер не отдаёт голосовой канал (SCO) — скорее всего тишина"; print }'
}

bt_mic_rows_from() {
  devs="$1"; srcs="$2"; st=$(sco_state)
  case "$st" in
    broken) hint="адаптер не отдаёт голосовой канал (SCO) — попытка будет, но скорее всего тишина"; av=no ;;
    ok)     hint="переключит наушники в режим гарнитуры (звук станет моно)"; av=yes ;;
    *)      hint="переключит в гарнитуру и проверит голосовой канал"; av=yes ;;
  esac
  echo "$devs" | while IFS='|' read -r mac nm conn mode active avail hs batt paired dhci; do
    [ -n "$mac" ] || continue
    [ "$conn" = yes ] && [ "$hs" = yes ] || continue
    # узел микрофона уже есть (гарнитурный профиль активен) — его выдал pw_nodes
    echo "$srcs" | grep -q "bluez_input\.\($mac\|$(us "$mac")\)" && continue
    printf 'bt:%s|%s (микрофон гарнитуры)|no|%s|%s\n' "$mac" "$nm" "$av" "$hint"
  done
}
bt_mic_rows() { bt_mic_rows_from "$(raw_devices)" "$(pw_nodes sources "$(default_source)")"; }

nodes_of() {
  kind="$1"; devs=$(raw_devices)
  if [ "$kind" = sinks ]; then
    pw_nodes sinks "$(default_sink)"
  else
    srcs=$(pw_nodes sources "$(default_source)")
    { echo "$srcs"; bt_mic_rows_from "$devs" "$srcs"; bt_offline_rows "$devs" sources; } | sco_note_sources
    return
  fi
  bt_offline_rows "$devs" "$kind"
}
desc_of() { nodes_of "$1" | awk -F'|' -v k="$2" '$1==k {print $2; exit}'; }

list_nodes() {
  kind="$1"
  i=0
  nodes_of "$kind" | while IFS='|' read -r key desc cur avail hint; do
    i=$((i + 1))
    mark='  '; [ "$cur" = yes ] && mark=' *'
    sfx=""
    [ "$avail" = no ] && sfx=" — недоступно"
    [ -n "$hint" ] && sfx="$sfx  ($hint)"
    printf '%s %d) %s%s\n' "$mark" "$i" "$desc" "$sfx"
  done
}

# Применить выбор строки: обычный узел, порт карты или микрофон гарнитуры.
apply_choice() {
  kind="$1"; key="$2"; desc="$3"
  case "$key" in
    node:*)
      n=${key#node:}
      if [ "$kind" = sinks ]; then pactl set-default-sink "$n"; else pactl set-default-source "$n"; fi
      ok "по умолчанию: $desc" ;;
    port:*)
      rest=${key#port:}; n=${rest%%:*}; port=${rest#*:}
      if [ "$kind" = sinks ]; then
        pactl set-sink-port "$n" "$port" && pactl set-default-sink "$n"
      else
        pactl set-source-port "$n" "$port" && pactl set-default-source "$n"
      fi
      ok "по умолчанию: $desc" ;;
    conn:*)
      mac=${key#conn:}
      cmd_connect "$mac" || return 1
      sleep 2
      if [ "$kind" = sinks ]; then
        n=$(sink_of "$mac"); [ -n "$n" ] && pactl set-default-sink "$n" && ok "выход: $desc"
      else
        apply_choice sources "bt:$mac" "$desc"
      fi ;;
    bt:*)
      mac=${key#bt:}
      apply_profile "$mac" headset || return 1
      cfg_set "$mac" headset
      sleep 1
      src=$(source_of "$mac")
      [ -n "$src" ] || { bad "микрофон гарнитуры не появился"; return 1; }
      pactl set-default-source "$src" && ok "микрофон: $desc" ;;
  esac
}

select_node() {
  kind="$1"; want="${2:-}"
  if [ -z "$want" ]; then
    [ "$kind" = sinks ] && echo "== Выходы (звёздочка — по умолчанию)" || echo "== Входы (звёздочка — по умолчанию)"
    list_nodes "$kind"; return 0
  fi
  case "$want" in
    node:*|port:*|bt:*)   # UI передаёт готовый ключ строки
      d=$(nodes_of "$kind" | awk -F'|' -v k="$want" '$1==k {print $2; exit}')
      apply_choice "$kind" "$want" "${d:-$want}"; return $? ;;
  esac
  # подстрока, а не регулярное выражение: в названиях устройств бывают скобки
  line=$(nodes_of "$kind" | awk -v w="$want" -F'|' '
    NR==w {print; exit}
    index(tolower($2), tolower(w)) {print; exit}')
  [ -n "$line" ] || { bad "не найдено: $want"; list_nodes "$kind"; return 1; }
  key=$(echo "$line" | cut -d'|' -f1); desc=$(echo "$line" | cut -d'|' -f2)
  apply_choice "$kind" "$key" "$desc"
}

# --- Команды -------------------------------------------------------------
cmd_devices() {
  audio_devices | while IFS='|' read -r mac name; do
    [ -n "$mac" ] || continue
    st="не подключено"; is_connected "$mac" && st="подключено"
    manual_off "$mac" && st="$st (отключено вручную)"
    b=$(battery_of "$mac"); [ -n "$b" ] && st="$st, батарея $b%"
    printf '%s  %s — %s\n' "$mac" "$name" "$st"
  done
}

cmd_connect() {
  mac="${1:-$(audio_devices | head -1 | cut -d'|' -f1)}"
  [ -n "$mac" ] || { bad "нет спаренных наушников — сначала сопряжение"; return 1; }
  dh=$(dev_adapter "$mac")
  if [ -n "$dh" ] && [ "$dh" != "$(adapter_hci)" ]; then
    inf "устройство спарено на $dh — переключаю адаптер"
    adapter_use "$dh" >/dev/null 2>&1
    BT_TABLE=""
  fi
  manual_off_clear "$mac"
  btctl "trust $mac" >/dev/null 2>&1
  if timeout 15 bluetoothctl connect "$mac" >/dev/null 2>&1 && is_connected "$mac"; then
    sleep 2; apply_profile "$mac"; ok "$(name_of "$mac") — подключены"
  else
    bad "$(name_of "$mac") — не отвечают (выключены / подключены к телефону)"; return 1
  fi
}

cmd_disconnect() {
  mac="${1:-$(audio_devices | while IFS='|' read -r m n; do is_connected "$m" && { echo "$m"; break; }; done)}"
  [ -n "$mac" ] || { bad "нет подключённых наушников"; return 1; }
  manual_off_set "$mac"
  btctl "disconnect $mac" >/dev/null 2>&1
  ok "$(name_of "$mac") — отключены; автоматика их больше не трогает до «Подключить»"
}

cmd_profile() {
  want="${1:-}"; mac="${2:-}"
  [ -n "$mac" ] || mac=$(audio_devices | while IFS='|' read -r m n; do is_connected "$m" && { echo "$m"; break; }; done)
  [ -n "$mac" ] || mac=$(audio_devices | head -1 | cut -d'|' -f1)
  [ -n "$mac" ] || { bad "нет спаренных наушников"; return 1; }
  if [ -z "$want" ]; then
    echo "== $(name_of "$mac")"
    inf "выбран режим: $(cfg_get "$mac")"
    inf "активный профиль: $(active_profile_of "$mac")"
    inf "доступные: $(profiles_of "$mac" | tr '\n' ' ')"
    inf "автопереключение WirePlumber: $(wpctl settings "$WP_AUTOSWITCH" 2>/dev/null | sed -n 's/^Value: //p')"
    return 0
  fi
  case "$want" in auto|a2dp|headset) ;; *) bad "режим: auto | a2dp | headset"; return 2 ;; esac
  cfg_set "$mac" "$want"
  apply_profile "$mac" "$want"
}

cmd_status() {
  echo "== Адаптер"
  if hciconfig "$(adapter_hci)" 2>/dev/null | grep -q 'UP RUNNING'; then ok "hci0 UP"; else bad "hci0 DOWN — mazzy-bt-audio fix"; fi
  if [ -x /usr/local/sbin/mt7630e-bt-reset.sh ]; then inf "ACL: $(/usr/local/sbin/mt7630e-bt-reset.sh acl-check 2>/dev/null | sed 's/^acl: //')"; fi
  if journalctl -b -u bluetooth --no-pager 2>/dev/null | grep -q 'Protocol not available'; then
    inf "в журнале сессии была гонка с WirePlumber (Protocol not available) — лечится переподключением"
  fi
  echo "== Конфиг аудио"
  cd="${XDG_CONFIG_HOME:-$HOME/.config}/wireplumber/wireplumber.conf.d"
  n=$(ls "$cd" 2>/dev/null | grep -c '^5[0-9]-bluez')
  case "$n" in
    1) ok "конфиг BlueZ: $(ls "$cd" | grep '^5[0-9]-bluez')" ;;
    0) bad "конфиг BlueZ не установлен — запусти install.sh" ;;
    *) bad "конфигов BlueZ несколько ($(ls "$cd" | grep '^5[0-9]-bluez' | tr '\n' ' ')) — запусти install.sh" ;;
  esac
  echo "== Устройства"
  audio_devices | while IFS='|' read -r mac name; do
    [ -n "$mac" ] || continue
    if is_connected "$mac"; then ok "$name ($mac) — подключено"; else inf "$name ($mac) — не подключено"; fi
    [ -n "$(card_of "$mac")" ] || continue
    inf "  режим: $(cfg_get "$mac"); активный профиль: $(active_profile_of "$mac")"
    inf "  доступные профили: $(profiles_of "$mac" | tr '\n' ' ')"
    if [ -n "$(source_of "$mac")" ]; then ok "  микрофон доступен: $(source_of "$mac")"
    elif has_headset "$mac"; then inf "  микрофон появится в профиле «гарнитура» (mazzy-bt-audio profile headset)"
    else bad "  устройство без HFP — микрофона нет"; fi
  done
  echo "== PipeWire"
  echo "-- выходы"; list_nodes sinks
  echo "-- входы";  list_nodes sources
}

# Машинный вывод для mazzy-settings (разделитель «|»), чтобы UI не разбирал человеческие строки.
raw_devices() {
  cards=$(pactl list cards 2>/dev/null)
  CFG_DATA=$(cat "$CFG" 2>/dev/null)   # конфиг читаем один раз на весь список
  bt_dev_unique | while IFS='|' read -r mac name paired conn audio hs batt dhci; do
    [ -n "$mac" ] || continue
    [ "$audio" = yes ] || continue
    # PipeWire пишет имя карты то через двоеточия, то через подчёркивания — берём ту, что есть
    card=$(echo "$cards" | awk -v a="Name: bluez_card.$mac" -v b="Name: bluez_card.$(us "$mac")" '
      index($0,a) || index($0,b) {sub(/^[[:space:]]*Name: /,""); print; exit}')
    [ -n "$card" ] || card="bluez_card.$(us "$mac")"
    pa=$(echo "$cards" | awk -v c="Name: $card" '
      $0 ~ c {inc=1} inc && /^\tProfiles:/ {p=1; next}
      p && /^\t\t[a-z0-9_-]+:/ {sub(/^\t\t/,""); sub(/:.*/,""); printf "%s ", $0}
      inc && /^\tActive Profile:/ {sub(/^\tActive Profile: /,""); print "|" $0; exit}')
    avail=${pa%%|*}; active=${pa#*|}
    [ "$avail" = "$active" ] && active=""
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$mac" "$name" "$conn" "$(cfg_get "$mac")" "$active" "$avail" "$hs" "$batt" "$paired" "$dhci"
  done
}

raw_nodes() { nodes_of "$1"; }
raw_adapter() {
  up=no; hciconfig "$(adapter_hci)" 2>/dev/null | grep -q 'UP RUNNING' && up=yes
  acl=unknown
  [ -x /usr/local/sbin/mt7630e-bt-reset.sh ] &&
    acl=$(/usr/local/sbin/mt7630e-bt-reset.sh acl-check 2>/dev/null | sed 's/^acl: //')
  stamp=""
  [ -r /run/mt7630e-chip-reset.stamp ] && stamp=$(date -d @"$(cat /run/mt7630e-chip-reset.stamp)" '+%H:%M:%S' 2>/dev/null)
  printf '%s|%s|%s\n' "$up" "$acl" "$stamp"
}

# Всё, что нужно странице настроек, одним вызовом: секции «#devices/#sinks/#sources/#adapter».
# Четыре отдельных вызова стоили лишних запусков процесса на каждое обновление страницы.
raw_all() {
  echo "#adapters"; echo "mode|$(adapter_mode)"; adapters
  devs=$(raw_devices)
  srcs=$(pw_nodes sources "$(default_source)")
  echo "#devices"; echo "$devs"
  echo "#sinks";   pw_nodes sinks "$(default_sink)"; bt_offline_rows "$devs" sinks
  echo "#sources"; { echo "$srcs"; bt_mic_rows_from "$devs" "$srcs"; bt_offline_rows "$devs" sources; } | sco_note_sources
  echo "#adapter"; raw_adapter
}

usage() { sed -n '2,15p' "$0"; }

case "${1:-status}" in
  session)     automation session ;;
  resume)      automation resume ;;
  after-reset) automation after-reset ;;
  trigger)     m=$(awk '{print $1}' "$SYS_RUN/trigger" 2>/dev/null); automation "${m:-session}" ;;
  adapter-changed) BT_TABLE=""; adapter_apply; automation session ;;
  connect)     cmd_connect "${2:-}" ;;
  disconnect)  cmd_disconnect "${2:-}" ;;
  profile)     cmd_profile "${2:-}" "${3:-}" ;;
  out)         select_node sinks "${2:-}" ;;
  in)          select_node sources "${2:-}" ;;
  devices)     cmd_devices ;;
  adapter)     cmd_adapter "${2:-}" ;;
  raw-adapters) adapters ;;
  pair)        cmd_pair "${2:-}" ;;
  raw-scan)    scan_audio "${2:-12}" ;;
  raw-devices) raw_devices ;;
  raw-sinks)   raw_nodes sinks ;;
  raw-sources) raw_nodes sources ;;
  raw-adapter) raw_adapter ;;
  raw-all)     raw_all ;;
  status)      cmd_status ;;
  -h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
