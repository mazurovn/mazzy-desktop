#!/bin/sh
# Bluetooth на ASUS N750 (MT7630E, USB 0489:e069): ядро не знает этот ID, поэтому привязываем его
# к btusb через udev, а чип оживляем сбросом (сервис при загрузке + watchdog + хук сна). См. README.md.
# Запуск: pkexec sh system/install-bluetooth.sh
# Аудио (профили A2DP/HFP, выбор выхода и микрофона, подключение наушников) — пользовательская часть:
#   mazzy-bt-audio status    (ставится этим же скриптом в /usr/local/bin)
set -e
cd "$(dirname "$0")"
install -m644 90-mt7630e-bluetooth.rules 91-mazzy-bt-adapter.rules 92-webcam-no-autosuspend.rules /etc/udev/rules.d/
install -m755 mt7630e-bt-reset.sh mt7630e-bt-watchdog.sh /usr/local/sbin/
install -m755 mazzy-bt-audio.sh /usr/local/bin/mazzy-bt-audio
install -m755 mazzy-bt-trigger.sh /usr/local/bin/mazzy-bt-trigger
install -m644 mt7630e-bluetooth.service mt7630e-bt-watchdog.service mt7630e-bt-watchdog.timer /etc/systemd/system/
install -d /etc/systemd/system/bluetooth.service.d /etc/bluetooth/main.conf.d /etc/systemd/system-sleep
install -d /usr/share/polkit-1/rules.d
install -m644 bluetooth-override.conf /etc/systemd/system/bluetooth.service.d/override.conf
# bluetoothd перезапускаем только если его конфиг реально изменился: перезапуск рвёт все
#живые соединения, а скрипт ставится часто (обновление скриптов стека).
if ! cmp -s 60-mazzy-bluetooth.conf /etc/bluetooth/main.conf.d/60-mazzy-bluetooth.conf; then
  install -m644 60-mazzy-bluetooth.conf /etc/bluetooth/main.conf.d/
  NEED_BT_RESTART=1
fi
install -m644 50-mazzy-connectivity.rules /usr/share/polkit-1/rules.d/
install -m755 mt7630e-bt-sleep.sh /etc/systemd/system-sleep/mt7630e-bt
echo btusb > /etc/modules-load.d/btusb.conf
udevadm control --reload
systemctl daemon-reload
[ "${NEED_BT_RESTART:-0}" = 1 ] && { systemctl restart bluetooth.service || true; }
systemctl enable bluetooth.service
# Лечилки MT7630E включаем только если этот чип действительно стоит в машине: на другом железе
# они сбрасывают чужое PCI-устройство по адресу 03:00.0 (проверено 2026-09-23 на Broadcom BCM4352).
if [ "$(cat /sys/bus/pci/devices/0000:03:00.0/vendor 2>/dev/null)" = 0x14c3 ] ||
   lsusb 2>/dev/null | grep -qE '0489:e069|0e8d:763f'; then
  systemctl enable mt7630e-bluetooth.service mt7630e-bt-watchdog.timer
  systemctl start mt7630e-bt-watchdog.timer
  echo "MT7630E найден: сервис сброса чипа и watchdog включены"
else
  systemctl disable --now mt7630e-bluetooth.service mt7630e-bt-watchdog.timer 2>/dev/null || true
  echo "MT7630E не найден: лечилки чипа выключены (на этом железе они не нужны)"
fi
echo "OK: правила, сервисы, watchdog, хук сна и polkit-правило установлены"
echo "Дальше (от пользователя, не root):  sh install.sh   — пользовательские юниты и конфиг аудио"
