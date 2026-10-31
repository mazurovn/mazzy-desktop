#!/bin/sh
# Сборка mazzy-shell (Nim) + libmazzy_mojo (Mojo). Результат → ~/.local/bin, ~/.local/lib/mazzy
set -e
cd "$(dirname "$0")"
MOJO=${MOJO:-$HOME/.mojo-venv/bin/mojo}
LIBDIR=$HOME/.local/lib/mazzy
mkdir -p gen "$LIBDIR" ~/.local/bin
wayland-scanner client-header protocols/wlr-layer-shell-unstable-v1.xml gen/wlr-layer-shell-unstable-v1-client-protocol.h
wayland-scanner private-code  protocols/wlr-layer-shell-unstable-v1.xml gen/wlr-layer-shell-unstable-v1-protocol.c
# hyprland-toplevel-export-v1.xml — из hyprwm/hyprland-protocols (commit 301733a, интерфейс v2): снимки окон для карусели
wayland-scanner client-header protocols/hyprland-toplevel-export-v1.xml gen/hyprland-toplevel-export-v1-client-protocol.h
wayland-scanner private-code  protocols/hyprland-toplevel-export-v1.xml gen/hyprland-toplevel-export-v1-protocol.c
wayland-scanner client-header /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml gen/xdg-shell-client-protocol.h
wayland-scanner private-code  /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml gen/xdg-shell-protocol.c
# Mango отдаёт снимок окна этими протоколами. hyprland_toplevel_export там нет.
wayland-scanner client-header /usr/share/wayland-protocols/staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml gen/ext-image-copy-capture-v1-client-protocol.h
wayland-scanner private-code  /usr/share/wayland-protocols/staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml gen/ext-image-copy-capture-v1-protocol.c
wayland-scanner client-header /usr/share/wayland-protocols/staging/ext-image-capture-source/ext-image-capture-source-v1.xml gen/ext-image-capture-source-v1-client-protocol.h
wayland-scanner private-code  /usr/share/wayland-protocols/staging/ext-image-capture-source/ext-image-capture-source-v1.xml gen/ext-image-capture-source-v1-protocol.c
wayland-scanner client-header /usr/share/wayland-protocols/staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml gen/ext-foreign-toplevel-list-v1-client-protocol.h
wayland-scanner private-code  /usr/share/wayland-protocols/staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml gen/ext-foreign-toplevel-list-v1-protocol.c
echo "==> Mojo: libmazzy_mojo.so"
"$MOJO" build --emit shared-lib -o "$LIBDIR/libmazzy_mojo.so" ../mojo/mazzy.mojo 2>&1 | grep -v Crashpad || true
[ -f "$LIBDIR/libmazzy_mojo.so" ]
echo "==> Nim: mazzy-shell, mazzy-ctl, mazzy-settings"
nim c -d:release -d:danger --opt:size --mm:arc -d:MojoDir="$LIBDIR" --hints:off -o:$HOME/.local/bin/mazzy-shell mazzy_shell.nim
nim c -d:release -d:danger --opt:size --mm:arc --hints:off -o:$HOME/.local/bin/mazzy-ctl mazzy_ctl.nim
rm -f ~/.local/bin/mazzy-settings   # мог быть симлинком на старый Python-скрипт
nim c -d:release --opt:size --mm:arc --hints:off -o:$HOME/.local/bin/mazzy-settings mazzy_settings.nim
strip ~/.local/bin/mazzy-shell ~/.local/bin/mazzy-ctl ~/.local/bin/mazzy-settings
ls -la ~/.local/bin/mazzy-shell ~/.local/bin/mazzy-ctl ~/.local/bin/mazzy-settings "$LIBDIR/libmazzy_mojo.so"
