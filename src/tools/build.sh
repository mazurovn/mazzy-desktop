#!/bin/sh
# Утилиты Go и MoonBit → ~/.local/bin. Nim и Mojo собирает src/nim/build.sh.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$HOME/.local/bin"

echo "==> Go: mazzy-wavpeak"
(
	cd "$ROOT/src/go/wavpeak"
	go build -trimpath -ldflags "-s -w" -o "$HOME/.local/bin/mazzy-wavpeak" .
)

echo "==> MoonBit: mazzy-sessionfile"
(
	cd "$ROOT/src/moon/sessionfile"
	moon build --target native --release
	install -m 755 _build/native/release/build/main/main.exe "$HOME/.local/bin/mazzy-sessionfile"
)
