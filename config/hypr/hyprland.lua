-- Mazzy на Hyprland 0.56. Формат Lua: .conf при старте даёт предупреждение
-- «Lua config not found, using legacy config».
-- Клавиатура, сочетания и ползунки настроек по-прежнему лежат в conf/:
--   conf/input.conf          kb_layout, kb_options
--   conf/binds.conf          сочетания (страница «Клавиши»)
--   conf/mazzy-effects.conf  блюр, зазоры, тень, анимации
-- Этот файл читает их при старте. Плагины 0.53 (hyprexpo, hyprfocus) не грузятся.
-- Раскладка dwindle. Ленту scrolling не включаем.

local confDir = (os.getenv("HOME") or "") .. "/.config/hypr/conf"

local function readKey(path, key)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    for line in f:lines() do
        if not line:match("^%s*#") then
            local v = line:match("^%s*" .. key .. "%s*=%s*(.-)%s*$")
            if v and v ~= "" then
                f:close()
                return v
            end
        end
    end
    f:close()
    return nil
end

local function setPath(root, dotted, value)
    local node = root
    local parts = {}
    for p in dotted:gmatch("[^%.]+") do
        parts[#parts + 1] = p
    end
    for i = 1, #parts - 1 do
        local k = parts[i]
        if type(node[k]) ~= "table" then
            node[k] = {}
        end
        node = node[k]
    end
    node[parts[#parts]] = value
end

local effectBool = {
    ["decoration.blur.enabled"] = true,
    ["decoration.shadow.enabled"] = true,
    ["decoration.dim_inactive"] = true,
    ["animations.enabled"] = true,
}

local function overlayEffects(cfg, path)
    local f = io.open(path, "r")
    if not f then
        return
    end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w:]+)%s*=%s*(.-)%s*$")
        if k then
            local dotted = k:gsub(":", ".")
            local num = tonumber(v)
            if not num then
                error("mazzy-effects: не число «" .. v .. "» у " .. k)
            end
            if effectBool[dotted] then
                setPath(cfg, dotted, num ~= 0)
            else
                setPath(cfg, dotted, num)
            end
        end
    end
    f:close()
end

-- Экран сидит на Intel HD 4600. GTX 850M только рендерит, глобальный EGL-замок не ставим.
hl.env("AQ_DRM_DEVICES", "/dev/dri/intel-card")
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
hl.env("QT_WAYLAND_DISABLE_WINDOWDECORATION", "1")
hl.env("QT_AUTO_SCREEN_SCALE_FACTOR", "1")
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
hl.env("GDK_BACKEND", "wayland,x11")
hl.env("MOZ_ENABLE_WAYLAND", "1")
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "auto")

hl.monitor({
    output = "eDP-1",
    mode = "preferred",
    position = "0x0",
    scale = 1,
})
hl.monitor({
    output = "",
    mode = "preferred",
    position = "auto-right",
    scale = 1,
})

hl.workspace_rule({ workspace = "1", persistent = true, default = true })
hl.workspace_rule({ workspace = "2", persistent = true })
hl.workspace_rule({ workspace = "3", persistent = true })
hl.workspace_rule({ workspace = "4", persistent = true })
hl.workspace_rule({ workspace = "5", persistent = true })

local kbLayout = readKey(confDir .. "/input.conf", "kb_layout") or "us,ru"
local kbOptions = readKey(confDir .. "/input.conf", "kb_options") or "grp:win_space_toggle,caps:escape_shifted_capslock"

local cfg = {
    general = {
        gaps_in = 6,
        gaps_out = 14,
        border_size = 1,
        col = {
            active_border = "rgba(ffffff33)",
            inactive_border = "rgba(ffffff12)",
        },
        resize_on_border = true,
        extend_border_grab_area = 12,
        allow_tearing = false,
        layout = "dwindle",
    },
    decoration = {
        rounding = 12,
        rounding_power = 2.5,
        active_opacity = 1.0,
        inactive_opacity = 0.96,
        dim_inactive = true,
        dim_strength = 0.06,
        shadow = {
            enabled = true,
            range = 12,
            render_power = 2,
            offset = { 0, 4 },
            color = "rgba(00000055)",
            color_inactive = "rgba(0000002e)",
        },
        blur = {
            enabled = true,
            size = 2,
            passes = 1,
            vibrancy = 0,
            noise = 0,
            brightness = 1.0,
            contrast = 1.0,
            popups = true,
            popups_ignorealpha = 0.5,
            ignore_opacity = true,
            new_optimizations = true,
            xray = false,
        },
    },
    animations = {
        enabled = true,
    },
    dwindle = {
        preserve_split = true,
        force_split = 2,
        smart_split = false,
    },
    master = {
        new_status = "master",
    },
    misc = {
        disable_hyprland_logo = true,
        disable_splash_rendering = true,
        focus_on_activate = false,
        animate_manual_resizes = true,
        animate_mouse_windowdragging = true,
    },
    input = {
        kb_layout = kbLayout,
        kb_options = kbOptions,
        follow_mouse = 1,
        sensitivity = 0,
        numlock_by_default = true,
        touchpad = {
            natural_scroll = true,
            tap_to_click = true,
            clickfinger_behavior = true,
            scroll_factor = 0.6,
            disable_while_typing = true,
        },
    },
}

overlayEffects(cfg, confDir .. "/mazzy-effects.conf")
hl.config(cfg)

hl.gesture({ fingers = 3, direction = "horizontal", action = "workspace" })
hl.gesture({ fingers = 4, direction = "up", action = "special", workspace_name = "hidden" })

hl.curve("easeOutExpo", { type = "bezier", points = { { 0.16, 1 }, { 0.3, 1 } } })
hl.curve("easeOutQuint", { type = "bezier", points = { { 0.23, 1 }, { 0.32, 1 } } })
hl.curve("easeInOutCubic", { type = "bezier", points = { { 0.65, 0.05 }, { 0.36, 1 } } })
hl.curve("overshot", { type = "bezier", points = { { 0.05, 0.9 }, { 0.1, 1.05 } } })
hl.curve("linear", { type = "bezier", points = { { 0, 0 }, { 1, 1 } } })

local function anim(leaf, speed, curve, style)
    hl.animation({
        leaf = leaf,
        enabled = true,
        speed = speed,
        bezier = curve,
        style = style,
    })
end

anim("global", 10, "default")
anim("windowsIn", 4, "easeOutExpo", "popin 85%")
anim("windowsOut", 3, "easeInOutCubic", "popin 85%")
anim("windowsMove", 4, "easeOutQuint")
anim("border", 6, "easeOutQuint")
anim("fadeIn", 3, "easeOutQuint")
anim("fadeOut", 3, "easeInOutCubic")
anim("fadeDim", 4, "easeOutQuint")
anim("layersIn", 3, "easeOutExpo", "fade")
anim("layersOut", 2, "easeInOutCubic", "fade")
anim("workspacesIn", 4, "easeOutExpo", "slidefade 15%")
anim("workspacesOut", 4, "easeInOutCubic", "slidefade 15%")
anim("specialWorkspaceIn", 4, "overshot", "slidevert")
anim("specialWorkspaceOut", 3, "easeInOutCubic", "slidevert")

local function loadBinds(path)
    local f = io.open(path, "r")
    if not f then
        error("нет файла сочетаний " .. path)
    end
    local vars = {}
    local function expand(s)
        return (s:gsub("%$([%w_]+)", function(n)
            local v = vars[n]
            if not v then
                return "$" .. n
            end
            return v
        end))
    end
    local dir = { l = "left", r = "right", u = "up", d = "down" }
    local function direction(s)
        return dir[s] or s
    end
    local function split4(s)
        local parts = {}
        local rest = s
        for _ = 1, 3 do
            local a, b = rest:match("^([^,]*),(.*)$")
            if not a then
                break
            end
            parts[#parts + 1] = (a:match("^%s*(.-)%s*$"))
            rest = b
        end
        parts[#parts + 1] = (rest:match("^%s*(.-)%s*$"))
        return parts
    end
    local function flagsFor(kind)
        local suffix = kind:match("^bind([a-z]*)$")
        if not suffix then
            error("неизвестная команда бинда " .. kind)
        end
        if suffix:find("[^elmrn]") then
            error("неизвестный флаг бинда " .. kind)
        end
        local flags = {}
        local any = false
        if suffix:find("e", 1, true) then flags.repeating = true; any = true end
        if suffix:find("l", 1, true) then flags.locked = true; any = true end
        if suffix:find("m", 1, true) then flags.mouse = true; any = true end
        if suffix:find("r", 1, true) then flags.release = true; any = true end
        if suffix:find("n", 1, true) then flags.non_consuming = true; any = true end
        if any then
            return flags
        end
        return nil
    end
    local function dispatcher(action, arg)
        if action == "exec" then
            return hl.dsp.exec_cmd(expand(arg))
        elseif action == "killactive" then
            return hl.dsp.window.close()
        elseif action == "fullscreen" then
            local mode = (arg == "1") and "maximized" or "fullscreen"
            return hl.dsp.window.fullscreen({ mode = mode })
        elseif action == "togglefloating" then
            return hl.dsp.window.float({ action = "toggle" })
        elseif action == "pseudo" then
            return hl.dsp.window.pseudo()
        elseif action == "layoutmsg" then
            return hl.dsp.layout(arg)
        elseif action == "movetoworkspacesilent" then
            return hl.dsp.window.move({ workspace = arg, follow = false })
        elseif action == "togglespecialworkspace" then
            return hl.dsp.workspace.toggle_special(arg)
        elseif action == "movefocus" then
            return hl.dsp.focus({ direction = direction(arg) })
        elseif action == "movewindow" then
            if arg == "" then
                return hl.dsp.window.drag()
            end
            return hl.dsp.window.move({ direction = direction(arg) })
        elseif action == "resizewindow" then
            return hl.dsp.window.resize()
        elseif action == "resizeactive" then
            local x, y = arg:match("^(-?%d+)%s+(-?%d+)$")
            if not x then
                error("resizeactive: «" .. arg .. "»")
            end
            return hl.dsp.window.resize({ x = tonumber(x), y = tonumber(y), relative = true })
        elseif action == "workspace" then
            return hl.dsp.focus({ workspace = tonumber(arg) or arg })
        elseif action == "movetoworkspace" then
            return hl.dsp.window.move({ workspace = tonumber(arg) or arg })
        end
        error("неизвестный диспетчер " .. action)
    end
    local n = 0
    for line in f:lines() do
        local raw = line:match("^(.-)%s*#") or line
        raw = raw:match("^%s*(.-)%s*$")
        if raw ~= "" then
            local name, value = raw:match("^%$(%w+)%s*=%s*(.-)%s*$")
            if name then
                vars[name] = value
            else
                local kind, body = raw:match("^(bind%a*)%s*=%s*(.-)%s*$")
                if kind then
                    local parts = split4(body)
                    if #parts < 3 then
                        error("короткий бинд: " .. raw)
                    end
                    local keys = (function()
                        local mods = expand(parts[1])
                        local bits = {}
                        for w in mods:gmatch("%S+") do
                            bits[#bits + 1] = w
                        end
                        bits[#bits + 1] = expand(parts[2])
                        return table.concat(bits, " + ")
                    end)()
                    local disp = dispatcher(parts[3], parts[4] or "")
                    local flags = flagsFor(kind)
                    if flags then
                        hl.bind(keys, disp, flags)
                    else
                        hl.bind(keys, disp)
                    end
                    n = n + 1
                end
            end
        end
    end
    f:close()
    if n == 0 then
        error("в " .. path .. " нет сочетаний")
    end
end

loadBinds(confDir .. "/binds.conf")

hl.layer_rule({
    name = "noctalia",
    match = { namespace = "^noctalia-(bar-.+|notification|dock|panel|attached-panel|osd|window-switcher)$" },
    no_anim = true,
    ignore_alpha = 0.5,
    blur = true,
    blur_popups = true,
})
hl.layer_rule({
    name = "mazzy-chrome",
    match = { namespace = "^mazzy-(bar|dock)$" },
    no_anim = true,
})
hl.layer_rule({
    name = "mazzy-switcher",
    match = { namespace = "^mazzy-switcher$" },
    no_anim = true,
    blur = true,
    ignore_alpha = 0.3,
})

hl.window_rule({
    name = "suppress-maximize",
    match = { class = ".*" },
    suppress_event = "maximize",
})
hl.window_rule({
    name = "fix-xwayland-drags",
    match = {
        class = "^$",
        title = "^$",
        xwayland = true,
        float = true,
        fullscreen = false,
        pin = false,
    },
    no_focus = true,
})
hl.window_rule({
    name = "float-settings",
    match = { class = "^(dev.noctalia.Noctalia|org.gnome.Settings|gnome-control-center|qt6ct)$" },
    float = true,
    center = true,
    size = { 1100, 720 },
})
hl.window_rule({
    name = "cursor-float",
    match = { class = "^(cursor|Cursor)$" },
    float = true,
    center = true,
    size = { 1400, 900 },
})
hl.window_rule({
    name = "float-utils",
    match = { class = "^(org.gnome.Calculator|pavucontrol|nm-connection-editor|blueman-manager|xdg-desktop-portal-gtk|org.pulseaudio.pavucontrol)$" },
    float = true,
    center = true,
    size = { "monitor_w * 0.4", "monitor_h * 0.5" },
})
hl.window_rule({
    name = "float-dialogs",
    match = { title = "^(Open File|Save File|Open Folder|Choose Files|Выберите файл|Открыть|Сохранить как)$" },
    float = true,
    center = true,
    size = { "monitor_w * 0.6", "monitor_h * 0.6" },
})
hl.window_rule({
    name = "zoom-float",
    match = { class = "^(zoom)$" },
    float = true,
})
hl.window_rule({
    name = "zoom-meeting-tile",
    match = { class = "^(zoom)$", title = "^(Zoom Meeting|Zoom Workplace).*" },
    float = false,
})
hl.window_rule({
    name = "kitty-opacity",
    match = { class = "^(kitty)$" },
    opacity = "0.92 0.88",
})
hl.window_rule({
    name = "opaque-video",
    match = { class = "^(firefox|mpv|vlc|zoom)$", fullscreen = true },
    opacity = "1.0 1.0",
})
hl.window_rule({
    name = "firefox-pip",
    match = { title = "^(Picture-in-Picture)$" },
    float = true,
    pin = true,
    size = { "monitor_w * 0.3", "monitor_h * 0.3" },
    move = { "monitor_w * 0.68", "monitor_h * 0.66" },
})

-- Только первый старт сессии. Повтор на reload поднял бы вторую оболочку.
hl.on("hyprland.start", function()
    hl.exec_cmd("systemctl --user import-environment WAYLAND_DISPLAY XDG_CURRENT_DESKTOP HYPRLAND_INSTANCE_SIGNATURE")
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP HYPRLAND_INSTANCE_SIGNATURE")
    hl.exec_cmd("/usr/libexec/hyprpolkitagent")
    hl.exec_cmd("mako")
    hl.exec_cmd("env __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json " .. os.getenv("HOME") .. "/.local/bin/mazzy-shell")
    hl.exec_cmd("nm-applet --indicator")
    hl.exec_cmd("blueman-applet")
    hl.exec_cmd("wl-paste --type text --watch cliphist store")
    hl.exec_cmd("wl-paste --type image --watch cliphist store")
    hl.exec_cmd("gsettings set org.gnome.desktop.interface color-scheme prefer-dark")
    hl.exec_cmd("gsettings set org.gnome.desktop.interface icon-theme Papirus-Dark")
    hl.exec_cmd("gsettings set org.gnome.desktop.interface cursor-theme Adwaita")
    hl.exec_cmd("hyprctl setcursor Adwaita 24")
end)
