--[[
    Noka LocalPlayer heartbeat 4.1

    Installed by Noka as a separate Delta Autoexec/Autoexecute script.
    It contains no licensing, HWID collection, remote requests, analytics,
    or downloaded code. Communication is local Delta Workspace files only.

    4.0: bounded controller registration, strict marker validation, and
    deterministic connection cleanup after replacement.
    4.1: instance-property reads are exception-proofed and the writer thread
    survives per-tick errors, so a Roblox place-teardown race can never kill
    the heartbeat silently.
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local HEARTBEAT_INTERVAL = 4
local INITIAL_LOADING_GRACE = 12
local STATE_KEY = "__NOKA_LOCALPLAYER_HEARTBEAT_V3"
local task_library = task
local wait_for = task_library and task_library.wait or wait
local spawn_task = task_library and task_library.spawn or spawn

if type(wait_for) ~= "function" or type(spawn_task) ~= "function" then
    warn("[NOKA] This executor does not provide task.wait/spawn compatibility.")
    return
end

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
    if type(marker.launched_at) ~= "number" then return nil end
    if math.abs(os.time() - marker.launched_at) > 1800 then return nil end
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
            if marker then
                -- Return where it was found, so the heartbeat is written beside
                -- it whichever root the executor's file API is relative to.
                local directory = path:match("^(.*)/[^/]+$") or "Noka"
                return marker, directory
            end
        end
    end
    return nil, nil
end

local previous = shared[STATE_KEY]
if type(previous) == "table" then
    previous.running = false
    if previous.teleport_connection then pcall(previous.teleport_connection.Disconnect, previous.teleport_connection) end
end

-- A state surviving a Roblox teleport belongs to this clone. Retaining that
-- package/token prevents another clone's shared launch marker being adopted.
local marker = type(previous) == "table" and previous.marker or nil
local marker_dir = type(previous) == "table" and previous.marker_dir or nil
if type(marker) ~= "table" then
    -- The controller writes the marker immediately before this clone boots, but
    -- an executor can attach a moment early. Retry briefly instead of giving up,
    -- because giving up here means the controller never sees a heartbeat.
    for _ = 1, 20 do
        marker, marker_dir = read_launch_marker()
        if type(marker) == "table" then break end
        wait_for(1)
    end
end
if type(marker) ~= "table" then
    warn("[NOKA] Launch marker unavailable; start this clone through Noka.")
    return
end
marker_dir = marker_dir or "Noka"

local started_at = os.time()
local state = {
    running = true,
    marker = marker,
    marker_dir = marker_dir,
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

ensure_folder(marker_dir)
ensure_folder(marker_dir .. "/heartbeats")

local function safe_name(value)
    return tostring(value):gsub("[^%w%._%-]", "_")
end

local heartbeat_path = marker_dir .. "/heartbeats/" .. safe_name(marker.package) .. ".json"
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
            -- A new hop starts a new transition window; without this reset a
            -- long chain of teleports looks like one stuck 120s+ transition.
            state.transition_started_at = os.time()
            begin_transition(120)
        end)
    end)
    if ok then state.teleport_connection = connection end
end

-- Reading a property off an instance that Roblox is tearing down can throw;
-- a missing value must degrade the sample, never kill the heartbeat thread.
local function safe_property(instance, key)
    local ok, value = pcall(function()
        return instance[key]
    end)
    if ok then return value end
    return nil
end

local function sample_local_player()
    -- Roblox replaces LocalPlayer during place transitions. Always fetch the
    -- current object; never interpret the old object's Parent as a failure.
    local player = Players.LocalPlayer
    bind_teleport_event(player)
    if player then
        state.last_player_name = safe_property(player, "Name")
            or state.last_player_name
        state.last_display_name = safe_property(player, "DisplayName")
            or state.last_display_name
        state.last_user_id = safe_property(player, "UserId")
            or state.last_user_id
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
        place_id = safe_property(game, "PlaceId"),
        job_id = safe_property(game, "JobId"),
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
    local disconnect_warning_sent = false
    local write_warning_sent = false
    local tick_error_count = 0
    while state.running and shared[STATE_KEY] == state do
        local now = os.time()
        if now >= next_write then
            next_write = now + HEARTBEAT_INTERVAL
            -- One thrown error must never kill the writer thread: the
            -- controller can only see this file, so silence equals death.
            local tick_ok, tick_error = pcall(function()
                local prompt_visible, reason = false, nil
                local checked, check_error = pcall(function()
                    prompt_visible, reason = visible_disconnect_prompt()
                end)
                if checked and prompt_visible then
                    state.prompt_hits = math.min(2, state.prompt_hits + 1)
                else
                    state.prompt_hits = 0
                end
                if not checked and not disconnect_warning_sent then
                    disconnect_warning_sent = true
                    warn("[NOKA] Disconnect check failed: " .. tostring(check_error))
                end

                -- The Roblox prompt must remain visible for two heartbeat samples;
                -- a one-frame/template flash cannot mark the clone disconnected.
                local health = state.prompt_hits >= 2 and "disconnected" or nil
                local written, write_error = write_heartbeat(health, health and reason or nil)
                if not written and not write_warning_sent then
                    write_warning_sent = true
                    warn("[NOKA] Heartbeat write failed: " .. tostring(write_error))
                end
            end)
            if not tick_ok then
                tick_error_count = tick_error_count + 1
                if tick_error_count <= 5 then
                    warn("[NOKA] Heartbeat tick error (" .. tick_error_count .. "): " .. tostring(tick_error))
                end
            end
        end
        wait_for(1)
    end
    if state.teleport_connection then
        pcall(state.teleport_connection.Disconnect, state.teleport_connection)
        state.teleport_connection = nil
    end
    state.bound_player = nil
end)

print("[NOKA] Resilient LocalPlayer heartbeat connected.")
