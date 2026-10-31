#!/usr/bin/env bash
# MAZZY_VO — установка окружения Hyprland + Noctalia на Ubuntu 26.04.
# Запуск: ./install.sh   (пароль спросит pkexec/sudo один раз)
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Плагины hyprexpo/hyprfocus сюда не входят: их ABI только у Hyprland 0.53.
PKGS=(hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk hyprpolkitagent
      kitty wl-clipboard cliphist grim slurp swappy brightnessctl playerctl
      qt6-wayland qt6ct fonts-inter fonts-jetbrains-mono fonts-noto-color-emoji
      papirus-icon-theme nwg-look noctalia
      nim gcc libwayland-dev libegl-dev libgles-dev wayland-protocols libxkbcommon-dev
      libgdk-pixbuf-2.0-dev libpango1.0-dev libcairo2-dev libadwaita-1-dev)

as_root() { if [ "$(id -u)" = 0 ]; then "$@"; elif command -v pkexec >/dev/null && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then pkexec "$@"; else sudo "$@"; fi; }

echo "==> Репозиторий Noctalia + пакеты"
tmp=$(mktemp -d)
curl -fsSL https://pkg.noctalia.dev/deb/nickh-archive-keyring.deb -o "$tmp/keyring.deb"
curl -fsSL https://pkg.noctalia.dev/deb/noctalia-resolute.sources -o "$tmp/noctalia.sources"
as_root bash -c "set -e; export DEBIAN_FRONTEND=noninteractive
  dpkg -i '$tmp/keyring.deb' >/dev/null
  install -m644 '$tmp/noctalia.sources' /etc/apt/sources.list.d/noctalia-resolute.sources
  apt-get update -qq
  apt-get install -y ${PKGS[*]}"
rm -rf "$tmp"

echo "==> Bluetooth (MT7630E, USB 0489:e069 — ядро его не знает, правило udev)"
as_root sh "$REPO/system/install-bluetooth.sh"

echo "==> Симлинки конфигов в ~/.config"
mkdir -p ~/.config
for d in "$REPO"/config/*/; do
  name=$(basename "$d")
  [ "$name" = applications ] && continue   # .desktop — отдельно, в ~/.local/share
  if [ -e ~/.config/"$name" ] && [ ! -L ~/.config/"$name" ]; then
    mv ~/.config/"$name" ~/.config/"$name.bak-$(date +%Y%m%d%H%M%S)"
  fi
  ln -sfn "$d" ~/.config/"$name"
done

echo "==> .desktop-переопределения (Noctalia → настройки, GNOME Settings в лаунчере)"
mkdir -p ~/.local/share/applications
ln -sf "$REPO"/config/applications/*.desktop ~/.local/share/applications/
update-desktop-database ~/.local/share/applications 2>/dev/null || true

echo "==> Пользовательские юниты Bluetooth-аудио (подключение профилей после готовности WirePlumber)"
mkdir -p ~/.config/systemd/user
install -m644 "$REPO"/system/mazzy-bt-audio.service "$REPO"/system/mazzy-bt-audio-trigger.service \
              "$REPO"/system/mazzy-bt-audio.path ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable mazzy-bt-audio.service >/dev/null
systemctl --user enable --now mazzy-bt-audio.path >/dev/null
# старый конфиг «только A2DP» ломал микрофон — с 2026-09-23 в репозитории остался один 51-bluez-headset.conf.
# Если ~/.config/wireplumber — симлинк в репозиторий, ничего не удаляем: рабочее дерево git не трогаем.
wpd=$(readlink -f ~/.config/wireplumber/wireplumber.conf.d 2>/dev/null || true)
case "${wpd:-}" in "$REPO"*|"") : ;; *) rm -f "$wpd/51-bluez-a2dp-only.conf" ;; esac

echo "==> prime-run: приложения на GTX 850M, стол остаётся на Intel"
mkdir -p ~/.local/bin
install -m755 "$REPO"/system/prime-run ~/.local/bin/prime-run

echo "==> Сборка Nim, Mojo, Go и MoonBit"
if [ ! -x "$HOME/.mojo-venv/bin/mojo" ]; then
  echo "Нет компилятора Mojo: ~/.mojo-venv/bin/mojo" >&2
  echo "Его отдаёт пакет mojo издателя Modular. Код Mazzy Python не запускает." >&2
  exit 1
fi
mkdir -p ~/.local/bin
"$REPO"/src/nim/build.sh
"$REPO"/src/tools/build.sh

echo "==> Обои"
mkdir -p ~/Pictures/Wallpapers
cp -n "$REPO"/wallpapers/*.jpg ~/Pictures/Wallpapers/
[ -e ~/Pictures/Wallpapers/default.jpg ] || cp ~/Pictures/Wallpapers/mountain-night.jpg ~/Pictures/Wallpapers/default.jpg

echo "==> Проверка конфигов"
Hyprland --verify-config 2>&1 | grep -E 'config ok|error' || true
noctalia config validate 2>&1 | grep -vE 'include cycle' || true

echo
echo "Готово. Выйдите из GNOME и на экране входа выберите сессию «Hyprland»."
