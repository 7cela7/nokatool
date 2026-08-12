#!/data/data/com.termux/files/usr/bin/lua

-- Noka single-file build.
-- The root Termux controller, helpers, and Delta LocalPlayer heartbeat are
-- carried in this file. Runtime configuration is stored under $HOME/NOKA.
-- First run in Termux 0.118.1:
--   pkg install -y lua54 curl coreutils procps grep
--   termux-setup-storage
--   lua /sdcard/Download/noka.lua

local Core = (function()
local Core = {}

local ARRAY_MT = { __noka_json_array = true }

function Core.trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

function Core.shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function Core.url_decode(value)
    value = tostring(value or ""):gsub("+", " ")
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

    if input:match("^roblox://") then
        if input:match("^roblox://experiences/start%?")
            or input:match("^roblox://navigation/share_links%?") then
            return { kind = "deeplink", uri = input, display = input }
        end
        return nil, "unsupported roblox:// link"
    end

    if not input:match("^https?://") then
        return nil, "enter a numeric place ID or a complete Roblox URL"
    end

    local host = input:match("^https?://([^/%?#]+)")
    local lower_host = host and host:lower() or ""
    if lower_host ~= "roblox.com" and lower_host:sub(-11) ~= ".roblox.com" then
        return nil, "the URL must be on roblox.com"
    end

    local query = Core.parse_query(input)
    local share_code = query_value_case_insensitive(query, "code")
    local share_type = query_value_case_insensitive(query, "type")
    local path = input:match("^https?://[^/]+([^%?#]*)") or ""

    if share_code and (path:match("/share/?$") or path:match("/share%-links/?$")) then
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
    local rows = math.max(1, math.floor(math.sqrt(count)))
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
    local changed = 0
    for _, coordinate in ipairs({ "left", "top", "right", "bottom" }) do
        local key = "app_cloner_current_window_" .. coordinate
        local replacements = 0
        content, replacements = content:gsub(
            '(<[iI][nN][tT]%s+[^>]-name="' .. key .. '"[^>]-value=")(%-?%d+)("[^>]*>)',
            function(prefix, _, suffix)
                return prefix .. tostring(math.floor(tonumber(bounds[coordinate]) or 0)) .. suffix
            end)
        if replacements ~= 1 then return nil, 0, "expected exactly one " .. key .. " entry" end
        changed = changed + 1
    end
    return content, changed
end

function Core.confirm_app_cloner_bounds(content, bounds)
    content = tostring(content or "")
    local confirmed = 0
    local actual = {}
    for _, coordinate in ipairs({ "left", "top", "right", "bottom" }) do
        local key = "app_cloner_current_window_" .. coordinate
        local value = content:match('<[iI][nN][tT]%s+[^>]-name="' .. key
            .. '"[^>]-value="(%-?%d+)"[^>]*>')
        actual[coordinate] = tonumber(value)
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
    if value == nil then return "null" end
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
    for key in pairs(value) do keys[#keys + 1] = tostring(key) end
    table.sort(keys)
    for _, key in ipairs(keys) do
        parts[#parts + 1] = Core.json_encode(key, stack) .. ":" .. Core.json_encode(value[key], stack)
    end
    stack[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
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
    local recent = matches and age ~= nil and age <= timeout
    local loading = recent and (heartbeat.state == "loading" or heartbeat.transitioning == true)
    local transition_started = loading and tonumber(heartbeat.transition_started_at) or nil
    local transition_age = transition_started and now - transition_started or 0
    local transition_active = loading and transition_age <= transition_grace
    local explicit_failure = matches
        and (heartbeat.online == false or heartbeat.state == "disconnected")
    local stale = now > grace_until and not recent
    local transition_overdue = now > grace_until and loading and transition_age > transition_grace

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

return Core
end)()

local EMBEDDED_HEARTBEAT = [========[
--[[
    Noka LocalPlayer heartbeat 3.0

    Installed by Noka as a separate Delta Autoexec/Autoexecute script.
    It contains no licensing, HWID collection, remote requests, analytics,
    or downloaded code. Communication is local Delta Workspace files only.
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local HEARTBEAT_INTERVAL = 4
local INITIAL_LOADING_GRACE = 12
local STATE_KEY = "__NOKA_LOCALPLAYER_HEARTBEAT_V3"
local task_library = task
local wait_for = task_library and task_library.wait or wait
local spawn_task = task_library and task_library.spawn or spawn

local function environment()
    if type(getgenv) == "function" then
        local ok, value = pcall(getgenv)
        if ok and type(value) == "table" then return value end
    end
    return _G
end

local shared = environment()

local function safe_is_file(path)
    if type(isfile) ~= "function" then return false end
    local ok, result = pcall(isfile, path)
    return ok and result == true
end

local function safe_read(path)
    if type(readfile) ~= "function" or not safe_is_file(path) then return nil end
    local ok, contents = pcall(readfile, path)
    if ok and type(contents) == "string" then return contents end
    return nil
end

local function ensure_folder(path)
    if type(isfolder) ~= "function" or type(makefolder) ~= "function" then return false end
    local ok, exists = pcall(isfolder, path)
    if ok and exists then return true end
    return pcall(makefolder, path)
end

local function decode_marker(contents)
    local ok, marker = pcall(HttpService.JSONDecode, HttpService, contents)
    if not ok or type(marker) ~= "table" then return nil end
    if type(marker.package) ~= "string" or marker.package == "" then return nil end
    if type(marker.token) ~= "string" or marker.token == "" then return nil end
    return marker
end

local function read_launch_marker()
    local candidates = {
        "Noka/current_launch.json",
        "Workspace/Noka/current_launch.json",
        "workspace/Noka/current_launch.json",
        "../Workspace/Noka/current_launch.json",
        "../workspace/Noka/current_launch.json",
        "../../Workspace/Noka/current_launch.json",
        "../../workspace/Noka/current_launch.json",
    }
    for _, path in ipairs(candidates) do
        local contents = safe_read(path)
        if contents then
            local marker = decode_marker(contents)
            if marker then return marker end
        end
    end
    return nil
end

local previous = shared[STATE_KEY]
if type(previous) == "table" then
    previous.running = false
    if previous.teleport_connection then pcall(previous.teleport_connection.Disconnect, previous.teleport_connection) end
end

-- A state surviving a Roblox teleport belongs to this clone. Retaining that
-- package/token prevents another clone's shared launch marker being adopted.
local marker = type(previous) == "table" and previous.marker or nil
if type(marker) ~= "table" then marker = read_launch_marker() end
if not marker then
    warn("[NOKA] Launch marker unavailable; start this clone through Noka.")
    return
end

local started_at = os.time()
local state = {
    running = true,
    marker = marker,
    sequence = type(previous) == "table" and tonumber(previous.sequence) or 0,
    last_player_name = type(previous) == "table" and previous.last_player_name or nil,
    last_display_name = type(previous) == "table" and previous.last_display_name or nil,
    last_user_id = type(previous) == "table" and previous.last_user_id or nil,
    transition_started_at = type(previous) == "table" and previous.transition_started_at or started_at,
    loading_until = started_at + INITIAL_LOADING_GRACE,
    prompt_hits = 0,
    bound_player = nil,
    teleport_connection = nil,
}
shared[STATE_KEY] = state

ensure_folder("Noka")
ensure_folder("Noka/heartbeats")

local function safe_name(value)
    return tostring(value):gsub("[^%w%._%-]", "_")
end

local heartbeat_path = "Noka/heartbeats/" .. safe_name(marker.package) .. ".json"
local redundant_path = heartbeat_path .. ".next"

local function begin_transition(extra_seconds)
    local now = os.time()
    state.transition_started_at = state.transition_started_at or now
    state.loading_until = math.max(state.loading_until or 0, now + (extra_seconds or INITIAL_LOADING_GRACE))
end

local function bind_teleport_event(player)
    if player == state.bound_player then return end
    if state.teleport_connection then
        pcall(state.teleport_connection.Disconnect, state.teleport_connection)
        state.teleport_connection = nil
    end
    state.bound_player = player
    if not player then return end
    local ok, connection = pcall(function()
        return player.OnTeleport:Connect(function()
            begin_transition(120)
        end)
    end)
    if ok then state.teleport_connection = connection end
end

local function sample_local_player()
    -- Roblox replaces LocalPlayer during place transitions. Always fetch the
    -- current object; never interpret the old object's Parent as a failure.
    local player = Players.LocalPlayer
    bind_teleport_event(player)
    if player then
        state.last_player_name = player.Name
        state.last_display_name = player.DisplayName
        state.last_user_id = player.UserId
    end
    return player
end

local function game_is_loaded()
    local ok, loaded = pcall(game.IsLoaded, game)
    return ok and loaded == true
end

local DISCONNECT_TERMS = {
    "disconnect", "connection", "reconnect", "kicked", "internet",
    "teleport failed", "error code", "koneksi", "terputus", "gagal",
    "264", "266", "267", "268", "271", "272", "273", "274",
    "275", "277", "278", "279", "280", "282", "284", "285",
    "286", "524", "529", "610", "769", "770", "771", "772", "773",
}

local function visible_disconnect_prompt()
    local ok, core_gui = pcall(game.GetService, game, "CoreGui")
    if not ok or not core_gui then return false end
    local prompt_gui = core_gui:FindFirstChild("RobloxPromptGui")
    if not prompt_gui then return false end
    local overlay = prompt_gui:FindFirstChild("promptOverlay")
        or prompt_gui:FindFirstChild("PromptOverlay")
    if not overlay then return false end
    local error_prompt = overlay:FindFirstChild("ErrorPrompt")
    if not error_prompt or not error_prompt.Visible then return false end

    -- Hidden prompt templates elsewhere in promptOverlay are deliberately not
    -- scanned because they previously caused false disconnect detections.
    local reason
    local descendants_ok, descendants = pcall(error_prompt.GetDescendants, error_prompt)
    if descendants_ok then
        for _, descendant in ipairs(descendants) do
            local label_ok, is_label = pcall(descendant.IsA, descendant, "TextLabel")
            if label_ok and is_label and descendant.Visible then
                local original = tostring(descendant.Text or "")
                local lowered = string.lower(original)
                for _, term in ipairs(DISCONNECT_TERMS) do
                    if string.find(lowered, term, 1, true) then
                        reason = string.sub(original, 1, 160)
                        break
                    end
                end
            end
            if reason then break end
        end
    end
    return true, reason or "Roblox ErrorPrompt visible"
end

local function write_heartbeat(health, reason)
    if type(writefile) ~= "function" then return false, "writefile is unavailable" end
    local now = os.time()
    local player = sample_local_player()
    local loaded = game_is_loaded()

    if not loaded or not player then begin_transition(30) end
    local loading = not loaded or not player or now < (state.loading_until or 0)
    if not loading then state.transition_started_at = nil end
    if health ~= "disconnected" then health = loading and "loading" or "online" end

    state.sequence = (state.sequence or 0) + 1
    local payload = {
        package = marker.package,
        token = marker.token,
        timestamp = now,
        sequence = state.sequence,
        state = health,
        online = health ~= "disconnected",
        transitioning = health == "loading",
        transition_started_at = state.transition_started_at,
        player_ready = player ~= nil,
        player = state.last_player_name,
        display_name = state.last_display_name,
        user_id = state.last_user_id,
        place_id = game.PlaceId,
        job_id = game.JobId,
    }
    if reason then payload.reason = reason end

    local encoded_ok, body = pcall(HttpService.JSONEncode, HttpService, payload)
    if not encoded_ok then return false, tostring(body) end

    -- Keep two independently readable copies. If Termux samples while one
    -- writefile call is replacing a file, it can still read the other copy.
    local next_ok, next_error = pcall(writefile, redundant_path, body)
    local main_ok, main_error = pcall(writefile, heartbeat_path, body)
    if not next_ok and not main_ok then
        return false, tostring(main_error or next_error)
    end
    return true
end

write_heartbeat("loading")

spawn_task(function()
    local next_write = 0
    local warned = false
    while state.running and shared[STATE_KEY] == state do
        local now = os.time()
        if now >= next_write then
            next_write = now + HEARTBEAT_INTERVAL
            local prompt_visible, reason = false, nil
            local checked, check_error = pcall(function()
                prompt_visible, reason = visible_disconnect_prompt()
            end)
            if checked and prompt_visible then
                state.prompt_hits = state.prompt_hits + 1
            else
                state.prompt_hits = 0
            end
            if not checked and not warned then
                warned = true
                warn("[NOKA] Disconnect check failed: " .. tostring(check_error))
            end

            -- The Roblox prompt must remain visible for two heartbeat samples;
            -- a one-frame/template flash cannot mark the clone disconnected.
            local health = state.prompt_hits >= 2 and "disconnected" or nil
            local written, write_error = write_heartbeat(health, health and reason or nil)
            if not written and not warned then
                warned = true
                warn("[NOKA] Heartbeat write failed: " .. tostring(write_error))
            end
        end
        wait_for(1)
    end
end)

print("[NOKA] Resilient LocalPlayer heartbeat connected.")

]========]

local function running_inside_roblox()
    if game == nil then return false end
    local ok, players = pcall(function() return game:GetService("Players") end)
    return ok and players ~= nil
end

if running_inside_roblox() then
    if type(loadstring) ~= "function" then
        warn("[NOKA] Delta loadstring is unavailable; the embedded heartbeat could not start.")
        return
    end
    local heartbeat_chunk, heartbeat_error = loadstring(EMBEDDED_HEARTBEAT)
    if not heartbeat_chunk then
        warn("[NOKA] Embedded heartbeat compile error: " .. tostring(heartbeat_error))
        return
    end
    return heartbeat_chunk()
end
local DATA_DIR = os.getenv("NOKA_DATA_DIR") or ((os.getenv("HOME") or ".") .. "/NOKA")
local CONFIG_PATH = DATA_DIR .. "/config.lua"
local STATE_DIR = DATA_DIR .. "/state"
local DEVICE_BACKUP_PATH = STATE_DIR .. "/device-backup.lua"
local LOG_PATH = STATE_DIR .. "/noka.log"
local STOP_REQUEST_PATH = STATE_DIR .. "/stop-requested"
local DELTA_ROOT = "/storage/emulated/0/Delta"
local ARCEUS_ROOT = "/storage/emulated/0/Arceus X"
local EXECUTOR_ROOTS = { DELTA_ROOT, ARCEUS_ROOT }
local SYSTEM_AM = "/system/bin/am"
local SYSTEM_INPUT = "/system/bin/input"
local TERMUX_SLEEP = (os.getenv("PREFIX") or "/data/data/com.termux/files/usr") .. "/bin/sleep"
local WARMUP_DELAY = 7
local STATUS_BAR_CLEARANCE = 8
local FAILURE_CONFIRMATIONS = 3
local MIN_HEARTBEAT_TIMEOUT = 30
local TRANSITION_GRACE = 120
local REGISTRATION_TIMEOUT = 45
local WEBHOOK_AVATAR_URL = "https://cdn.discordapp.com/attachments/1476719698090397806/1537197131415167026/5s1b21v.png"
local PLAY_STORE_PACKAGE = "com.android.vending"
local BACKGROUND_OPS = { "RUN_IN_BACKGROUND", "RUN_ANY_IN_BACKGROUND", "WAKE_LOCK", "SYSTEM_ALERT_WINDOW" }
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
        "export NOKA_DATA_DIR=" .. Core.shell_quote(DATA_DIR),
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
    version = 4,
    packages = {},
    launch_delay = 5,
    check_interval = 2,
    heartbeat_timeout = 30,
    startup_grace = 90,
    recovery_cooldown = 15,
    webhook_url = "",
    webhook_interval = 60,
    webhook_message_id = "",
    window_gap = 0,
    top_inset = 0,
    bottom_inset = 0,
    termux_package = "com.termux",
    optimization_applied = false,
}

local function ensure_directory(path)
    os.execute("mkdir -p " .. Core.shell_quote(path))
end

ensure_directory(STATE_DIR)

local function log(level, message)
    local line = string.format("[%s] %-5s %s", os.date("%Y-%m-%d %H:%M:%S"), level, tostring(message))
    print(line)
    local handle = io.open(LOG_PATH, "a")
    if handle then
        handle:write(line, "\n")
        handle:close()
    end
end

local function command(command_line)
    local pipe = io.popen(command_line .. " 2>&1")
    if not pipe then return "", false, -1 end
    local output = pipe:read("*a")
    local ok, _, code = pipe:close()
    return Core.trim(output), ok == true, tonumber(code) or (ok and 0 or 1)
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

local function active_executor_roots()
    local active = {}
    for _, path in ipairs(EXECUTOR_ROOTS) do
        local _, exists = root("test -d " .. Core.shell_quote(path), true)
        if exists then active[#active + 1] = path end
    end
    if #active == 0 then active[1] = DELTA_ROOT end
    return active
end

local function active_executor_workspaces()
    local active = {}
    for _, executor_root in ipairs(active_executor_roots()) do
        local found = false
        for _, folder in ipairs({ "Workspace", "workspace" }) do
            local path = executor_root .. "/" .. folder
            local _, exists = root("test -d " .. Core.shell_quote(path), true)
            if exists then active[#active + 1] = path; found = true end
        end
        if not found then active[#active + 1] = executor_root .. "/Workspace" end
    end
    return active
end

local function copy_table(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[copy_table(key)] = copy_table(item) end
    return result
end

local function merge_defaults(target, defaults)
    for key, value in pairs(defaults) do
        if target[key] == nil then target[key] = copy_table(value) end
    end
    return target
end

local function serialize(value, indent)
    indent = indent or 0
    local value_type = type(value)
    if value_type == "string" then return string.format("%q", value) end
    if value_type == "number" or value_type == "boolean" then return tostring(value) end
    if value_type ~= "table" then return "nil" end
    local pad, next_pad = string.rep(" ", indent), string.rep(" ", indent + 4)
    local result = { "{\n" }
    local numeric = true
    local max = 0
    for key in pairs(value) do
        if type(key) ~= "number" then numeric = false break end
        max = math.max(max, key)
    end
    if numeric then
        for index = 1, max do
            result[#result + 1] = next_pad .. serialize(value[index], indent + 4) .. ",\n"
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
                key_text = "[" .. serialize(key) .. "]"
            end
            result[#result + 1] = next_pad .. key_text .. " = " .. serialize(value[key], indent + 4) .. ",\n"
        end
    end
    result[#result + 1] = pad .. "}"
    return table.concat(result)
end

local function load_lua_table(path)
    local chunk, load_error = loadfile(path, "t", {})
    if not chunk then return nil, load_error end
    local ok, value = pcall(chunk)
    if not ok or type(value) ~= "table" then return nil, value end
    return value
end

local function load_config()
    local loaded = load_lua_table(CONFIG_PATH)
    if type(loaded) ~= "table" then loaded = {} end
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
        loaded.heartbeat_timeout = math.max(MIN_HEARTBEAT_TIMEOUT,
            tonumber(loaded.heartbeat_timeout) or MIN_HEARTBEAT_TIMEOUT)
        loaded.version = 4
    end
    local merged = merge_defaults(loaded, DEFAULT_CONFIG)
    merged.heartbeat_timeout = math.max(MIN_HEARTBEAT_TIMEOUT,
        tonumber(merged.heartbeat_timeout) or MIN_HEARTBEAT_TIMEOUT)
    return merged
end

local function save_config(config)
    local temporary = CONFIG_PATH .. ".tmp"
    local handle, open_error = io.open(temporary, "w")
    if not handle then return nil, open_error end
    handle:write("-- Generated by Noka. Use the Configuration menu to edit safely.\nreturn ", serialize(config), "\n")
    handle:close()
    os.rename(temporary, CONFIG_PATH)
    os.execute("chmod 600 " .. Core.shell_quote(CONFIG_PATH))
    return true
end

local config = load_config()

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
        local slice = math.min(0.2, remaining)
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
    os.remove(STOP_REQUEST_PATH)
    stop_announced = false
    local prefix = os.getenv("PREFIX") or "/data/data/com.termux/files/usr"
    local bash = prefix .. "/bin/bash"
    local watcher = [==[
while true; do
    key=''
    IFS= read -r -s -n 1 key </dev/tty || exit 1
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
    else
        log("INFO", "Press END in Termux at any time to stop Noka")
    end
end

local function stop_end_listener()
    if end_listener_pid then
        root("kill " .. tostring(end_listener_pid) .. " 2>/dev/null || true", true)
        end_listener_pid = nil
    end
    os.remove(STOP_REQUEST_PATH)
end

local function print_header(subtitle)
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
    if subtitle then print(gray .. "  " .. subtitle .. reset) end
    print("")
end

local PANEL_WIDTH = 76

local function print_panel(title, rows)
    local inner_width = PANEL_WIDTH - 4
    local function line(text)
        text = tostring(text or "")
        if #text > inner_width then text = text:sub(1, inner_width - 3) .. "..." end
        print("│ " .. text .. string.rep(" ", inner_width - #text) .. " │")
    end
    print("┌" .. string.rep("─", PANEL_WIDTH - 2) .. "┐")
    line(title)
    line("")
    for _, row in ipairs(rows or {}) do
        line(string.format("  %-3s %-23s %s", row[1], row[2], row[3] or ""))
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
    local temporary = STATE_DIR .. "/packages.txt"
    local handle = assert(io.open(temporary, "w"))
    for _, package_name in ipairs(packages) do handle:write(package_name, "\n") end
    handle:close()
    local output, ok, code = command("grep -E -- " .. Core.shell_quote(pattern) .. " " .. Core.shell_quote(temporary))
    os.remove(temporary)
    if not ok and code == 2 then return nil, "invalid POSIX regular expression" end
    local result = {}
    for package_name in output:gmatch("[^\r\n]+") do result[#result + 1] = package_name end
    return result
end

local function choose_packages()
    local packages, package_error = list_installed_packages()
    if not packages then return nil, package_error end
    while true do
        print_panel("PACKAGE DISCOVERY", {
            { "1.", "Automatic", "com.roblox.*, free.*, premium.*" },
            { "2.", "Regular expression", "custom POSIX package pattern" },
            { "3.", "Names / wildcards", "verified installed packages only" },
        })
        local mode = prompt("Selection", "1")
        local selected
        if mode == "1" then
            selected = Core.filter_automatic_packages(packages)
        elseif mode == "2" then
            local pattern = prompt("Package regex (example: ^example\\..*$)", "")
            selected, package_error = filter_posix_regex(packages, pattern)
            if not selected then print("\n" .. package_error .. "\n") end
        elseif mode == "3" then
            local values = Core.split_list(prompt("Package names/patterns, separated by spaces or commas", ""))
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
    print("")
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
    return url:match("^https://[%w%.%-]*discord%.com/api/webhooks/%d+/[%w_%-%.]+$") ~= nil
        or url:match("^https://discordapp%.com/api/webhooks/%d+/[%w_%-%.]+$") ~= nil
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
    print_header("Setup Wizard")
    if not have_root() then
        print("Noka is root-only. Grant root to Termux, then run the wizard again.")
        return false
    end
    local packages, choose_error = choose_packages()
    if not packages then print(choose_error or "Setup cancelled."); return false end
    local entries = assign_targets(packages, config.packages)
    if not entries then return false end
    local webhook = ask_webhook(config.webhook_url)
    if webhook == nil then return false end
    local delay = prompt_number("Homepage wait before roblox:// game join, in seconds", config.launch_delay, 0, 600)
    if not delay then return false end

    config.packages = entries
    config.webhook_url = webhook
    config.webhook_message_id = ""
    config.launch_delay = delay
    config.optimization_applied = false
    assert(save_config(config))
    print("\nSetup complete. " .. #entries .. " verified package(s) are ready.")
    return true
end

local function configuration_menu()
    while true do
        print_header("Configuration")
        print_panel("CONFIGURATION", {
            { "1.", "Packages", string.format("%d configured", #config.packages) },
            { "2.", "Join destinations", "edit per package" },
            { "3.", "Homepage wait", string.format("%.1f seconds before roblox:// join", config.launch_delay) },
            { "4.", "Discord webhook", config.webhook_url == "" and "disabled" or "configured" },
            { "5.", "Watchdog interval", string.format("%.1f seconds", config.check_interval) },
            { "6.", "Heartbeat timeout", string.format("%.1f seconds", config.heartbeat_timeout) },
            { "7.", "Join grace period", string.format("%.1f seconds", config.startup_grace) },
            { "8.", "Status update", string.format("every %.1f seconds", config.webhook_interval) },
            { "9.", "Window spacing", string.format("%d pixels", config.window_gap) },
            { "0.", "Back", "return to SELECT" },
        })
        print("\nCurrent instances:")
        for index, entry in ipairs(config.packages) do
            print(string.format("     %2d. %-34s %s", index, entry.package, entry.target.display or entry.target.uri))
        end
        local choice = prompt("\nChange", "0")
        if choice == "0" or choice == nil then return end
        if choice == "1" then
            local packages = choose_packages()
            if packages then
                local entries = assign_targets(packages, config.packages)
                if entries then config.packages = entries; config.optimization_applied = false end
            end
        elseif choice == "2" then
            local names = {}
            for _, entry in ipairs(config.packages) do names[#names + 1] = entry.package end
            local entries = assign_targets(names, config.packages)
            if entries then config.packages = entries end
        elseif choice == "3" then
            config.launch_delay = prompt_number("New homepage wait before roblox:// join, in seconds", config.launch_delay, 0, 600) or config.launch_delay
        elseif choice == "4" then
            local value = ask_webhook(config.webhook_url)
            if value then config.webhook_url = value; config.webhook_message_id = "" end
        elseif choice == "5" then
            config.check_interval = prompt_number("New watchdog interval", config.check_interval, 1, 60) or config.check_interval
        elseif choice == "6" then
            config.heartbeat_timeout = prompt_number("New heartbeat timeout", config.heartbeat_timeout,
                MIN_HEARTBEAT_TIMEOUT, 600) or config.heartbeat_timeout
        elseif choice == "7" then
            config.startup_grace = prompt_number("New join grace period", config.startup_grace, 15, 900) or config.startup_grace
        elseif choice == "8" then
            config.webhook_interval = prompt_number("New Discord update interval", config.webhook_interval, 15, 3600) or config.webhook_interval
        elseif choice == "9" then
            config.window_gap = prompt_number("New spacing in pixels", config.window_gap, 0, 100) or config.window_gap
        end
        save_config(config)
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

local function save_device_backup()
    if load_lua_table(DEVICE_BACKUP_PATH) then return true end
    local backup = {
        settings = {}, properties = {}, package_controls = {},
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
    backup.play_store_disabled = disabled:find("package:" .. PLAY_STORE_PACKAGE, 1, true) ~= nil
    backup.deviceidle = root("cmd deviceidle enabled", true)
    local whitelist = root("cmd deviceidle whitelist", true)
    local controlled_packages = { config.termux_package }
    for _, entry in ipairs(config.packages) do controlled_packages[#controlled_packages + 1] = entry.package end
    for _, package_name in ipairs(controlled_packages) do
        local controls = { whitelisted = whitelist:find(package_name, 1, true) ~= nil, appops = {} }
        for _, operation in ipairs(BACKGROUND_OPS) do
            local output = root(string.format("appops get %s %s", Core.shell_quote(package_name), operation), true)
            controls.appops[operation] = output:match(operation .. ":%s*([%w_]+)") or "default"
        end
        backup.package_controls[package_name] = controls
    end
    local handle = assert(io.open(DEVICE_BACKUP_PATH, "w"))
    handle:write("return ", serialize(backup), "\n")
    handle:close()
    os.execute("chmod 600 " .. Core.shell_quote(DEVICE_BACKUP_PATH))
    return true
end

local function grant_background(package_name)
    root("cmd deviceidle whitelist +" .. Core.shell_quote(package_name), true)
    for _, operation in ipairs(BACKGROUND_OPS) do
        root(string.format("appops set %s %s allow", Core.shell_quote(package_name), operation), true)
    end
    root(string.format("cmd appops set %s RUN_IN_BACKGROUND allow", Core.shell_quote(package_name)), true)
end

local function optimize_device()
    local expected_settings
    if not config.optimization_applied then
        log("INFO", "Applying Noka's root device profile")
        save_device_backup()
        local settings = {
            window_animation_scale = "0", transition_animation_scale = "0", animator_duration_scale = "0",
            low_power = "0", low_power_trigger_level = "0", adaptive_battery_management_enabled = "0",
            app_standby_enabled = "0", app_auto_restriction_enabled = "0", forced_app_standby_enabled = "0",
            force_resizable_activities = "1", enable_freeform_support = "1", enable_non_resizable_multi_window = "1",
        }
        expected_settings = settings
        for key, value in pairs(settings) do write_setting("global", key, value) end
        root("cmd deviceidle disable", true)
        root("setprop persist.logd.size 65536", true)
        root("setprop persist.log.tag Settings", true)
        root("setprop persist.log.tag.snet_event_log I", true)
        root("setprop ctl.start logd-reinit", true)
        root("pm disable-user --user 0 " .. PLAY_STORE_PACKAGE, true)
    end
    grant_background(config.termux_package)
    for _, entry in ipairs(config.packages) do grant_background(entry.package) end
    command("termux-wake-lock")
    config.optimization_applied = true
    save_config(config)
    local warnings = 0
    if expected_settings then
        for key, expected in pairs(expected_settings) do
            if read_setting("global", key) ~= expected then
                warnings = warnings + 1
                log("WARN", "Device firmware rejected global setting: " .. key)
            end
        end
        local disabled = root("pm list packages -d --user 0", true)
        if not disabled:find("package:" .. PLAY_STORE_PACKAGE, 1, true) then
            warnings = warnings + 1
            log("WARN", "Google Play Store could not be disabled on this firmware")
        end
        if read_property("persist.log.tag"):sub(1, 8) ~= "Settings" then
            warnings = warnings + 1
            log("WARN", "The firmware rejected the Developer Options log-buffer setting")
        end
    end
    log("INFO", string.format("Device profile applied with %d warning(s); Google Play services were not changed", warnings))
end

local function restore_device()
    if not have_root() then log("ERROR", "Root is required to restore device settings"); return false end
    local backup = load_lua_table(DEVICE_BACKUP_PATH)
    if not backup then log("ERROR", "No Noka device backup exists"); return false end
    for compound, value in pairs(backup.settings or {}) do
        local namespace, key = compound:match("^([^:]+):(.+)$")
        if value == "null" or value == "" then
            root(string.format("settings delete %s %s", namespace, Core.shell_quote(key)), true)
        else
            write_setting(namespace, key, value)
        end
    end
    for key, value in pairs(backup.properties or {}) do root("setprop " .. Core.shell_quote(key) .. " " .. Core.shell_quote(value), true) end
    root("setprop ctl.start logd-reinit", true)
    if not backup.play_store_disabled then root("pm enable --user 0 " .. PLAY_STORE_PACKAGE, true) end
    if tostring(backup.deviceidle):match("1") then root("cmd deviceidle enable", true) end
    for package_name, controls in pairs(backup.package_controls or {}) do
        if not controls.whitelisted then
            root("cmd deviceidle whitelist -" .. Core.shell_quote(package_name), true)
        end
        for operation, mode in pairs(controls.appops or {}) do
            root(string.format("appops set %s %s %s", Core.shell_quote(package_name), operation,
                Core.shell_quote(mode)), true)
        end
    end
    config.optimization_applied = false
    save_config(config)
    command("termux-wake-unlock")
    log("INFO", "Restored the recorded pre-Noka device settings")
    return true
end

local function install_heartbeat()
    local autoexecute_dirs = {}
    local active_autoexecute = {}
    for _, executor_root in ipairs(active_executor_roots()) do
        local found = false
        for _, folder in ipairs({ "Autoexecute", "autoexecute", "Autoexec", "autoexec" }) do
            local path = executor_root .. "/" .. folder
            autoexecute_dirs[#autoexecute_dirs + 1] = path
            local _, exists = root("test -d " .. Core.shell_quote(path), true)
            if exists then active_autoexecute[#active_autoexecute + 1] = path; found = true end
        end
        if not found then active_autoexecute[#active_autoexecute + 1] = executor_root .. "/Autoexecute" end
    end

    local heartbeat_source = STATE_DIR .. "/noka_heartbeat.lua"
    local heartbeat_file, open_error = io.open(heartbeat_source, "w")
    if not heartbeat_file then return nil, "could not extract heartbeat: " .. tostring(open_error) end
    heartbeat_file:write(EMBEDDED_HEARTBEAT)
    heartbeat_file:close()

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

    -- Remove only earlier Noka heartbeat installers. Unrelated auto-execute
    -- scripts are never touched.
    local legacy = {}
    for _, executor_root in ipairs(active_executor_roots()) do
        legacy[#legacy + 1] = executor_root .. "/noka_heartbeat.lua"
    end
    for _, path in ipairs(autoexecute_dirs) do
        legacy[#legacy + 1] = path .. "/noka_heartbeat.lua"
        legacy[#legacy + 1] = path .. "/noka.lua"
    end
    local removals = {}
    for _, path in ipairs(legacy) do removals[#removals + 1] = Core.shell_quote(path) end
    root("rm -f " .. table.concat(removals, " "), true)

    for _, path in ipairs(active_autoexecute) do
        local destination = path .. "/noka_heartbeat.lua"
        local operation = "cp " .. Core.shell_quote(heartbeat_source) .. " " .. Core.shell_quote(destination)
            .. "; chmod 0644 " .. Core.shell_quote(destination)
            .. "; cmp -s " .. Core.shell_quote(heartbeat_source) .. " " .. Core.shell_quote(destination)
        local _, copied = root(operation, true)
        if not copied then return nil, "could not activate Noka heartbeat in " .. path end
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
    local probe = STATE_DIR .. "/display-probe.png"
    local _, captured = root("screencap -p " .. Core.shell_quote(probe)
        .. "; chmod 0644 " .. Core.shell_quote(probe), true)
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

    local content, readable = root("cat " .. Core.shell_quote(path), true)
    if not readable or content == "" then return nil, path, 0, "preferences XML could not be read" end
    local patched, changes, patch_error = Core.patch_app_cloner_bounds(content, bounds)
    if not patched or changes ~= 4 then return nil, path, 0, patch_error or "four exact keys were not found" end

    local temporary = STATE_DIR .. "/app-cloner-bounds-" .. package_name:gsub("[^%w_.-]", "_") .. ".xml"
    local handle, open_error = io.open(temporary, "wb")
    if not handle then return nil, path, 0, tostring(open_error) end
    handle:write(patched)
    handle:close()

    local android_backup = path .. ".bak"
    local noka_backup = path .. ".noka.bak"
    local android_noka_backup = android_backup .. ".noka.bak"
    local qpath, qtemporary = Core.shell_quote(path), Core.shell_quote(temporary)
    local qandroid_backup = Core.shell_quote(android_backup)
    local write_command = "test -e " .. Core.shell_quote(noka_backup) .. " || cp -p "
        .. qpath .. " " .. Core.shell_quote(noka_backup)
        .. "; if test -e " .. qandroid_backup .. "; then test -e " .. Core.shell_quote(android_noka_backup)
        .. " || cp -p " .. qandroid_backup .. " " .. Core.shell_quote(android_noka_backup) .. "; fi"
        .. "; cat " .. qtemporary .. " > " .. qpath .. " || exit 1"
        .. "; if test -e " .. qandroid_backup .. "; then cat " .. qtemporary .. " > "
        .. qandroid_backup .. " || exit 1; fi"
        .. "; restorecon " .. qpath .. " " .. qandroid_backup .. " 2>/dev/null || true; sync"
    local write_output, written = root(write_command, true)
    os.remove(temporary)
    if not written then return nil, path, 0, "XML write failed: " .. tostring(write_output) end

    local verified, verify_ok = root("cat " .. qpath, true)
    local confirmed = verify_ok and Core.confirm_app_cloner_bounds(verified, bounds) or 0
    if confirmed ~= 4 or Core.trim(verified) ~= Core.trim(patched) then
        return nil, path, confirmed, "main XML read-back mismatch"
    end
    local _, android_backup_exists = root("test -e " .. qandroid_backup, true)
    if android_backup_exists then
        local backup_content, backup_ok = root("cat " .. qandroid_backup, true)
        local backup_confirmed = backup_ok and Core.confirm_app_cloner_bounds(backup_content, bounds) or 0
        if backup_confirmed ~= 4 then
            return nil, path, confirmed, "Android SharedPreferences .bak read-back mismatch"
        end
    end
    return true, path, confirmed
end

local function confirm_saved_bounds(path, bounds)
    local content, ok = root("cat " .. Core.shell_quote(path), true)
    if not ok then return false, 0, {} end
    local confirmed, actual = Core.confirm_app_cloner_bounds(content, bounds)
    return confirmed == 4, confirmed, actual
end

local function restore_bounds()
    if not have_root() then log("ERROR", "Root is required to restore App Cloner preferences"); return false end
    local restored = 0
    for _, entry in ipairs(config.packages) do
        local roots = {
            "/storage/emulated/0/Android/data/" .. entry.package,
            "/data/user/0/" .. entry.package .. "/shared_prefs",
            "/data/data/" .. entry.package .. "/shared_prefs",
        }
        local quoted = {}
        for _, path in ipairs(roots) do quoted[#quoted + 1] = Core.shell_quote(path) end
        local output = root("find " .. table.concat(quoted, " ")
            .. " -maxdepth 7 -type f -name '*.noka.bak' 2>/dev/null", true)
        for backup in output:gmatch("[^\r\n]+") do
            local original = backup:gsub("%.noka%.bak$", "")
            local _, ok = root("cp -p " .. Core.shell_quote(backup) .. " " .. Core.shell_quote(original)
                .. "; restorecon " .. Core.shell_quote(original) .. " 2>/dev/null || true", true)
            if ok then restored = restored + 1 end
        end
    end
    log("INFO", string.format("Restored %d App Cloner preference backup(s)", restored))
    return true
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
        root("kill -9 " .. pids:gsub("[^%d%s]", "") .. " 2>/dev/null || true", true)
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
    local temporary = STATE_DIR .. "/current_launch.json"
    local handle = assert(io.open(temporary, "w"))
    handle:write(payload)
    handle:close()
    local operations = {}
    for _, workspace in ipairs(active_executor_workspaces()) do
        local noka_dir = workspace .. "/Noka"
        local marker_path = noka_dir .. "/current_launch.json"
        operations[#operations + 1] = "mkdir -p " .. Core.shell_quote(noka_dir .. "/heartbeats")
        operations[#operations + 1] = "cp " .. Core.shell_quote(temporary) .. " " .. Core.shell_quote(marker_path)
        operations[#operations + 1] = "chmod 0666 " .. Core.shell_quote(marker_path)
    end
    local command_line = table.concat(operations, "; ")
    local output, ok = root(command_line, true)
    os.remove(temporary)
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

local function restart_and_join(entry, state, reason)
    local now = os.time()
    if state.last_attempt and now - state.last_attempt < config.recovery_cooldown then return false end
    state.last_attempt = now
    local token = string.format("%d-%06d", now, math.random(0, 999999))
    local marker_ok, marker_error = write_launch_marker(entry, token)
    if not marker_ok then log("ERROR", entry.package .. ": marker write failed: " .. tostring(marker_error)); return false end

    local stopped, stop_error = terminate_clone(entry)
    if not stopped then
        log("ERROR", entry.package .. ": full termination failed: " .. tostring(stop_error))
        return false
    end
    local saved, preference_path, confirmed, save_error = patch_app_cloner_preferences(entry.package, state.bounds)
    if not saved or confirmed ~= 4 then
        log("ERROR", entry.package .. ": XML bounds save failed before restart: " .. tostring(save_error))
        return false
    end
    state.preference_path = preference_path
    local opened, open_result = launch_homepage(entry)
    if not opened then
        log("ERROR", entry.package .. ": homepage launch failed: " .. tostring(open_result))
        return false
    end
    local persisted, persisted_count = confirm_saved_bounds(preference_path, state.bounds)
    if not persisted then
        terminate_clone(entry)
        log("ERROR", string.format("%s: clone changed its XML bounds during launch (%d/4 remain); stopped",
            entry.package, persisted_count))
        return false
    end
    log("INFO", string.format("%s: homepage opened; waiting %.1f second(s)",
        entry.package, tonumber(config.launch_delay) or 5))
    if not wait_or_stop(config.launch_delay) then return false end
    if stop_requested() then return false end

    local joined, join_result = launch_game(entry)
    if not joined then
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
    local registration_deadline = os.time() + REGISTRATION_TIMEOUT
    while os.time() <= registration_deadline do
        if stop_requested() then return false end
        local heartbeat = read_heartbeat and read_heartbeat(entry.package, token) or nil
        if heartbeat and heartbeat.token == token
            and heartbeat.timestamp and heartbeat.timestamp >= state.last_launch - 5 then
            state.heartbeat = heartbeat
            log("INFO", entry.package .. ": LocalPlayer heartbeat registered")
            return true
        end
        if not wait_or_stop(1) then return false end
    end
    log("ERROR", entry.package .. ": heartbeat did not register within "
        .. REGISTRATION_TIMEOUT .. " seconds; refusing to overwrite its launch marker")
    return false
end

local function close_warm_tasks()
    for _, entry in ipairs(config.packages) do terminate_clone(entry) end
    root(SYSTEM_INPUT .. " keyevent 3", true)
end

local function read_process(package_name)
    local output = root("pidof " .. Core.shell_quote(package_name), true)
    local pid = tonumber(output:match("(%d+)"))
    if not pid then return nil end
    local status = root("cat /proc/" .. pid .. "/status", true)
    local rss = tonumber(status:match("VmRSS:%s*(%d+)%s+kB")) or 0
    local process_stat = root("cat /proc/" .. pid .. "/stat", true)
    local after_name = process_stat:match("^%d+ %b() (.+)$") or ""
    local fields = {}
    for field in after_name:gmatch("%S+") do fields[#fields + 1] = field end
    local ticks = (tonumber(fields[12]) or 0) + (tonumber(fields[13]) or 0)
    return pid, math.floor(rss / 1024 + 0.5), ticks
end

local function window_present(package_name, windows_dump)
    local start = 1
    while true do
        local position = windows_dump:find(package_name, start, true)
        if not position then return false end
        local block = windows_dump:sub(math.max(1, position - 400), math.min(#windows_dump, position + 1400))
        if block:find("isOnScreen=true", 1, true) or block:find("isVisible=true", 1, true)
            or (block:find("mViewVisibility=0x0", 1, true) and block:find("mHasSurface=true", 1, true)) then
            return true
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
            local candidate, ok = root("cat " .. Core.shell_quote(path), true)
            -- Ignore a file sampled midway through writefile(). The redundant
            -- copy normally remains complete while the other is replaced.
            if ok and candidate ~= "" and candidate:match("%}%s*$") then
                local heartbeat = {
                    timestamp = tonumber(candidate:match('"timestamp"%s*:%s*(%d+)')),
                    sequence = tonumber(candidate:match('"sequence"%s*:%s*(%d+)')) or 0,
                    token = candidate:match('"token"%s*:%s*"([^"]*)"'),
                    player = candidate:match('"player"%s*:%s*"([^"]*)"'),
                    user_id = candidate:match('"user_id"%s*:%s*(%d+)'),
                    place_id = candidate:match('"place_id"%s*:%s*(%d+)'),
                    state = candidate:match('"state"%s*:%s*"([^"]*)"'),
                    transitioning = candidate:match('"transitioning"%s*:%s*true') ~= nil,
                    transition_started_at = tonumber(candidate:match('"transition_started_at"%s*:%s*(%d+)')),
                    online = candidate:match('"online"%s*:%s*false') == nil,
                    reason = candidate:match('"reason"%s*:%s*"([^"]*)"'),
                }
                if heartbeat.timestamp and heartbeat.token then
                    if expected_token and heartbeat.token == expected_token then
                        if newer(heartbeat, best_match) then best_match = heartbeat end
                    elseif newer(heartbeat, best_any) then
                        best_any = heartbeat
                    end
                end
            end
        end
    end
    return best_match or best_any
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

local function system_metrics()
    local model = root("getprop ro.product.model", true)
    local meminfo = root("cat /proc/meminfo", true)
    local total = tonumber(meminfo:match("MemTotal:%s*(%d+)")) or 1
    local available = tonumber(meminfo:match("MemAvailable:%s*(%d+)"))
        or tonumber(meminfo:match("MemFree:%s*(%d+)")) or 0
    local battery = root("dumpsys battery", true)
    local temperature = tonumber(battery:match("temperature:%s*(%d+)")) or 0
    local level = tonumber(battery:match("level:%s*(%d+)")) or 0
    return {
        model = model ~= "" and model or "Android device",
        ram_free_mb = math.floor(available / 1024 + 0.5),
        ram_free_pct = math.floor(available * 100 / total + 0.5),
        temperature = temperature / 10,
        battery = level,
    }
end

local previous_cpu
local function cpu_percent()
    local stat = root("head -1 /proc/stat", true)
    local values = {}
    for value in stat:gmatch("%d+") do values[#values + 1] = tonumber(value) end
    if #values < 4 then return 0 end
    local idle = (values[4] or 0) + (values[5] or 0)
    local total = 0
    for _, value in ipairs(values) do total = total + value end
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
    root("chmod 0644 " .. Core.shell_quote(path), true)
    return true
end

local function build_webhook_payload(runtime)
    local metrics = system_metrics()
    local online = 0
    local details = {}
    for _, entry in ipairs(config.packages) do
        local state = runtime[entry.package]
        local status = state.online and "🟢" or "🔴"
        if state.online then online = online + 1 end
        local name = entry.package
        if state.heartbeat and state.heartbeat.player and state.heartbeat.player ~= "" then
            name = name .. " · " .. state.heartbeat.player
        end
        details[#details + 1] = string.format("%s **%s**\n└ ⏱️ %s  |  💾 %d MB  |  ⚡ %.1f%%",
            status, name, Core.format_duration(os.time() - (state.first_seen or os.time())),
            state.rss_mb or 0, state.process_cpu or 0)
    end
    local timestamp = os.time()
    local description = table.concat({
        "Last Updated: " .. os.date("%B %d at %H:%M", timestamp),
        string.format("\n**Device Information:**\n📱┃Device: %s\n⚙️┃CPU: %.0f%%\n💾┃RAM: %d MB free",
            metrics.model, cpu_percent(), metrics.ram_free_mb),
        string.format("\n**Instance Status:**\n🤖┃Total: %d\n🟢┃Online: %d\n🔴┃Offline: %d",
            #config.packages, online, #config.packages - online),
        "\n**Application Details**\n" .. table.concat(details, "\n"),
    }, "\n")
    if #description > 4000 then description = description:sub(1, 3970) .. "\n… additional instances omitted" end
    return {
        username = "Noka",
        avatar_url = WEBHOOK_AVATAR_URL,
        allowed_mentions = { parse = Core.json_array({}) },
        attachments = Core.json_array({ { id = 0, filename = "noka-status.png", description = "Noka floating Roblox instances" } }),
        embeds = Core.json_array({ {
            title = "📊 Noka Status Update",
            description = description,
            image = { url = "attachment://noka-status.png" },
            footer = { text = "discord.gg/noka" },
        } }),
    }
end

local function send_webhook(runtime)
    if config.webhook_url == "" then return true end
    local payload_path = STATE_DIR .. "/webhook-payload.json"
    local screenshot_path = STATE_DIR .. "/noka-status.png"
    capture_screen(screenshot_path)
    local handle = assert(io.open(payload_path, "w"))
    handle:write(Core.json_encode(build_webhook_payload(runtime)))
    handle:close()
    local url = config.webhook_url
    local command_line = "curl -sS -f -X POST "
        .. "-F " .. Core.shell_quote("payload_json=<" .. payload_path)
        .. " -F " .. Core.shell_quote("files[0]=@" .. screenshot_path .. ";type=image/png")
        .. " " .. Core.shell_quote(url)
    local response, ok = command(command_line)
    if not ok then log("WARN", "Discord update failed: " .. response); return false end
    if config.webhook_message_id ~= "" then
        config.webhook_message_id = ""
        save_config(config)
    end
    return true
end

local function verify_configuration()
    if #config.packages == 0 then return nil, "run the Setup Wizard first" end
    if #config.packages > 30 then return nil, "Noka supports a maximum of 30 configured packages" end
    local installed, package_error = list_installed_packages()
    if not installed then return nil, package_error end
    local available = package_set(installed)
    for _, entry in ipairs(config.packages) do
        if not available[entry.package] then return nil, entry.package .. " is no longer installed" end
        local target, target_error = Core.parse_join_target(entry.target.input or entry.target.uri)
        if not target then return nil, entry.package .. ": " .. target_error end
        entry.target.uri = target.uri
        entry.target.kind = target.kind
        entry.target.display = target.display
    end
    return true
end

local function run_sequence(once)
    local valid, configuration_error = verify_configuration()
    if not valid then log("ERROR", configuration_error); return false end
    if not have_root() then log("ERROR", "Noka is root-only; root access was not granted"); return false end
    local heartbeat_ok, heartbeat_error = install_heartbeat()
    if not heartbeat_ok then log("ERROR", heartbeat_error); return false end
    optimize_device()
    start_end_listener()
    local function finish(result)
        stop_end_listener()
        return result
    end

    local width, height, detected_left, detected_top, detected_right, detected_bottom = screen_size()
    local top_inset = math.max(config.top_inset, detected_top + STATUS_BAR_CLEARANCE)
    local bottom_inset = math.max(config.bottom_inset, detected_bottom)
    local left_inset = detected_left
    local right_inset = detected_right
    local bounds, columns, rows, row_counts = Core.calculate_bounds(#config.packages, width, height,
        config.window_gap, top_inset, bottom_inset, left_inset, right_inset)
    log("INFO", string.format(
        "Window grid: %s (%d row(s), max %d columns) framebuffer=%dx%d insets L%d T%d R%d B%d",
        table.concat(row_counts, "+"), rows, columns, width, height,
        left_inset, top_inset, right_inset, bottom_inset))

    log("INFO", string.format("Homepage warm-up phase: every clone receives exactly %d seconds", WARMUP_DELAY))
    for index, entry in ipairs(config.packages) do
        if stop_requested() then return finish(false) end
        local stopped, stop_error = terminate_clone(entry)
        if not stopped then
            log("ERROR", entry.package .. ": could not stop clone before saving bounds: " .. tostring(stop_error))
            close_warm_tasks()
            return finish(false)
        end
        local saved, preference_path, confirmed, save_error = patch_app_cloner_preferences(entry.package, bounds[index])
        if not saved or confirmed ~= 4 then
            log("ERROR", entry.package .. ": App Cloner XML save failed; launch cancelled: " .. tostring(save_error))
            close_warm_tasks()
            return finish(false)
        end
        local cell = bounds[index]
        log("INFO", string.format(
            "%s: bounds saved and confirmed 4/4 (left=%d top=%d right=%d bottom=%d in %s)",
            entry.package, cell.left, cell.top, cell.right, cell.bottom, preference_path))
        local ok, launch_result = launch_homepage(entry)
        if not ok then
            log("ERROR", entry.package .. ": warm launch failed: " .. tostring(launch_result))
            close_warm_tasks()
            return finish(false)
        end
        local persisted, persisted_count = confirm_saved_bounds(preference_path, cell)
        if not persisted then
            terminate_clone(entry)
            log("ERROR", string.format("%s: XML changed during launch (%d/4 bounds remain); sequence cancelled",
                entry.package, persisted_count))
            close_warm_tasks()
            return finish(false)
        end
        log("INFO", entry.package .. ": XML remained confirmed 4/4 after homepage launch")
        log("INFO", string.format("%s: homepage warm-up wait (%d seconds)", entry.package, WARMUP_DELAY))
        if not wait_or_stop(WARMUP_DELAY) then return finish(false) end
    end
    close_warm_tasks()
    log("INFO", "All warm-up clones terminated; Android home screen opened")

    math.randomseed(os.time())
    local runtime = {}
    log("INFO", string.format("Game-join phase: homepage wait is %.1f second(s)",
        tonumber(config.launch_delay) or 5))
    for index, entry in ipairs(config.packages) do
        if stop_requested() then return finish(false) end
        runtime[entry.package] = {
            first_seen = os.time(), last_launch = 0, online = false, rss_mb = 0, bounds = bounds[index],
        }
        if not restart_and_join(entry, runtime[entry.package], "configured join") then
            log("ERROR", entry.package .. ": initial game join could not establish its heartbeat; sequence stopped")
            return finish(false)
        end
    end

    local last_webhook = 0
    cpu_percent()
    while true do
        if stop_requested() then return finish(false) end
        local now = os.time()
        local windows = root("dumpsys window windows", true)
        for index, entry in ipairs(config.packages) do
            local state = runtime[entry.package]
            local pid, rss, ticks = read_process(entry.package)
            if pid and pid ~= state.pid then
                state.pid = pid
                state.first_seen = now
                state.process_ticks = nil
                state.process_sample_at = nil
            end
            state.rss_mb = rss or 0
            if pid and state.process_ticks and state.process_sample_at and now > state.process_sample_at then
                state.process_cpu = math.max(0, math.min(100,
                    (ticks - state.process_ticks) / 100 / (now - state.process_sample_at) * 100))
            else
                state.process_cpu = 0
            end
            state.process_ticks = ticks
            state.process_sample_at = now
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
            if stop_requested() then return finish(false) end
        end
        if config.webhook_url ~= "" and now - last_webhook >= config.webhook_interval then
            send_webhook(runtime)
            last_webhook = now
        end
        if once then return finish(true) end
        if not wait_or_stop(config.check_interval) then return finish(false) end
    end
end

local function open_all_tabs()
    local valid, configuration_error = verify_configuration()
    if not valid then log("ERROR", configuration_error); return false end
    if not have_root() then
        log("ERROR", "Noka is root-only; root access was not granted")
        return false
    end

    local all_opened = true
    for _, entry in ipairs(config.packages) do
        local opened, open_result = launch_homepage(entry)
        if not opened then
            log("ERROR", entry.package .. ": tab launch failed: " .. tostring(open_result))
            all_opened = false
        else
            log("INFO", entry.package .. ": tab opened on the Roblox homepage")
        end
    end
    return all_opened
end

local function main_menu()
    while true do
        print_header()
        print_panel("SELECT", {
            { "1.", "Setup Wizard", "packages, destinations & webhook" },
            { "2.", "Configuration", "view and edit every setting" },
            { "3.", "Start Rejoin", "prepare, launch & supervise clones" },
            { "4.", "Open All Tabs", "open configured clone homepages" },
            { "0.", "Exit", "close Noka" },
        })
        local choice = prompt("\nSelection", "3")
        if choice == "1" then setup_wizard(); prompt("\nPress Enter to continue", "")
        elseif choice == "2" then configuration_menu()
        elseif choice == "3" then run_sequence(false); return
        elseif choice == "4" then open_all_tabs(); prompt("\nPress Enter to continue", "")
        elseif choice == "0" or choice == nil then return
        end
    end
end

local argument = arg and arg[1]
if argument == "--setup" then setup_wizard()
elseif argument == "--start" then run_sequence(false)
elseif argument == "--once" then run_sequence(true)
elseif argument == "--restore-device" then restore_device()
elseif argument == "--restore-bounds" then restore_bounds()
elseif argument == "--check-config" then
    local ok, message = verify_configuration()
    if ok then print("Noka configuration is valid.") else io.stderr:write(message .. "\n"); os.exit(1) end
else main_menu() end
