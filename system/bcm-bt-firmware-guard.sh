#!/bin/sh
# Broadcom BCM20702 (USB 13d3:3404 и родственные): при инициализации btusb чип обязан получить
# патч прошивки brcm/BCM20702A1-*.hcd. Если btusb поднялся раньше, чем файл стал доступен
# (dracut не кладёт этот .hcd в initramfs — см. dracut-bcm-bt-firmware.conf), чип остаётся на ROM-прошивке «build 0000» —
# наушники подключаются и тут же отваливаются (`Host is down`). Тогда перезагружаем btusb:
# драйвер перечитает прошивку уже с корневой ФС. Правило udev 91-mazzy-bt-adapter.rules
# отметит появление адаптера, и mazzy-bt-audio.path переподключит наушники.
set -u
log() { echo "bcm-bt-firmware-guard: $*"; }

grep -qs BCM20702 /sys/class/bluetooth/hci*/device/../product || { log "адаптера BCM20702 нет"; exit 0; }

kmsg=$(journalctl -k -b -o cat --no-pager 2>/dev/null)
if echo "$kmsg" | grep -qE "hci[0-9]+: BCM20702A1 '.*\.hcd' Patch"; then
  log "патч прошивки загружен"; exit 0
fi
if ! echo "$kmsg" | grep -q "BCM: firmware Patch file not found"; then
  log "патч не упоминается в журнале ядра — ничего не делаю"; exit 0
fi
ls /lib/firmware/brcm/BCM20702A1-*.hcd* >/dev/null 2>&1 || { log "файла прошивки нет в /lib/firmware/brcm"; exit 1; }

log "патч не загрузился при старте — перезагружаю btusb"
modprobe -r btusb && sleep 1 && modprobe btusb
sleep 3
if journalctl -k -b -o cat --no-pager | grep -qE "hci[0-9]+: BCM20702A1 '.*\.hcd' Patch"; then
  log "патч загружен после перезагрузки btusb"
else
  log "патч так и не загрузился"; exit 1
fi
