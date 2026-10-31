#!/bin/sh
# Пишет метку для mazzy-bt-audio.path. В правиле udev знака % нет:
# udev считает % подстановкой и отклоняет date +%s.
mkdir -p /run/mazzy-bt
echo "adapter-changed $(date +%s)" > /run/mazzy-bt/trigger
chmod 644 /run/mazzy-bt/trigger
