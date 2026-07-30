--[[
    widget.lua (Standalone Glass Panel with Top 5 CPU & Top 5 MEM)
--]]

pcall(require, "cairo")

-- Portable drawing-surface helper (Wayland + X11 fallback)
local has_cairo_xlib, cairo_xlib = pcall(require, "cairo_xlib")
if not has_cairo_xlib then
    cairo_xlib = setmetatable({}, {
        __index = function(_, k) return _G[k] end,
    })
end

local function get_draw_surface()
    if conky_surface then
        local s = conky_surface()
        if s then return s, false end
    end
    if conky_window and cairo_xlib_surface_create then
        local s = cairo_xlib_surface_create(conky_window.display,
            conky_window.drawable, conky_window.visual,
            conky_window.width, conky_window.height)
        return s, true
    end
    return nil, false
end

-- Resolves the directory this .lua file lives in, regardless of Conky's
-- working directory, so a relative default logo path (see CFG.logo below)
-- still finds the file next to widget.lua.
local function script_dir()
    local str = debug.getinfo(2, "S").source:sub(2)
    return str:match("(.*/)") or "./"
end

-- ==================== Config ====================

-- Color palette, defined once so both CFG.colors (panel text/accents) and
-- CFG.graphs (per-graph line/fill colors) can reference the same values.
local COLOR_TEXT   = 0xFFFFFF
local COLOR_ORANGE = 0xE7660B
local COLOR_YELLOW = 0xDCE142
local COLOR_GREEN  = 0x42E147
local COLOR_BLUE   = 0x00A2FF
local COLOR_PURPLE = 0xAA88FF
local COLOR_BAR_BG = 0x333344
local COLOR_DANGER = 0xFF3B30

local CFG = {
    network_iface = "auto", -- "auto" for automatic detection, or specify an interface explicitly (e.g. "eth0")
    aur_helper = "yay",   -- "yay", "paru", or "none" -- ignored entirely on non-pacman systems
    show_flatpak = true,  -- true/false: include Flatpak update count

    net_max_download = 30, -- MB/s -- hard ceiling the download graph will never exceed
    net_max_upload   = 6,  -- MB/s -- hard ceiling the upload graph will never exceed

    -- Logo overlay, drawn once per frame at a fixed position over the whole
    -- widget canvas (not tied to a specific panel). Only `height` is
    -- adjustable -- width is derived automatically from the PNG's own
    -- aspect ratio, so the image never looks stretched or squashed.
    logo = {
        path   = script_dir() .. "logo.png", -- default: logo.png next to widget.lua; can be an absolute path instead
        x      = 140,
        y      = 74,
        height = 76,
    },

    font = "DejaVu Sans Mono",
    margin = 10,
    top_margin = 10,
    pad = 12,
    gap = 12,
    corner_radius = 10,

    glass_base_color = 0x08081A,
    glass_base_alpha = 0.35,

    colors = {
        text     = COLOR_TEXT,
        accent1  = COLOR_ORANGE, -- Orange
        accent2  = COLOR_YELLOW, -- Yellow
        accent3  = COLOR_GREEN,  -- Green
        accent4  = COLOR_BLUE,   -- Blue
        bar_bg   = COLOR_BAR_BG,
        danger   = COLOR_DANGER, -- used by the CPU graph above 90% load
    },

    -- Per-graph appearance/behavior. Each entry is passed straight into
    -- draw_area_graph(), so any field here can be tuned independently:
    --   height         - graph height in px
    --   color          - line/fill color (hex); ignored if dynamic_color is set
    --   fill_alpha_near - fill opacity near the baseline (bottom) of the graph
    --   fill_alpha_far  - fill opacity at the far/top edge of the graph
    --   line_alpha     - opacity of the top line stroke (0-1)
    --   line_width     - top line stroke width in px
    --   line_lighten   - how much to blend the stroke toward white (0-1)
    --   samples        - history length kept for this graph (1 sample/tick)
    --   max            - fixed y-axis ceiling (CPU only; network uses the
    --                    net_max_download/upload settings above instead)
    --   dynamic_color  - (CPU only) true: color follows load_color_hex()
    --                    (green/yellow/red, VU-meter style); false: use
    --                    the static `color` field instead
    graphs = {
        cpu = {
            height         = 24,
            color          = COLOR_YELLOW,
            dynamic_color  = true,
            fill_alpha_near = 0.55,
            fill_alpha_far  = 0.04,
            line_alpha     = 0.95,
            line_width     = 1.5,
            line_lighten   = 0.4,
            samples        = 40,
            max            = 100, -- fixed 0-100%, not user-adjustable
        },
        net_down = {
            height         = 30,
            color          = COLOR_BLUE,
            fill_alpha_near = 0.55,
            fill_alpha_far  = 0.04,
            line_alpha     = 0.95,
            line_width     = 1.5,
            line_lighten   = 0.4,
            samples        = 40,
        },
        net_up = {
            height         = 30,
            color          = COLOR_ORANGE,
            fill_alpha_near = 0.55,
            fill_alpha_far  = 0.04,
            line_alpha     = 0.95,
            line_width     = 1.5,
            line_lighten   = 0.4,
            samples        = 40,
        },
    },
}

-- ==================== Widget State ====================

local W = {
    cache = {},
}

-- ==================== Generic Helpers ====================

local function hex_to_rgb(hex)
    local r = math.floor(hex / 65536) % 256
    local g = math.floor(hex / 256) % 256
    local b = hex % 256
    return r / 255, g / 255, b / 255
end

local function hex_to_rgba(hex, alpha)
    local r, g, b = hex_to_rgb(hex)
    return r, g, b, alpha
end

-- Blend a hex color toward white by `amt` (0..1) -- used for a brighter
-- graph stroke on top of its own (darker) fill color.
local function lighten(hex, amt)
    local r, g, b = hex_to_rgb(hex)
    r = r + (1 - r) * amt
    g = g + (1 - g) * amt
    b = b + (1 - b) * amt
    return r, g, b
end

-- Green->yellow->red VU-meter mapping for a 0..100 load percentage, used by
-- the CPU graph when CFG.graphs.cpu.dynamic_color is true.
local function load_color_hex(pct)
    if pct < 70 then return CFG.colors.accent3      -- green
    elseif pct < 90 then return CFG.colors.accent2  -- yellow
    else return CFG.colors.danger end                -- red
end

local function shell(cmd)
    local h = io.popen(cmd)
    if not h then return nil end
    local out = h:read("*a")
    h:close()
    if out then out = out:gsub("%s+$", "") end
    return out
end

local function cached(key, interval, fn)
    local c = W.cache[key]
    if not c then
        c = { value = nil, last = 0 }
        W.cache[key] = c
    end
    local now = os.time()
    if now - c.last >= interval then
        local ok, result = pcall(fn)
        if ok and result ~= nil then
            c.value = result
        end
        c.last = now
    end
    return c.value
end

local function num(s)
    if s == nil then return 0 end
    return tonumber((tostring(s):gsub(",", "."))) or 0
end

-- Detects OS PRETTY_NAME dynamically from /etc/os-release
local function get_os_name()
    return cached("os_name", 86400, function()
        local f = io.open("/etc/os-release", "r")
        if f then
            for line in f:lines() do
                local name = line:match('^PRETTY_NAME="?([^"]+)"?')
                if name then
                    f:close()
                    return name
                end
            end
            f:close()
        end
        return conky_parse("${sysname}")
    end) or "Linux"
end

-- Detects the active network interface automatically
local function detect_default_interface()
    return cached("auto_net_iface", 60, function()
        local dirs = shell("ls /sys/class/net/ 2>/dev/null") or ""
        for iface in dirs:gmatch("[^\r\n]+") do
            if iface ~= "lo" and not iface:find("^virbr") and not iface:find("^docker") and not iface:find("^veth") then
                local operstate_file = io.open("/sys/class/net/" .. iface .. "/operstate", "r")
                if operstate_file then
                    local state = operstate_file:read("*l") or ""
                    operstate_file:close()
                    if state == "up" or state == "unknown" then
                        return iface
                    end
                end
            end
        end
        for iface in dirs:gmatch("[^\r\n]+") do
            if iface ~= "lo" then return iface end
        end
        return "eth0"
    end) or "eth0"
end

local function get_network_interface()
    if not CFG.network_iface or CFG.network_iface == "" or CFG.network_iface == "auto" then
        return detect_default_interface()
    end
    return CFG.network_iface
end

-- ==================== Logo Overlay ====================

local function get_logo_surface()
    if W.logo_surface then return W.logo_surface end
    if W.logo_load_failed then return nil end

    local ok, surface = pcall(cairo_image_surface_create_from_png, CFG.logo.path)
    if not ok or not surface then
        W.logo_load_failed = true
        io.stderr:write("widget.lua: could not load logo via cairo_image_surface_create_from_png: "
            .. tostring(CFG.logo.path) .. "\n")
        return nil
    end
    if cairo_surface_status and cairo_surface_status(surface) ~= 0 then
        W.logo_load_failed = true
        io.stderr:write("widget.lua: logo file not found or invalid: " .. tostring(CFG.logo.path) .. "\n")
        return nil
    end

    W.logo_surface = surface
    W.logo_w = cairo_image_surface_get_width(surface)
    W.logo_h = cairo_image_surface_get_height(surface)
    return surface
end

local function draw_logo(cr)
    if not CFG.logo or not CFG.logo.path or CFG.logo.path == "" then return end
    local surface = get_logo_surface()
    if not surface or not W.logo_h or W.logo_h == 0 then return end

    local scale = CFG.logo.height / W.logo_h

    cairo_save(cr)
    cairo_translate(cr, CFG.logo.x, CFG.logo.y)
    cairo_scale(cr, scale, scale)
    cairo_set_source_surface(cr, surface, 0, 0)
    cairo_paint(cr)
    cairo_restore(cr)
end

-- ==================== Cached Data Sources ====================

local function get_pkg_manager()
    return cached("pkg_manager", 86400, function()
        local p = shell("command -v pacman 2>/dev/null")
        if p and p ~= "" then return "pacman" end
        local d = shell("command -v dnf 2>/dev/null")
        if d and d ~= "" then return "dnf" end
        local a = shell("command -v apt 2>/dev/null")
        if a and a ~= "" then return "apt" end
        return "none"
    end) or "none"
end

local function get_aur_updates()
    if get_pkg_manager() ~= "pacman" then return nil end
    if CFG.aur_helper == "yay" then
        return tonumber(shell("yay -Qua 2>/dev/null | wc -l")) or 0
    elseif CFG.aur_helper == "paru" then
        return tonumber(shell("paru -Qua 2>/dev/null | wc -l")) or 0
    end
    return nil
end

local function get_flatpak_updates()
    local has_flatpak = cached("has_flatpak", 86400, function()
        local p = shell("command -v flatpak 2>/dev/null")
        return p ~= nil and p ~= ""
    end)
    if not has_flatpak then return nil end

    return cached("flatpak_updates", 1800, function()
        shell("flatpak update --appstream >/dev/null 2>&1")
        return tonumber(shell("flatpak remote-ls --updates 2>/dev/null | wc -l")) or 0
    end)
end

local function get_updates()
    return cached("pacman_aur_updates", 1800, function()
        local mgr = get_pkg_manager()
        local lines = {}

        if mgr == "pacman" then
            local n = tonumber(shell("checkupdates 2>/dev/null | wc -l")) or 0
            table.insert(lines, string.format("Pacman  Updates: %d", n))
        elseif mgr == "dnf" then
            local n = tonumber(shell("dnf check-update -q 2>/dev/null | grep -v '^$' | wc -l")) or 0
            table.insert(lines, string.format("DNF     Updates: %d", n))
        elseif mgr == "apt" then
            local n = tonumber(shell("apt list --upgradable 2>/dev/null | grep -c '/'")) or 0
            table.insert(lines, string.format("Apt     Updates: %d", n))
        else
            table.insert(lines, "No supported package manager found")
        end

        local aur_cnt = get_aur_updates()
        if aur_cnt then
            table.insert(lines, string.format("AUR     Updates: %d", aur_cnt))
        end

        if CFG.show_flatpak then
            local fp_cnt = get_flatpak_updates()
            if fp_cnt then
                table.insert(lines, string.format("Flatpak Updates: %d", fp_cnt))
            end
        end

        return lines
    end) or { "Updates: 0" }
end

local function find_cpu_temp_sensor()
    return cached("cpu_temp_path", 86400, function()
        local dirs = shell("ls -d /sys/class/hwmon/hwmon*/ 2>/dev/null") or ""
        for dir in dirs:gmatch("[^\n]+") do
            local nf = io.open(dir .. "name", "r")
            if nf then
                local chip = (nf:read("*l") or ""):lower()
                nf:close()
                if chip:find("coretemp") or chip:find("k10temp") or chip:find("zenpower") then
                    for i = 1, 8 do
                        if io.open(dir .. "temp" .. i .. "_input", "r") then
                            return dir .. "temp" .. i .. "_input"
                        end
                    end
                end
            end
        end
        return nil
    end)
end

local function get_cpu_temp()
    local path = find_cpu_temp_sensor()
    if not path then return "" end
    return cached("cpu_temp", 3, function()
        local f = io.open(path, "r")
        if not f then return "" end
        local raw = tonumber(f:read("*l"))
        f:close()
        if not raw then return "" end
        return string.format("(%.0f°C)", raw / 1000)
    end) or ""
end

-- ==================== Drawing Primitives ====================

local function draw_rounded_rect_path(cr, x, y, w, h, r)
    cairo_new_path(cr)
    cairo_move_to(cr, x + r, y)
    cairo_line_to(cr, x + w - r, y)
    cairo_arc(cr, x + w - r, y + r, r, -math.pi / 2, 0)
    cairo_line_to(cr, x + w, y + h - r)
    cairo_arc(cr, x + w - r, y + h - r, r, 0, math.pi / 2)
    cairo_line_to(cr, x + r, y + h)
    cairo_arc(cr, x + r, y + h - r, r, math.pi / 2, math.pi)
    cairo_line_to(cr, x, y + r)
    cairo_arc(cr, x + r, y + r, r, math.pi, 3 * math.pi / 2)
    cairo_close_path(cr)
end

local function draw_glass_box(cr, x, y, w, h)
    local r = CFG.corner_radius

    cairo_set_source_rgba(cr, hex_to_rgba(CFG.glass_base_color, CFG.glass_base_alpha))
    draw_rounded_rect_path(cr, x, y, w, h, r)
    cairo_fill(cr)

    cairo_save(cr)
    draw_rounded_rect_path(cr, x, y, w, h, r)
    cairo_clip(cr)

    local g2 = cairo_pattern_create_linear(x, y, x, y + h)
    cairo_pattern_add_color_stop_rgba(g2, 0.00, hex_to_rgba(0xFFFFFF, 0.25))
    cairo_pattern_add_color_stop_rgba(g2, 0.15, hex_to_rgba(0xAABBFF, 0.03))
    cairo_pattern_add_color_stop_rgba(g2, 0.85, hex_to_rgba(0xAABBFF, 0.03))
    cairo_pattern_add_color_stop_rgba(g2, 1.00, hex_to_rgba(0xFFFFFF, 0.20))
    cairo_set_source(cr, g2)
    cairo_rectangle(cr, x, y, w, h)
    cairo_fill(cr)
    cairo_pattern_destroy(g2)

    local spec_h = math.min(h * 0.35, 45)
    local g4 = cairo_pattern_create_linear(x, y, x, y + spec_h)
    cairo_pattern_add_color_stop_rgba(g4, 0.00, hex_to_rgba(0xFFFFFF, 0.30))
    cairo_pattern_add_color_stop_rgba(g4, 1.00, hex_to_rgba(0xFFFFFF, 0.0))
    cairo_set_source(cr, g4)
    cairo_rectangle(cr, x, y, w, spec_h)
    cairo_fill(cr)
    cairo_pattern_destroy(g4)

    cairo_restore(cr)

    local gb = cairo_pattern_create_linear(x, y, x, y + h)
    cairo_pattern_add_color_stop_rgba(gb, 0.00, hex_to_rgba(0xFFFFFF, 0.40))
    cairo_pattern_add_color_stop_rgba(gb, 0.50, hex_to_rgba(0x8899EE, 0.15))
    cairo_pattern_add_color_stop_rgba(gb, 1.00, hex_to_rgba(0xFFFFFF, 0.40))
    cairo_set_source(cr, gb)
    cairo_set_line_width(cr, 1.0)
    draw_rounded_rect_path(cr, x + 0.5, y + 0.5, w - 1, h - 1, r)
    cairo_stroke(cr)
    cairo_pattern_destroy(gb)
end

local function draw_text(cr, x, y, text, size, color_hex, alpha, bold, align)
    cairo_select_font_face(cr, CFG.font, CAIRO_FONT_SLANT_NORMAL,
        bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
    cairo_set_font_size(cr, size)
    local rr, gg, bb = hex_to_rgb(color_hex)
    cairo_set_source_rgba(cr, rr, gg, bb, alpha or 1)

    local tx = x
    if align == "center" or align == "right" then
        local ext = cairo_text_extents_t:create()
        cairo_text_extents(cr, text, ext)
        tx = (align == "center") and (x - ext.width / 2) or (x - ext.width)
    end
    cairo_move_to(cr, tx, y)
    cairo_show_text(cr, text)
end

local function draw_progress_bar(cr, x, y, w, h, pct, fill_color)
    local r = h / 2
    cairo_set_source_rgba(cr, hex_to_rgba(CFG.colors.bar_bg, 0.6))
    draw_rounded_rect_path(cr, x, y, w, h, r)
    cairo_fill(cr)

    local fill_w = math.max(r * 2, (w * math.min(100, math.max(0, pct))) / 100)
    cairo_set_source_rgba(cr, hex_to_rgba(fill_color, 0.9))
    draw_rounded_rect_path(cr, x, y, fill_w, h, r)
    cairo_fill(cr)
end

-- ==================== History / Area Graphs ====================

local DEFAULT_HISTORY_LEN = 40

local function push_history(key, value, max_len)
    max_len = max_len or DEFAULT_HISTORY_LEN
    W.history = W.history or {}
    local h = W.history[key]
    if not h then
        h = {}
        W.history[key] = h
    end
    table.insert(h, value)
    while #h > max_len do
        table.remove(h, 1)
    end
    return h
end

local function history_peak(history)
    local m = 0
    for _, v in ipairs(history) do
        if v > m then m = v end
    end
    return m
end

local function draw_area_graph(cr, x, y, w, gcfg, history, max_val, color_override)
    local n = #history
    if n < 2 or max_val <= 0 then return end

    local samples = gcfg.samples or DEFAULT_HISTORY_LEN
    local h = gcfg.height
    local step = w / (samples - 1)
    local offset = (samples - n) * step
    local color = color_override or gcfg.color

    cairo_save(cr)
    cairo_translate(cr, x, y + h)
    cairo_scale(cr, 1, -1)

    local grad = cairo_pattern_create_linear(0, 0, 0, h)
    cairo_pattern_add_color_stop_rgba(grad, 0, hex_to_rgba(color, gcfg.fill_alpha_near or 0.55))
    cairo_pattern_add_color_stop_rgba(grad, 1, hex_to_rgba(color, gcfg.fill_alpha_far or 0.04))
    cairo_set_source(cr, grad)
    cairo_move_to(cr, offset, 0)
    for i = 1, n do
        local v = math.min(history[i], max_val)
        cairo_line_to(cr, offset + (i - 1) * step, (v / max_val) * h)
    end
    cairo_line_to(cr, offset + (n - 1) * step, 0)
    cairo_close_path(cr)
    cairo_fill(cr)
    cairo_pattern_destroy(grad)

    local lr, lg, lb = lighten(color, gcfg.line_lighten or 0.4)
    cairo_set_source_rgba(cr, lr, lg, lb, gcfg.line_alpha or 0.95)
    cairo_set_line_width(cr, gcfg.line_width or 1.5)
    cairo_move_to(cr, offset, (math.min(history[1], max_val) / max_val) * h)
    for i = 2, n do
        local v = math.min(history[i], max_val)
        cairo_line_to(cr, offset + (i - 1) * step, (v / max_val) * h)
    end
    cairo_stroke(cr)
    cairo_restore(cr)
end

-- ==================== Panels Layout ====================

local function draw_time_panel(cr, x, y, w, h)
    local time_str = conky_parse("${time %H:%M}")
    local date_str = conky_parse("${time %a %d %b}")
    local os_name  = get_os_name()
    local host_str = conky_parse("${nodename}") .. " | " .. os_name
    local uptime_str = conky_parse("${uptime_short}")

    draw_text(cr, x, y + 36, time_str, 32, CFG.colors.accent1, 1, true)
    draw_text(cr, x + 115, y + 18, date_str, 12, CFG.colors.text, 0.9, true)
    draw_text(cr, x + 115, y + 35, host_str, 10, CFG.colors.text, 0.85)

    local line_h = 13
    local uy = y + 70
    for _, line in ipairs(get_updates()) do
        draw_text(cr, x, uy, line, 10, CFG.colors.accent2, 0.9)
        uy = uy + line_h
    end
    draw_text(cr, x, uy + 3, "Uptime: " .. uptime_str, 10, CFG.colors.text, 0.7)
end

local function draw_cpu_panel(cr, x, y, w, h)
    local cpu_pct = num(conky_parse("${cpu cpu0}"))
    local freq = conky_parse("${freq_g}")
    local temp = get_cpu_temp()

    local g = CFG.graphs.cpu
    local cpu_hist = push_history("cpu", cpu_pct, g.samples)

    draw_text(cr, x, y + 12, "CPU", 11, CFG.colors.accent2, 1, true)
    local sub = string.format("%.0f%% @ %sGHz %s", cpu_pct, freq, temp)
    draw_text(cr, x + w, y + 12, sub, 10, CFG.colors.text, 0.8, false, "right")

    local graph_color = g.dynamic_color and load_color_hex(cpu_pct) or nil
    draw_area_graph(cr, x, y + 18, w, g, cpu_hist, g.max, graph_color)

    local list_y = y + 18 + g.height + 12
    draw_text(cr, x, list_y, "Top Processes:", 9, CFG.colors.accent2, 1)
    for i = 1, 5 do
        local name = conky_parse("${top name " .. i .. "}")
        local cpu = num(conky_parse("${top cpu " .. i .. "}"))
        local yy = list_y + i * 15
        draw_text(cr, x, yy, name, 10, CFG.colors.text, 0.9, true)
        draw_text(cr, x + w, yy, string.format("%.2f%%", cpu), 10, CFG.colors.accent2, 0.9, true, "right")
    end
end

local function draw_ram_panel(cr, x, y, w, h)
    local mem_pct = num(conky_parse("${memperc}"))
    local mem_used = conky_parse("${mem}")
    local mem_max = conky_parse("${memmax}")

    draw_text(cr, x, y + 12, "RAM", 11, CFG.colors.accent3, 1, true)
    local sub = string.format("%s / %s (%d%%)", mem_used, mem_max, mem_pct)
    draw_text(cr, x + w, y + 12, sub, 10, CFG.colors.text, 0.8, false, "right")

    draw_progress_bar(cr, x, y + 20, w, 12, mem_pct, CFG.colors.accent3)

    draw_text(cr, x, y + 54, "Top Memory Processes:", 9, CFG.colors.accent2, 1)
    for i = 1, 5 do
        local name = conky_parse("${top_mem name " .. i .. "}")
        local mem = num(conky_parse("${top_mem mem " .. i .. "}"))
        local yy = y + 54 + i * 15
        draw_text(cr, x, yy, name, 10, CFG.colors.text, 0.9, true)
        draw_text(cr, x + w, yy, string.format("%.2f%%", mem), 10, CFG.colors.accent3, 0.9, true, "right")
    end
end

local function draw_storage_panel(cr, x, y, w, h)
    draw_text(cr, x, y + 12, "STORAGE", 11, COLOR_PURPLE, 1, true)

    -- Root
    local r_used = conky_parse("${fs_used /}")
    local r_size = conky_parse("${fs_size /}")
    local r_pct = num(conky_parse("${fs_used_perc /}"))
    draw_text(cr, x, y + 42, "/ Root", 10, CFG.colors.text, 0.85)
    draw_text(cr, x + w, y + 42, string.format("%s / %s", r_used, r_size), 9, CFG.colors.text, 0.6, false, "right")
    draw_progress_bar(cr, x, y + 48, w, 10, r_pct, COLOR_PURPLE)

    -- Home
    local h_used = conky_parse("${fs_used /home}")
    local h_size = conky_parse("${fs_size /home}")
    local h_pct = num(conky_parse("${fs_used_perc /home}"))
    draw_text(cr, x, y + 74, "/ Home", 10, CFG.colors.text, 0.8)
    draw_text(cr, x + w, y + 74, string.format("%s / %s", h_used, h_size), 9, CFG.colors.text, 0.6, false, "right")
    draw_progress_bar(cr, x, y + 80, w, 10, h_pct, COLOR_ORANGE)
end

local function draw_network_panel(cr, x, y, w, h)
    local iface = get_network_interface()
    local up = conky_parse("${upspeed " .. iface .. "}")
    local down = conky_parse("${downspeed " .. iface .. "}")
    local totalup = conky_parse("${totalup " .. iface .. "}")
    local totaldown = conky_parse("${totaldown " .. iface .. "}")

    local down_kib = num(conky_parse("${downspeedf " .. iface .. "}"))
    local up_kib = num(conky_parse("${upspeedf " .. iface .. "}"))

    local gd = CFG.graphs.net_down
    local gu = CFG.graphs.net_up
    local down_hist = push_history("net_down", down_kib, gd.samples)
    local up_hist = push_history("net_up", up_kib, gu.samples)

    draw_text(cr, x, y + 12, "NETWORK", 11, CFG.colors.accent4, 1, true)
    draw_text(cr, x + w, y + 12, iface, 10, CFG.colors.text, 0.85, false, "right")

    draw_text(cr, x, y + 30, "v " .. down, 11, CFG.colors.accent4, 1, true)
    draw_text(cr, x + w, y + 30, "^ " .. up, 11, CFG.colors.accent1, 1, true, "right")

    local graph_gap = 8
    local half_w = (w - graph_gap) / 2
    local graph_y = y + 54
    local down_ceiling_kib = CFG.net_max_download * 1024
    local up_ceiling_kib = CFG.net_max_upload * 1024
    local down_max = math.min(down_ceiling_kib, math.max(history_peak(down_hist) * 1.3, 64))
    local up_max = math.min(up_ceiling_kib, math.max(history_peak(up_hist) * 1.3, 64))

    draw_area_graph(cr, x, graph_y, half_w, gd, down_hist, down_max)
    draw_area_graph(cr, x + half_w + graph_gap, graph_y, half_w, gu, up_hist, up_max)

    local total_y = graph_y + math.max(gd.height, gu.height) + 24
    draw_text(cr, x, total_y, "Total: " .. totaldown, 10, CFG.colors.text, 0.7)
    draw_text(cr, x + w, total_y, "Total: " .. totalup, 10, CFG.colors.text, 0.7, false, "right")
end

-- ==================== Main Render Loop ====================

function conky_main()
    local surface, owns_surface = get_draw_surface()
    if not surface then return end

    local cr = cairo_create(surface)

    cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR)
    cairo_paint(cr)
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER)

    local total_w = conky_window and conky_window.width or 1800
    local total_h = conky_window and conky_window.height or 130

    local num_panels = 5
    local panel_w = math.floor((total_w - (CFG.margin * 2) - (CFG.gap * (num_panels - 1))) / num_panels)
    local panel_h = total_h - (CFG.top_margin * 2)

    local panels = {
        draw_time_panel,
        draw_cpu_panel,
        draw_ram_panel,
        draw_storage_panel,
        draw_network_panel
    }

    local current_x = CFG.margin
    local y = CFG.top_margin

    for _, draw_fn in ipairs(panels) do
        draw_glass_box(cr, current_x, y, panel_w, panel_h)
        draw_fn(cr, current_x + CFG.pad, y + CFG.pad, panel_w - (2 * CFG.pad), panel_h - (2 * CFG.pad))
        current_x = current_x + panel_w + CFG.gap
    end

    draw_logo(cr)

    cairo_destroy(cr)
    if owns_surface then
        cairo_surface_destroy(surface)
    end
end