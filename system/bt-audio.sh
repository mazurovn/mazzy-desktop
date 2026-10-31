#!/bin/bash
# Bluetooth-аудио для любых наушников: стерео (A2DP) + гарнитура с микрофоном (HFP/HSP),
# выбор выхода и микрофона, автопереключение профиля. Без привязки к конкретным MAC-адресам.
# Привилегированное — только через pkexec (polkit-правило 50-mazzy-connectivity.rules), паролей в файлах нет.
#
#   bash system/bt-audio.sh            — подключить спаренное и показать состояние
#   bash system/bt-audio.sh status     — адаптер, ACL, устройства, профили, выход/микрофон
#   bash system/bt-audio.sh pair       — найти и спарить новые наушники
#   bash system/bt-audio.sh mic [MAC]  — проверить микрофон (запись 3 с + уровень сигнала)
#   bash system/bt-audio.sh profile [auto|a2dp|headset] [MAC]
#   bash system/bt-audio.sh out|in [номер|имя]    — выбрать выход / вход по умолчанию
#   bash system/bt-audio.sh connect|disconnect [MAC]
#   bash system/bt-audio.sh fix        — сброс чипа при мёртвом ACL + переподключение
#
# Общая логика живёт в mazzy-bt-audio (тот же репозиторий, ставится в /usr/local/bin).
set -o pipefail
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE=$(command -v mazzy-bt-audio || echo "$SRC_DIR/mazzy-bt-audio.sh")
RESET=/usr/local/sbin/mt7630e-bt-reset.sh
ok()  { echo -e "  \e[32m✔\e[0m $1"; }
bad() { echo -e "  \e[31m✘\e[0m $1"; }
inf() { echo -e "  · $1"; }

core() { sh "$CORE" "$@"; }
audio_devices() { core devices | awk '{print $1}'; }
name_of() { bluetoothctl info "$1" 2>/dev/null | sed -n 's/^\tName: //p' | head -1; }
is_connected() { bluetoothctl info "$1" 2>/dev/null | grep -q 'Connected: yes'; }

# Сопряжение живёт в mazzy-bt-audio: там ответ на числовой код идёт через FIFO ровно в момент запроса
# (bluetoothctl спрашивает «Confirm passkey … (yes/no)» асинхронно, заранее скормленный ответ теряется).
pair_new() {
  echo "Включи на наушниках режим сопряжения (держать кнопку до мигания) и нажми Enter…"; read -r
  core pair "$1"
  echo; core status
}

# Проверка микрофона: переключаем в гарнитуру, пишем 3 с, считаем уровень сигнала, возвращаем профиль.
mic_test() {
  local mac="$1"
  [ -n "$mac" ] || mac=$(for m in $(audio_devices); do is_connected "$m" && { echo "$m"; break; }; done)
  [ -n "$mac" ] || { bad "нет подключённых наушников"; return 1; }
  local before src wav
  before=$(core profile "$mac" | sed -n 's/^  · выбран режим: //p')
  core profile headset "$mac" || return 1
  sleep 2
  src=$(pactl list sources short | awk -v a="bluez_input.$mac" -v b="bluez_input.${mac//:/_}" 'index($2,a)==1||index($2,b)==1{print $2; exit}')
  [ -n "$src" ] || { bad "микрофон не появился в PipeWire"; core profile "${before:-auto}" "$mac"; return 1; }
  inf "микрофон: $src — говори 3 секунды…"
  wav=$(mktemp --suffix=.wav)
  local sco_before sco_after
  sco_before=$(hciconfig hci0 2>/dev/null | grep -o 'sco:[0-9]*' | head -1 | cut -d: -f2)
  timeout 6 pw-record --target "$src" "$wav" >/dev/null 2>&1 &
  sleep 4; kill %1 2>/dev/null; wait 2>/dev/null
  sco_after=$(hciconfig hci0 2>/dev/null | grep -o 'sco:[0-9]*' | head -1 | cut -d: -f2)
  if [ -s "$wav" ]; then
    local peak tool=""
    if [ -x "${MAZZY_WAVPEAK:-}" ]; then tool=$MAZZY_WAVPEAK
    elif [ -x "$HOME/.local/bin/mazzy-wavpeak" ]; then tool=$HOME/.local/bin/mazzy-wavpeak
    elif command -v mazzy-wavpeak >/dev/null 2>&1; then tool=$(command -v mazzy-wavpeak)
    fi
    if [ -n "$tool" ]; then
      peak=$("$tool" "$wav" 2>/dev/null || true)
    else
      bad "нет mazzy-wavpeak: соберите src/tools/build.sh"
      peak=0
    fi
    if [ "${peak:-0}" -gt 300 ]; then ok "сигнал есть (пик $peak), микрофон работает"
    else
      bad "тишина (пик $peak): SCO-пакетов принято ${sco_before:-0} → ${sco_after:-0}"
      inf "если SCO не растёт — адаптер не отдаёт голосовой канал (см. system/README.md)"
    fi
  else bad "запись пустая"; fi
  rm -f "$wav"
  inf "возвращаю режим: ${before:-auto}"
  core profile "${before:-auto}" "$mac" >/dev/null
}

fix() {
  echo "== Починка"
  if [ -x "$RESET" ]; then
    pkexec "$RESET" auto || bad "не удалось выполнить сброс (нет polkit-правила? запусти install.sh)"
  else
    bad "$RESET не установлен — pkexec sh $SRC_DIR/install-bluetooth.sh"
  fi
  systemctl --user restart wireplumber; sleep 4
  systemctl --user start mazzy-bt-audio.service 2>/dev/null || core session
}

connect_all() {
  local any=0
  for mac in $(audio_devices); do
    any=1
    if is_connected "$mac"; then ok "$(name_of "$mac") — уже подключены"; else core connect "$mac"; fi
  done
  [ "$any" = 1 ] || inf "спаренных наушников нет — запусти: bash $0 pair"
}

case "${1:-setup}" in
  status)     core status ;;
  pair)       pair_new "${2:-}" ;;
  mic)        mic_test "$2" ;;
  profile)    core profile "${2:-}" "${3:-}" ;;
  out)        core out "${2:-}" ;;
  in)         core in "${2:-}" ;;
  connect)    core connect "${2:-}" ;;
  disconnect) core disconnect "${2:-}" ;;
  devices)    core devices ;;
  fix)        fix; echo; core status ;;
  setup)      connect_all; echo; core status ;;
  *) sed -n '2,18p' "$0"; exit 2 ;;
esac
