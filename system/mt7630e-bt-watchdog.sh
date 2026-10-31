#!/bin/sh
# Раз в минуту: hci0 UP, ACL жив, bluetoothd жив? Иначе чиним чип.
# Сброс чипа (роняет Wi-Fi на ~10 с) — только при мёртвом ACL и не чаще 1 раза в 10 мин (reset.sh auto).
#
# Наушники здесь НЕ подключаются: слепой `bluetoothctl connect` к выключенным наушникам стоил 12 с радио
# и строку `Host is down` в журнале каждую минуту. Подключением занимается пользовательский юнит
# mazzy-bt-audio.service (по событию: старт сессии, пробуждение, сброс чипа) и сами наушники через
# политику BlueZ (ReconnectAttempts/ReconnectIntervals в 60-mazzy-bluetooth.conf). См. спеку bt-audio.
/usr/local/sbin/mt7630e-bt-reset.sh auto || exit 1
systemctl is-active -q bluetooth || systemctl start bluetooth
exit 0
