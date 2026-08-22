#!/data/data/com.termux/files/usr/bin/lua

-- Noka Rejoin 6.0 (Termux controller), based on the SOL rewrite 5.0.
-- Runtime data: /storage/emulated/0/Noka. The LocalPlayer heartbeat is not
-- shipped with this script: an already-installed copy in an executor
-- autoexecute folder is reused, and otherwise it downloads once from the
-- official project page. See fetch_heartbeat_source.
--
-- Changes versus the SOL rewrite 5.0:
--   * Solver-gated launch: every clone's account is submitted to the
--     configured captcha solver as an asynchronous job before its launch and
--     the controller waits for a terminal answer first. Clean accounts pass
--     immediately; accounts that cannot be cleared are parked, closed, and
--     relaunched in a second pass once their solve finishes instead of
--     aborting the whole sequence.
--   * Monitoring captcha lane: an open clone that burns CPU above
--     captcha_cpu_threshold while its heartbeat stays bad is treated as a
--     live captcha: closed, exported to the solver, and softly reopened
--     after the solver reports success.
--   * The heartbeat script is external (Luraph-obfuscatable on its own).
--   * Root work per watchdog cycle is batched into two shell passes instead
--     of one process spawn per probe; heartbeat files are read directly
--     without root.
--   * Fixed: Discord message edits no longer clear the status screenshot;
--     Lua 5.1/Luraph-safe config loading and JSON decoding paths.
--   * Grid hardening: when dumpsys reports no stable inset and no StatusBar
--     frame, the top inset falls back to the 24dp framework status-bar height
--     converted with the real panel density, so clones never slide under it.
--   * Device hygiene: clone caches are purged and RAM is refreshed before
--     anything else runs; after warm-up every background app (clones
--     included) is terminated so the join phase starts clean.
--   * Status updates: fresh Discord messages by default (60s floor); editing
--     one message is an opt-in mode with a 10s floor. The embed shows the
--     total session uptime, and the first update waits for every heartbeat
--     to register plus a random 30-45 second settling window.
-- First run in Termux 0.118.1:
--   pkg install -y lua54 curl coreutils procps grep sqlite
--   termux-setup-storage
--   lua /sdcard/Download/noka-rejoin.lua
-- Flags: --skip/--start, --once, --setup, --no-resize, --check-config,
--   --restore-device, --restore-bounds, --reset, and --self-test.

local Core = (function()
local Core = {}

local ARRAY_MT = { __noka_json_array = true }
local JSON_NULL = setmetatable({}, { __tostring = function() return "null" end })
Core.JSON_NULL = JSON_NULL

function Core.trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

function Core.shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function Core.url_decode(value)
    value = tostring(value or ""):gsub("%+", " ")
    return (value:gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

function Core.url_encode(value)
    return (tostring(value or ""):gsub("([^%w%-%._~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end))
end

function Core.parse_query(url)
    local result = {}
    local query = tostring(url or ""):match("%?([^#]*)") or ""
    for pair in query:gmatch("[^&]+") do
        local key, value = pair:match("^([^=]+)=?(.*)$")
        if key then
            result[Core.url_decode(key)] = Core.url_decode(value)
        end
    end
    return result
end

local function query_value_case_insensitive(query, wanted)
    wanted = wanted:lower()
    for key, value in pairs(query) do
        if key:lower() == wanted then
            return value
        end
    end
end

function Core.parse_join_target(input)
    input = Core.trim(input)
    if input == "" then
        return nil, "a game ID, game URL, or private-server URL is required"
    end

    if input:match("^%d+$") then
        return {
            kind = "place",
            place_id = input,
            uri = "roblox://experiences/start?placeId=" .. input,
            display = "Game " .. input,
        }
    end

    local lower_input = input:lower()
    if lower_input:match("^roblox://") then
        local query = Core.parse_query(input)
        if lower_input:match("^roblox://experiences/start%?") then
            local place_id = query_value_case_insensitive(query, "placeId")
            if not place_id or not place_id:match("^%d+$") then
                return nil, "the roblox:// experience link needs a numeric placeId"
            end
            local link_code = query_value_case_insensitive(query, "linkCode")
            local uri = "roblox://experiences/start?placeId=" .. place_id
            local kind, display = "place", "Game " .. place_id
            if link_code and link_code ~= "" then
                uri = uri .. "&linkCode=" .. Core.url_encode(link_code)
                kind, display = "private", "Private server for game " .. place_id
            end
            return { kind = kind, place_id = place_id, link_code = link_code,
                uri = uri, display = display }
        elseif lower_input:match("^roblox://navigation/share_links%?") then
            local code = query_value_case_insensitive(query, "code")
            if not code or code == "" then return nil, "the roblox:// share link needs a code" end
            local share_type = query_value_case_insensitive(query, "type") or "Server"
            return { kind = "share", share_code = code, share_type = share_type,
                uri = "roblox://navigation/share_links?code=" .. Core.url_encode(code)
                    .. "&type=" .. Core.url_encode(share_type),
                display = string.format("Roblox share link (%s)", share_type) }
        end
        return nil, "unsupported roblox:// link"
    end

    if not lower_input:match("^https?://") then
        return nil, "enter a numeric place ID or a complete Roblox URL"
    end

    local host = input:match("^[Hh][Tt][Tt][Pp][Ss]?://([^/%?#]+)")
    local lower_host = host and host:lower() or ""
    if lower_host ~= "roblox.com" and lower_host:sub(-11) ~= ".roblox.com" then
        return nil, "the URL must be on roblox.com"
    end

    local query = Core.parse_query(input)
    local share_code = query_value_case_insensitive(query, "code")
    local share_type = query_value_case_insensitive(query, "type")
    local path = input:match("^[Hh][Tt][Tt][Pp][Ss]?://[^/]+([^%?#]*)") or ""

    if share_code and share_code ~= ""
        and (path:match("/share/?$") or path:match("/share%-links/?$")) then
        share_type = share_type ~= "" and share_type or "Server"
        local uri = "roblox://navigation/share_links?code=" .. Core.url_encode(share_code)
            .. "&type=" .. Core.url_encode(share_type)
        return {
            kind = "share",
            share_code = share_code,
            share_type = share_type,
            uri = uri,
            display = string.format("Roblox share link (%s)", share_type),
        }
    end

    local place_id = input:match("/games/(%d+)")
        or query_value_case_insensitive(query, "placeId")
    if place_id and not tostring(place_id):match("^%d+$") then
        place_id = nil
    end
    if not place_id then
        return nil, "could not find a numeric Roblox place ID in that URL"
    end

    local link_code = query_value_case_insensitive(query, "privateServerLinkCode")
        or query_value_case_insensitive(query, "linkCode")
    local uri = "roblox://experiences/start?placeId=" .. place_id
    local kind = "place"
    local display = "Game " .. place_id
    if link_code and link_code ~= "" then
        uri = uri .. "&linkCode=" .. Core.url_encode(link_code)
        kind = "private"
        display = "Private server for game " .. place_id
    end

    return {
        kind = kind,
        place_id = place_id,
        link_code = link_code,
        uri = uri,
        display = display,
    }
end

function Core.is_package_name(value)
    value = Core.trim(value)
    if value == "" or #value > 255 or not value:find(".", 1, true) then return false end
    if value:sub(1, 1) == "." or value:sub(-1) == "." or value:find("..", 1, true) then return false end
    if value:find("[^%w_%.]") then return false end
    for segment in value:gmatch("[^.]+") do
        if not segment:match("^[%a_][%w_]*$") then return false end
    end
    return true
end

function Core.is_automatic_package(package_name)
    package_name = Core.trim(package_name)
    local prefixes = { "com.roblox.", "free.", "premium." }
    for _, prefix in ipairs(prefixes) do
        if #package_name > #prefix and package_name:sub(1, #prefix) == prefix then return true end
    end
    return false
end

function Core.filter_automatic_packages(packages)
    local result, seen = {}, {}
    for _, package_name in ipairs(packages or {}) do
        if Core.is_automatic_package(package_name) and not seen[package_name] then
            result[#result + 1] = package_name
            seen[package_name] = true
        end
    end
    table.sort(result)
    return result
end

function Core.glob_to_pattern(glob)
    glob = Core.trim(glob)
    local output = { "^" }
    for index = 1, #glob do
        local char = glob:sub(index, index)
        if char == "*" then
            output[#output + 1] = ".*"
        elseif char == "?" then
            output[#output + 1] = "."
        elseif char:match("[%(%)%.%%%+%-%[%]%^%$]") then
            output[#output + 1] = "%" .. char
        else
            output[#output + 1] = char
        end
    end
    output[#output + 1] = "$"
    return table.concat(output)
end

function Core.filter_packages(packages, globs)
    local result, seen = {}, {}
    local patterns = {}
    for _, glob in ipairs(globs or {}) do
        patterns[#patterns + 1] = Core.glob_to_pattern(glob)
    end
    for _, package_name in ipairs(packages or {}) do
        for _, pattern in ipairs(patterns) do
            if package_name:match(pattern) and not seen[package_name] then
                result[#result + 1] = package_name
                seen[package_name] = true
                break
            end
        end
    end
    table.sort(result)
    return result
end

function Core.split_list(value)
    local result = {}
    for part in tostring(value or ""):gmatch("[^,%s]+") do
        result[#result + 1] = Core.trim(part)
    end
    return result
end

function Core.calculate_bounds(count, width, height, gap, top_inset, bottom_inset, left_inset, right_inset)
    count = math.max(1, math.min(30, math.floor(tonumber(count) or 1)))
    width = math.max(1, tonumber(width) or 1080)
    height = math.max(1, tonumber(height) or 1920)
    gap = math.max(0, math.floor(tonumber(gap) or 0))
    top_inset = math.max(0, tonumber(top_inset) or 0)
    bottom_inset = math.max(0, tonumber(bottom_inset) or 0)
    left_inset = math.max(0, tonumber(left_inset) or 0)
    right_inset = math.max(0, tonumber(right_inset) or 0)

    local usable_height = math.max(1, height - top_inset - bottom_inset)
    local usable_width = math.max(1, width - left_inset - right_inset)
    -- Rounding instead of flooring avoids the pathological one-row layout for
    -- three clones while preserving the compact two-clone layout.
    local rows = math.max(1, math.floor(math.sqrt(count) + 0.5))
    local base_per_row = math.floor(count / rows)
    local extra = count % rows
    local row_counts = {}
    local columns = 1
    for row = 1, rows do
        row_counts[row] = base_per_row + (row <= extra and 1 or 0)
        columns = math.max(columns, row_counts[row])
    end

    local result, index = {}, 1
    local available_height = math.max(rows, usable_height - gap * (rows - 1))
    for row = 1, rows do
        local row_index = row - 1
        local top = top_inset + math.floor(row_index * available_height / rows) + row_index * gap
        local bottom = top_inset + math.floor(row * available_height / rows) + row_index * gap
        local row_columns = row_counts[row]
        local available_width = math.max(row_columns, usable_width - gap * (row_columns - 1))
        for column = 1, row_columns do
            local column_index = column - 1
            local left = left_inset + math.floor(column_index * available_width / row_columns) + column_index * gap
            local right = left_inset + math.floor(column * available_width / row_columns) + column_index * gap
            result[index] = { left = left, top = top, right = right, bottom = bottom }
            index = index + 1
        end
    end
    return result, columns, rows, row_counts
end

function Core.parse_display_geometry(window_output, display_output, wm_output, rotation_output)
    window_output = tostring(window_output or "")
    display_output = tostring(display_output or "")
    wm_output = tostring(wm_output or "")
    rotation_output = tostring(rotation_output or "")

    local function valid_pair(width, height)
        width, height = tonumber(width), tonumber(height)
        if width and height and width > 0 and height > 0 then return width, height end
    end

    local function first_geometry(output, patterns)
        for _, pattern in ipairs(patterns) do
            local width, height = output:match(pattern)
            width, height = valid_pair(width, height)
            if width then return width, height end
        end
    end

    -- These fields describe the display in its current rotation. `wm size`
    -- usually reports the natural portrait size, which is not suitable for a
    -- landscape freeform grid.
    local current_patterns = {
        "mCurrentDisplayRect=Rect%(%-?%d+,%s*%-?%d+%s+%-%s+(%d+),%s*(%d+)%)",
        "DisplayFrames%s+w=(%d+)%s+h=(%d+)",
        "cur=(%d+)x(%d+)",
        "logicalWidth=(%d+),%s*logicalHeight=(%d+)",
        "logicalWidth=(%d+)%s+logicalHeight=(%d+)",
    }
    local width, height = first_geometry(window_output, current_patterns)
    if not width then width, height = first_geometry(display_output, current_patterns) end

    if not width then
        width, height = wm_output:match("Override size:%s*(%d+)x(%d+)")
        if not width then width, height = wm_output:match("Physical size:%s*(%d+)x(%d+)") end
        width, height = valid_pair(width, height)
        width, height = width or 1080, height or 1920

        local rotation = window_output:match("ROTATION_(%d)")
            or window_output:match("mRotation=(%d)")
            or rotation_output:match("SurfaceOrientation:%s*(%d)")
            or rotation_output:match("(%d)")
        rotation = tonumber(rotation)
        if (rotation == 1 or rotation == 3) and width < height then width, height = height, width end
        if (rotation == 0 or rotation == 2) and width > height then width, height = height, width end
    end

    local left, top, right, bottom = window_output:match(
        "mStable=Rect%((%-?%d+),%s*(%-?%d+)%s+%-%s+(%-?%d+),%s*(%-?%d+)%)")
    if not left then
        left, top, right, bottom = window_output:match(
            "mStable=%[(%-?%d+),(%-?%d+)%]%[(%-?%d+),(%-?%d+)%]")
    end
    if not left then
        left, top, right, bottom = window_output:match(
            "stable=%[(%-?%d+),(%-?%d+)%]%[(%-?%d+),(%-?%d+)%]")
    end
    if not left then
        local inset_left, inset_top, inset_right, inset_bottom = window_output:match(
            "mStableInsets=Rect%((%-?%d+),%s*(%-?%d+)%s+%-%s+(%-?%d+),%s*(%-?%d+)%)")
        if inset_left then
            left, top = tonumber(inset_left), tonumber(inset_top)
            right = width - tonumber(inset_right)
            bottom = height - tonumber(inset_bottom)
        end
    end
    left, top, right, bottom = tonumber(left), tonumber(top), tonumber(right), tonumber(bottom)
    if not left or not top or not right or not bottom or right <= left or bottom <= top
        or right > width or bottom > height then
        left, top, right, bottom = 0, 0, width, height
    end
    return width, height, math.max(0, left), math.max(0, top),
        math.max(0, width - right), math.max(0, height - bottom)
end

function Core.parse_png_dimensions(header)
    if type(header) ~= "string" or #header < 24 or header:sub(1, 8) ~= "\137PNG\r\n\26\n" then
        return nil
    end
    local function uint32(offset)
        local a, b, c, d = header:byte(offset, offset + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d
    end
    local width, height = uint32(17), uint32(21)
    if width <= 0 or height <= 0 then return nil end
    return width, height
end

function Core.patch_app_cloner_bounds(content, bounds)
    content = tostring(content or "")
    local wanted = {}
    for _, coordinate in ipairs({ "left", "top", "right", "bottom" }) do
        wanted["app_cloner_current_window_" .. coordinate] = {
            coordinate = coordinate,
            value = math.floor(tonumber(bounds and bounds[coordinate]) or 0),
            count = 0,
        }
    end

    local patched = content:gsub("<[iI][nN][tT]%s+[^>]->", function(tag)
        local name = tag:match('[nN][aA][mM][eE]%s*=%s*"([^"]+)"')
        local item = name and wanted[name] or nil
        if not item then return tag end
        item.count = item.count + 1
        local replacements
        tag, replacements = tag:gsub(
            '([vV][aA][lL][uU][eE]%s*=%s*")%-?%d+(")',
            function(prefix, suffix) return prefix .. tostring(item.value) .. suffix end,
            1)
        if replacements ~= 1 then item.invalid = true end
        return tag
    end)

    local changed = 0
    for key, item in pairs(wanted) do
        if item.count ~= 1 or item.invalid then
            return nil, 0, "expected exactly one integer value for " .. key
        end
        changed = changed + 1
    end
    return patched, changed
end

function Core.confirm_app_cloner_bounds(content, bounds)
    content = tostring(content or "")
    local confirmed = 0
    local actual = {}
    for _, coordinate in ipairs({ "left", "top", "right", "bottom" }) do
        local key = "app_cloner_current_window_" .. coordinate
        local match_count, value = 0, nil
        for tag in content:gmatch("<[iI][nN][tT]%s+[^>]->") do
            local name = tag:match('[nN][aA][mM][eE]%s*=%s*"([^"]+)"')
            if name == key then
                match_count = match_count + 1
                value = tag:match('[vV][aA][lL][uU][eE]%s*=%s*"(%-?%d+)"')
            end
        end
        actual[coordinate] = match_count == 1 and tonumber(value) or nil
        if actual[coordinate] == tonumber(bounds[coordinate]) then confirmed = confirmed + 1 end
    end
    return confirmed, actual
end

function Core.json_array(value)
    return setmetatable(value or {}, ARRAY_MT)
end

local function json_escape(value)
    return tostring(value):gsub('[%z\1-\31\\"]', function(char)
        local replacements = {
            ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b',
            ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
        }
        return replacements[char] or string.format("\\u%04x", string.byte(char))
    end)
end

local function is_array(value)
    local mt = getmetatable(value)
    if mt and mt.__noka_json_array then
        return true
    end
    local max, count = 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
            return false
        end
        max = math.max(max, key)
        count = count + 1
    end
    return count > 0 and max == count
end

function Core.json_encode(value, stack)
    local value_type = type(value)
    if value == nil or value == JSON_NULL then return "null" end
    if value_type == "boolean" then return value and "true" or "false" end
    if value_type == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            return "null"
        end
        return tostring(value)
    end
    if value_type == "string" then return '"' .. json_escape(value) .. '"' end
    if value_type ~= "table" then return '"' .. json_escape(tostring(value)) .. '"' end

    stack = stack or {}
    if stack[value] then error("cannot JSON-encode a cyclic table") end
    stack[value] = true
    local parts = {}
    if is_array(value) then
        for index = 1, #value do
            parts[#parts + 1] = Core.json_encode(value[index], stack)
        end
        stack[value] = nil
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for key in pairs(value) do
        if type(key) ~= "string" then error("JSON object keys must be strings") end
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = Core.json_encode(key, stack) .. ":" .. Core.json_encode(value[key], stack)
    end
    stack[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

function Core.json_decode(source)
    if type(source) ~= "string" then return nil, "JSON input must be a string" end
    local index, length, depth = 1, #source, 0

    local function fail(message)
        error(string.format("%s at byte %d", message, index), 0)
    end

    local function skip_space()
        while index <= length and source:sub(index, index):match("[ \t\r\n]") do index = index + 1 end
    end

    local parse_value
    local function parse_string()
        if source:sub(index, index) ~= '"' then fail("expected string") end
        index = index + 1
        local parts, start = {}, index
        while index <= length do
            local char = source:sub(index, index)
            if char == '"' then
                parts[#parts + 1] = source:sub(start, index - 1)
                index = index + 1
                return table.concat(parts)
            elseif char == "\\" then
                parts[#parts + 1] = source:sub(start, index - 1)
                index = index + 1
                local escaped = source:sub(index, index)
                local simple = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
                    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
                if simple[escaped] then
                    parts[#parts + 1] = simple[escaped]
                    index = index + 1
                elseif escaped == "u" then
                    local hex = source:sub(index + 1, index + 4)
                    if not hex:match("^%x%x%x%x$") then fail("invalid Unicode escape") end
                    local codepoint = tonumber(hex, 16)
                    index = index + 5
                    if codepoint >= 0xD800 and codepoint <= 0xDBFF
                        and source:sub(index, index + 1) == "\\u" then
                        local low_hex = source:sub(index + 2, index + 5)
                        local low = low_hex:match("^%x%x%x%x$") and tonumber(low_hex, 16) or nil
                        if low and low >= 0xDC00 and low <= 0xDFFF then
                            codepoint = 0x10000 + (codepoint - 0xD800) * 0x400 + (low - 0xDC00)
                            index = index + 6
                        end
                    end
                    if codepoint >= 0xD800 and codepoint <= 0xDFFF then fail("unpaired Unicode surrogate") end
                    -- utf8.char is Lua 5.3+; Luraph/Lua 5.1 targets fall back.
                    local utf8_ok, decoded = pcall(utf8 and utf8.char or string.char, codepoint)
                    parts[#parts + 1] = utf8_ok and decoded or "?"
                else
                    fail("invalid escape")
                end
                start = index
            elseif char:byte() < 32 then
                fail("control character in string")
            else
                index = index + 1
            end
        end
        fail("unterminated string")
    end

    local function parse_array()
        depth = depth + 1
        if depth > 128 then fail("JSON nesting exceeds 128 levels") end
        index = index + 1
        local result = Core.json_array({})
        skip_space()
        if source:sub(index, index) == "]" then index = index + 1; depth = depth - 1; return result end
        while true do
            result[#result + 1] = parse_value()
            skip_space()
            local char = source:sub(index, index)
            if char == "]" then index = index + 1; depth = depth - 1; return result end
            if char ~= "," then fail("expected ',' or ']'") end
            index = index + 1
            skip_space()
        end
    end

    local function parse_object()
        depth = depth + 1
        if depth > 128 then fail("JSON nesting exceeds 128 levels") end
        index = index + 1
        local result = {}
        skip_space()
        if source:sub(index, index) == "}" then index = index + 1; depth = depth - 1; return result end
        while true do
            local key = parse_string()
            skip_space()
            if source:sub(index, index) ~= ":" then fail("expected ':'") end
            index = index + 1
            result[key] = parse_value()
            skip_space()
            local char = source:sub(index, index)
            if char == "}" then index = index + 1; depth = depth - 1; return result end
            if char ~= "," then fail("expected ',' or '}'") end
            index = index + 1
            skip_space()
        end
    end

    parse_value = function()
        skip_space()
        local char = source:sub(index, index)
        if char == '"' then return parse_string() end
        if char == "[" then return parse_array() end
        if char == "{" then return parse_object() end
        local literals = { ["true"] = true, ["false"] = false, ["null"] = JSON_NULL }
        for literal, value in pairs(literals) do
            if source:sub(index, index + #literal - 1) == literal then
                index = index + #literal
                return value
            end
        end
        local number_text = source:sub(index):match("^-?%d+%.?%d*[eE]?[+-]?%d*")
        if number_text and number_text ~= "" then
            local valid = number_text:match("^-?%d+$")
                or number_text:match("^-?%d+%.%d+$")
                or number_text:match("^-?%d+[eE][+-]?%d+$")
                or number_text:match("^-?%d+%.%d+[eE][+-]?%d+$")
            if number_text:match("^-?0%d") then valid = nil end
            local number = valid and tonumber(number_text) or nil
            if number and number == number and number ~= math.huge and number ~= -math.huge then
                index = index + #number_text
                return number
            end
        end
        fail("invalid value")
    end

    local ok, value = pcall(parse_value)
    if not ok then return nil, value end
    skip_space()
    if index <= length then return nil, string.format("trailing data at byte %d", index) end
    return value
end

function Core.format_duration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    local days = math.floor(seconds / 86400)
    local hours = math.floor((seconds % 86400) / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if days > 0 then return string.format("%dd %dh %dm", days, hours, minutes) end
    if hours > 0 then return string.format("%dh %dm", hours, minutes) end
    return string.format("%dm", minutes)
end

function Core.advance_failure_count(previous, failed, threshold)
    threshold = math.max(1, math.floor(tonumber(threshold) or 1))
    if not failed then return 0, false end
    local count = math.min(threshold, math.max(0, math.floor(tonumber(previous) or 0)) + 1)
    return count, count >= threshold
end

function Core.classify_heartbeat(heartbeat, expected_token, now, timeout, grace_until, transition_grace)
    now = tonumber(now) or 0
    timeout = math.max(1, tonumber(timeout) or 30)
    grace_until = tonumber(grace_until) or 0
    transition_grace = math.max(1, tonumber(transition_grace) or 120)

    local matches = type(heartbeat) == "table" and heartbeat.token == expected_token
    local timestamp = matches and tonumber(heartbeat.timestamp) or nil
    local age = timestamp and now - timestamp or nil
    local recent = matches and age ~= nil and age >= -15 and age <= timeout
    local loading = recent and (heartbeat.state == "loading" or heartbeat.transitioning == true)
    local transition_started = loading and tonumber(heartbeat.transition_started_at) or nil
    local transition_age = transition_started and now - transition_started or math.huge
    local transition_active = loading and transition_started ~= nil
        and transition_age >= -15 and transition_age <= transition_grace
    local explicit_failure = recent
        and (heartbeat.online == false or heartbeat.state == "disconnected")
    local stale = now > grace_until and not recent
    local transition_overdue = now > grace_until and loading and not transition_active

    return {
        matches = matches,
        age = age,
        recent = recent,
        loading = loading,
        transition_age = transition_age,
        transition_active = transition_active,
        explicit_failure = explicit_failure,
        stale = stale,
        transition_overdue = transition_overdue,
        bad = explicit_failure or stale or transition_overdue,
        acceptable = recent and not explicit_failure,
        in_expected_grace = now <= grace_until or transition_active,
    }
end

-- Normalizes one solver HTTP answer into "ok" / "busy" / "failed" / "unknown".
function Core.parse_solver_result(body, code)
    if code == "202" then return "busy" end
    local response = Core.json_decode(body or "")
    if type(response) == "table" then
        local status = tostring(response.status or response.result or ""):lower()
        if status == "processing" or status == "pending" or status == "queued" then return "busy" end
        if status == "ok" or status == "success" or status == "completed"
            or status == "solved" or status == "already_solved" then return "ok" end
        if response.success == true then return "ok" end
        if response.success == false or response.error ~= nil
            or status == "failed" or status == "error" then return "failed" end
    end
    local plain = Core.trim(body or ""):lower()
    if plain == "ok" or plain == "success" or plain == "solved" then return "ok" end
    return "unknown"
end

function Core.run_self_tests()
    local tests, failures = 0, {}
    local function check(name, condition)
        tests = tests + 1
        if not condition then failures[#failures + 1] = name end
    end

    check("URL decoding", Core.url_decode("private%2Bserver+one") == "private+server one")
    local target = Core.parse_join_target(
        "https://www.roblox.com/games/123/Test?privateServerLinkCode=a%2Bb")
    check("private-server parsing", target and target.place_id == "123"
        and target.uri == "roblox://experiences/start?placeId=123&linkCode=a%2Bb")
    local upper_target = Core.parse_join_target("HTTPS://WWW.ROBLOX.COM/games/456/Test")
    check("case-insensitive URL scheme", upper_target and upper_target.place_id == "456")
    check("lookalike Roblox host rejected",
        Core.parse_join_target("https://evilroblox.com/games/456/Test") == nil)
    check("empty share code rejected",
        Core.parse_join_target("https://www.roblox.com/share?code=&type=Server") == nil)
    local deep_target = Core.parse_join_target(
        "roblox://experiences/start?placeId=789&linkCode=private%2Bcode")
    check("direct deep-link normalization", deep_target and deep_target.kind == "private"
        and deep_target.uri == "roblox://experiences/start?placeId=789&linkCode=private%2Bcode")
    local json = Core.json_encode({ text = "line\n\"quoted\"", values = Core.json_array({ 1, true, JSON_NULL }) })
    local decoded, decode_error = Core.json_decode(json)
    check("JSON round trip", decoded and not decode_error and decoded.text == "line\n\"quoted\""
        and decoded.values[1] == 1 and decoded.values[2] == true and decoded.values[3] == JSON_NULL)
    local invalid_json = Core.json_decode('{"value":01}')
    check("invalid JSON rejected", invalid_json == nil)
    local unicode_json = Core.json_decode('"\\uD83D\\uDE00"')
    check("JSON surrogate pair", unicode_json ~= nil and #unicode_json > 0)
    check("solver parse ok", Core.parse_solver_result('{"status":"ok"}', "200") == "ok")
    check("solver parse already solved", Core.parse_solver_result('{"result":"already_solved"}', "200") == "ok")
    check("solver parse busy", Core.parse_solver_result('{"status":"processing"}', "202") == "busy")
    check("solver parse failed", Core.parse_solver_result('{"success":false}', "200") == "failed")
    check("solver parse plain", Core.parse_solver_result("ok", "200") == "ok")
    check("solver parse garbage", Core.parse_solver_result("<html>", "503") == "unknown")
    local bounds = { left = 1, top = 2, right = 300, bottom = 400 }
    local xml = '<map><int value="0" name="app_cloner_current_window_left" />'
        .. '<int name="app_cloner_current_window_top" value="0" />'
        .. '<int name="app_cloner_current_window_right" value="0" />'
        .. '<int name="app_cloner_current_window_bottom" value="0" /></map>'
    local patched = Core.patch_app_cloner_bounds(xml, bounds)
    local confirmed = patched and Core.confirm_app_cloner_bounds(patched, bounds) or 0
    check("App Cloner XML patch", confirmed == 4)
    local duplicate_xml = xml:gsub("</map>",
        '<int name="app_cloner_current_window_left" value="0" /></map>')
    check("duplicate App Cloner key rejected", Core.patch_app_cloner_bounds(duplicate_xml, bounds) == nil)
    local grid, _, rows, row_counts = Core.calculate_bounds(3, 1080, 1920, 0, 0, 0, 0, 0)
    check("three-clone grid is balanced", #grid == 3 and rows == 2
        and row_counts[1] == 2 and row_counts[2] == 1)
    local width, height = Core.parse_display_geometry("", "", "Physical size: 1080x1920", "SurfaceOrientation: 1")
    check("rotated display geometry", width == 1920 and height == 1080)
    local heartbeat = Core.classify_heartbeat({ token = "x", timestamp = 100, state = "loading" },
        "x", 100, 30, 0, 120)
    check("missing transition timestamp rejected", heartbeat.bad == true)
    local future = Core.classify_heartbeat({ token = "x", timestamp = 1000, state = "online", online = true },
        "x", 100, 30, 0, 120)
    check("far-future heartbeat rejected", future.bad == true and future.recent == false)

    if #failures > 0 then
        return nil, string.format("%d/%d self-tests failed: %s", #failures, tests, table.concat(failures, ", "))
    end
    return true, string.format("%d self-tests passed", tests)
end

return Core
end)()

-- The LocalPlayer heartbeat is not embedded; it is either reused from an
-- executor autoexecute folder or downloaded once (see fetch_heartbeat_source).

local DATA_DIR = "/storage/emulated/0/Noka"
local LEGACY_DATA_DIR = (os.getenv("HOME") or ".") .. "/NOKA"
local LEGACY_SHARED_CONFIG_PATH = DATA_DIR .. "/config.lua"
local CONFIG_PATH = DATA_DIR .. "/config-solrewrite.lua"
local STATE_DIR = DATA_DIR .. "/state"
local DEVICE_BACKUP_PATH = STATE_DIR .. "/device-backup.lua"
local BOUNDS_MANIFEST_PATH = STATE_DIR .. "/bounds-backups.lua"
local LOG_PATH = STATE_DIR .. "/noka-solrewrite.log"
local DELTA_ROOT = "/storage/emulated/0/Delta"
local ARCEUS_ROOT = "/storage/emulated/0/Arceus X"
local EXECUTOR_ROOTS = { DELTA_ROOT, ARCEUS_ROOT }
local SYSTEM_AM = "/system/bin/am"
local SYSTEM_INPUT = "/system/bin/input"
local TERMUX_PREFIX = os.getenv("PREFIX") or "/data/data/com.termux/files/usr"
local TERMUX_SLEEP = TERMUX_PREFIX .. "/bin/sleep"
local PRIVATE_TMP_DIR = TERMUX_PREFIX .. "/tmp/noka"
local CONTROLLER_LOCK_DIR = PRIVATE_TMP_DIR .. "/controller.lock"
local STOP_REQUEST_PATH = PRIVATE_TMP_DIR .. "/stop-requested"
local PRIVATE_CONFIG_DIR = (os.getenv("HOME") or "/data/data/com.termux/files/home") .. "/.config/noka"
local SECRETS_PATH = PRIVATE_CONFIG_DIR .. "/secrets-solrewrite.lua"
local WARMUP_DELAY = 7
local STATUS_BAR_CLEARANCE = 8
local FAILURE_CONFIRMATIONS = 3
local MIN_HEARTBEAT_TIMEOUT = 30
local TRANSITION_GRACE = 120
local DEFAULT_REGISTRATION_TIMEOUT = 180
local WEBHOOK_AVATAR_URL = "https://cdn.discordapp.com/attachments/1476719698090397806/1537197131415167026/5s1b21v.png"
local PLAY_STORE_PACKAGE = "com.android.vending"
local BACKGROUND_OPS = { "RUN_IN_BACKGROUND", "RUN_ANY_IN_BACKGROUND", "WAKE_LOCK", "SYSTEM_ALERT_WINDOW" }

local FLAGS = {}
for _, value in ipairs(arg or {}) do FLAGS[tostring(value)] = true end
if FLAGS["--self-test"] then
    local ok, message = Core.run_self_tests()
    local stream = ok and io.stdout or io.stderr
    stream:write((ok and "Noka: " or "Noka self-test failure: ") .. tostring(message) .. "\n")
    os.exit(ok and 0 or 1)
end

local function read_process_uid()
    local pipe = io.popen("id -u 2>/dev/null")
    if not pipe then return nil end
    local value = Core.trim(pipe:read("*a"))
    pipe:close()
    return value
end

local RUNNING_AS_ROOT = read_process_uid() == "0"

local function elevate_once()
    if RUNNING_AS_ROOT then return end

    local source_path = debug.getinfo(1, "S").source:sub(2)
    if source_path:sub(1, 1) ~= "/" then
        local pwd = io.popen("pwd 2>/dev/null")
        if not pwd then error("Noka could not resolve its source path") end
        local directory = Core.trim(pwd:read("*a"))
        pwd:close()
        source_path = directory .. "/" .. source_path
    end

    local prefix = os.getenv("PREFIX") or "/data/data/com.termux/files/usr"
    local user_home = os.getenv("HOME") or "/data/data/com.termux/files/home"
    local lua_binary = prefix .. "/bin/lua"
    local arguments = {}
    for index = 1, #(arg or {}) do
        arguments[#arguments + 1] = Core.shell_quote(arg[index])
    end

    local environment = table.concat({
        "export HOME=" .. Core.shell_quote(user_home),
        "export PREFIX=" .. Core.shell_quote(prefix),
        "export PATH=" .. Core.shell_quote("/system/bin:/system/xbin:" .. prefix .. "/bin:" .. (os.getenv("PATH") or "")),
    }, "; ")
    local child = environment .. "; exec " .. Core.shell_quote(lua_binary) .. " "
        .. Core.shell_quote(source_path)
    if #arguments > 0 then child = child .. " " .. table.concat(arguments, " ") end

    io.stdout:write("Noka is requesting root once for this session...\n")
    io.stdout:flush()
    local ok, _, code = os.execute("su -c " .. Core.shell_quote(child))
    os.exit(ok == true and 0 or tonumber(code) or 1)
end

elevate_once()

local DEFAULT_CONFIG = {
    version = 6,
    packages = {},
    launch_delay = 5,
    check_interval = 60,
    heartbeat_timeout = 90,
    startup_grace = 60,
    registration_timeout = DEFAULT_REGISTRATION_TIMEOUT,
    recovery_cooldown = 15,
    webhook_url = "",
    webhook_interval = 300,
    webhook_message_id = "",
    window_gap = 0,
    window_resize = true,
    solver_url = "",
    solver_key = "",
    solver_wait_timeout = 600,
    captcha_cpu_threshold = 3.0,
    deferred_relaunch_attempts = 2,
    webhook_edit_enabled = false,
    webhook_mask_usernames = false,
    autoblock_enabled = false,
    autoblock_targets = "",
    top_inset = 0,
    bottom_inset = 0,
    termux_package = "com.termux",
    optimization_applied = false,
}

local function ensure_directory(path)
    local ok, _, code = os.execute("mkdir -p " .. Core.shell_quote(path))
    return ok == true, tonumber(code)
end

local directory_ok = ensure_directory(STATE_DIR)
if not directory_ok then error("Noka could not create " .. STATE_DIR) end
local private_directory_ok = ensure_directory(PRIVATE_TMP_DIR)
if not private_directory_ok then error("Noka could not create " .. PRIVATE_TMP_DIR) end
os.execute("chmod 700 " .. Core.shell_quote(PRIVATE_TMP_DIR))
local private_config_ok = ensure_directory(PRIVATE_CONFIG_DIR)
if not private_config_ok then error("Noka could not create " .. PRIVATE_CONFIG_DIR) end
os.execute("chmod 700 " .. Core.shell_quote(PRIVATE_CONFIG_DIR))

local function file_exists(path)
    local handle = io.open(path, "r")
    if not handle then return false end
    handle:close()
    return true
end

local function copy_file(source_path, destination_path)
    local source_handle = io.open(source_path, "rb")
    if not source_handle then return nil, "source could not be opened" end
    local source_size = source_handle:seek("end")
    if not source_size or source_size > 2 * 1024 * 1024 then
        source_handle:close()
        return nil, source_size and "source exceeds 2 MiB" or "source size could not be read"
    end
    source_handle:seek("set", 0)
    local contents, read_error = source_handle:read("*a")
    source_handle:close()
    if contents == nil then return nil, read_error or "source could not be read" end
    local destination_handle, open_error = io.open(destination_path, "wb")
    if not destination_handle then return nil, open_error end
    local written, write_error = destination_handle:write(contents)
    local flushed, flush_error = destination_handle:flush()
    local closed, close_error = destination_handle:close()
    if not written or not flushed or not closed then
        os.remove(destination_path)
        return nil, write_error or flush_error or close_error or "copy failed"
    end
    return true
end

local temporary_counter = 0
local function self_pid()
    local handle = io.open("/proc/self/stat", "r")
    if not handle then return nil end
    local line = handle:read("*l") or ""
    handle:close()
    return tonumber(line:match("^(%d+)%s"))
end

local function temporary_path(label, directory)
    temporary_counter = temporary_counter + 1
    local pid = tostring(self_pid() or "process")
    local safe_label = tostring(label or "temporary"):gsub("[^%w_.-]", "_")
    return string.format("%s/.noka-%s.%s.%d.tmp", directory or PRIVATE_TMP_DIR,
        safe_label, pid, temporary_counter)
end

local function read_file(path, mode)
    local handle, open_error = io.open(path, mode or "rb")
    if not handle then return nil, open_error end
    local contents, read_error = handle:read("*a")
    local closed, close_error = handle:close()
    if contents == nil then return nil, read_error or "read failed" end
    if not closed then return nil, close_error or "close failed" end
    return contents
end

local function file_size(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local size = handle:seek("end")
    handle:close()
    return size
end

local function read_file_limited(path, maximum_bytes)
    local handle, open_error = io.open(path, "rb")
    if not handle then return nil, open_error end
    local contents, read_error = handle:read(maximum_bytes + 1)
    handle:close()
    if contents == nil then return nil, read_error or "read failed" end
    if #contents > maximum_bytes then return nil, "file exceeds size limit" end
    return contents
end

local function write_file(path, contents, mode)
    local handle, open_error = io.open(path, mode or "wb")
    if not handle then return nil, open_error end
    local written, write_error = handle:write(contents)
    local flushed, flush_error = handle:flush()
    local closed, close_error = handle:close()
    if not written or not flushed or not closed then
        os.remove(path)
        return nil, write_error or flush_error or close_error or "write failed"
    end
    return true
end

local function write_file_atomic(path, contents, permissions)
    local directory = path:match("^(.*)/[^/]+$") or "."
    local temporary = temporary_path("atomic", directory)
    local written, write_error = write_file(temporary, contents, "wb")
    if not written then os.remove(temporary); return nil, write_error end
    if permissions then
        -- Android emulated storage can ignore chmod even when the write itself
        -- is valid. Sensitive HTTP staging uses PRIVATE_TMP_DIR, where it works.
        os.execute("chmod " .. tostring(permissions) .. " " .. Core.shell_quote(temporary))
    end
    local renamed, rename_error = os.rename(temporary, path)
    if not renamed then os.remove(temporary); return nil, rename_error or "atomic rename failed" end
    return true
end

if not file_exists(CONFIG_PATH) then
    for _, legacy_config in ipairs({ LEGACY_SHARED_CONFIG_PATH, LEGACY_DATA_DIR .. "/config.lua" }) do
        if file_exists(legacy_config) and copy_file(legacy_config, CONFIG_PATH) then
            print("Noka SOL copied the existing configuration to " .. CONFIG_PATH)
            break
        end
    end
end

local log_write_count = 0
local function redact_log_message(message)
    local text = tostring(message)
    text = text:gsub("([%.]ROBLOSECURITY=)[^%s;\"']+", "%1[REDACTED]")
    text = text:gsub('("[Cc]ookie"%s*:%s*")[^"]+(")', "%1[REDACTED]%2")
    text = text:gsub('("[Aa][Pp][Ii]_[Kk][Ee][Yy]"%s*:%s*")[^"]+(")', "%1[REDACTED]%2")
    text = text:gsub("([Xx]%-[Aa][Pp][Ii]%-[Kk][Ee][Yy]:%s*)%S+", "%1[REDACTED]")
    text = text:gsub("(discord%.com/api/webhooks/%d+/)[%w_%.%-]+", "%1[REDACTED]")
    text = text:gsub("(discordapp%.com/api/webhooks/%d+/)[%w_%.%-]+", "%1[REDACTED]")
    return text
end

local function rotate_log_if_needed()
    local handle = io.open(LOG_PATH, "rb")
    if not handle then return end
    local size = handle:seek("end") or 0
    handle:close()
    if size >= 5 * 1024 * 1024 then
        os.remove(LOG_PATH .. ".1")
        os.rename(LOG_PATH, LOG_PATH .. ".1")
    end
end

local function log(level, message)
    log_write_count = log_write_count + 1
    if log_write_count % 256 == 1 then rotate_log_if_needed() end
    local line = string.format("[%s] %-5s %s", os.date("%Y-%m-%d %H:%M:%S"), level,
        redact_log_message(message))
    print(line)
    local handle = io.open(LOG_PATH, "a")
    if handle then
        handle:write(line, "\n")
        handle:close()
    end
end

local function command_raw(command_line)
    local pipe = io.popen(command_line .. " 2>&1")
    if not pipe then return "", false, -1 end
    local output = pipe:read("*a")
    local ok, _, code = pipe:close()
    return output or "", ok == true, tonumber(code) or (ok and 0 or 1)
end

local function command(command_line)
    local output, ok, code = command_raw(command_line)
    return Core.trim(output), ok, code
end

local function root(command_line, quiet)
    local output, ok, code
    if RUNNING_AS_ROOT then
        output, ok, code = command(command_line)
    else
        output, ok, code = command("su -c " .. Core.shell_quote(command_line))
    end
    if not ok and not quiet then
        log("WARN", string.format("root command failed (%s): %s", tostring(code), output))
    end
    return output, ok, code
end

local function have_root()
    local output, ok = root("id -u", true)
    return ok and output:match("^0$") ~= nil
end

local function curl_config_quote(value)
    value = tostring(value or "")
    if value:find("[%z\r\n]") then return nil, "curl value contains a control character" end
    return '"' .. value:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

-- URL, headers, cookies, and API keys live only in a mode-600 curl config.
-- This prevents credentials from appearing in ps/proc command-line output.
local function http_request(method, url, body, extra_headers, max_time, capture_headers)
    method = tostring(method or "GET"):upper()
    if method ~= "GET" and method ~= "POST" and method ~= "PATCH" then
        return nil, nil, "unsupported HTTP method"
    end
    local quoted_url, quote_error = curl_config_quote(url)
    if not quoted_url then return nil, nil, quote_error end

    local body_path = temporary_path("http-body")
    local config_path = temporary_path("curl-config")
    local headers_path = capture_headers and temporary_path("http-headers") or nil
    local request_path
    local config_lines = {
        "silent", "show-error", "request = " .. method,
        "connect-timeout = 15",
        "max-time = " .. tostring(math.max(1, math.min(900, tonumber(max_time) or 60))),
        "max-filesize = 10485760",
        "url = " .. quoted_url,
        "output = " .. assert(curl_config_quote(body_path)),
        "write-out = \"%{http_code}\"",
    }
    if headers_path then
        config_lines[#config_lines + 1] = "dump-header = " .. assert(curl_config_quote(headers_path))
    end

    for _, header in ipairs(extra_headers or {}) do
        local quoted_header, header_error = curl_config_quote(header)
        if not quoted_header then return nil, nil, header_error end
        config_lines[#config_lines + 1] = "header = " .. quoted_header
    end
    if body ~= nil then
        request_path = temporary_path("http-request")
        local request_ok, request_error = write_file(request_path, body, "wb")
        if not request_ok then return nil, nil, request_error end
        os.execute("chmod 600 " .. Core.shell_quote(request_path))
        config_lines[#config_lines + 1] = "header = \"Content-Type: application/json\""
        config_lines[#config_lines + 1] = "data-binary = "
            .. assert(curl_config_quote("@" .. request_path))
    end

    local config_ok, config_error = write_file(config_path, table.concat(config_lines, "\n") .. "\n", "wb")
    if not config_ok then
        if request_path then os.remove(request_path) end
        return nil, nil, config_error
    end
    os.execute("chmod 600 " .. Core.shell_quote(config_path))
    local status_output, transport_ok, transport_code = command(
        "curl -q --config " .. Core.shell_quote(config_path))
    local response_body = read_file(body_path, "rb") or ""
    local response_headers = headers_path and (read_file(headers_path, "rb") or "") or nil
    os.remove(config_path)
    os.remove(body_path)
    if headers_path then os.remove(headers_path) end
    if request_path then os.remove(request_path) end
    local status = status_output:match("(%d%d%d)%s*$")
    if not transport_ok then
        return response_body, status,
            string.format("curl failed (%s): %s", tostring(transport_code), status_output), response_headers
    end
    return response_body, status, nil, response_headers
end

local function http_get(url, max_time, extra_headers)
    return http_request("GET", url, nil, extra_headers, max_time)
end

local function http_post_json(url, body_table, extra_headers, max_time)
    local encoded_ok, body = pcall(Core.json_encode, body_table)
    if not encoded_ok then return nil, nil, tostring(body) end
    return http_request("POST", url, body, extra_headers, max_time)
end

-- The Roblox join-captcha solvers all share one shape: POST one account
-- (username + cookie, optionally placeId) and hold the request until the
-- solve finishes. Host names tune the payload; anything else gets the
-- universal webhook shape.
local function detect_solver_type(url)
    local host = (tostring(url):lower():match("^https?://([^/]+)")) or ""
    if host:find("highspec", 1, true) then return "highspec" end
    if host:find("zeropoint", 1, true) then return "zeropoint" end
    if host:find("blocksolve", 1, true) then return "blocksolve" end
    if host:find("zapzonex", 1, true) then return "zapzonex" end
    if host:find("omocaptcha", 1, true) then return "omocaptcha" end
    if host:find("yescaptcha", 1, true) then return "yescaptcha" end
    return "universal"
end

local executor_layout_cache
local function discover_executor_layout(refresh)
    if executor_layout_cache and not refresh then return executor_layout_cache end
    local layout = { roots = {}, workspaces = {}, autoexecute = {}, all_autoexecute = {} }
    for _, path in ipairs(EXECUTOR_ROOTS) do
        local _, exists = root("test -d " .. Core.shell_quote(path), true)
        if exists then layout.roots[#layout.roots + 1] = path end
    end
    for _, executor_root in ipairs(layout.roots) do
        local workspace_found = false
        for _, folder in ipairs({ "Workspace", "workspace" }) do
            local path = executor_root .. "/" .. folder
            local _, exists = root("test -d " .. Core.shell_quote(path), true)
            if exists then
                layout.workspaces[#layout.workspaces + 1] = path
                workspace_found = true
            end
        end
        if not workspace_found then layout.workspaces[#layout.workspaces + 1] = executor_root .. "/Workspace" end

        local autoexecute_found = false
        for _, folder in ipairs({ "Autoexecute", "autoexecute", "Autoexec", "autoexec" }) do
            local path = executor_root .. "/" .. folder
            layout.all_autoexecute[#layout.all_autoexecute + 1] = path
            local _, exists = root("test -d " .. Core.shell_quote(path), true)
            if exists then
                layout.autoexecute[#layout.autoexecute + 1] = path
                autoexecute_found = true
            end
        end
        if not autoexecute_found then
            layout.autoexecute[#layout.autoexecute + 1] = executor_root .. "/Autoexecute"
        end
    end
    executor_layout_cache = layout
    return layout
end

local function active_executor_workspaces()
    return discover_executor_layout(false).workspaces
end

local function active_autoexecute_directories()
    return discover_executor_layout(false).autoexecute
end

local function copy_table(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local result = {}
    seen[value] = result
    for key, item in pairs(value) do result[copy_table(key, seen)] = copy_table(item, seen) end
    return result
end

local function merge_defaults(target, defaults)
    for key, value in pairs(defaults) do
        if target[key] == nil then target[key] = copy_table(value) end
    end
    return target
end

local function serialize(value, indent, stack)
    indent = indent or 0
    local value_type = type(value)
    if value_type == "string" then return string.format("%q", value) end
    if value_type == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("cannot serialize a non-finite number")
        end
        return tostring(value)
    end
    if value_type == "boolean" then return tostring(value) end
    if value_type ~= "table" then return "nil" end
    stack = stack or {}
    if stack[value] then error("cannot serialize a cyclic table") end
    stack[value] = true
    local pad, next_pad = string.rep(" ", indent), string.rep(" ", indent + 4)
    local result = { "{\n" }
    local numeric = true
    local max, count = 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then numeric = false break end
        max = math.max(max, key)
        count = count + 1
    end
    -- Sparse numeric tables must be serialized as keyed tables. Iterating to a
    -- hostile key such as 1e100 would otherwise never finish.
    if numeric and max ~= count then numeric = false end
    if numeric then
        for index = 1, max do
            result[#result + 1] = next_pad .. serialize(value[index], indent + 4, stack) .. ",\n"
        end
    else
        local keys = {}
        for key in pairs(value) do keys[#keys + 1] = key end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, key in ipairs(keys) do
            local key_text
            if type(key) == "string" and key:match("^[%a_][%w_]*$") then
                key_text = key
            else
                key_text = "[" .. serialize(key, 0, stack) .. "]"
            end
            result[#result + 1] = next_pad .. key_text .. " = " .. serialize(value[key], indent + 4, stack) .. ",\n"
        end
    end
    result[#result + 1] = pad .. "}"
    stack[value] = nil
    return table.concat(result)
end

local function save_lua_table(path, value, header, permissions)
    local serialized_ok, serialized = pcall(serialize, value)
    if not serialized_ok then return nil, tostring(serialized) end
    return write_file_atomic(path, (header or "") .. "return " .. serialized .. "\n",
        permissions or "600")
end

-- Lua 5.1/Luraph-safe isolated compile: loadfile(path,"t",env) is 5.2+;
-- on 5.1 fall back to loadstring + setfenv so a config cannot touch globals.
local LUA_51 = _VERSION == "Lua 5.1"
local function compile_isolated(source, chunkname)
    if not LUA_51 then
        return load(source, chunkname or "=noka", "t", {})
    end
    local chunk, load_error = loadstring(source, chunkname or "=noka")
    if chunk and setfenv then pcall(setfenv, chunk, {}) end
    return chunk, load_error
end

local function load_lua_table(path)
    local size = file_size(path)
    if size and size > 2 * 1024 * 1024 then return nil, "Lua table file exceeds 2 MiB" end
    local contents, read_error = read_file(path, "rb")
    if not contents then return nil, read_error end
    local chunk, load_error = compile_isolated(contents)
    if not chunk then return nil, load_error end
    local ok, value = pcall(chunk)
    if not ok or type(value) ~= "table" then return nil, value end
    return value
end

local function process_start_time(pid)
    local stat = read_file("/proc/" .. tostring(pid) .. "/stat", "r")
    local after_name = stat and stat:match("^%d+ %(.+%) (.+)$") or nil
    if not after_name then return nil end
    local fields = {}
    for field in after_name:gmatch("%S+") do fields[#fields + 1] = field end
    return tonumber(fields[20])
end

local controller_lock_owner
local function acquire_controller_lock()
    local current_pid = self_pid()
    local current_start = current_pid and process_start_time(current_pid) or nil
    if not current_pid or not current_start then return nil, "could not identify the controller process" end

    for _ = 1, 2 do
        local _, created = root("mkdir " .. Core.shell_quote(CONTROLLER_LOCK_DIR), true)
        if created then
            controller_lock_owner = { pid = current_pid, start_time = current_start }
            local saved, save_error = save_lua_table(CONTROLLER_LOCK_DIR .. "/owner.lua",
                controller_lock_owner, nil, "600")
            if not saved then
                os.remove(CONTROLLER_LOCK_DIR .. "/owner.lua")
                os.remove(CONTROLLER_LOCK_DIR)
                controller_lock_owner = nil
                return nil, "could not record the controller lock: " .. tostring(save_error)
            end
            return true
        end

        local owner = load_lua_table(CONTROLLER_LOCK_DIR .. "/owner.lua")
        if type(owner) ~= "table" then
            os.execute(Core.shell_quote(TERMUX_SLEEP) .. " 0.5")
            owner = load_lua_table(CONTROLLER_LOCK_DIR .. "/owner.lua")
        end
        local owner_pid = type(owner) == "table" and tonumber(owner.pid) or nil
        local owner_start = type(owner) == "table" and tonumber(owner.start_time) or nil
        if owner_pid and owner_start and process_start_time(owner_pid) == owner_start then
            return nil, "another Noka controller is already running (PID " .. owner_pid .. ")"
        end
        os.remove(CONTROLLER_LOCK_DIR .. "/owner.lua")
        root("find " .. Core.shell_quote(CONTROLLER_LOCK_DIR)
            .. " -mindepth 1 -maxdepth 1 -type f -name '.noka-*' -delete 2>/dev/null", true)
        if not os.remove(CONTROLLER_LOCK_DIR) then
            return nil, "the stale controller lock could not be removed safely"
        end
    end
    return nil, "controller lock could not be acquired"
end

local function release_controller_lock()
    if not controller_lock_owner then return end
    local owner = load_lua_table(CONTROLLER_LOCK_DIR .. "/owner.lua")
    if type(owner) == "table" and tonumber(owner.pid) == controller_lock_owner.pid
        and tonumber(owner.start_time) == controller_lock_owner.start_time then
        os.remove(CONTROLLER_LOCK_DIR .. "/owner.lua")
        os.remove(CONTROLLER_LOCK_DIR)
    end
    controller_lock_owner = nil
end

local function cleanup_stale_private_files()
    local output = root("find " .. Core.shell_quote(PRIVATE_TMP_DIR)
        .. " -maxdepth 1 -type f -name '.noka-*' -mmin +1440 -print 2>/dev/null", true)
    local prefix = PRIVATE_TMP_DIR .. "/.noka-"
    for path in output:gmatch("[^\r\n]+") do
        if path:sub(1, #prefix) == prefix and not path:find("/", #prefix + 1, true) then
            os.remove(path)
        end
    end
end

local function load_config()
    local loaded, load_error = load_lua_table(CONFIG_PATH)
    if type(loaded) ~= "table" then
        if file_exists(CONFIG_PATH) then
            log("WARN", "Ignoring unreadable configuration: " .. tostring(load_error))
        end
        loaded = {}
    end
    local public_contains_secrets = type(loaded.webhook_url) == "string" and loaded.webhook_url ~= ""
        or type(loaded.solver_url) == "string" and loaded.solver_url ~= ""
        or type(loaded.solver_key) == "string" and loaded.solver_key ~= ""
        or type(loaded.packages) == "table" and next(loaded.packages) ~= nil
    local secrets, secrets_error = load_lua_table(SECRETS_PATH)
    if type(secrets) == "table" then
        if type(secrets.webhook_url) == "string" then loaded.webhook_url = secrets.webhook_url end
        if type(secrets.solver_url) == "string" then loaded.solver_url = secrets.solver_url end
        if type(secrets.solver_key) == "string" then loaded.solver_key = secrets.solver_key end
        if type(secrets.packages) == "table" then loaded.packages = secrets.packages end
        if type(secrets.autoblock_targets) == "string" then
            loaded.autoblock_targets = secrets.autoblock_targets
        end
    elseif file_exists(SECRETS_PATH) then
        log("WARN", "Ignoring unreadable private secrets: " .. tostring(secrets_error))
    end
    local old_version = tonumber(loaded.version) or 0
    if old_version < 2 then
        if loaded.window_gap == nil or loaded.window_gap == 4 then loaded.window_gap = 0 end
        loaded.version = 2
    end
    if old_version < 3 then
        if loaded.top_inset == 28 then loaded.top_inset = 0 end
        if loaded.bottom_inset == 8 then loaded.bottom_inset = 0 end
        loaded.version = 3
    end
    if old_version < 4 then
        if loaded.heartbeat_timeout ~= nil then
            loaded.heartbeat_timeout = math.max(MIN_HEARTBEAT_TIMEOUT,
                tonumber(loaded.heartbeat_timeout) or MIN_HEARTBEAT_TIMEOUT)
        end
        loaded.version = 4
    end
    if old_version < 5 then
        loaded.registration_timeout = tonumber(loaded.registration_timeout)
            or DEFAULT_REGISTRATION_TIMEOUT
        loaded.heartbeat_url = nil -- Version 4 exposed this setting but never used it.
        loaded.version = 5
    end
    -- Rejoin 6.0: solver-gated launch and monitoring captcha-lane settings.
    if old_version < 6 then
        loaded.solver_wait_timeout = nil
        loaded.captcha_cpu_threshold = nil
        loaded.deferred_relaunch_attempts = nil
        loaded.version = 6
    end
    local merged = merge_defaults(loaded, DEFAULT_CONFIG)
    merged.heartbeat_url = nil
    local function number(key, minimum, maximum)
        local value = tonumber(merged[key]) or DEFAULT_CONFIG[key]
        merged[key] = math.max(minimum, math.min(maximum, value))
    end
    number("launch_delay", 0, 600)
    number("check_interval", 1, 60)
    number("heartbeat_timeout", MIN_HEARTBEAT_TIMEOUT, 600)
    number("startup_grace", 15, 900)
    number("registration_timeout", 30, 900)
    number("recovery_cooldown", 0, 600)
    number("webhook_interval", 60, 3600)
    number("window_gap", 0, 100)
    number("top_inset", 0, 1000)
    number("bottom_inset", 0, 1000)
    number("solver_wait_timeout", 60, 1800)
    merged.captcha_cpu_threshold = math.max(1.0, math.min(50.0,
        tonumber(merged.captcha_cpu_threshold) or DEFAULT_CONFIG.captcha_cpu_threshold))
    merged.deferred_relaunch_attempts = math.floor(math.max(1, math.min(5,
        tonumber(merged.deferred_relaunch_attempts) or DEFAULT_CONFIG.deferred_relaunch_attempts)))
    local package_entries, numeric_keys = {}, {}
    if type(merged.packages) == "table" then
        for key in pairs(merged.packages) do
            if type(key) == "number" and key >= 1 and key % 1 == 0 then numeric_keys[#numeric_keys + 1] = key end
        end
        table.sort(numeric_keys)
        for _, key in ipairs(numeric_keys) do
            local entry = merged.packages[key]
            if type(entry) == "table" and Core.is_package_name(entry.package)
                and type(entry.target) == "table" then
                package_entries[#package_entries + 1] = entry
            else
                log("WARN", "Dropped malformed configured package entry " .. tostring(key))
            end
        end
    end
    merged.packages = package_entries
    for _, key in ipairs({ "webhook_url", "webhook_message_id", "solver_url", "solver_key",
        "autoblock_targets", "termux_package" }) do
        if type(merged[key]) ~= "string" then merged[key] = DEFAULT_CONFIG[key] end
    end
    merged.webhook_url = Core.trim(merged.webhook_url)
    merged.webhook_message_id = Core.trim(merged.webhook_message_id)
    merged.solver_url = Core.trim(merged.solver_url)
    merged.solver_key = Core.trim(merged.solver_key)
    for _, key in ipairs({ "window_resize", "webhook_mask_usernames", "autoblock_enabled",
        "webhook_edit_enabled", "optimization_applied" }) do
        if type(merged[key]) ~= "boolean" then merged[key] = DEFAULT_CONFIG[key] end
    end
    if not Core.is_package_name(merged.termux_package) then
        merged.termux_package = DEFAULT_CONFIG.termux_package
    end
    merged.version = DEFAULT_CONFIG.version
    return merged, public_contains_secrets or old_version < DEFAULT_CONFIG.version
end

local function save_config(config)
    local public_config = copy_table(config)
    public_config.webhook_url = ""
    public_config.solver_url = ""
    public_config.solver_key = ""
    public_config.packages = {}
    public_config.autoblock_targets = ""
    local secrets = { webhook_url = config.webhook_url or "", solver_url = config.solver_url or "",
        solver_key = config.solver_key or "", packages = copy_table(config.packages or {}),
        autoblock_targets = config.autoblock_targets or "" }
    local public_ok, serialized_public = pcall(serialize, public_config)
    if not public_ok then return nil, tostring(serialized_public) end
    local secrets_ok, serialized_secrets = pcall(serialize, secrets)
    if not secrets_ok then return nil, tostring(serialized_secrets) end
    local public_contents = "-- Generated by Noka. Secrets are stored in Termux private storage.\nreturn "
        .. serialized_public .. "\n"
    local secrets_contents = "-- Generated by Noka. Do not share this file.\nreturn "
        .. serialized_secrets .. "\n"

    local previous_secrets, previous_secrets_error = read_file(SECRETS_PATH, "rb")
    if file_exists(SECRETS_PATH) and not previous_secrets then
        return nil, "existing private secrets could not be read: " .. tostring(previous_secrets_error)
    end
    local secrets_saved, secrets_error = write_file_atomic(SECRETS_PATH, secrets_contents, "600")
    if not secrets_saved then return nil, "private secrets could not be saved: " .. tostring(secrets_error) end
    local public_saved, public_error = write_file_atomic(CONFIG_PATH, public_contents, "600")
    if not public_saved then
        if previous_secrets then
            write_file_atomic(SECRETS_PATH, previous_secrets, "600")
        else
            os.remove(SECRETS_PATH)
        end
        return nil, public_error
    end
    return true
end

local config, config_needs_save = load_config()
if not file_exists(CONFIG_PATH) or config_needs_save then
    local saved, save_error = save_config(config)
    if not saved then error("Noka could not initialize " .. CONFIG_PATH .. ": " .. tostring(save_error)) end
end

-- Set by the --no-resize flag; when false the App Cloner XML bounds are never
-- touched and clones keep whatever window size they already have.
local resize_session_disabled = false

local function resize_enabled()
    if resize_session_disabled then return false end
    return config.window_resize ~= false
end

local function solver_enabled()
    return Core.trim(config.solver_url or "") ~= ""
end

local function prompt(label, default)
    if default ~= nil and tostring(default) ~= "" then
        io.write(string.format("%s [%s]: ", label, tostring(default)))
    else
        io.write(label .. ": ")
    end
    io.flush()
    local value = io.read("*l")
    if value == nil then return nil end
    value = Core.trim(value)
    if value == "" and default ~= nil then return tostring(default) end
    return value
end

local function prompt_number(label, default, minimum, maximum)
    while true do
        local value = prompt(label, default)
        if value == nil then return nil end
        local number = tonumber(value)
        if number and number >= minimum and number <= maximum then return number end
        print(string.format("Enter a number from %s to %s.", minimum, maximum))
    end
end

local function yes_no(label, default_yes)
    local suffix = default_yes and "Y/n" or "y/N"
    while true do
        local value = prompt(label .. " (" .. suffix .. ")", "")
        if value == nil or value == "" then return default_yes end
        value = value:lower()
        if value == "y" or value == "yes" then return true end
        if value == "n" or value == "no" then return false end
    end
end

local end_listener_pid
local stop_announced = false

local function stop_requested()
    local handle = io.open(STOP_REQUEST_PATH, "r")
    if not handle then return false end
    handle:close()
    if not stop_announced then
        stop_announced = true
        log("INFO", "END received; stopping the Noka rejoin sequence")
    end
    return true
end

local function uptime_seconds()
    local handle = io.open("/proc/uptime", "r")
    if not handle then return nil end
    local value = tonumber((handle:read("*l") or ""):match("^(%d+%.?%d*)"))
    handle:close()
    return value
end

local function wait_or_stop(seconds)
    seconds = math.max(0, tonumber(seconds) or 0)
    local started = uptime_seconds()
    local deadline = started and (started + seconds)
    local remaining = seconds
    while remaining > 0 do
        if stop_requested() then return false end
        local slice = math.min(1.0, remaining)
        local sleep_value = string.format("%.3f", slice):gsub(",", ".")
        os.execute(Core.shell_quote(TERMUX_SLEEP) .. " " .. sleep_value)
        if deadline then
            local now = uptime_seconds()
            remaining = now and math.max(0, deadline - now) or (remaining - slice)
        else
            remaining = remaining - slice
        end
    end
    return not stop_requested()
end

local function start_end_listener()
    if end_listener_pid then return true end
    os.remove(STOP_REQUEST_PATH)
    stop_announced = false
    local prefix = os.getenv("PREFIX") or "/data/data/com.termux/files/usr"
    local bash = prefix .. "/bin/bash"
    local parent_pid = self_pid()
    if not parent_pid then
        log("WARN", "END-key listener could not determine the controller PID")
        return false
    end
    local watcher = [==[
parent_pid=]==] .. tostring(parent_pid) .. [==[
while true; do
    kill -0 "$parent_pid" 2>/dev/null || exit 0
    key=''
    IFS= read -r -s -n 1 -t 0.5 key </dev/tty || continue
    if [[ "$key" == $'\e' ]]; then
        rest=''
        IFS= read -r -s -n 2 -t 0.4 rest </dev/tty || true
        if [[ "$rest" == '[F' || "$rest" == 'OF' ]]; then
            printf 'END\n' > ]==] .. Core.shell_quote(STOP_REQUEST_PATH) .. [==[
            exit 0
        elif [[ "$rest" == '[4' ]]; then
            tail=''
            IFS= read -r -s -n 1 -t 0.2 tail </dev/tty || true
            if [[ "$tail" == '~' ]]; then
                printf 'END\n' > ]==] .. Core.shell_quote(STOP_REQUEST_PATH) .. [==[
                exit 0
            fi
        fi
    fi
done
]==]
    local command_line = Core.shell_quote(bash) .. " -c " .. Core.shell_quote(watcher)
        .. " >/dev/null 2>&1 & echo $!"
    local output, ok = command(command_line)
    end_listener_pid = ok and tonumber(output:match("(%d+)%s*$")) or nil
    if not end_listener_pid then
        log("WARN", "END-key listener could not start; watchdog operation will continue normally")
        return false
    else
        log("INFO", "Press END in Termux at any time to stop Noka")
        return true
    end
end

local function stop_end_listener()
    if end_listener_pid then
        root("kill " .. tostring(end_listener_pid) .. " 2>/dev/null || true", true)
        end_listener_pid = nil
    end
    os.remove(STOP_REQUEST_PATH)
end

-- Rejoin: two-value protocol instead of table.pack/table.unpack so the whole
-- controller parses under Lua 5.1/Luraph.
local function with_end_listener(operation, finalizer)
    start_end_listener()
    local ok, result = xpcall(operation, debug.traceback)
    stop_end_listener()
    if finalizer then
        local finalized, finalizer_error = pcall(finalizer, ok, result)
        if not finalized then log("ERROR", "Sequence cleanup failed: " .. tostring(finalizer_error)) end
    end
    if not ok then
        log("ERROR", "Unhandled sequence error: " .. tostring(result))
        return false
    end
    return true, result
end

local function print_header()
    local reset = "\27[0m"
    local bold_white = "\27[1;97m"
    local gray = "\27[90m"
    if os.getenv("NO_COLOR") then reset, bold_white, gray = "", "", "" end
    io.write("\27[2J\27[3J\27[H")
    print(bold_white .. [[███╗   ██╗ ██████╗ ██╗  ██╗ █████╗ ]] .. reset)
    print(bold_white .. [[████╗  ██║██╔═══██╗██║ ██╔╝██╔══██╗]] .. reset)
    print(bold_white .. [[██╔██╗ ██║██║   ██║█████╔╝ ███████║]] .. reset)
    print(bold_white .. [[██║╚██╗██║██║   ██║██╔═██╗ ██╔══██║]] .. reset)
    print(bold_white .. [[██║ ╚████║╚██████╔╝██║  ██╗██║  ██║]] .. reset)
    print(bold_white .. [[╚═╝  ╚═══╝ ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═╝]] .. reset)
    print("")
    print(gray .. "  discord.gg/noka" .. reset)
    print("")
end

local PANEL_WIDTH = 76

local function print_panel(title, rows)
    local inner_width = PANEL_WIDTH - 4
    local gray = "\27[90m"
    local reset = "\27[0m"
    if os.getenv("NO_COLOR") then gray, reset = "", "" end
    local function line(text)
        text = tostring(text or "")
        if #text > inner_width then text = text:sub(1, inner_width - 3) .. "..." end
        print("│ " .. text .. string.rep(" ", inner_width - #text) .. " │")
    end
    -- Descriptions are gray; the "0." back/exit row is fully gray and sits one
    -- blank line below the actionable rows.
    local function row_line(row, grayed)
        local left = string.format("  %-3s %-23s", tostring(row[1] or ""), tostring(row[2] or ""))
        local description = tostring(row[3] or "")
        if description == "" then left = left:gsub("%s+$", "") end
        if #left > inner_width then left = left:sub(1, inner_width) end
        local available = inner_width - #left
        if #description > available then
            if available > 3 then description = description:sub(1, available - 3) .. "..."
            else description = description:sub(1, available) end
        end
        local padding = string.rep(" ", available - #description)
        local content
        if grayed then
            content = gray .. left .. description .. reset .. padding
        elseif description ~= "" then
            content = left .. gray .. description .. reset .. padding
        else
            content = left .. padding
        end
        print("│ " .. content .. " │")
    end
    print("┌" .. string.rep("─", PANEL_WIDTH - 2) .. "┐")
    line(title)
    line("")
    local index = 0
    for _, row in ipairs(rows or {}) do
        index = index + 1
        local grayed = tostring(row[1]) == "0."
        if grayed and index > 1 then line("") end
        row_line(row, grayed)
    end
    print("└" .. string.rep("─", PANEL_WIDTH - 2) .. "┘")
end

local function list_installed_packages()
    local output, ok = root("pm list packages --user 0", true)
    if not ok then return nil, "could not query Android Package Manager" end
    local packages = {}
    for line in output:gmatch("[^\r\n]+") do
        local package_name = line:match("^package:(.+)$")
        if package_name and Core.is_package_name(package_name) then packages[#packages + 1] = package_name end
    end
    table.sort(packages)
    return packages
end

local function package_set(packages)
    local result = {}
    for _, package_name in ipairs(packages) do result[package_name] = true end
    return result
end

local function filter_posix_regex(packages, pattern)
    local temporary = temporary_path("packages")
    local contents = #packages > 0 and (table.concat(packages, "\n") .. "\n") or ""
    local written, write_error = write_file(temporary, contents, "wb")
    if not written then return nil, "could not stage the package list: " .. tostring(write_error) end
    local output, ok, code = command("grep -E -- " .. Core.shell_quote(pattern) .. " " .. Core.shell_quote(temporary))
    os.remove(temporary)
    if not ok and code == 2 then return nil, "invalid POSIX regular expression" end
    local result = {}
    for package_name in output:gmatch("[^\r\n]+") do result[#result + 1] = package_name end
    return result
end

local function choose_packages()
    print_header()
    local packages, package_error = list_installed_packages()
    if not packages then return nil, package_error end
    while true do
        print_panel("PACKAGE DISCOVERY", {
            { "1.", "Automatic", "com.roblox.*, free.*, premium.*" },
            { "2.", "Regular expression", "custom POSIX package pattern" },
            { "3.", "Names / wildcards", "verified installed packages only" },
        })
        local mode = prompt("Selection", "1")
        if mode == nil then return nil, "Setup cancelled." end
        local selected
        if mode == "1" then
            selected = Core.filter_automatic_packages(packages)
        elseif mode == "2" then
            local pattern = prompt("Package regex (example: ^example\\..*$)", "")
            if pattern == nil then return nil, "Setup cancelled." end
            selected, package_error = filter_posix_regex(packages, pattern)
            if not selected then print("\n" .. package_error .. "\n") end
        elseif mode == "3" then
            local package_input = prompt("Package names/patterns, separated by spaces or commas", "")
            if package_input == nil then return nil, "Setup cancelled." end
            local values = Core.split_list(package_input)
            local installed = package_set(packages)
            selected = {}
            local seen = {}
            for _, value in ipairs(values) do
                if value:find("*", 1, true) or value:find("?", 1, true) then
                    for _, match in ipairs(Core.filter_packages(packages, { value })) do
                        if not seen[match] then selected[#selected + 1] = match; seen[match] = true end
                    end
                elseif installed[value] and not seen[value] then
                    selected[#selected + 1] = value
                    seen[value] = true
                else
                    print("  Not installed: " .. value)
                end
            end
            table.sort(selected)
        else
            print("Unknown selection.\n")
        end

        if selected and #selected > 0 then
            if #selected > 30 then
                print(string.format("\nNoka supports at most 30 packages; this matched %d. Narrow the selection.\n", #selected))
                selected = nil
            end
        end
        if selected and #selected > 0 then
            print("\nDetected and verified:")
            for index, package_name in ipairs(selected) do print(string.format("  %2d  %s", index, package_name)) end
            if yes_no("Use these packages?", true) then return selected end
            print("")
        elseif selected then
            print("\nNo installed package matched. Try another method.\n")
        end
    end
end

local function ask_join_target(label, previous)
    while true do
        local value = prompt(label, previous and previous.input or "")
        if value == nil then return nil end
        local target, target_error = Core.parse_join_target(value)
        if target then
            target.input = value
            print("     → " .. target.uri)
            return target
        end
        print("     " .. target_error)
    end
end

local function assign_targets(packages, old_entries)
    local old_by_package = {}
    for _, entry in ipairs(old_entries or {}) do old_by_package[entry.package] = entry end
    print_header()
    print_panel("JOIN DESTINATIONS", {
        { "1.", "Shared destination", "one game or private server for all" },
        { "2.", "Per-package", "a separate destination for every clone" },
    })
    local mode = prompt("Selection", "1")
    local entries = {}
    local shared
    if mode ~= "2" then shared = ask_join_target("Roblox game ID, game URL, or private-server URL") end
    if not shared and mode ~= "2" then return nil end
    for _, package_name in ipairs(packages) do
        local target = shared
        if mode == "2" then
            local old = old_by_package[package_name]
            target = ask_join_target("  " .. package_name, old and old.target)
            if not target then return nil end
        end
        entries[#entries + 1] = { package = package_name, target = copy_table(target) }
    end
    return entries
end

local function valid_webhook(url)
    if url == "" then return true end
    local host, path = url:match("^https://([^/%?#]+)(/[^%?#]*)$")
    if not host then return false end
    host = host:lower()
    local allowed = host == "discord.com" or host == "discordapp.com"
        or host == "canary.discord.com" or host == "ptb.discord.com"
    return allowed and path:match("^/api/webhooks/%d+/[%w_%.%-]+$") ~= nil
end

local function valid_solver_url(url)
    if url == "" then return true end
    local scheme, authority = url:match("^(https?)://([^/%?#]+)")
    if not scheme or authority:find("[%s@]") then return false end
    local host = authority:lower()
    if host:sub(1, 1) == "[" then
        host = host:match("^%[([^%]]+)%]:?%d*$") or ""
    else
        host = host:gsub(":%d+$", "")
    end
    if host == "" then return false end
    return scheme == "https" or host == "localhost" or host == "127.0.0.1" or host == "::1"
end

local function ask_webhook(current)
    while true do
        if current and current ~= "" then print("Current webhook: configured (hidden)") end
        local value = prompt("Discord webhook URL (empty disables updates)")
        if value == nil then return nil end
        if valid_webhook(value) then return value end
        print("That is not a Discord webhook URL.")
    end
end

local function setup_wizard()
    print_header()
    if not have_root() then
        print("Noka is root-only. Grant root to Termux, then run the wizard again.")
        return false
    end
    -- No END listener here: the watcher reads /dev/tty and would steal
    -- keystrokes and paste bytes from the wizard's own prompts.
    local packages, choose_error = choose_packages()
    if not packages then print(choose_error or "Setup cancelled."); return false end
    local entries = assign_targets(packages, config.packages)
    if not entries then return false end
    print_header()
    local webhook = ask_webhook(config.webhook_url)
    if webhook == nil then return false end
    local delay = prompt_number("Homepage wait, in seconds", config.launch_delay, 0, 600)
    if not delay then return false end

    config.packages = entries
    config.webhook_url = webhook
    config.launch_delay = delay
    config.optimization_applied = false
    local saved, save_error = save_config(config)
    if not saved then print("Setup could not be saved: " .. tostring(save_error)); return false end
    print("\nSetup complete. " .. #entries .. " verified package(s) are ready.")
    return true
end

local GAME_NAMES_PATH = STATE_DIR .. "/game-names.lua"
local game_names_cache

local function load_game_names()
    if not game_names_cache then
        local loaded = load_lua_table(GAME_NAMES_PATH)
        game_names_cache = {}
        if type(loaded) == "table" then
            local count = 0
            for place_id, name in pairs(loaded) do
                place_id = tostring(place_id)
                if count < 1000 and place_id:match("^%d+$") and type(name) == "string" then
                    game_names_cache[place_id] = name
                    count = count + 1
                end
            end
        end
    end
    return game_names_cache
end

local function save_game_names()
    if not game_names_cache then return end
    local saved, save_error = save_lua_table(GAME_NAMES_PATH, game_names_cache, nil, "600")
    if not saved then log("WARN", "Could not save the game-name cache: " .. tostring(save_error)) end
end

local function resolve_place_name(place_id)
    local cache = load_game_names()
    if cache[place_id] then return cache[place_id] end
    local body, code = http_get("https://apis.roblox.com/universes/v1/places/" .. place_id .. "/universe", 15)
    local universe = code == "200" and Core.json_decode(body) or nil
    local universe_id = type(universe) == "table" and tonumber(universe.universeId) or nil
    if not universe_id then return nil end
    local games_body, games_code = http_get(
        "https://games.roblox.com/v1/games?universeIds=" .. tostring(universe_id), 15)
    local games = games_code == "200" and Core.json_decode(games_body) or nil
    local first_game = type(games) == "table" and type(games.data) == "table" and games.data[1] or nil
    local name = type(first_game) == "table" and first_game.name or nil
    if name and name ~= "" then
        cache[place_id] = name
        save_game_names()
        return name
    end
    return nil
end

local function target_display(target)
    if type(target) ~= "table" then return "Invalid destination" end
    if target.place_id then
        local place_id = tostring(target.place_id)
        local name = place_id:match("^%d+$") and resolve_place_name(place_id) or nil
        local base = name or ("Game " .. place_id)
        if target.kind == "private" then return "Private server: " .. base end
        return base
    end
    return tostring(target.display or target.uri or "Invalid destination")
end

local function remove_packages()
    if #config.packages == 0 then
        print("\nNo packages are configured.")
        return
    end
    print("")
    for index, entry in ipairs(config.packages) do
        print(string.format("     %2d. %-34s %s", index, entry.package, target_display(entry.target)))
    end
    local value = prompt("Remove (numbers or names, 'all')", "")
    if value == nil or value == "" then return end
    local remove = {}
    if value:lower() == "all" then
        for _, entry in ipairs(config.packages) do remove[entry.package] = true end
    else
        for _, token in ipairs(Core.split_list(value)) do
            local entry
            local index = tonumber(token)
            if index then entry = config.packages[index] end
            if not entry then
                for _, candidate in ipairs(config.packages) do
                    if candidate.package == token then entry = candidate break end
                end
            end
            if entry then
                remove[entry.package] = true
            else
                print("  Not configured: " .. token)
            end
        end
    end
    local count = 0
    for _ in pairs(remove) do count = count + 1 end
    if count == 0 then return end
    if not yes_no(string.format("Remove %d package(s) from the configuration?", count), true) then return end
    local kept = {}
    for _, entry in ipairs(config.packages) do
        if not remove[entry.package] then kept[#kept + 1] = entry end
    end
    local previous_packages = config.packages
    config.packages = kept
    local saved, save_error = save_config(config)
    if not saved then
        config.packages = previous_packages
        print("Package removal was not saved: " .. tostring(save_error))
        return
    end
    print(string.format("Removed %d package(s); %d remain.", count, #kept))
end

local function configuration_menu()
    while true do
        print_header("Configuration")
        local webhook_interval = effective_webhook_interval()
        print_panel("CONFIGURATION", {
            { "1.", "Packages", string.format("%d configured", #config.packages) },
            { "2.", "Remove packages", "remove configured clones" },
            { "3.", "Join destinations", "edit per package" },
            { "4.", "Homepage wait", string.format("%.1f seconds", config.launch_delay) },
            { "5.", "Discord webhook", config.webhook_url == "" and "disabled" or "configured" },
            { "6.", "Watchdog interval", string.format("%.1f seconds", config.check_interval) },
            { "7.", "Heartbeat timeout", string.format("%.1f seconds", config.heartbeat_timeout) },
            { "8.", "Join grace period", string.format("%.1f seconds", config.startup_grace) },
            { "9.", "Status update", webhook_interval >= 60
                and string.format("every %d min", math.floor(webhook_interval / 60 + 0.5))
                or string.format("every %d seconds", webhook_interval) },
            { "10.", "Window resizing", resize_enabled() and "enabled" or "disabled" },
            { "11.", "Captcha solver", solver_enabled() and ("configured (" .. detect_solver_type(config.solver_url) .. ")") or "disabled" },
            { "12.", "Mask usernames", config.webhook_mask_usernames and "package only on webhook" or "visible on webhook" },
            { "13.", "Auto block accounts", config.autoblock_enabled
                and ((Core.trim(config.autoblock_targets or "") ~= ""
                    and "mutual + extra targets" or "mutual between clones"))
                or "disabled" },
            { "14.", "Heartbeat registration", string.format("timeout after %.0f seconds", config.registration_timeout) },
            { "15.", "Status message mode", config.webhook_edit_enabled
                and "edit one message (10s+)" or "new messages (60s+)" },
            { "0.", "Back", "return to SELECT" },
        })
        print("\nCurrent instances:")
        for index, entry in ipairs(config.packages) do
            print(string.format("     %2d. %-34s %s", index, entry.package, target_display(entry.target)))
        end
        local choice = prompt("\nChange", "0")
        if choice == "0" or choice == "00" or choice == nil then return end
        local previous_config = copy_table(config)
        if choice == "1" then
            local packages = choose_packages()
            if packages then
                local entries = assign_targets(packages, config.packages)
                if entries then config.packages = entries; config.optimization_applied = false end
            end
        elseif choice == "2" then
            remove_packages()
        elseif choice == "3" then
            local names = {}
            for _, entry in ipairs(config.packages) do names[#names + 1] = entry.package end
            local entries = assign_targets(names, config.packages)
            if entries then config.packages = entries end
        elseif choice == "4" then
            config.launch_delay = prompt_number("New homepage wait, in seconds", config.launch_delay, 0, 600) or config.launch_delay
        elseif choice == "5" then
            local value = ask_webhook(config.webhook_url)
            if value then config.webhook_url = value end
        elseif choice == "6" then
            config.check_interval = prompt_number("New watchdog interval", config.check_interval, 1, 60) or config.check_interval
        elseif choice == "7" then
            config.heartbeat_timeout = prompt_number("New heartbeat timeout", config.heartbeat_timeout,
                MIN_HEARTBEAT_TIMEOUT, 600) or config.heartbeat_timeout
        elseif choice == "8" then
            config.startup_grace = prompt_number("New join grace period", config.startup_grace, 15, 900) or config.startup_grace
        elseif choice == "9" then
            local minimum = config.webhook_edit_enabled and 10 or 60
            while true do
                local value = prompt(string.format(
                    "New Discord update interval, in seconds (minimum %d)", minimum),
                    tostring(config.webhook_interval))
                if value == nil then break end
                local seconds = tonumber(value)
                if seconds and seconds % 1 == 0 and seconds >= minimum and seconds <= 3600 then
                    config.webhook_interval = seconds
                    break
                end
                print(string.format("Enter a whole number of seconds from %d to 3600.", minimum))
            end
        elseif choice == "10" then
            config.window_resize = not (config.window_resize ~= false)
            print("Window resizing " .. ((config.window_resize ~= false) and "enabled." or "disabled."))
        elseif choice == "11" then
            local url = prompt("Captcha solver URL ('off' disables)", config.solver_url)
            if url ~= nil then
                url = Core.trim(url)
                if url:lower() == "off" or url:lower() == "none" then url = "" end
                if not valid_solver_url(url) then
                    print("Solver URLs must use HTTPS (HTTP is allowed only for localhost).")
                else
                    config.solver_url = url
                end
                if config.solver_url ~= "" and config.solver_url == url then
                    print("Detected solver type: " .. detect_solver_type(config.solver_url))
                    config.solver_key = ""
                elseif config.solver_url == "" then
                    config.solver_key = ""
                end
            end
        elseif choice == "12" then
            config.webhook_mask_usernames = not config.webhook_mask_usernames
            print("Webhook usernames " .. (config.webhook_mask_usernames
                and "hidden; the package name is shown instead." or "visible on the webhook."))
        elseif choice == "13" then
            config.autoblock_enabled = not config.autoblock_enabled
            if config.autoblock_enabled then
                print("Auto block enabled: every clone will automatically block every other clone,")
                print("so two farmed accounts never end up in the same server.")
            else
                print("Auto block disabled.")
            end
            if config.autoblock_enabled then
                local targets = prompt("Optionally also block extra accounts (usernames/IDs, empty = clones only)",
                    config.autoblock_targets)
                if targets ~= nil then config.autoblock_targets = targets end
            end
        elseif choice == "14" then
            config.registration_timeout = prompt_number("Heartbeat registration timeout",
                config.registration_timeout, 30, 900) or config.registration_timeout
        elseif choice == "15" then
            config.webhook_edit_enabled = not (config.webhook_edit_enabled == true)
            if config.webhook_edit_enabled then
                print("Status messages now edit one Discord message; intervals down to 10 seconds unlock.")
            else
                print("Status messages are fresh posts again; the interval floor is back to 60 seconds.")
            end
            if (tonumber(config.webhook_interval) or 300) < (config.webhook_edit_enabled and 10 or 60) then
                config.webhook_interval = config.webhook_edit_enabled and 10 or 60
                print(string.format("Interval adjusted to %d seconds for this mode.", config.webhook_interval))
            end
        end
        local saved, save_error = save_config(config)
        if not saved then
            config = previous_config
            print("Configuration change was rolled back: " .. tostring(save_error))
        end
    end
end

local function read_setting(namespace, key)
    local output = root(string.format("settings get %s %s", namespace, Core.shell_quote(key)), true)
    return output
end

local function write_setting(namespace, key, value)
    return root(string.format("settings put %s %s %s", namespace, Core.shell_quote(key), Core.shell_quote(value)), true)
end

local function read_property(key)
    return root("getprop " .. Core.shell_quote(key), true)
end

local function output_contains_package(output, package_name)
    for token in tostring(output or ""):gmatch("[%a_][%w_%.]+") do
        if token == package_name then return true end
    end
    return false
end

local function save_device_backup()
    local backup, backup_error = load_lua_table(DEVICE_BACKUP_PATH)
    if file_exists(DEVICE_BACKUP_PATH) and type(backup) ~= "table" then
        return nil, "existing device backup is unreadable: " .. tostring(backup_error)
    end
    if type(backup) ~= "table" then
        backup = {
            version = 2, settings = {}, properties = {}, package_controls = {},
            play_store_disabled = false, deviceidle = "",
        }
        local settings = {
            { "global", "window_animation_scale" }, { "global", "transition_animation_scale" },
            { "global", "animator_duration_scale" }, { "global", "low_power" },
            { "global", "low_power_trigger_level" }, { "global", "adaptive_battery_management_enabled" },
            { "global", "app_standby_enabled" }, { "global", "app_auto_restriction_enabled" },
            { "global", "forced_app_standby_enabled" }, { "global", "force_resizable_activities" },
            { "global", "enable_freeform_support" }, { "global", "enable_non_resizable_multi_window" },
        }
        for _, item in ipairs(settings) do
            backup.settings[item[1] .. ":" .. item[2]] = read_setting(item[1], item[2])
        end
        for _, key in ipairs({ "persist.logd.size", "persist.log.tag", "persist.log.tag.snet_event_log" }) do
            backup.properties[key] = read_property(key)
        end
        local disabled = root("pm list packages -d --user 0", true)
        backup.play_store_disabled = output_contains_package(disabled, PLAY_STORE_PACKAGE)
        backup.deviceidle = root("cmd deviceidle enabled", true)
    end
    backup.package_controls = type(backup.package_controls) == "table" and backup.package_controls or {}
    local whitelist = root("cmd deviceidle whitelist", true)
    local controlled_packages = { config.termux_package }
    for _, entry in ipairs(config.packages) do controlled_packages[#controlled_packages + 1] = entry.package end
    for _, package_name in ipairs(controlled_packages) do
        if not backup.package_controls[package_name] then
            local controls = { whitelisted = output_contains_package(whitelist, package_name), appops = {} }
            for _, operation in ipairs(BACKGROUND_OPS) do
                local output = root(string.format("appops get %s %s", Core.shell_quote(package_name), operation), true)
                controls.appops[operation] = output:match(operation .. ":%s*([%w_]+)") or "default"
            end
            backup.package_controls[package_name] = controls
        end
    end
    local saved, save_error = save_lua_table(DEVICE_BACKUP_PATH, backup, nil, "600")
    if not saved then return nil, save_error end
    return backup
end

local function grant_background(package_name)
    local failures = 0
    local _, whitelisted = root("cmd deviceidle whitelist +" .. Core.shell_quote(package_name), true)
    if not whitelisted then failures = failures + 1 end
    for _, operation in ipairs(BACKGROUND_OPS) do
        local _, allowed = root(string.format("appops set %s %s allow",
            Core.shell_quote(package_name), operation), true)
        if not allowed then failures = failures + 1 end
    end
    return failures
end

local function optimize_device()
    local backup, backup_error = save_device_backup()
    if not backup then
        log("ERROR", "Device optimization cancelled before changes: " .. tostring(backup_error))
        return false
    end
    local expected_settings = {
        window_animation_scale = "0", transition_animation_scale = "0", animator_duration_scale = "0",
        low_power = "0", low_power_trigger_level = "0", adaptive_battery_management_enabled = "0",
        app_standby_enabled = "0", app_auto_restriction_enabled = "0", forced_app_standby_enabled = "0",
        force_resizable_activities = "1", enable_freeform_support = "1", enable_non_resizable_multi_window = "1",
    }
    local warnings, profile_warnings = 0, 0
    if not config.optimization_applied then
        log("INFO", "Applying Noka's root device profile")
        for key, value in pairs(expected_settings) do write_setting("global", key, value) end
        root("cmd deviceidle disable", true)
        root("setprop persist.logd.size 65536", true)
        root("setprop persist.log.tag Settings", true)
        root("setprop persist.log.tag.snet_event_log I", true)
        root("setprop ctl.start logd-reinit", true)
        root("pm disable-user --user 0 " .. PLAY_STORE_PACKAGE, true)
    end
    warnings = warnings + grant_background(config.termux_package)
    for _, entry in ipairs(config.packages) do warnings = warnings + grant_background(entry.package) end
    local _, wake_locked = command("termux-wake-lock")
    if not wake_locked then warnings = warnings + 1; log("WARN", "Termux wake lock could not be acquired") end
    do
        for key, expected in pairs(expected_settings) do
            if read_setting("global", key) ~= expected then
                warnings = warnings + 1
                profile_warnings = profile_warnings + 1
                log("WARN", "Device firmware rejected global setting: " .. key)
            end
        end
        local disabled = root("pm list packages -d --user 0", true)
        if not disabled:find("package:" .. PLAY_STORE_PACKAGE, 1, true) then
            warnings = warnings + 1
            profile_warnings = profile_warnings + 1
            log("WARN", "Google Play Store could not be disabled on this firmware")
        end
        if read_property("persist.log.tag"):sub(1, 8) ~= "Settings" then
            warnings = warnings + 1
            profile_warnings = profile_warnings + 1
            log("WARN", "The firmware rejected the Developer Options log-buffer setting")
        end
        local deviceidle = root("cmd deviceidle enabled", true)
        if tostring(deviceidle):match("1") then
            warnings = warnings + 1
            profile_warnings = profile_warnings + 1
            log("WARN", "Android device-idle mode is still enabled")
        end
    end
    config.optimization_applied = profile_warnings == 0
    local config_saved, config_error = save_config(config)
    if not config_saved then
        log("ERROR", "Could not record optimization state: " .. tostring(config_error))
        return false
    end
    log("INFO", string.format("Device profile applied with %d warning(s); Google Play services were not changed", warnings))
    return true
end

local function restore_device()
    if not have_root() then log("ERROR", "Root is required to restore device settings"); return false end
    local backup = load_lua_table(DEVICE_BACKUP_PATH)
    if not backup then log("ERROR", "No Noka device backup exists"); return false end
    local failures = 0
    local function restored_command(command_line)
        local _, ok = root(command_line, true)
        if not ok then failures = failures + 1 end
        return ok
    end
    for compound, value in pairs(backup.settings or {}) do
        local namespace, key = compound:match("^([^:]+):(.+)$")
        if namespace and key then
            if value == "null" or value == "" then
                restored_command(string.format("settings delete %s %s", namespace, Core.shell_quote(key)))
            else
                local _, ok = write_setting(namespace, key, value)
                if not ok then failures = failures + 1 end
            end
        else
            failures = failures + 1
        end
    end
    for key, value in pairs(backup.properties or {}) do
        restored_command("setprop " .. Core.shell_quote(key) .. " " .. Core.shell_quote(value))
    end
    restored_command("setprop ctl.start logd-reinit")
    if not backup.play_store_disabled then restored_command("pm enable --user 0 " .. PLAY_STORE_PACKAGE) end
    if tostring(backup.deviceidle):match("1") then restored_command("cmd deviceidle enable") end
    for package_name, controls in pairs(backup.package_controls or {}) do
        if Core.is_package_name(package_name) and type(controls) == "table" then
            local _, installed = root("pm path " .. Core.shell_quote(package_name), true)
            if installed then
                if not controls.whitelisted then
                    restored_command("cmd deviceidle whitelist -" .. Core.shell_quote(package_name))
                end
                for operation, mode in pairs(controls.appops or {}) do
                    if tostring(operation):match("^[A-Z_]+$") and tostring(mode):match("^[%w_]+$") then
                        restored_command(string.format("appops set %s %s %s", Core.shell_quote(package_name), operation,
                            Core.shell_quote(mode)))
                    else
                        failures = failures + 1
                    end
                end
            else
                log("INFO", "Skipping restore for uninstalled package " .. package_name)
            end
        else
            failures = failures + 1
        end
    end
    local _, wake_unlocked = command("termux-wake-unlock")
    if not wake_unlocked then log("WARN", "Termux wake lock could not be released") end
    if failures == 0 then
        config.optimization_applied = false
        local saved, save_error = save_config(config)
        if not saved then
            log("ERROR", "Device was restored, but configuration could not be updated: " .. tostring(save_error))
            return false
        end
        log("INFO", "Restored the recorded pre-Noka device settings")
        return true
    end
    log("ERROR", string.format("Device restore completed with %d failed operation(s); rerun --restore-device", failures))
    return false
end

local HEARTBEAT_MARKER = "NOKA_LOCALPLAYER_HEARTBEAT"
-- Rejoin: the heartbeat is NOT downloaded on every start. An existing copy in
-- an executor autoexecute folder is reused as-is; the project page is only
-- contacted when no valid copy is installed yet. Every source passes the
-- marker check before use.
local function fetch_heartbeat_source()
    -- Declared inside so the main chunk stays under Lua's 200-local ceiling.
    local HEARTBEAT_SOURCE_URL =
        "https://raw.githubusercontent.com/7cela7/nokatool/refs/heads/main/noka-heartbeat.lua"
    local target = STATE_DIR .. "/noka_heartbeat.lua"

    local function accept(contents, description)
        if not contents or #contents == 0 or #contents > 512 * 1024
            or not contents:find(HEARTBEAT_MARKER, 1, true) then
            return nil
        end
        local written, write_error = write_file_atomic(target, contents, "600")
        if not written then
            log("WARN", "heartbeat could not be staged from " .. description .. ": "
                .. tostring(write_error))
            return nil
        end
        return target
    end

    -- 1) An already-installed copy in an executor autoexecute folder wins.
    local layout = discover_executor_layout(false)
    for _, directory in ipairs(layout.autoexecute) do
        local candidate = directory .. "/noka_heartbeat.lua"
        local contents = read_file_limited(candidate, 512 * 1024)
        if contents then
            local staged = accept(contents, candidate)
            if staged then
                log("INFO", "Using the heartbeat already installed in " .. directory)
                return staged
            end
            log("WARN", "ignoring " .. candidate .. ": not a valid Noka heartbeat")
        end
    end

    -- 2) Nothing installed yet: fetch it from the project page once.
    local body, code, request_error = http_get(HEARTBEAT_SOURCE_URL, 30)
    if code == "200" and body then
        local staged = accept(body, "the project page download")
        if staged then
            log("INFO", "Heartbeat script downloaded from the project page")
            return staged
        end
    end
    log("WARN", "heartbeat download failed (" .. tostring(code or request_error or "no response") .. ")")

    return nil, "no usable heartbeat was found; connect to the internet so the project page"
        .. " download can run"
end

local function install_heartbeat()
    local layout = discover_executor_layout(true)
    if #layout.roots == 0 then
        return nil, "no supported executor storage was found (expected Delta or Arceus X)"
    end
    local active_autoexecute = active_autoexecute_directories()

    local heartbeat_source, source_error = fetch_heartbeat_source()
    if not heartbeat_source then return nil, source_error end

    local directories = {}
    for _, path in ipairs(active_autoexecute) do
        directories[#directories + 1] = Core.shell_quote(path)
    end
    for _, path in ipairs(active_executor_workspaces()) do
        directories[#directories + 1] = Core.shell_quote(path .. "/Noka/heartbeats")
    end
    local _, directories_ok = root("mkdir -p " .. table.concat(directories, " "), true)
    if not directories_ok then
        return nil, "could not create executor auto-execute directories"
    end

    -- Remove old generic noka.lua files only when their contents identify them
    -- as this heartbeat. A user's unrelated auto-execute file is never deleted.
    for _, path in ipairs(layout.all_autoexecute) do
        local legacy_path = path .. "/noka.lua"
        local legacy = read_file(legacy_path, "rb")
        if legacy and legacy:find("NOKA_LOCALPLAYER_HEARTBEAT", 1, true) then
            os.remove(legacy_path)
        end
    end

    for _, path in ipairs(active_autoexecute) do
        local destination = path .. "/noka_heartbeat.lua"
        local temporary = destination .. ".noka.tmp"
        local operation = "cp " .. Core.shell_quote(heartbeat_source) .. " " .. Core.shell_quote(temporary)
            .. " && chmod 0644 " .. Core.shell_quote(temporary)
            .. " && cmp -s " .. Core.shell_quote(heartbeat_source) .. " " .. Core.shell_quote(temporary)
            .. " && mv -f " .. Core.shell_quote(temporary) .. " " .. Core.shell_quote(destination)
        local _, copied = root(operation, true)
        if not copied then
            root("rm -f " .. Core.shell_quote(temporary), true)
            return nil, "could not activate Noka heartbeat in " .. path
        end
    end
    return true
end

local function screen_size()
    local display_windows = root("dumpsys window displays", true)
    local all_windows = root("dumpsys window windows", true)
    local policy = root("dumpsys window policy", true)
    local windows = display_windows .. "\n" .. all_windows .. "\n" .. policy
    local displays = root("dumpsys display", true)
    local wm = root("wm size", true)
    local rotation = root("dumpsys input", true)
    local probe = temporary_path("display-probe") .. ".png"
    local _, captured = root("screencap -p " .. Core.shell_quote(probe)
        .. " && chmod 0600 " .. Core.shell_quote(probe), true)
    local framebuffer_width, framebuffer_height
    if captured then
        local handle = io.open(probe, "rb")
        local header = handle and handle:read(24)
        if handle then handle:close() end
        framebuffer_width, framebuffer_height = Core.parse_png_dimensions(header)
    end
    os.remove(probe)
    if framebuffer_width and framebuffer_height then
        windows = string.format("DisplayFrames w=%d h=%d\n", framebuffer_width, framebuffer_height) .. windows
    end
    local width, height, left, top, right, bottom = Core.parse_display_geometry(windows, displays, wm, rotation)

    local function window_frame(name)
        local search_from = 1
        while true do
            local start = windows:find(name, search_from, true)
            if not start then return nil end
            local block = windows:sub(start, math.min(#windows, start + 2200))
            local l, t, r, b = block:match("mFrame=%[(%-?%d+),(%-?%d+)%]%[(%-?%d+),(%-?%d+)%]")
            if not l then
                l, t, r, b = block:match("frame=%[(%-?%d+),(%-?%d+)%]%[(%-?%d+),(%-?%d+)%]")
            end
            if l then return tonumber(l), tonumber(t), tonumber(r), tonumber(b) end
            search_from = start + #name
        end
    end

    if top == 0 then
        local _, status_top, _, status_bottom = window_frame("StatusBar")
        if status_top == 0 and status_bottom and status_bottom > 0 and status_bottom < height / 4 then
            top = status_bottom
        elseif height < width then
            top = 25
        else
            -- No stable inset and no StatusBar frame were reported. Fall back
            -- to the framework default: the status bar is 24 DENSITY-INDEPENDENT
            -- pixels, not 24 physical pixels (36px @240dpi, 48px @320dpi, and so
            -- on), so the dp value is converted with the real panel density.
            local density_output = root("wm density", true)
            local density = tonumber(density_output:match("Override density:%s*(%d+)"))
                or tonumber(density_output:match("Physical density:%s*(%d+)"))
                or tonumber((root("getprop ro.sf.lcd_density", true)))
            if density and density >= 120 and density <= 1000 then
                top = math.max(24, math.floor(24 * density / 160 + 0.5))
                log("INFO", string.format(
                    "StatusBar inset unavailable; using the %ddp framework default at %ddpi (%dpx)",
                    24, density, top))
            end
        end
    end
    if right == 0 then
        local nav_left, nav_top, nav_right, nav_bottom = window_frame("NavigationBar")
        if nav_left and nav_right == width and nav_left > width / 2
            and nav_top == 0 and nav_bottom == height then
            right = width - nav_left
        end
    end
    return width, height, left, top, right, bottom
end

local function load_bounds_manifest()
    local manifest, manifest_error = load_lua_table(BOUNDS_MANIFEST_PATH)
    if file_exists(BOUNDS_MANIFEST_PATH) and type(manifest) ~= "table" then
        return nil, "bounds backup manifest is unreadable: " .. tostring(manifest_error)
    end
    manifest = type(manifest) == "table" and manifest or { version = 1, entries = {} }
    manifest.entries = type(manifest.entries) == "table" and manifest.entries or {}
    return manifest
end

local function save_bounds_manifest(manifest)
    return save_lua_table(BOUNDS_MANIFEST_PATH, manifest, nil, "600")
end

local function patch_app_cloner_preferences(package_name, bounds)
    local exact_paths = {
        "/data/data/" .. package_name .. "/shared_prefs/" .. package_name .. "_preferences.xml",
        "/data/user/0/" .. package_name .. "/shared_prefs/" .. package_name .. "_preferences.xml",
    }
    local path
    for _, candidate in ipairs(exact_paths) do
        local _, exists = root("test -f " .. Core.shell_quote(candidate), true)
        if exists then path = candidate; break end
    end
    if not path then return nil, nil, 0, "exact App Cloner preferences XML was not found" end

    local manifest, manifest_error = load_bounds_manifest()
    if not manifest then return nil, path, 0, manifest_error end
    local content, read_error = read_file_limited(path, 16 * 1024 * 1024)
    if not content or content == "" then
        return nil, path, 0, "preferences XML could not be read: " .. tostring(read_error)
    end
    local patched, changes, patch_error = Core.patch_app_cloner_bounds(content, bounds)
    if not patched or changes ~= 4 then return nil, path, 0, patch_error or "four exact keys were not found" end

    local temporary = temporary_path("app-cloner-bounds-" .. package_name)
    local staged, stage_error = write_file(temporary, patched, "wb")
    if not staged then return nil, path, 0, tostring(stage_error) end
    os.execute("chmod 600 " .. Core.shell_quote(temporary))

    local android_backup = path .. ".bak"
    local noka_backup = path .. ".noka.bak"
    local android_noka_backup = android_backup .. ".noka.bak"
    local qpath, qtemporary = Core.shell_quote(path), Core.shell_quote(temporary)
    local qandroid_backup = Core.shell_quote(android_backup)
    local main_swap = path .. ".noka.tmp"
    local android_swap = android_backup .. ".noka.tmp"
    local main_rollback = path .. ".noka.rollback"
    local android_rollback = android_backup .. ".noka.rollback"
    local transaction_files = table.concat({ Core.shell_quote(main_swap), Core.shell_quote(android_swap),
        Core.shell_quote(main_rollback), Core.shell_quote(android_rollback) }, " ")

    local function rollback(reason, confirmed)
        local rollback_command = "set -e; if test -e " .. Core.shell_quote(main_rollback)
            .. "; then cp -p " .. Core.shell_quote(main_rollback) .. " " .. qpath .. "; fi"
            .. "; if test -e " .. Core.shell_quote(android_rollback) .. "; then cp -p "
            .. Core.shell_quote(android_rollback) .. " " .. qandroid_backup .. "; fi"
            .. "; restorecon " .. qpath .. " " .. qandroid_backup .. " 2>/dev/null || true; sync"
        local rollback_output, rollback_ok = root(rollback_command, true)
        if rollback_ok then root("rm -f " .. transaction_files, true) end
        local suffix = rollback_ok and "; pre-change XML restored"
            or "; ROLLBACK FAILED (snapshots retained): " .. tostring(rollback_output)
        return nil, path, confirmed or 0, reason .. suffix
    end

    -- Recover an interrupted prior transaction before taking a fresh snapshot.
    local write_command = "set -e; if test -e " .. Core.shell_quote(main_rollback)
        .. "; then cp -p " .. Core.shell_quote(main_rollback) .. " " .. qpath .. "; fi"
        .. "; if test -e " .. Core.shell_quote(android_rollback) .. "; then cp -p "
        .. Core.shell_quote(android_rollback) .. " " .. qandroid_backup .. "; fi"
        .. "; rm -f " .. transaction_files
        .. "; test -e " .. Core.shell_quote(noka_backup) .. " || cp -p "
        .. qpath .. " " .. Core.shell_quote(noka_backup)
        .. "; cp -p " .. qpath .. " " .. Core.shell_quote(main_rollback)
        .. "; cp -p " .. qpath .. " " .. Core.shell_quote(main_swap)
        .. "; cat " .. qtemporary .. " > " .. Core.shell_quote(main_swap)
        .. "; mv -f " .. Core.shell_quote(main_swap) .. " " .. qpath
        .. "; if test -e " .. qandroid_backup .. "; then test -e " .. Core.shell_quote(android_noka_backup)
        .. " || cp -p " .. qandroid_backup .. " " .. Core.shell_quote(android_noka_backup)
        .. "; cp -p " .. qandroid_backup .. " " .. Core.shell_quote(android_rollback)
        .. "; cp -p " .. qandroid_backup .. " " .. Core.shell_quote(android_swap)
        .. "; cat " .. qtemporary .. " > " .. Core.shell_quote(android_swap)
        .. "; mv -f " .. Core.shell_quote(android_swap) .. " " .. qandroid_backup .. "; fi"
        .. "; restorecon " .. qpath .. " " .. qandroid_backup .. " 2>/dev/null || true; sync"
    local write_output, written = root(write_command, true)
    os.remove(temporary)
    if not written then
        return rollback("XML transaction failed: " .. tostring(write_output), 0)
    end

    local verified = read_file_limited(path, 16 * 1024 * 1024)
    local confirmed = verified and Core.confirm_app_cloner_bounds(verified, bounds) or 0
    if confirmed ~= 4 or verified ~= patched then
        return rollback("main XML read-back mismatch", confirmed)
    end
    if file_exists(android_backup) then
        local backup_content = read_file_limited(android_backup, 16 * 1024 * 1024)
        local backup_confirmed = backup_content and Core.confirm_app_cloner_bounds(backup_content, bounds) or 0
        if backup_confirmed ~= 4 or backup_content ~= patched then
            return rollback("Android SharedPreferences .bak read-back mismatch", confirmed)
        end
    end

    manifest.entries[path] = noka_backup
    if file_exists(android_noka_backup) then manifest.entries[android_backup] = android_noka_backup end
    local manifest_saved, manifest_save_error = save_bounds_manifest(manifest)
    if not manifest_saved then
        return rollback("could not record bounds backup: " .. tostring(manifest_save_error), confirmed)
    end
    root("rm -f " .. transaction_files, true)
    return true, path, confirmed
end

local function confirm_saved_bounds(path, bounds)
    local content = read_file_limited(path, 16 * 1024 * 1024)
    if not content then return false, 0, {} end
    local confirmed, actual = Core.confirm_app_cloner_bounds(content, bounds)
    return confirmed == 4, confirmed, actual
end

local function restore_bounds()
    if not have_root() then log("ERROR", "Root is required to restore App Cloner preferences"); return false end
    local manifest, manifest_error = load_bounds_manifest()
    if not manifest then log("ERROR", manifest_error); return false end
    local entries = copy_table(manifest.entries)
    -- Import backups created by pre-rewrite builds for packages that are still
    -- configured, so upgrading does not strand a valid restore point.
    for _, entry in ipairs(config.packages) do
        for _, base in ipairs({ "/data/data/", "/data/user/0/" }) do
            local original = base .. entry.package .. "/shared_prefs/" .. entry.package .. "_preferences.xml"
            if file_exists(original .. ".noka.bak") then entries[original] = original .. ".noka.bak" end
            if file_exists(original .. ".bak.noka.bak") then
                entries[original .. ".bak"] = original .. ".bak.noka.bak"
            end
        end
    end

    local function safe_restore_pair(original, backup)
        if type(original) ~= "string" or type(backup) ~= "string" or backup ~= original .. ".noka.bak" then
            return false
        end
        local package_name = original:match("^/data/user/0/([^/]+)/shared_prefs/")
            or original:match("^/data/data/([^/]+)/shared_prefs/")
        return package_name ~= nil and Core.is_package_name(package_name)
    end

    local restored = 0
    local rejected = 0
    for original, backup in pairs(entries) do
        if safe_restore_pair(original, backup) and file_exists(backup) then
            local swap = original .. ".noka.restore"
            local _, ok = root("cp -p " .. Core.shell_quote(backup) .. " " .. Core.shell_quote(swap)
                .. " && mv -f " .. Core.shell_quote(swap) .. " " .. Core.shell_quote(original)
                .. " && { restorecon " .. Core.shell_quote(original) .. " 2>/dev/null || true; }", true)
            if ok then restored = restored + 1 else root("rm -f " .. Core.shell_quote(swap), true) end
        else
            rejected = rejected + 1
        end
    end
    log("INFO", string.format("Restored %d App Cloner preference backup(s); rejected %d invalid/missing entry(s)",
        restored, rejected))
    return rejected == 0
end

local function resolve_activity(package_name, action, category, uri)
    local parts = { "cmd package resolve-activity --brief --user 0", "-a", Core.shell_quote(action) }
    if category then parts[#parts + 1] = "-c"; parts[#parts + 1] = Core.shell_quote(category) end
    if uri then parts[#parts + 1] = "-d"; parts[#parts + 1] = Core.shell_quote(uri) end
    parts[#parts + 1] = "-p"
    parts[#parts + 1] = Core.shell_quote(package_name)
    local output, ok = root(table.concat(parts, " "), true)
    if not ok then return nil end
    local component
    for line in output:gmatch("[^\r\n]+") do
        if line:match("^[%w%._]+/[%w%._$]+$") then component = line end
    end
    if component and component:match("^" .. package_name:gsub("%.", "%%.") .. "/") then return component end
end

local function terminate_clone(entry)
    local task_ids = {}
    for _, dump_command in ipairs({ "dumpsys activity activities", "dumpsys activity recents" }) do
        local dump = root(dump_command, true)
        local current_task
        for line in dump:gmatch("[^\r\n]+") do
            local task = line:match("%sTask[^#]*#(%d+)") or line:match("taskId=(%d+)")
                or line:match("Task%{[^#]*#(%d+)")
            if task then current_task = tonumber(task) end
            if current_task and line:find(entry.package, 1, true) then task_ids[current_task] = true end
        end
    end
    local output, stopped = root(SYSTEM_AM .. " force-stop --user 0 " .. Core.shell_quote(entry.package), true)
    if not stopped then return nil, output end
    -- Removing a stale task clears its old windowing mode. This command never
    -- supplies bounds; App Cloner's four XML values remain the only sizing path.
    for task_id in pairs(task_ids) do root(SYSTEM_AM .. " task remove " .. tostring(task_id), true) end
    for _ = 1, 20 do
        local pids = root("pidof " .. Core.shell_quote(entry.package), true)
        if pids == "" then return true end
        root(Core.shell_quote(TERMUX_SLEEP) .. " 0.1", true)
    end
    local pids = root("pidof " .. Core.shell_quote(entry.package), true)
    if pids ~= "" then
        local numeric = {}
        for pid in pids:gmatch("%d+") do numeric[#numeric + 1] = pid end
        if #numeric > 0 then root("kill -9 " .. table.concat(numeric, " ") .. " 2>/dev/null || true", true) end
        root(Core.shell_quote(TERMUX_SLEEP) .. " 0.1", true)
    end
    if root("pidof " .. Core.shell_quote(entry.package), true) ~= "" then
        return nil, "clone processes remained after force-stop"
    end
    return true
end

local function launch_homepage(entry)
    local component = resolve_activity(entry.package, "android.intent.action.MAIN", "android.intent.category.LAUNCHER")
    if not component then return nil, "launcher activity could not be resolved" end
    local command_line = SYSTEM_AM .. " start -W --user 0 -n "
        .. Core.shell_quote(component)
    local output, ok = root(command_line, true)
    if not ok or output:find("Error:", 1, true) or output:find("Exception", 1, true) then return nil, output end
    return true, output
end

local function write_launch_marker(entry, token)
    local payload = Core.json_encode({
        package = entry.package,
        token = token,
        target_uri = entry.target.uri,
        launched_at = os.time(),
    })
    local temporary = temporary_path("current-launch")
    local staged, stage_error = write_file(temporary, payload, "wb")
    if not staged then return nil, stage_error end
    os.execute("chmod 600 " .. Core.shell_quote(temporary))
    local operations, marker_temporaries = {}, {}
    for _, workspace in ipairs(active_executor_workspaces()) do
        local noka_dir = workspace .. "/Noka"
        local marker_path = noka_dir .. "/current_launch.json"
        local marker_temporary = marker_path .. ".noka.tmp"
        marker_temporaries[#marker_temporaries + 1] = marker_temporary
        local heartbeat_name = entry.package:gsub("[^%w%._%-]", "_") .. ".json"
        operations[#operations + 1] = "mkdir -p " .. Core.shell_quote(noka_dir .. "/heartbeats")
        operations[#operations + 1] = "rm -f "
            .. Core.shell_quote(noka_dir .. "/heartbeats/" .. heartbeat_name) .. " "
            .. Core.shell_quote(noka_dir .. "/heartbeats/" .. heartbeat_name .. ".next")
        operations[#operations + 1] = "cp " .. Core.shell_quote(temporary) .. " " .. Core.shell_quote(marker_temporary)
        operations[#operations + 1] = "chmod 0644 " .. Core.shell_quote(marker_temporary)
        operations[#operations + 1] = "mv -f " .. Core.shell_quote(marker_temporary) .. " " .. Core.shell_quote(marker_path)
    end
    local command_line = "set -e; " .. table.concat(operations, "; ")
    local output, ok = root(command_line, true)
    os.remove(temporary)
    if not ok then
        local quoted = {}
        for _, path in ipairs(marker_temporaries) do quoted[#quoted + 1] = Core.shell_quote(path) end
        if #quoted > 0 then root("rm -f " .. table.concat(quoted, " "), true) end
    end
    return ok, output
end

local function launch_game(entry)
    local command_line = SYSTEM_AM .. " start -W --user 0"
        .. " -a android.intent.action.VIEW -c android.intent.category.BROWSABLE"
        .. " -d " .. Core.shell_quote(entry.target.uri)
        .. " -p " .. Core.shell_quote(entry.package)
    local output, ok = root(command_line, true)
    if ok and not output:find("Error:", 1, true) and not output:find("Exception", 1, true) then
        return true, output
    end

    local component = resolve_activity(entry.package, "android.intent.action.VIEW",
        "android.intent.category.BROWSABLE", entry.target.uri)
    if not component then
        return nil, "package-scoped launch failed and the clone has no Roblox VIEW activity: " .. tostring(output)
    end
    local fallback = SYSTEM_AM .. " start -W --user 0"
        .. " -n " .. Core.shell_quote(component)
        .. " -a android.intent.action.VIEW -c android.intent.category.BROWSABLE"
        .. " -d " .. Core.shell_quote(entry.target.uri)
    local fallback_output, fallback_ok = root(fallback, true)
    if not fallback_ok or fallback_output:find("Error:", 1, true)
        or fallback_output:find("Exception", 1, true) then
        return nil, tostring(output) .. " | explicit fallback: " .. tostring(fallback_output)
    end
    return true, fallback_output
end

local read_heartbeat
local solver_solve_entry
local autoblock_run
-- Rejoin: async solver machinery lives further down (next to the sync solver
-- code) and is forward-declared here so the sequence can use it.
local spawn_background_solver
local read_solver_result
local wait_for_solver_result
-- Rejoin: cookie helpers live in the cookie section below; the join gate in
-- run_sequence probes them when no solver is configured.
local cookie_db_path
local read_roblosecurity
local launch_token_counter = 0

local function new_launch_token()
    launch_token_counter = launch_token_counter + 1
    local random_uuid = read_file("/proc/sys/kernel/random/uuid", "r")
    random_uuid = random_uuid and Core.trim(random_uuid) or ""
    if random_uuid:match("^[%x%-]+$") then
        return string.format("%s-%d", random_uuid, launch_token_counter)
    end
    return string.format("%d-%d-%d", os.time(), math.floor((uptime_seconds() or 0) * 1000),
        launch_token_counter)
end

local function restart_and_join(entry, state, reason)
    local now, monotonic_now = os.time(), uptime_seconds() or os.time()
    if state.last_attempt_monotonic
        and monotonic_now - state.last_attempt_monotonic < config.recovery_cooldown then
        return false, "recovery cooldown is active"
    end
    state.last_attempt_monotonic = monotonic_now
    if solver_enabled() and now - (state.solver_attempted_at or 0) >= 600 then
        state.solver_attempted_at = now
        local solved = solver_solve_entry(entry, state.heartbeat and state.heartbeat.player or nil)
        if solved then state.solved_at = os.time() end
    end

    local stopped, stop_error = terminate_clone(entry)
    if not stopped then
        log("ERROR", entry.package .. ": full termination failed: " .. tostring(stop_error))
        return false
    end
    local preference_path
    if resize_enabled() then
        local saved, path, confirmed, save_error = patch_app_cloner_preferences(entry.package, state.bounds)
        if not saved or confirmed ~= 4 then
            log("ERROR", entry.package .. ": XML bounds save failed before restart: " .. tostring(save_error))
            return false
        end
        preference_path = path
        state.preference_path = path
    end
    local token = new_launch_token()
    local marker_ok, marker_error = write_launch_marker(entry, token)
    if not marker_ok then
        log("ERROR", entry.package .. ": marker write failed: " .. tostring(marker_error))
        return false, marker_error
    end
    local opened, open_result = launch_homepage(entry)
    if not opened then
        terminate_clone(entry)
        log("ERROR", entry.package .. ": homepage launch failed: " .. tostring(open_result))
        return false
    end
    if preference_path then
        local persisted, persisted_count = confirm_saved_bounds(preference_path, state.bounds)
        if not persisted then
            terminate_clone(entry)
            log("ERROR", string.format("%s: clone changed its XML bounds during launch (%d/4 remain); stopped",
                entry.package, persisted_count))
            return false
        end
    end
    log("INFO", string.format("%s: homepage opened; waiting %.1f second(s)",
        entry.package, tonumber(config.launch_delay) or 5))
    if not wait_or_stop(config.launch_delay) then terminate_clone(entry); return false end
    if stop_requested() then terminate_clone(entry); return false end

    local joined, join_result = launch_game(entry)
    if not joined then
        terminate_clone(entry)
        log("ERROR", entry.package .. ": game launch failed: " .. tostring(join_result))
        return false
    end
    state.token = token
    state.last_launch = os.time()
    state.grace_until = state.last_launch + config.startup_grace
    state.reason = reason or "scheduled join"
    state.failure_counts = {}
    log("INFO", entry.package .. ": roblox:// intent delivered (" .. state.reason .. "): "
        .. tostring(join_result):gsub("[\r\n]+", " | "))

    -- Do not overwrite the shared launch marker for the next clone until this
    -- clone's separate Autoexec heartbeat has claimed its package/token.
    log("INFO", entry.package .. ": waiting for LocalPlayer heartbeat (press END to cancel)")
    local registration_started = uptime_seconds() or os.time()
    local registration_timeout = math.max(30,
        tonumber(config.registration_timeout) or DEFAULT_REGISTRATION_TIMEOUT)
    while (uptime_seconds() or os.time()) - registration_started < registration_timeout do
        if stop_requested() then terminate_clone(entry); return false end
        local heartbeat = read_heartbeat and read_heartbeat(entry.package, token) or nil
        if heartbeat and heartbeat.token == token
            and heartbeat.timestamp and heartbeat.timestamp >= state.last_launch - 5 then
            state.heartbeat = heartbeat
            state.online = true
            log("INFO", entry.package .. ": LocalPlayer heartbeat registered")
            return true
        end
        if not wait_or_stop(1) then terminate_clone(entry); return false end
    end
    terminate_clone(entry)
    local timeout_message = string.format("heartbeat did not register within %.0f seconds; clone stopped",
        registration_timeout)
    log("ERROR", entry.package .. ": " .. timeout_message)
    return false, timeout_message
end

local function close_warm_tasks()
    for _, entry in ipairs(config.packages) do terminate_clone(entry) end
    root(SYSTEM_INPUT .. " keyevent 3", true)
end

-- Rejoin: one root spawn can answer many probes. Each spec prints a sentinel
-- line, then its command; the combined output is parsed back per key.
local function run_batched(specs)
    if #specs == 0 then return {} end
    local pieces = {}
    for index, spec in ipairs(specs) do
        pieces[#pieces + 1] = "printf '__NK" .. index .. "__\\n'; " .. spec.shell
    end
    local output = root(table.concat(pieces, "; "), true)
    local results = {}
    local current, buffers = nil, {}
    for line in (output .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        local marker = line:match("^__NK(%d+)__$")
        if marker and specs[tonumber(marker)] then
            current = tonumber(marker)
            buffers[current] = {}
        elseif current and specs[current] then
            local buffer = buffers[current]
            buffer[#buffer + 1] = line
        end
    end
    for index, spec in ipairs(specs) do
        results[spec.key] = Core.trim(table.concat(buffers[index] or {}, "\n"))
    end
    return results
end

-- Per-cycle process snapshot: two root spawns total (pids, then stats) no
-- matter how many clones are supervised; heartbeat files stay direct reads.
local process_probe_cache = nil
local function refresh_process_probes(packages)
    if #packages == 0 then process_probe_cache = { pids = {}, stats = {} } return end
    local pid_specs = {}
    for index, package_name in ipairs(packages) do
        pid_specs[index] = { key = "pid:" .. package_name,
            shell = "pidof " .. Core.shell_quote(package_name) }
    end
    local pid_results = run_batched(pid_specs)
    local stat_specs = {
        { key = "_cpu", shell = "head -1 /proc/stat" },
        { key = "_mem", shell = "cat /proc/meminfo" },
    }
    for _, package_name in ipairs(packages) do
        for value in (pid_results["pid:" .. package_name] or ""):gmatch("%d+") do
            local pid = tostring(value)
            stat_specs[#stat_specs + 1] = { key = "rss:" .. package_name .. ":" .. pid,
                shell = "cat /proc/" .. pid .. "/status 2>/dev/null" }
            stat_specs[#stat_specs + 1] = { key = "stat:" .. package_name .. ":" .. pid,
                shell = "cat /proc/" .. pid .. "/stat 2>/dev/null" }
        end
    end
    process_probe_cache = { pids = pid_results, stats = run_batched(stat_specs) }
end

local function read_process(package_name)
    if not process_probe_cache then return nil end
    local pids = {}
    for value in (process_probe_cache.pids["pid:" .. package_name] or ""):gmatch("%d+") do
        pids[#pids + 1] = tonumber(value)
    end
    if #pids == 0 then return nil end
    table.sort(pids)
    local rss, ticks, readable = 0, 0, 0
    for _, pid in ipairs(pids) do
        local status = process_probe_cache.stats["rss:" .. package_name .. ":" .. pid]
        local process_stat = process_probe_cache.stats["stat:" .. package_name .. ":" .. pid]
        if status and process_stat then
            rss = rss + (tonumber(status:match("VmRSS:%s*(%d+)%s+kB")) or 0)
            -- The process name may contain spaces or ')'; the greedy match uses
            -- the final closing parenthesis before the state field.
            local after_name = process_stat:match("^%d+ %(.+%) (.+)$") or ""
            local fields = {}
            for field in after_name:gmatch("%S+") do fields[#fields + 1] = field end
            ticks = ticks + (tonumber(fields[12]) or 0) + (tonumber(fields[13]) or 0)
            readable = readable + 1
        end
    end
    if readable == 0 then return nil end
    return pids[1], math.floor(rss / 1024 + 0.5), ticks
end

local function window_present(package_name, windows_dump)
    local start = 1
    while true do
        local position = windows_dump:find(package_name, start, true)
        if not position then return false end
        local before = position > 1 and windows_dump:sub(position - 1, position - 1) or ""
        local after_position = position + #package_name
        local after = windows_dump:sub(after_position, after_position)
        if not before:match("[%w_%.]") and not after:match("[%w_%.]") then
            local block = windows_dump:sub(math.max(1, position - 400), math.min(#windows_dump, position + 1400))
            if block:find("isOnScreen=true", 1, true) or block:find("isVisible=true", 1, true)
                or (block:find("mViewVisibility=0x0", 1, true) and block:find("mHasSurface=true", 1, true)) then
                return true
            end
        end
        start = position + #package_name
    end
end

read_heartbeat = function(package_name, expected_token)
    local file_name = package_name:gsub("[^%w%._%-]", "_") .. ".json"
    local best_match, best_any

    local function newer(candidate, current)
        if not current then return true end
        if candidate.timestamp ~= current.timestamp then return candidate.timestamp > current.timestamp end
        return (candidate.sequence or 0) > (current.sequence or 0)
    end

    for _, workspace in ipairs(active_executor_workspaces()) do
        for _, suffix in ipairs({ "", ".next" }) do
            local path = workspace .. "/Noka/heartbeats/" .. file_name .. suffix
            local candidate = read_file_limited(path, 64 * 1024)
            -- Ignore a file sampled midway through writefile(). The redundant
            -- copy normally remains complete while the other is replaced.
            if candidate and candidate ~= "" and candidate:match("%}%s*$") then
                local heartbeat = Core.json_decode(candidate)
                local valid_state = type(heartbeat) == "table"
                    and heartbeat.package == package_name
                    and type(heartbeat.timestamp) == "number"
                    and type(heartbeat.sequence) == "number"
                    and type(heartbeat.token) == "string"
                    and (heartbeat.state == "online" or heartbeat.state == "loading"
                        or heartbeat.state == "disconnected")
                    and type(heartbeat.online) == "boolean"
                    and type(heartbeat.transitioning) == "boolean"
                if valid_state then
                    if expected_token and heartbeat.token == expected_token then
                        if newer(heartbeat, best_match) then best_match = heartbeat end
                    elseif newer(heartbeat, best_any) then
                        best_any = heartbeat
                    end
                end
            end
        end
    end
    if expected_token then return best_match end
    return best_any
end

local function confirmed_monitor_failure(entry, state, key, failed, detail)
    state.failure_counts = state.failure_counts or {}
    local previous = state.failure_counts[key] or 0
    local count, confirmed = Core.advance_failure_count(previous, failed, FAILURE_CONFIRMATIONS)
    state.failure_counts[key] = count
    if failed and previous == 0 then
        log("WARN", string.format("%s: monitoring suspicion 1/%d (%s); waiting for confirmation",
            entry.package, FAILURE_CONFIRMATIONS, detail))
    elseif not failed and previous > 0 then
        log("INFO", string.format("%s: monitoring signal recovered after %d/%d miss(es) (%s)",
            entry.package, previous, FAILURE_CONFIRMATIONS, detail))
    end
    return confirmed
end

local cached_device_model
local function system_metrics()
    if not cached_device_model then
        local model = root("getprop ro.product.model", true)
        cached_device_model = model ~= "" and model or "Android device"
    end
    local meminfo = process_probe_cache and process_probe_cache.stats._mem
        or read_file("/proc/meminfo", "r") or ""
    local available = tonumber(meminfo:match("MemAvailable:%s*(%d+)"))
        or tonumber(meminfo:match("MemFree:%s*(%d+)")) or 0
    return {
        model = cached_device_model,
        ram_free_mb = math.floor(available / 1024 + 0.5),
    }
end

local previous_cpu
local function cpu_percent()
    local stat = (process_probe_cache and process_probe_cache.stats._cpu
        or read_file("/proc/stat", "r") or ""):match("[^\r\n]+") or ""
    local values = {}
    for value in stat:gmatch("%d+") do values[#values + 1] = tonumber(value) end
    if #values < 4 then return 0 end
    local idle = (values[4] or 0) + (values[5] or 0)
    local total = 0
    -- guest/guest_nice are already included in user/nice and must not be
    -- counted twice.
    for index = 1, math.min(8, #values) do total = total + values[index] end
    local percent = 0
    if previous_cpu and total > previous_cpu.total then
        percent = 100 * (1 - (idle - previous_cpu.idle) / (total - previous_cpu.total))
    end
    previous_cpu = { idle = idle, total = total }
    return math.max(0, math.min(100, percent))
end

local function capture_screen(path)
    local output, ok = root("screencap -p " .. Core.shell_quote(path), true)
    if not ok then return nil, output end
    root("chmod 0600 " .. Core.shell_quote(path), true)
    return true
end

local function truncate_utf8(text, maximum_bytes)
    text = tostring(text or "")
    maximum_bytes = maximum_bytes or #text
    if #text <= maximum_bytes then return text end
    local offset_ok, next_character = pcall(utf8.offset, text, 0, maximum_bytes + 1)
    if offset_ok and next_character then return text:sub(1, next_character - 1) end
    return text:sub(1, maximum_bytes):gsub("[\128-\255]+$", "")
end

local function discord_text(value, maximum_bytes)
    local text = tostring(value or ""):gsub("[%z\1-\31]", " ")
    text = text:gsub("([\\`*_~|<>])", "\\%1")
    return truncate_utf8(text, maximum_bytes)
end

-- Rejoin: total session uptime, formatted as requested — minutes below an
-- hour, whole hours up to a day (no minutes), then compact days+hours.
local SESSION_STARTED_AT = os.time()
local function format_total_uptime(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))
    if seconds < 3600 then
        return string.format("%dm", math.floor(seconds / 60))
    end
    local days = math.floor(seconds / 86400)
    if days >= 1 then
        return string.format("%dd%dh", days, math.floor((seconds % 86400) / 3600))
    end
    return string.format("%dh", math.floor(seconds / 3600))
end

local function build_webhook_payload(runtime, include_image)
    local metrics = system_metrics()
    local online = 0
    local details = {}
    for _, entry in ipairs(config.packages) do
        local state = runtime[entry.package]
        local status = state.online and "🟢" or "🔴"
        if state.online then online = online + 1 end
        local name = entry.package
        if not config.webhook_mask_usernames
            and state.heartbeat and state.heartbeat.player and state.heartbeat.player ~= "" then
            name = state.heartbeat.player
        end
        name = discord_text(name, 80)
        details[#details + 1] = string.format("%s **%s**\n└ ⏱️ %s  |  💾 %d MB  |  ⚡ %.1f%%",
            status, name, Core.format_duration(os.time() - (state.first_seen or os.time())),
            state.rss_mb or 0, state.process_cpu or 0)
    end
    local timestamp = os.time()
    local description = table.concat({
        string.format("Total Uptime: %s", format_total_uptime(os.time() - SESSION_STARTED_AT)),
        string.format("Last Updated: <t:%d:f>", timestamp),
        string.format("\n**Device Information:**\n📱┃Device: %s\n⚙️┃CPU: %.0f%%\n💾┃RAM: %d MB free",
            discord_text(metrics.model, 80), cpu_percent(), metrics.ram_free_mb),
        string.format("\n**Instance Status:**\n🤖┃Total: %d\n🟢┃Online: %d\n🔴┃Offline: %d",
            #config.packages, online, #config.packages - online),
        "\n**Application Details**\n" .. table.concat(details, "\n"),
    }, "\n")
    if #description > 4000 then
        description = truncate_utf8(description, 3950) .. "\n… additional instances omitted"
    end
    local payload = {
        username = "Noka",
        avatar_url = WEBHOOK_AVATAR_URL,
        allowed_mentions = { parse = Core.json_array({}) },
        embeds = Core.json_array({ {
            title = "📊 Noka Status Update",
            description = description,
            footer = { text = "discord.gg/noka" },
        } }),
    }
    if include_image then
        payload.attachments = Core.json_array({ {
            id = 0, filename = "noka-status.png", description = "Noka floating Roblox instances",
        } })
        payload.embeds[1].image = { url = "attachment://noka-status.png" }
    end
    return payload
end

local function discord_multipart(method, url, payload_path, screenshot_path)
    local response_path = temporary_path("discord-response")
    local config_path = temporary_path("discord-curl")
    local lines = {
        "silent", "show-error", "request = " .. method,
        "connect-timeout = 15", "max-time = 60", "max-filesize = 10485760",
        "url = " .. assert(curl_config_quote(url)),
        "output = " .. assert(curl_config_quote(response_path)),
        "write-out = \"%{http_code}\"",
        "form = " .. assert(curl_config_quote("payload_json=<" .. payload_path)),
    }
    if screenshot_path then
        lines[#lines + 1] = "form = "
            .. assert(curl_config_quote("files[0]=@" .. screenshot_path .. ";type=image/png"))
    end
    local configured, config_error = write_file(config_path, table.concat(lines, "\n") .. "\n", "wb")
    if not configured then return nil, nil, config_error end
    os.execute("chmod 600 " .. Core.shell_quote(config_path))
    local status_output, ok, exit_code = command("curl -q --config " .. Core.shell_quote(config_path))
    local response = read_file(response_path, "rb") or ""
    os.remove(config_path)
    os.remove(response_path)
    local status = status_output:match("(%d%d%d)%s*$")
    if not ok then return response, status, "curl failed (" .. tostring(exit_code) .. "): " .. status_output end
    return response, status
end

-- Rejoin: status updates are fresh messages by default; the single-message
-- edit mode is an explicit opt-in (webhook_edit_enabled) with a 10 second
-- floor instead of the 60 second new-message floor.
local function effective_webhook_interval()
    local interval = tonumber(config.webhook_interval) or 300
    local minimum = config.webhook_edit_enabled and 10 or 60
    return math.max(minimum, interval)
end

local function send_webhook(runtime)
    if config.webhook_url == "" then return true end
    local attempted_screenshot_path = temporary_path("noka-status") .. ".png"
    local screenshot_ok = capture_screen(attempted_screenshot_path)
    local screenshot_path = screenshot_ok and attempted_screenshot_path or nil
    if not screenshot_ok then os.remove(attempted_screenshot_path) end
    local payload_path = temporary_path("webhook-payload")
    local payload = Core.json_encode(build_webhook_payload(runtime, screenshot_path ~= nil))
    local payload_ok, payload_error = write_file(payload_path, payload, "wb")
    if not payload_ok then
        if screenshot_path then os.remove(screenshot_path) end
        log("WARN", "Discord update could not be staged: " .. tostring(payload_error))
        return false
    end
    os.execute("chmod 600 " .. Core.shell_quote(payload_path))

    local response, code, request_error = discord_multipart(
        "POST", config.webhook_url .. "?wait=true", payload_path, screenshot_path)
    os.remove(payload_path)
    if screenshot_path then os.remove(screenshot_path) end
    if request_error or not code or code:sub(1, 1) ~= "2" then
        log("WARN", string.format("Discord update failed (HTTP %s): %s",
            tostring(code), tostring(request_error or response):sub(1, 240)))
        return false
    end
    return true
end

local function verify_configuration()
    if type(config.packages) ~= "table" then return nil, "configured packages must be a list" end
    if #config.packages == 0 then return nil, "run the Setup Wizard first" end
    if #config.packages > 30 then return nil, "Noka supports a maximum of 30 configured packages" end
    if not valid_webhook(config.webhook_url) then return nil, "the configured Discord webhook URL is invalid" end
    if not valid_solver_url(Core.trim(config.solver_url or "")) then
        return nil, "the configured solver URL must use HTTPS (or localhost HTTP)"
    end
    local installed, package_error = list_installed_packages()
    if not installed then return nil, package_error end
    local available = package_set(installed)
    local seen = {}
    for index, entry in ipairs(config.packages) do
        if type(entry) ~= "table" or not Core.is_package_name(entry.package)
            or type(entry.target) ~= "table" then
            return nil, string.format("configured package entry %d is malformed", index)
        end
        if seen[entry.package] then return nil, entry.package .. " is configured more than once" end
        seen[entry.package] = true
        if not available[entry.package] then return nil, entry.package .. " is no longer installed" end
        local target_source = type(entry.target.input) == "string" and Core.trim(entry.target.input) or ""
        if target_source == "" then target_source = entry.target.uri end
        local target, target_error = Core.parse_join_target(target_source)
        if not target then return nil, entry.package .. ": " .. target_error end
        entry.target.input = target_source
        entry.target.uri = target.uri
        entry.target.kind = target.kind
        entry.target.display = target.display
        entry.target.place_id = target.place_id
        entry.target.link_code = target.link_code
        entry.target.share_code = target.share_code
        entry.target.share_type = target.share_type
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Rejoin: device hygiene. Cache purge runs before anything else in the
-- sequence, the RAM refresher follows it, and background apps are swept
-- after the warm-up phase so the join phase starts from a clean slate.
-- ---------------------------------------------------------------------------

-- Clears every clone's cache directories. Only true cache locations are
-- touched: /cache, code_cache, and the external cache dir. The WebView
-- profile (app_webview) is never touched because the .ROBLOSECURITY cookie
-- database lives there.
local function clear_clone_caches()
    log("INFO", "Cache purge: clearing every configured clone's cache directories")
    local cleared = 0
    for _, entry in ipairs(config.packages) do
        local package_name = entry.package
        local targets = {}
        for _, prefix in ipairs({ "/data/data/", "/data/user/0/" }) do
            targets[#targets + 1] = prefix .. package_name .. "/cache"
            targets[#targets + 1] = prefix .. package_name .. "/code_cache"
        end
        targets[#targets + 1] = "/storage/emulated/0/Android/data/" .. package_name .. "/cache"
        local quoted = {}
        for _, directory in ipairs(targets) do
            quoted[#quoted + 1] = Core.shell_quote(directory)
        end
        -- -mindepth 1 keeps the directories themselves; only contents die.
        local _, ok = root("find " .. table.concat(quoted, " ")
            .. " -mindepth 1 -delete 2>/dev/null; exit 0", true)
        if ok then cleared = cleared + 1 end
    end
    log("INFO", string.format("Cache purge: %d clone(s) processed", cleared))
end

-- Frees kernel page cache and compacts memory so clones start with maximum
-- available RAM. Kernels that forbid the sysctl writes are logged quietly;
-- CPU state cannot be flushed on Android, dropping caches is the closest
-- meaningful refresh.
local function refresh_device_memory()
    root("sync", true)
    local _, dropped = root("echo 3 > /proc/sys/vm/drop_caches", true)
    if not dropped then
        log("WARN", "the kernel refused drop_caches; RAM refresh was partial")
    end
    root("echo 1 > /proc/sys/vm/compact_memory 2>/dev/null", true)
    log("INFO", "RAM refresh: page cache dropped and memory compacted")
end

-- Kills every background application (all users' cached/background apps).
-- Foreground and persistent system apps are untouched by am kill-all, so
-- Termux itself survives. Runs after warm-up so nothing but Noka's own next
-- launches competes for RAM during the join phase.
local function kill_background_apps()
    local output, ok = root(SYSTEM_AM .. " kill --user 0 all", true)
    if not ok then
        log("WARN", "background app sweep failed: " .. tostring(output))
        return
    end
    log("INFO", "Background app sweep: all non-essential applications were terminated")
end

local function run_sequence(once)
    local valid, configuration_error = verify_configuration()
    if not valid then log("ERROR", configuration_error); return false end
    if not have_root() then log("ERROR", "Noka is root-only; root access was not granted"); return false end
    -- Rejoin: hygiene first — caches, then RAM — before any solver work.
    clear_clone_caches()
    refresh_device_memory()
    local heartbeat_ok, heartbeat_error = install_heartbeat()
    if not heartbeat_ok then log("ERROR", heartbeat_error); return false end
    if not optimize_device() then return false end
    local sequence_phase = "preparing"
    return with_end_listener(function()

    local resizing = resize_enabled()
    local bounds
    if resizing then
        local width, height, detected_left, detected_top, detected_right, detected_bottom = screen_size()
        local top_inset = math.max(config.top_inset, detected_top + STATUS_BAR_CLEARANCE)
        local bottom_inset = math.max(config.bottom_inset, detected_bottom)
        local left_inset = detected_left
        local right_inset = detected_right
        local columns, rows, row_counts
        bounds, columns, rows, row_counts = Core.calculate_bounds(#config.packages, width, height,
            config.window_gap, top_inset, bottom_inset, left_inset, right_inset)
        log("INFO", string.format(
            "Window grid: %s (%d row(s), max %d columns) framebuffer=%dx%d insets L%d T%d R%d B%d",
            table.concat(row_counts, "+"), rows, columns, width, height,
            left_inset, top_inset, right_inset, bottom_inset))
    else
        log("INFO", "Window resizing is disabled; App Cloner window bounds are left untouched")
    end

    -- Rejoin: fire every account's solver submission up front so the solves
    -- run concurrently while warm-up proceeds; each join waits only for its
    -- own answer in the join phase.
    local solver_attempted = {}
    if solver_enabled() then
        log("INFO", "Captcha solver pass: submitting every configured account asynchronously")
        local submitted = 0
        for _, entry in ipairs(config.packages) do
            if stop_requested() then return false end
            if spawn_background_solver(entry, nil) then
                submitted = submitted + 1
                solver_attempted[entry.package] = os.time()
                wait_or_stop(1) -- respect per-account submission cooldowns
            end
        end
        log("INFO", string.format("Captcha solver pass: %d account submission(s) queued", submitted))
    end
    if autoblock_run then
        if stop_requested() then return false end
        autoblock_run()
    end

    sequence_phase = "warmup"
    log("INFO", string.format("Homepage warm-up phase: every clone receives exactly %d seconds", WARMUP_DELAY))
    for index, entry in ipairs(config.packages) do
        if stop_requested() then return false end
        local stopped, stop_error = terminate_clone(entry)
        if not stopped then
            log("ERROR", entry.package .. ": could not stop clone before saving bounds: " .. tostring(stop_error))
            close_warm_tasks()
            return false
        end
        local preference_path, cell
        if resizing then
            local saved, path, confirmed, save_error = patch_app_cloner_preferences(entry.package, bounds[index])
            if not saved or confirmed ~= 4 then
                log("ERROR", entry.package .. ": App Cloner XML save failed; launch cancelled: " .. tostring(save_error))
                close_warm_tasks()
                return false
            end
            preference_path = path
            cell = bounds[index]
            log("INFO", string.format(
                "%s: bounds saved and confirmed 4/4 (left=%d top=%d right=%d bottom=%d in %s)",
                entry.package, cell.left, cell.top, cell.right, cell.bottom, preference_path))
        end
        local ok, launch_result = launch_homepage(entry)
        if not ok then
            log("ERROR", entry.package .. ": warm launch failed: " .. tostring(launch_result))
            close_warm_tasks()
            return false
        end
        if preference_path then
            local persisted, persisted_count = confirm_saved_bounds(preference_path, cell)
            if not persisted then
                terminate_clone(entry)
                log("ERROR", string.format("%s: XML changed during launch (%d/4 bounds remain); sequence cancelled",
                    entry.package, persisted_count))
                close_warm_tasks()
                return false
            end
            log("INFO", entry.package .. ": XML remained confirmed 4/4 after homepage launch")
        end
        log("INFO", string.format("%s: homepage warm-up wait (%d seconds)", entry.package, WARMUP_DELAY))
        if not wait_or_stop(WARMUP_DELAY) then return false end
    end
    close_warm_tasks()
    log("INFO", "All warm-up clones terminated; Android home screen opened")
    -- Rejoin: sweep every remaining background app so only Noka's next
    -- launches compete for RAM during the join phase.
    kill_background_apps()

    sequence_phase = "initial-join"
    log("INFO", string.format("Game-join phase: homepage wait is %.1f second(s)",
        tonumber(config.launch_delay) or 5))
    local runtime, deferred = {}, {}
    for index, entry in ipairs(config.packages) do
        runtime[entry.package] = {
            first_seen = os.time(), last_launch = 0, online = false, rss_mb = 0,
            bounds = resizing and bounds[index] or nil,
            solver_attempted_at = solver_attempted[entry.package],
            captcha_pending = false, captcha_deadline = 0,
        }
    end
    -- Join pass A: every account waits for its own solver answer (queued in
    -- the background during warm-up) and then launches. Accounts that cannot
    -- be cleared are closed and parked; the sequence never stops for them.
    for index, entry in ipairs(config.packages) do
        if stop_requested() then return false end
        local state = runtime[entry.package]
        local cleared, clear_error = true, nil
        if solver_enabled() then
            log("INFO", entry.package .. ": waiting for its captcha solver answer before launch")
            cleared, clear_error = wait_for_solver_result(entry)
            if cleared then state.solved_at = os.time() end
        else
            local db_path = cookie_db_path(entry.package)
            if not (db_path and read_roblosecurity(db_path)) then
                log("WARN", entry.package .. ": no stored .ROBLOSECURITY; launching without a solver gate")
            end
        end
        if stop_requested() then return false end
        if cleared then
            local joined, join_error = restart_and_join(entry, state, "configured join")
            if not joined then
                deferred[#deferred + 1] = entry
                log("WARN", string.format("%s: initial join did not register (%s); parked for a second pass"
                    , entry.package, tostring(join_error or "unknown")))
            end
        else
            deferred[#deferred + 1] = entry
            terminate_clone(entry)
            log("WARN", string.format("%s: not cleared by the solver (%s); parked while other clones launch",
                entry.package, tostring(clear_error)))
        end
    end

    -- Join pass B: drain the parked accounts. Each gets one fresh solve, and
    -- once the solver reports success the clone is reopened through the same
    -- soft reopen path as everyone else.
    local still_stopped = {}
    if #deferred > 0 then
        sequence_phase = "deferred-relaunch"
        log("INFO", string.format("Second pass: relaunching %d parked account(s) after their solves", #deferred))
        for _, entry in ipairs(deferred) do
            if stop_requested() then return false end
            local state = runtime[entry.package]
            local attempts = 0
            local maximum_attempts = tonumber(config.deferred_relaunch_attempts) or 2
            local opened = false
            while attempts < maximum_attempts and not stop_requested() do
                attempts = attempts + 1
                spawn_background_solver(entry, state.heartbeat and state.heartbeat.player or nil)
                state.solver_attempted_at = os.time()
                wait_or_stop(1)
                local cleared, clear_error = wait_for_solver_result(entry)
                if not cleared then
                    log("WARN", string.format("%s: solver attempt %d/%d did not clear the account (%s)",
                        entry.package, attempts, maximum_attempts, tostring(clear_error)))
                elseif stop_requested() then
                    break
                else
                    local joined, join_error = restart_and_join(entry, state, "cleared by solver")
                    if joined then
                        opened = true
                        break
                    end
                    log("WARN", string.format("%s: reopen attempt %d/%d failed to register (%s)",
                        entry.package, attempts, maximum_attempts, tostring(join_error or "unknown")))
                end
            end
            if not opened then
                terminate_clone(entry)
                still_stopped[#still_stopped + 1] = entry.package
                log("ERROR", entry.package .. ": could not be cleared and relaunched; it stays stopped until supervision picks it up")
            end
        end
    end
    if #still_stopped > 0 then
        log("INFO", "Accounts left stopped for supervision: " .. table.concat(still_stopped, ", "))
    end

    local last_webhook = -math.huge
    local first_status_gate
    -- Extra parentheses matter: command() returns (output, ok, code) and a
    -- trailing call expands ALL its values into tonumber(), whose optional
    -- second argument (base) then receives the boolean success flag.
    local clock_ticks = tonumber((command("getconf CLK_TCK"))) or 100
    if clock_ticks <= 0 then clock_ticks = 100 end
    cpu_percent()
    sequence_phase = "monitoring"
    while true do
        if stop_requested() then return false end
        local supervised_packages = {}
        for _, entry in ipairs(config.packages) do supervised_packages[#supervised_packages + 1] = entry.package end
        refresh_process_probes(supervised_packages)
        local windows = root("dumpsys window windows", true)
        for index, entry in ipairs(config.packages) do
            local state = runtime[entry.package]
            local now = os.time()
            local sample_monotonic = uptime_seconds() or now
            local pid, rss, ticks = read_process(entry.package)
            if pid and pid ~= state.pid then
                state.pid = pid
                state.first_seen = now
                state.process_ticks = nil
                state.process_sample_at = nil
            elseif not pid then
                state.pid = nil
            end
            state.rss_mb = rss or 0
            if pid and state.process_ticks and state.process_sample_at
                and sample_monotonic > state.process_sample_at then
                state.process_cpu = math.max(0, math.min(100,
                    (ticks - state.process_ticks) / clock_ticks
                        / (sample_monotonic - state.process_sample_at) * 100))
            else
                state.process_cpu = 0
            end
            state.process_ticks = ticks
            state.process_sample_at = sample_monotonic
            state.heartbeat = read_heartbeat(entry.package, state.token)
            local heartbeat = state.heartbeat
            local heartbeat_timeout = math.max(MIN_HEARTBEAT_TIMEOUT,
                tonumber(config.heartbeat_timeout) or MIN_HEARTBEAT_TIMEOUT)
            local heartbeat_status = Core.classify_heartbeat(heartbeat, state.token, now,
                heartbeat_timeout, state.grace_until, TRANSITION_GRACE)
            local visible = window_present(entry.package, windows)

            local heartbeat_detail
            if heartbeat_status.explicit_failure then
                heartbeat_detail = "confirmed Roblox disconnect: "
                    .. tostring(heartbeat.reason or "ErrorPrompt visible")
            elseif heartbeat_status.transition_overdue then
                heartbeat_detail = string.format("loading transition exceeded %d seconds", TRANSITION_GRACE)
            elseif heartbeat_status.stale then
                heartbeat_detail = string.format("heartbeat older than %d seconds", heartbeat_timeout)
            else
                heartbeat_detail = "heartbeat healthy"
            end

            local process_confirmed = confirmed_monitor_failure(entry, state, "process",
                pid == nil, "process absent")
            local heartbeat_confirmed = confirmed_monitor_failure(entry, state, "heartbeat",
                heartbeat_status.bad, heartbeat_detail)

            -- App Cloner floating windows are not reported consistently by
            -- every Android 10 dumpsys build. A fresh heartbeat overrides a
            -- visibility miss; visibility can only corroborate a bad heartbeat.
            local window_suspect = pid ~= nil and not visible
                and not heartbeat_status.acceptable and not heartbeat_status.in_expected_grace
            local window_confirmed = confirmed_monitor_failure(entry, state, "window",
                window_suspect, "window absent and heartbeat unavailable")

            -- Rejoin: live-captcha lane. An opened clone that burns CPU above
            -- the threshold while its heartbeat stays confirmed-bad is treated
            -- as stuck on a captcha: close it, export its credential to the
            -- solver, and softly reopen once the solver reports success.
            local cpu_active = (state.process_cpu or 0) >= config.captcha_cpu_threshold
            local registration_overdue = (state.last_launch or 0) > 0 and now > state.grace_until
                and (now - state.last_launch) >= math.max(60, tonumber(config.registration_timeout) or 180)
            local captcha_handled = false

            if state.captcha_pending then
                captcha_handled = true
                heartbeat_detail = "awaiting a captcha solver answer"
                state.online = false
                local result = read_solver_result(entry)
                if result == "ok" then
                    state.captcha_pending = false
                    log("INFO", entry.package .. ": solver cleared the account; reopening through the soft reopen path")
                    restart_and_join(entry, state, "account cleared by solver")
                elseif result == "busy" then
                    if os.time() >= (state.captcha_deadline or 0) then
                        state.captcha_pending = false
                        log("ERROR", entry.package .. ": solver did not answer before the captcha deadline; returning to normal supervision")
                    end
                else
                    state.captcha_pending = false
                    log("ERROR", entry.package .. ": captcha recovery ended without success (" .. tostring(result) .. "); returning to normal supervision")
                end
            elseif heartbeat_confirmed and pid ~= nil and cpu_active
                and registration_overdue and solver_enabled() then
                captcha_handled = true
                log("WARN", string.format(
                    "%s: live captcha suspected (%s; CPU %.1f%% >= %.1f%% with no heartbeat); closing and exporting the credential to the solver",
                    entry.package, heartbeat_detail, state.process_cpu or 0, config.captcha_cpu_threshold))
                terminate_clone(entry)
                state.failure_counts = {}
                state.online = false
                spawn_background_solver(entry, state.heartbeat and state.heartbeat.player or nil)
                state.solver_attempted_at = os.time()
                state.captcha_pending = true
                state.captcha_deadline = os.time() + math.max(60, tonumber(config.solver_wait_timeout) or 600)
            end

            if not captcha_handled then
                state.online = pid ~= nil and not process_confirmed
                    and not heartbeat_confirmed
                    and (heartbeat_status.acceptable or heartbeat_status.in_expected_grace)
                local reason
                if process_confirmed then
                    reason = "process absent for " .. FAILURE_CONFIRMATIONS .. " consecutive checks"
                elseif heartbeat_confirmed then
                    reason = heartbeat_detail .. " for " .. FAILURE_CONFIRMATIONS .. " consecutive checks"
                elseif window_confirmed then
                    reason = "window absent with no healthy heartbeat for "
                        .. FAILURE_CONFIRMATIONS .. " consecutive checks"
                end
                if reason then restart_and_join(entry, state, reason) end
            end
            if stop_requested() then return false end
        end
        -- Rejoin: the first status update waits until every clone's heartbeat
        -- has registered, plus a random 30-45 second settling window on top.
        if first_status_gate == nil then
            local all_registered = true
            for _, entry in ipairs(config.packages) do
                local clone_state = runtime[entry.package]
                if type(clone_state) ~= "table" or not clone_state.online then
                    all_registered = false
                    break
                end
            end
            if all_registered then
                first_status_gate = os.time() + math.random(30, 45)
                log("INFO", string.format(
                    "Every heartbeat is registered; first status update in %d second(s)",
                    first_status_gate - os.time()))
            end
        end
        local webhook_now = uptime_seconds() or os.time()
        if config.webhook_url ~= "" and first_status_gate ~= nil and webhook_now >= first_status_gate
            and webhook_now - last_webhook >= effective_webhook_interval() then
            send_webhook(runtime)
            last_webhook = webhook_now
        end
        if once then return true end
        if not wait_or_stop(config.check_interval) then return false end
    end
    end, function(callback_ok, result)
        if sequence_phase ~= "monitoring" and (not callback_ok or result == false) then
            close_warm_tasks()
            log("INFO", "Incomplete startup was cleaned up; no partially launched clone was left running")
        end
    end)
end

local function open_all_tabs()
    local valid, configuration_error = verify_configuration()
    if not valid then log("ERROR", configuration_error); return false end
    if not have_root() then
        log("ERROR", "Noka is root-only; root access was not granted")
        return false
    end

    return with_end_listener(function()
        local all_opened = true
        for _, entry in ipairs(config.packages) do
            if stop_requested() then
                log("INFO", "END received; stopping Open All Tabs")
                return false
            end
            local opened, open_result = launch_homepage(entry)
            if not opened then
                log("ERROR", entry.package .. ": tab launch failed: " .. tostring(open_result))
                all_opened = false
            else
                log("INFO", entry.package .. ": tab opened on the Roblox homepage")
            end
        end
        return all_opened
    end)
end

local COOKIE_DIR = DATA_DIR .. "/Cookies"
local COOKIE_DB_SUFFIX = "/app_webview/Default/Cookies"
local COOKIE_NAME = ".ROBLOSECURITY"
local SQLITE3 = (os.getenv("PREFIX") or "/data/data/com.termux/files/usr") .. "/bin/sqlite3"

local function sql_quote(value)
    return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function have_sqlite3()
    local _, ok = command("test -x " .. Core.shell_quote(SQLITE3))
    return ok
end

cookie_db_path = function(package_name)
    local path = "/data/data/" .. package_name .. COOKIE_DB_SUFFIX
    if file_exists(path) then return path end
    return nil
end

-- sqlite warnings land on the same captured stream, so only the final line of
-- a successful query is treated as the result.
local function sqlite_scalar(db_path, sql)
    local output, ok = root("{ " .. Core.shell_quote(SQLITE3) .. " -readonly "
        .. Core.shell_quote(db_path) .. " " .. Core.shell_quote(sql) .. " 2>/dev/null; }", true)
    if not ok then return nil end
    local last
    for line in output:gmatch("[^\r\n]+") do last = line end
    return last and Core.trim(last) or nil
end

-- Returns the plaintext cookie, or nil plus true when the clone only stores a
-- WebView-encrypted value that this build cannot read.
read_roblosecurity = function(db_path)
    local where = " WHERE name=" .. sql_quote(COOKIE_NAME)
        .. " AND (host_key=" .. sql_quote("roblox.com")
        .. " OR host_key=" .. sql_quote(".roblox.com")
        .. " OR host_key LIKE " .. sql_quote("%.roblox.com") .. ")"
    for _, order in ipairs({ " ORDER BY creation_utc DESC", "" }) do
        local row = sqlite_scalar(db_path,
            "SELECT value, length(encrypted_value) FROM cookies" .. where .. order .. " LIMIT 1;")
        if row then
            local value, encrypted_length = row:match("^(.*)|(%d+)$")
            if value and value ~= "" then return value end
            return nil, (tonumber(encrypted_length) or 0) > 0
        end
    end
    return nil, false
end

-- Mandatory live check: a cookie only enters the export file when Roblox
-- itself confirms it. Returns the user id and name, or nil plus "dead" for a
-- rejected cookie / a reason string when the API could not be reached.
local function verify_cookie_api(cookie)
    for _ = 1, 2 do
        local body, code = http_get("https://users.roblox.com/v1/users/authenticated", 15,
            { "Cookie: .ROBLOSECURITY=" .. cookie })
        if code == "200" then
            local user = Core.json_decode(body)
            local user_id = type(user) == "table" and tonumber(user.id) or nil
            local username = type(user) == "table" and user.name or nil
            if user_id then return user_id, username end
            return nil, "unexpected API response"
        elseif code == "401" then
            return nil, "dead"
        end
        os.execute(Core.shell_quote(TERMUX_SLEEP) .. " 2")
    end
    return nil, "API unreachable"
end

local function export_cookies()
    print_header("Cookie Export")
    if not have_root() then print("Noka is root-only; root access was not granted.") return end
    if not have_sqlite3() then print("sqlite3 is missing. Install it with: pkg install -y sqlite") return end
    if #config.packages == 0 then print("No packages configured; run the Setup Wizard first.") return end
    return with_end_listener(function()
        local cookies, report, seen = {}, {}, {}
        for _, entry in ipairs(config.packages) do
            if stop_requested() then
                print("Export aborted.")
                return false
            end
            local status
            local db_path = cookie_db_path(entry.package)
            if not db_path then
                status = "no WebView cookie database (launch the clone once)"
            else
                local cookie, encrypted = read_roblosecurity(db_path)
                if not cookie then
                    if encrypted then
                        status = "WebView-encrypted cookie; plaintext export impossible"
                    else
                        status = "no .ROBLOSECURITY cookie stored"
                    end
                else
                    local user_id, info = verify_cookie_api(cookie)
                    if user_id then
                        if not seen[cookie] then cookies[#cookies + 1] = cookie; seen[cookie] = true end
                        status = string.format("live: %s (%s)", info or "unknown", user_id)
                    elseif info == "dead" then
                        status = "dead cookie (logged out or reset); skipped"
                    else
                        status = "verification failed (" .. tostring(info) .. "); skipped"
                    end
                end
            end
            report[#report + 1] = string.format("     %-36s %s", entry.package, status)
        end
        for _, line in ipairs(report) do print(line) end
        if #cookies == 0 then print("\nNo live cookies to export."); return true end
        local directory_created = ensure_directory(COOKIE_DIR)
        if not directory_created then print("Could not create " .. COOKIE_DIR); return false end
        local path = string.format("%s/%s-%d-cookie-export.txt", COOKIE_DIR,
            os.date("%Y%m%d-%H%M%S"), #cookies)
        local written, write_error = write_file_atomic(path, table.concat(cookies, "\n") .. "\n", "600")
        if not written then
            print("Could not write " .. path .. ": " .. tostring(write_error))
            return false
        end
        print(string.format("\nExported %d unique live cookie(s) to %s", #cookies, path))
        print("Treat this file as a password; Android shared storage may not enforce Unix file modes.")
        log("INFO", string.format("Exported %d unique live cookie(s); no cookie value was written to the log", #cookies))
        return true
    end)
end

-- ---------------------------------------------------------------------------
-- Captcha solver + auto block. solver_solve_entry / autoblock_run are
-- forward-declared near the watchdog so run_sequence can call them.
-- ---------------------------------------------------------------------------

local function solver_response_status(body, code)
    if code == "202" then return "busy" end
    local response = Core.json_decode(body or "")
    if type(response) == "table" then
        local status = tostring(response.status or response.result or ""):lower()
        if status == "processing" or status == "pending" or status == "queued" then return "busy" end
        if status == "ok" or status == "success" or status == "completed"
            or status == "solved" or status == "already_solved" then return "ok" end
        if response.success == true then return "ok" end
        if response.success == false or response.error ~= nil
            or status == "failed" or status == "error" then return "failed" end
    end
    local plain = Core.trim(body or ""):lower()
    if plain == "ok" or plain == "success" or plain == "solved" then return "ok" end
    return "unknown"
end

-- Webhook-style solvers (zeropoint, blocksolve, zapzonex, omocaptcha, and the
-- universal "Third Party Solver URL" convention): one blocking POST per
-- account; the response says when the join challenge is cleared.
local function solve_via_webhook(entry, username, cookie, url, key, place_id)
    local started = uptime_seconds() or os.time()
    local attempt = 0
    while (uptime_seconds() or os.time()) - started < 600 do
        if stop_requested() then return false end
        attempt = attempt + 1
        local body = { username = username, cookie = cookie }
        if key ~= "" then body.api_key = key end
        if place_id then body.placeId = tonumber(place_id) or place_id end
        local headers = {}
        if key ~= "" then headers[#headers + 1] = "X-API-Key: " .. key end
        local response, code, request_error = http_post_json(url, body, headers, 150)
        if request_error then
            log("WARN", entry.package .. ": solver transport error: " .. tostring(request_error))
        end
        if code == "400" or code == "401" or code == "402" or code == "403" then
            log("ERROR", string.format("%s: solver rejected the request (HTTP %s): %s",
                entry.package, tostring(code), tostring(response):sub(1, 160)))
            return false
        end
        local status = solver_response_status(response, code)
        if status == "ok" then
            log("INFO", entry.package .. ": solver reports the account is clear")
            return true
        elseif status == "busy" then
            if not wait_or_stop(10) then return false end
        elseif status == "failed" then
            log("WARN", string.format("%s: solver attempt %d failed (HTTP %s): %s",
                entry.package, attempt, tostring(code), tostring(response):sub(1, 160)))
            if not wait_or_stop(5) then return false end
        else
            log("WARN", string.format("%s: solver returned no explicit success state (HTTP %s): %s",
                entry.package, tostring(code), tostring(response):sub(1, 160)))
            if not wait_or_stop(10) then return false end
        end
    end
    log("ERROR", entry.package .. ": solver did not clear the account within 10 minutes")
    return false
end

-- highspec is job-based: submit once, then poll the job to a terminal state.
local function solve_highspec(entry, base_url, username, cookie)
    local base, embedded_query = base_url:match("^([^?]+)(%?.*)$")
    base = (base or base_url):gsub("/+$", "")
    embedded_query = embedded_query and embedded_query:sub(2) or ""
    local submit_query = "service=directapi"
    if embedded_query ~= "" then submit_query = submit_query .. "&" .. embedded_query end
    local submit_url = base .. "/external/job/captcha/submit?" .. submit_query
    local headers = {}
    local body, code, submit_error = http_post_json(submit_url,
        { note = "Noka Rejoin", accounts = Core.json_array({ { username = username, cookie = cookie } }) },
        headers, 60)
    local submitted = Core.json_decode(body or "")
    local job_id = type(submitted) == "table" and submitted.id or nil
    if type(job_id) == "number" then job_id = tostring(job_id) end
    if type(job_id) ~= "string" or job_id == "" then
        log("ERROR", string.format("%s: highspec submit failed (HTTP %s): %s",
            entry.package, tostring(code), tostring(submit_error or body):sub(1, 160)))
        return false
    end
    local started = uptime_seconds() or os.time()
    while (uptime_seconds() or os.time()) - started < 600 do
        if stop_requested() then return false end
        if not wait_or_stop(5) then return false end
        local status_url = base .. "/external/job/" .. Core.url_encode(job_id)
        if embedded_query ~= "" then status_url = status_url .. "?" .. embedded_query end
        local sbody, status_code, status_error = http_get(status_url, 30, headers)
        local status_body = Core.json_decode(sbody or "")
        local status = type(status_body) == "table" and tostring(status_body.status or ""):lower() or ""
        if status == "completed" then
            local success_amount = tonumber(status_body.success_amount) or 0
            if success_amount >= 1 then
                log("INFO", entry.package .. ": solver reports the account is clear")
                return true
            end
            log("ERROR", entry.package .. ": highspec job completed without a successful solve")
            return false
        elseif status == "failed" then
            log("ERROR", entry.package .. ": highspec job failed")
            return false
        elseif status_error then
            log("WARN", string.format("%s: highspec poll failed (HTTP %s): %s",
                entry.package, tostring(status_code), tostring(status_error)))
        end
    end
    log("ERROR", entry.package .. ": highspec job timed out")
    return false
end

solver_solve_entry = function(entry, known_username)
    local url = Core.trim(config.solver_url or "")
    if url == "" then return true end
    local stype = detect_solver_type(url)
    if stype == "yescaptcha" then
        log("ERROR", entry.package .. ": yescaptcha is token-based and cannot clear a Roblox join challenge from a cookie alone")
        return false
    end
    local db_path = cookie_db_path(entry.package)
    local cookie = db_path and read_roblosecurity(db_path) or nil
    if not cookie then
        log("WARN", entry.package .. ": no stored .ROBLOSECURITY; solver submission skipped")
        return false
    end
    local username = known_username
    if not username or username == "" then
        local user_id, verified_name = verify_cookie_api(cookie)
        if not user_id or type(verified_name) ~= "string" or verified_name == "" then
            log("WARN", entry.package .. ": solver submission skipped because the cookie owner could not be verified")
            return false
        end
        username = verified_name
    end
    local place_id = entry.target and entry.target.place_id or nil
    if stype == "highspec" then
        return solve_highspec(entry, url, username, cookie)
    end
    return solve_via_webhook(entry, username, cookie, url, "", place_id)
end

-- ---------------------------------------------------------------------------
-- Rejoin: asynchronous solver jobs. A submission is fired as a detached curl
-- (webhook-style solvers hold their request server-side) or as an instantly
-- submitted highspec job; the controller keeps working and polls the result
-- later. Results live in STATE_DIR/solver keyed by sanitized package name.
-- ---------------------------------------------------------------------------

local SOLVER_DIR = STATE_DIR .. "/solver"
local async_solver_jobs = {}

local function solver_safe_name(package_name)
    return tostring(package_name):gsub("[^%w%._%-]", "_")
end

local function cleanup_solver_files(job)
    if job.cfg_path then os.remove(job.cfg_path); job.cfg_path = nil end
    -- The request body holds the account cookie; remove it as soon as the
    -- answer is terminal (or the job expires).
    if job.body_path then os.remove(job.body_path); job.body_path = nil end
end

spawn_background_solver = function(entry, known_username)
    local url = Core.trim(config.solver_url or "")
    if url == "" then return true end
    local stype = detect_solver_type(url)
    if stype == "yescaptcha" then
        log("ERROR", entry.package .. ": yescaptcha is token-based and cannot clear a Roblox join challenge from a cookie alone")
        return false
    end
    local db_path = cookie_db_path(entry.package)
    local cookie = db_path and read_roblosecurity(db_path) or nil
    if not cookie then
        log("WARN", entry.package .. ": no stored .ROBLOSECURITY; solver submission skipped")
        return false
    end
    local username = known_username
    if not username or username == "" then
        local user_id, verified_name = verify_cookie_api(cookie)
        if not user_id or type(verified_name) ~= "string" or verified_name == "" then
            log("WARN", entry.package .. ": solver submission skipped because the cookie owner could not be verified")
            return false
        end
        username = verified_name
    end

    if stype == "highspec" then
        -- highspec answers its submit immediately with a job id; polling the
        -- job later is what makes this path asynchronous.
        local base, embedded_query = url:match("^([^?]+)(%?.*)$")
        base = (base or url):gsub("/+$", "")
        embedded_query = embedded_query and embedded_query:sub(2) or ""
        local submit_query = "service=directapi"
        if embedded_query ~= "" then submit_query = submit_query .. "&" .. embedded_query end
        local body, code, submit_error = http_post_json(
            base .. "/external/job/captcha/submit?" .. submit_query,
            { note = "Noka Rejoin", accounts = Core.json_array({ { username = username, cookie = cookie } }) },
            {}, 60)
        local submitted = Core.json_decode(body or "")
        local job_id = type(submitted) == "table" and submitted.id or nil
        if type(job_id) == "number" then job_id = tostring(job_id) end
        if type(job_id) ~= "string" or job_id == "" then
            log("ERROR", string.format("%s: highspec submit failed (HTTP %s): %s",
                entry.package, tostring(code), tostring(submit_error or body):sub(1, 160)))
            return false
        end
        async_solver_jobs[entry.package] = {
            kind = "highspec", job_id = job_id, base = base, query = embedded_query,
            deadline = os.time() + math.max(60, tonumber(config.solver_wait_timeout) or 600),
        }
        log("INFO", entry.package .. ": account queued with the highspec solver (job " .. job_id .. ")")
        return true
    end

    -- Webhook-style solvers (zeropoint, blocksolve, zapzonex, omocaptcha,
    -- universal): stage one blocking POST and detach it so the controller
    -- never waits on the solve while other clones keep launching.
    local key = Core.trim(config.solver_key or "")
    local payload_table = { username = username, cookie = cookie }
    if key ~= "" then payload_table.api_key = key end
    local place_id = entry.target and entry.target.place_id or nil
    if place_id then payload_table.placeId = tonumber(place_id) or place_id end
    local encoded_ok, payload = pcall(Core.json_encode, payload_table)
    if not encoded_ok then
        log("ERROR", entry.package .. ": could not encode the solver request: " .. tostring(payload))
        return false
    end
    ensure_directory(SOLVER_DIR)
    local safe = solver_safe_name(entry.package)
    local stamp = tostring(os.time())
    -- Unique paths per submission: an orphaned older curl can never deliver
    -- its late answer into the current job's slot.
    local body_path = PRIVATE_TMP_DIR .. "/.noka-solver." .. safe .. "." .. stamp .. ".body"
    local status_path = SOLVER_DIR .. "/" .. safe .. "." .. stamp .. ".status"
    local cfg_path = PRIVATE_TMP_DIR .. "/.noka-solver." .. safe .. "." .. stamp .. ".cfg"
    local config_lines = {
        "silent", "show-error",
        "connect-timeout = 15",
        "max-time = " .. tostring(math.max(60, tonumber(config.solver_wait_timeout) or 600)),
        "max-filesize = 10485760",
        "url = " .. assert(curl_config_quote(url)),
        "output = " .. assert(curl_config_quote(body_path)),
        'write-out = "%{http_code}"',
    }
    if key ~= "" then
        config_lines[#config_lines + 1] = "header = " .. assert(curl_config_quote("X-API-Key: " .. key))
    end
    local written, write_error = write_file(body_path, payload, "wb")
    if not written then
        log("ERROR", entry.package .. ": could not stage the solver request: " .. tostring(write_error))
        return false
    end
    -- The request body carries the account cookie; it is staged in Termux
    -- private storage where chmod 600 is enforced (shared storage is not).
    os.execute("chmod 600 " .. Core.shell_quote(body_path))
    written, write_error = write_file(cfg_path, table.concat(config_lines, "\n") .. "\n", "wb")
    if not written then
        os.remove(body_path)
        log("ERROR", entry.package .. ": could not stage the solver curl config: " .. tostring(write_error))
        return false
    end
    os.execute("chmod 600 " .. Core.shell_quote(cfg_path))
    local runner_command = "curl -q --config " .. Core.shell_quote(cfg_path)
        .. " > " .. Core.shell_quote(status_path) .. " 2>/dev/null"
    os.execute("nohup " .. Core.shell_quote(TERMUX_PREFIX .. "/bin/bash") .. " -c "
        .. Core.shell_quote(runner_command) .. " >/dev/null 2>&1 &")
    async_solver_jobs[entry.package] = {
        kind = "webhook", status_path = status_path, body_path = body_path,
        cfg_path = cfg_path,
        deadline = os.time() + math.max(60, tonumber(config.solver_wait_timeout) or 600),
    }
    log("INFO", entry.package .. ": account submitted to the captcha solver in the background (" .. detect_solver_type(url) .. ")")
    return true
end

-- Non-blocking poll. Returns "ok" / "failed" / "expired" when terminal,
-- "busy" while the job is still running, "none" when nothing was submitted.
read_solver_result = function(entry)
    local job = async_solver_jobs[entry.package]
    if not job then return "none" end
    if job.kind == "highspec" then
        local status_url = job.base .. "/external/job/" .. Core.url_encode(job.job_id)
        if job.query ~= "" then status_url = status_url .. "?" .. job.query end
        local sbody, _, status_error = http_get(status_url, 20)
        local response = Core.json_decode(sbody or "")
        local data = type(response) == "table" and (type(response.data) == "table" and response.data or response) or nil
        local status = type(data) == "table" and tostring(data.status or ""):lower() or ""
        if status == "completed" then
            local success_amount = type(data) == "table" and (tonumber(data.success_amount) or 0) or 0
            async_solver_jobs[entry.package] = nil
            if success_amount >= 1 then return "ok" end
            log("WARN", entry.package .. ": highspec job completed without a successful solve")
            return "failed"
        elseif status == "failed" then
            async_solver_jobs[entry.package] = nil
            return "failed"
        elseif status_error then
            log("WARN", entry.package .. ": highspec poll failed: " .. tostring(status_error))
        end
    else
        local status_text = read_file_limited(job.status_path, 64)
        if status_text then
            local code = Core.trim(status_text):match("(%d%d%d)")
            local body = read_file_limited(job.body_path, 1024 * 1024) or ""
            async_solver_jobs[entry.package] = nil
            cleanup_solver_files(job)
            return Core.parse_solver_result(body, code)
        end
    end
    if os.time() >= (job.deadline or 0) then
        async_solver_jobs[entry.package] = nil
        cleanup_solver_files(job)
        return "expired"
    end
    return "busy"
end

-- Blocking wait used by the launch gate. Returns true when the account is
-- clear, or false plus a short reason string.
wait_for_solver_result = function(entry)
    local deadline = os.time() + math.max(60, tonumber(config.solver_wait_timeout) or 600)
    while true do
        if stop_requested() then return false, "cancelled" end
        local result = read_solver_result(entry)
        if result == "ok" then return true end
        if result ~= "busy" then return false, result end
        if os.time() >= deadline then return false, "timed out" end
        if not wait_or_stop(5) then return false, "cancelled" end
    end
end

-- Auto block: block every configured target account on every clone, using each
-- clone's own stored cookie. The CSRF probe deliberately goes to /v2/logout
-- WITHOUT the token, so it only ever reads the 403 response header.
local function roblox_csrf_token(cookie)
    local _, _, request_error, headers = http_request("POST",
        "https://auth.roblox.com/v2/logout", "",
        { "Cookie: .ROBLOSECURITY=" .. cookie }, 15, true)
    if request_error then return nil, request_error end
    return headers and headers:match("[Xx]%-[Cc][Ss][Rr][Ff]%-[Tt][Oo][Kk][Ee][Nn]:%s*(%S+)") or nil
end

local function roblox_block_user(cookie, csrf, user_id)
    local body, code, request_error = http_request("POST",
        "https://users.roblox.com/v1/users/" .. user_id .. "/block", "",
        { "Cookie: .ROBLOSECURITY=" .. cookie, "X-CSRF-TOKEN: " .. csrf }, 15)
    return code and code:sub(1, 1) == "2", code, request_error or body
end

-- Rejoin: mutual auto block. Every clone's own cookie is verified first so
-- each account is identified; then every clone blocks every other clone, so
-- two farmed accounts never share a server. Extra manual targets remain
-- optional and are blocked in addition to the cross-block.
autoblock_run = function()
    if not config.autoblock_enabled then return end

    -- Phase 1: identify every clone through its own live cookie.
    local identities, order = {}, {}
    for _, entry in ipairs(config.packages) do
        if stop_requested() then return end
        local db_path = cookie_db_path(entry.package)
        local cookie = db_path and read_roblosecurity(db_path) or nil
        if not cookie then
            log("WARN", entry.package .. ": no stored cookie; it cannot take part in the mutual block")
        else
            local user_id, username = verify_cookie_api(cookie)
            if not user_id then
                log("WARN", entry.package .. ": cookie is not live (" .. tostring(username or "unverified")
                    .. "); it cannot take part in the mutual block")
            else
                identities[entry.package] = {
                    user_id = tostring(user_id), username = username, cookie = cookie,
                }
                order[#order + 1] = entry.package
            end
        end
    end
    if #order < 2 then
        log("WARN", string.format(
            "auto block: %d live clone identit(y/ies); at least 2 are required for a mutual block",
            #order))
        return
    end
    log("INFO", string.format("auto block: verified %d clone identit(y/ies); blocking them against each other",
        #order))

    -- Optional manual extras, resolved on top of the mutual set.
    local ids, names, seen_ids, seen_names = {}, {}, {}, {}
    for _, target in ipairs(Core.split_list(config.autoblock_targets or "")) do
        if target:match("^%d+$") then
            if not seen_ids[target] then ids[#ids + 1] = target; seen_ids[target] = true end
        else
            local lowered = target:lower()
            if not seen_names[lowered] then names[#names + 1] = target; seen_names[lowered] = true end
        end
    end
    if #names > 0 then
        local body, code, resolve_error = http_post_json("https://users.roblox.com/v1/usernames/users",
            { usernames = Core.json_array(names), excludeBannedUsers = false }, {}, 30)
        local response = code == "200" and Core.json_decode(body or "") or nil
        if type(response) == "table" and type(response.data) == "table" then
            for _, user in ipairs(response.data) do
                local id = type(user) == "table" and tostring(user.id or "") or ""
                if id:match("^%d+$") and not seen_ids[id] then
                    ids[#ids + 1] = id
                    seen_ids[id] = true
                end
            end
        elseif resolve_error or code ~= "200" then
            log("WARN", "auto block: extra-target resolution failed: "
                .. tostring(resolve_error or ("HTTP " .. tostring(code))))
        end
    end
    local extra_count = #ids

    -- Phase 2: every clone blocks every other clone plus any manual extras.
    for _, package_name in ipairs(order) do
        if stop_requested() then return end
        local identity = identities[package_name]
        local targets_for_clone = {}
        for _, other_package in ipairs(order) do
            if other_package ~= package_name then
                local other_id = identities[other_package].user_id
                if not seen_ids[other_id] then
                    targets_for_clone[#targets_for_clone + 1] = other_id
                end
            end
        end
        for _, user_id in ipairs(ids) do
            targets_for_clone[#targets_for_clone + 1] = user_id
        end

        local csrf, csrf_error = roblox_csrf_token(identity.cookie)
        if not csrf then
            log("WARN", package_name .. ": could not obtain a Roblox CSRF token; its block pass skipped: "
                .. tostring(csrf_error or "token absent"))
        else
            local blocked = 0
            local unsupported = false
            for _, user_id in ipairs(targets_for_clone) do
                local succeeded, code, detail = roblox_block_user(identity.cookie, csrf, user_id)
                if succeeded then
                    blocked = blocked + 1
                elseif code == "404" or code == "405" then
                    unsupported = true
                    log("WARN", "auto block endpoint is unavailable on this Roblox API version; stopping this pass")
                    break
                else
                    log("WARN", string.format("%s: block request for %s failed (HTTP %s): %s",
                        package_name, user_id, tostring(code), tostring(detail):sub(1, 120)))
                end
            end
            log("INFO", string.format("%s (%s): blocked %d/%d target(s)",
                package_name, identity.username or "?", blocked, #targets_for_clone))
            if unsupported then return end
        end
    end
end

local function cookie_tools_menu()
    while true do
        print_header("Cookie Tools")
        print_panel("COOKIE TOOLS", {
            { "1.", "Export cookies", "save live .ROBLOSECURITY from clones" },
            { "0.", "Back", "return to SELECT" },
        })
        local choice = prompt("\nSelection", "0")
        if choice == "0" or choice == nil then return
        elseif choice == "1" then export_cookies(); prompt("\nPress Enter to continue", "")
        end
    end
end

local function main_menu()
    while true do
        print_header()
        print_panel("SELECT", {
            { "1.", "Setup Wizard", "packages, destinations & webhook" },
            { "2.", "Start Rejoin", "prepare, launch & supervise clones" },
            { "3.", "Open All Tabs", "open configured clone homepages" },
            { "4.", "Cookie Tools", "export live .ROBLOSECURITY cookies" },
            { "5.", "Configuration", "view and edit every setting" },
            { "0.", "Exit", "close Noka" },
        })
        local default_choice = #config.packages > 0 and "2" or "1"
        local choice = prompt("\nSelection", default_choice)
        if choice == "1" then setup_wizard(); prompt("\nPress Enter to continue", "")
        elseif choice == "2" then run_sequence(false); return
        elseif choice == "3" then open_all_tabs(); prompt("\nPress Enter to continue", "")
        elseif choice == "4" then cookie_tools_menu()
        elseif choice == "5" then configuration_menu()
        elseif choice == "0" or choice == nil then return
        end
    end
end

if FLAGS["--no-resize"] then resize_session_disabled = true end
local function dispatch()
    if FLAGS["--reset"] then
        for key in pairs(config) do config[key] = nil end
        merge_defaults(config, DEFAULT_CONFIG)
        local saved, save_error = save_config(config)
        if not saved then error("Noka could not reset its configuration: " .. tostring(save_error)) end
        print("Noka configuration was reset to the defaults.")
        if setup_wizard() then return run_sequence(false) end
        return false
    elseif FLAGS["--check-config"] then
        local ok, message = verify_configuration()
        if ok then print("Noka configuration is valid."); return true end
        io.stderr:write(message .. "\n")
        return false
    elseif FLAGS["--restore-device"] then return restore_device()
    elseif FLAGS["--restore-bounds"] then return restore_bounds()
    elseif FLAGS["--once"] then return run_sequence(true)
    elseif FLAGS["--skip"] or FLAGS["--start"] then return run_sequence(false)
    elseif FLAGS["--setup"] then return setup_wizard()
    else main_menu(); return true end
end

-- Rejoin: packed into one table because the main chunk sits at Lua's
-- 200-local-variable ceiling; every top-level local counts against it.
local lock_result = { acquire_controller_lock() }
if not lock_result[1] then
    io.stderr:write("Noka could not start: " .. tostring(lock_result[2]) .. "\n")
    os.exit(1)
end
cleanup_stale_private_files()
local dispatch_ok, dispatch_result = xpcall(dispatch, debug.traceback)
stop_end_listener()
release_controller_lock()
if not dispatch_ok then
    io.stderr:write("Noka stopped after an unhandled error:\n" .. tostring(dispatch_result) .. "\n")
    os.exit(1)
end
if dispatch_result == false then os.exit(1) end
