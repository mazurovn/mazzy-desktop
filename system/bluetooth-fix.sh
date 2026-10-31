#!/bin/bash
# Диагностика и починка Bluetooth на машине с MT7630E (USB 0489:e069). Без хардкода MAC и без паролей:
# привилегированное — через pkexec (polkit-правило 50-mazzy-connectivity.rules).
#   bash system/bluetooth-fix.sh           — диагностика + починка
#   bash system/bluetooth-fix.sh status    — только диагностика
#   bash system/bluetooth-fix.sh chip      — полный сброс чипа (PCI bus reset; Wi-Fi пропадёт на ~10 с)
#   bash system/bluetooth-fix.sh reinstall — переустановить системную часть из system/
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESET=/usr/local/sbin/mt7630e-bt-reset.sh
CORE=$(command -v mazzy-bt-audio || echo "$SRC/mazzy-bt-audio.sh")
ok()  { echo -e "  \e[32m✔\e[0m $1"; }
bad() { echo -e "  \e[31m✘\e[0m $1"; }
inf() { echo -e "  · $1"; }

# Совпадают ли установленные скрипты с репозиторием (иначе на диске живёт старая версия).
check_installed() {
  echo "== Установленные скрипты"
  local diff=0 pair
  for pair in "$SRC/mt7630e-bt-reset.sh:/usr/local/sbin/mt7630e-bt-reset.sh" \
              "$SRC/mt7630e-bt-watchdog.sh:/usr/local/sbin/mt7630e-bt-watchdog.sh" \
              "$SRC/mazzy-bt-audio.sh:/usr/local/bin/mazzy-bt-audio" \
              "$SRC/mt7630e-bt-sleep.sh:/etc/systemd/system-sleep/mt7630e-bt" \
              "$SRC/60-mazzy-bluetooth.conf:/etc/bluetooth/main.conf.d/60-mazzy-bluetooth.conf" \
              "$SRC/50-mazzy-connectivity.rules:/usr/share/polkit-1/rules.d/50-mazzy-connectivity.rules"; do
    local repo=${pair%%:*} inst=${pair##*:}
    if [ ! -e "$inst" ]; then bad "не установлен: $inst"; diff=1
    elif ! cmp -s "$repo" "$inst"; then bad "устарел: $inst (отличается от $(basename "$repo"))"; diff=1; fi
  done
  [ $diff = 0 ] && ok "все файлы совпадают с репозиторием" || inf "переустановить: pkexec sh $SRC/install-bluetooth.sh"
}

diag() {
  echo "== USB-адаптер"
  id=$(lsusb | grep -oE '0489:e069|0e8d:763f' | head -1)
  [ -n "$id" ] && ok "MT7630E виден на USB ($id)" || bad "MT7630E НЕ виден на USB (аппаратная проблема / BIOS)"
  grep -q '^0489 e069' /sys/bus/usb/drivers/btusb/new_id 2>/dev/null && ok "btusb new_id привязан" || bad "btusb new_id НЕ привязан"

  echo "== hci0"
  if hciconfig hci0 2>/dev/null | grep -q 'UP RUNNING'; then ok "hci0 UP ($(hciconfig hci0 | awk '/BD Address/{print $3}'))"
  elif [ -d /sys/class/bluetooth/hci0 ]; then bad "hci0 есть, но DOWN"; else bad "hci0 отсутствует"; fi
  rfkill list bluetooth | grep -q 'blocked: yes' && bad "rfkill блокирует" || ok "rfkill не блокирует"

  echo "== ACL-канал (режим отказа №2: hci0 UP, но данные не ходят)"
  if [ -x "$RESET" ]; then
    verdict=$("$RESET" acl-check 2>/dev/null | sed 's/^acl: //')
    case "$verdict" in
      dead*)    bad "ACL мёртв — нужен сброс чипа (bluetooth-fix.sh chip): $verdict" ;;
      unknown*) inf "ACL: $verdict — вердикт можно вынести только при активном соединении" ;;
      *)        ok "ACL: $verdict" ;;
    esac
  else bad "$RESET не установлен"; fi
  hciconfig hci0 2>/dev/null | grep -oE '(RX|TX) bytes:-?[0-9]+ acl:[0-9]+ sco:[0-9]+' | sed 's/^/  · /'
  [ -f /run/mt7630e-chip-reset.stamp ] &&
    inf "последний сброс чипа: $(date -d @"$(cat /run/mt7630e-chip-reset.stamp)" '+%H:%M:%S')" ||
    inf "сброса чипа в этой сессии не было"
  if journalctl -b -u bluetooth --no-pager 2>/dev/null | grep -q 'Protocol not available'; then
    inf "была гонка с WirePlumber (Protocol not available) — лечится переподключением (mazzy-bt-audio session)"
  fi

  echo "== сервисы"
  for u in bluetooth mt7630e-bluetooth mt7630e-bt-watchdog.timer; do
    st=$(systemctl is-active $u); en=$(systemctl is-enabled $u 2>/dev/null)
    [ "$st" = active ] && ok "$u: $st / $en" || bad "$u: $st / $en"
  done
  for u in mazzy-bt-audio.path mazzy-bt-audio.service; do
    st=$(systemctl --user is-active $u 2>/dev/null); en=$(systemctl --user is-enabled $u 2>/dev/null)
    [ "$en" = enabled ] && ok "(user) $u: ${st:-inactive} / $en" || bad "(user) $u: ${st:-нет} / ${en:-не установлен} — запусти install.sh"
  done
  bluetoothctl show 2>/dev/null | grep -q 'Powered: yes' && ok "bluez Powered" || bad "bluez не Powered"

  check_installed

  echo "== Аудио"
  sh "$CORE" status | sed '1,/^== Устройства/d' | sed 's/^/  /'

  echo "== последние логи"
  journalctl -b -u mt7630e-bluetooth -u mt7630e-bt-watchdog --no-pager -n 6 -o cat | sed 's/^/  /'
  journalctl -k -b --no-pager 2>/dev/null | grep -E 'hci0|btusb' | tail -3 | sed 's/^/  /'
}

fix() {
  echo "== Починка"
  if [ -x "$RESET" ]; then pkexec "$RESET" auto; else bad "$RESET не установлен"; fi
  systemctl --user start mazzy-bt-audio.service 2>/dev/null || sh "$CORE" session
}
reinstall() { pkexec sh "$SRC/install-bluetooth.sh" && bash "$SRC/../install.sh" >/dev/null 2>&1; }
chip() { echo "== Полный сброс чипа (Wi-Fi пропадёт на ~10 с)"; pkexec "$RESET" chip; sleep 3; }

case "${1:-fix}" in
  status) diag ;;
  reinstall) reinstall; fix; echo; diag ;;
  chip) chip; fix; echo; diag ;;
  *) diag; echo; fix; echo; diag ;;
esac
