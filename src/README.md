# src — нативная часть MAZZY_VO (Nim, Mojo, Go, MoonBit)

```
nim/mazzy_shell.nim   бар, док, листы и карусель. Один бинарник для сессий Mango и Hyprland
nim/seat.nim          сокет места: клиенты, стол, живое имя раскладки
nim/sni.nim           трей StatusNotifierWatcher
nim/gfx.nim           GLES2: смешивание с предумноженной альфой, текст pangocairo
nim/hypr.nim          IPC Hyprland (.socket.sock JSON-запросы, .socket2.sock события)
nim/wl.nim            биндинги wayland-client / wlr-layer-shell / hyprland-toplevel-export / wl_shm / EGL / GLES2 / xkbcommon
nim/mazzy_ctl.nim     клиент для биндов: mazzy-ctl switcher next|prev|select|cancel, mazzy-ctl wallpaper reload
nim/protocols/        XML wlr-layer-shell и hyprland-toplevel-export-v1 (генерируется wayland-scanner в nim/gen/)
nim/tests/            test_tasks.nim — виджеты, док, раскладка, сессия; test_common.nim — конфиги. Бинарник теста в git не входит
nim/mazzy_common.nim  общее для демона и настроек: дефолты + load/save settings.json, сокеты, генератор
                      mazzy-effects.conf, парсер/запись binds.conf
nim/mazzy_settings.nim, adw.nim  MAZZY Environment — центр настроек (libadwaita через importc, без Python)
mojo/mazzy.mojo       libmazzy_mojo.so: раскладка карусели, сглаживание, миниатюры BGRA→RGBA с даунскейлом (C ABI)
nim/build.sh          сборка оболочки → ~/.local/bin/{mazzy-shell,mazzy-ctl,mazzy-settings}, ~/.local/lib/mazzy/libmazzy_mojo.so
go/wavpeak/           mazzy-wavpeak: пик PCM WAV для проверки микрофона
moon/sessionfile/     mazzy-sessionfile: Session/XSession и вставка строки в файл
tools/build.sh        Go и MoonBit → ~/.local/bin/{mazzy-wavpeak,mazzy-sessionfile}
```

Зависимости оболочки: `nim gcc libwayland-dev libegl-dev libgles-dev wayland-protocols libxkbcommon-dev
libgdk-pixbuf-2.0-dev libpango1.0-dev libcairo2-dev libadwaita-1-dev`. Компилятор Mojo — `~/.mojo-venv/bin/mojo`
(пакет `mojo` издателя Modular; в репозитории его не ставим). Go и MoonBit уже в системе; утилиты собирает `tools/build.sh`.

Сокеты `$XDG_RUNTIME_DIR/mazzy-switcher.sock` и `mazzy-wallpaper.sock`, конфиг `~/.config/mazzy/settings.json`
(правится через MAZZY Environment — `mazzy-settings`, он же шлёт `reload`; дефолты и схема — в `mazzy_common.nim`).

Превью карусели — снимок самого окна, не прямоугольника экрана. На Hyprland это
`hyprland_toplevel_export_v1` (младшие 32 бита адреса). На Mango — `ext-image-copy-capture`
с источника foreign toplevel: идентификатор тот же, что `foreign_toplevel_id`. Один кадр в
полёте, сессия закрывается сразу после него. За одно открытие снимаются выбранная карточка
и два соседа. Длинная сторона миниатюры не больше 640, в кэше не больше шести. Общий shm-пул
отпускается, когда карусель закрылась. Повтор того же окна не чаще раза в 1,2 с. Прогрев
после смены фокуса есть только на Hyprland. Если нет ни одного протокола — карточка с
заглушкой, старт не обрывается. Кадр уменьшает Mojo (`mz_bgra_to_rgba_fit`). `grim` карусели не нужен.
