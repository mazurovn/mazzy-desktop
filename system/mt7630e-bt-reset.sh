#!/bin/sh
# MT7630E (Wi-Fi PCIe 03:00.0 mt76x0e + BT USB 0489:e069, общий MCU). Два режима отказа:
#  1) HCI Reset timeout (-110), hci0 DOWN            -> USB port power-cycle (режим `usb`)
#  2) hci0 UP, но ACL мёртв: RX acl не растёт, "link tx timeout" -> только PCI bus reset чипа (режим `chip`)
# Режимы: chip (по умолчанию; boot/sleep), usb, auto (для watchdog: chip только при мёртвом ACL,
# не чаще 1 раза в 10 мин), acl-check (код 0 = жив/неизвестно, 1 = мёртв). См. openspec/specs/mt7630e-radio.
PCI=/sys/bus/pci/devices/0000:03:00.0
# Скрипт лечит КОНКРЕТНЫЙ чип MT7630E. 2026-09-23 в ноутбуке модуль заменили на Broadcom BCM4352 +
# BCM20702A0, и скрипт начал сбрасывать чужое PCI-устройство по тому же адресу 03:00.0 и выгружать
# btusb — каждые 20 секунд, пока не отключили юниты. Поэтому сначала проверяем, что железо наше.
mt7630e_present() {
  [ "$(cat $PCI/vendor 2>/dev/null)" = 0x14c3 ] && return 0      # MediaTek на PCI
  lsusb 2>/dev/null | grep -qE '0489:e069|0e8d:763f' && return 0 # его же BT на USB
  return 1
}
if ! mt7630e_present; then
  echo "MT7630E в системе нет (адаптер заменён?) — скрипт не нужен, выходим"
  exit 0
fi
STAMP=/run/mt7630e-chip-reset.stamp
STATE=${MT7630E_STATE:-/run/mt7630e-acl.state}   # снимок счётчиков: "ts tx rx conns dead_streak"
RUNDIR=${MT7630E_RUNDIR:-/run/mazzy-bt}          # was-connected + триггер для пользовательского юнита
RATE=600
log() { echo "$*"; }

find_dev() {
  for d in /sys/bus/usb/devices/*; do
    [ "$(cat $d/idVendor 2>/dev/null)" = 0489 ] && [ "$(cat $d/idProduct 2>/dev/null)" = e069 ] && { basename $d; return; }
    [ "$(cat $d/idVendor 2>/dev/null)" = 0e8d ] && [ "$(cat $d/idProduct 2>/dev/null)" = 763f ] && { basename $d; return; }
  done
}
bind_btusb() {
  modprobe btusb 2>/dev/null
  grep -q '^0489 e069' /sys/bus/usb/drivers/btusb/new_id 2>/dev/null || echo "0489 e069 0 0e8d 763f" > /sys/bus/usb/drivers/btusb/new_id
}
up_ok() { hciconfig hci0 up 2>/dev/null; hciconfig hci0 2>/dev/null | grep -q 'UP RUNNING'; }

# Адаптер выключен пользователем (BlueZ Powered=false) — это не поломка: при выборе другого
# адаптера (USB-донгл) встроенный намеренно гасится, и «лечить» его нельзя, иначе watchdog
# каждую минуту включает его обратно и жжёт по 3-14 с на power-cycle порта.
powered_off_by_user() {
  [ -d /sys/class/bluetooth/hci0 ] || return 1
  busctl --system get-property org.bluez /org/bluez/hci0 org.bluez.Adapter1 Powered 2>/dev/null |
    grep -q false
}

# Число активных ACL-линков (0 = устройств не подключено, вердикт о канале вынести нельзя).
acl_conns() { hcitool con 2>/dev/null | grep -c 'ACL'; }

# MAC подключённых устройств — снимок перед сбросом/сном, чтобы потом переподключить (без хардкода).
save_connected() {
  mkdir -p $RUNDIR
  hcitool con 2>/dev/null | awk '/ACL/{print $3}' > $RUNDIR/was-connected.tmp 2>/dev/null
  mv -f $RUNDIR/was-connected.tmp $RUNDIR/was-connected 2>/dev/null
}
# Разбудить пользовательский юнит: он дождётся эндпойнтов WirePlumber и переподключит наушники.
trigger_user_reconnect() {
  mkdir -p $RUNDIR
  echo "${1:-after-reset} $(date +%s)" > $RUNDIR/trigger.tmp
  mv -f $RUNDIR/trigger.tmp $RUNDIR/trigger
  chmod 644 $RUNDIR/trigger 2>/dev/null
}

# Детектор мёртвого ACL. Два признака, оба проверены на живом железе:
#  1) есть соединение, TX acl растёт, а RX acl так и остался НУЛЁМ — линк поднят, но с него не пришло
#     ни одного пакета (режим отказа после тёплого ребута); требуем два тика подряд;
#  2) "hci0: link tx timeout" в журнале ядра за 10 минут — обрыв канала в середине сессии.
# Правило «RX не вырос между тиками» НЕ годится: при воспроизведении A2DP ноутбук шлёт непрерывный поток,
# а обратно приходят только редкие AVRCP/ACK — 2026-09-23 это дало ложный вердикт и сброс чипа посреди музыки.
# Нет соединений -> unknown, сброс не выполняется.
acl_check() {
  [ "$MT7630E_FORCE_DEAD" = 1 ] && { log "acl: forced dead (test)"; return 1; }
  s=$(hciconfig hci0 2>/dev/null) || { log "acl: no hci0"; return 1; }
  # bytes-счётчики переполняются в минус — берём только acl: (первый = RX, второй = TX)
  rx=$(echo "$s" | grep -o 'acl:[0-9]*' | sed -n 1s/acl://p); tx=$(echo "$s" | grep -o 'acl:[0-9]*' | sed -n 2s/acl://p)
  rx=${rx:-0}; tx=${tx:-0}
  conns=$(acl_conns)
  ptx=0; prx=0; streak=0
  if [ -r $STATE ]; then
    read -r _pts ptx prx _pconns streak < $STATE 2>/dev/null
    ptx=${ptx:-0}; prx=${prx:-0}; streak=${streak:-0}
  fi

  if journalctl -k --since '-10min' -o cat 2>/dev/null | grep -q 'hci0: link tx timeout'; then
    echo "$(date +%s) $tx $rx $conns 0" > $STATE
    log "acl: dead (link tx timeout)"; return 1
  fi

  if [ "$conns" -eq 0 ]; then
    echo "$(date +%s) $tx $rx $conns 0" > $STATE
    log "acl: unknown (нет соединений)"; return 0
  fi

  if [ "$rx" -eq 0 ] && [ "$tx" -gt "$ptx" ]; then
    streak=$((streak + 1))
  else
    streak=0
  fi
  echo "$(date +%s) $tx $rx $conns $streak" > $STATE
  if [ "$streak" -ge 2 ]; then
    log "acl: dead (соединение есть, tx $ptx->$tx, а RX acl всё ещё 0; $streak тика подряд)"; return 1
  fi
  log "acl: alive (tx=$tx rx=$rx conns=$conns)"; return 0
}

# Режим 1: USB port power-cycle, до 5 попыток.
usb_reset() {
  DEV=$(find_dev); [ -n "$DEV" ] || { log "MT7630E BT not found on USB"; return 1; }
  bind_btusb
  PORT=$(readlink -f /sys/bus/usb/devices/$DEV/port)
  for try in 1 2 3 4 5; do
    sleep 2
    if up_ok; then
      log "hci0 up (try $try)"; echo on > /sys/bus/usb/devices/$DEV/power/control 2>/dev/null; return 0
    fi
    log "hci0 not up, power-cycle $PORT (try $try)"
    echo 1 > $PORT/disable; sleep 3; echo 0 > $PORT/disable; sleep 5
    DEV=$(find_dev); [ -n "$DEV" ] || { sleep 3; DEV=$(find_dev); }
  done
  log "hci0 still down"; return 1
}

# Режим 2: полный сброс чипа. Wi-Fi пропадает на ~10 с, NetworkManager переподключает сам.
chip_reset() {
  save_connected
  DEV=$(find_dev)
  PORT=$( [ -n "$DEV" ] && readlink -f /sys/bus/usb/devices/$DEV/port )
  [ -e "$PCI/reset" ] || { log "no PCI reset for $PCI"; return 1; }
  log "chip reset: start"
  systemctl stop bluetooth 2>/dev/null; hciconfig hci0 down 2>/dev/null
  modprobe -r btusb btmtk 2>/dev/null
  [ -n "$PORT" ] && echo 1 > $PORT/disable
  modprobe -r mt76x0e 2>/dev/null; sleep 1
  echo bus > $PCI/reset_method 2>/dev/null
  echo 1 > $PCI/reset || { log "pci reset failed"; }
  sleep 2
  modprobe mt76x0e || { sleep 3; modprobe mt76x0e; }
  sleep 3
  [ -n "$PORT" ] && { echo 0 > $PORT/disable; sleep 5; }
  bind_btusb; sleep 2
  date +%s > $STAMP
  rm -f $STATE
  usb_reset || return 1
  systemctl start --no-block bluetooth 2>/dev/null
  trigger_user_reconnect "${RECONNECT_MODE:-after-reset}"
  log "chip reset ok"
}

case "${1:-chip}" in
  usb)  usb_reset ;;
  chip) chip_reset ;;
  acl-check) acl_check ;;
  save-connected) save_connected; log "saved: $(tr '\n' ' ' < $RUNDIR/was-connected 2>/dev/null)" ;;
  trigger) trigger_user_reconnect "${2:-after-reset}" ;;
  auto)
    if powered_off_by_user; then
      log "hci0 выключен пользователем (выбран другой адаптер) — не трогаем"
      exit 0
    fi
    if hciconfig hci0 2>/dev/null | grep -q 'UP RUNNING'; then
      acl_check && exit 0
      last=$(cat $STAMP 2>/dev/null || echo 0); now=$(date +%s)
      [ $((now - last)) -lt $RATE ] && { log "chip reset skipped (rate limit, $((now - last))s ago)"; exit 0; }
      chip_reset
    else
      usb_reset || chip_reset
    fi ;;
  *) echo "usage: $0 [chip|usb|auto|acl-check|save-connected|trigger]"; exit 2 ;;
esac
