#!/bin/sh
# /etc/systemd/system-sleep/mt7630e-bt — пробуждение = тот же «тёплый старт» чипа.
# pre:  запомнить, какие устройства были подключены (без хардкода MAC).
# post: полный сброс чипа + разбудить пользовательский юнит, он вернёт наушники после готовности WirePlumber.
case "$1" in
  pre)  /usr/local/sbin/mt7630e-bt-reset.sh save-connected ;;
  post) sleep 3; RECONNECT_MODE=resume /usr/local/sbin/mt7630e-bt-reset.sh chip ;;
esac
exit 0
