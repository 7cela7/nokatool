local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local NOKADIR = "Noka"
local HEARTBEATS = NOKADIR .. "/heartbeats"
local STATE_KEY = "__NOKA_HEARTBEAT_V4"
local WRITE_INTERVAL = 4
local MARKER_WAIT = 10
local MARKER_MAX_AGE = 1800

if type(writefile) ~= "function"
    or type(readfile) ~= "function"
    or type(makefolder) ~= "function" then
    return
end

local function ensure(path)
    if type(isfolder) == "function" and isfolder(path) then
        return
    end
    pcall(makefolder, path)
end

ensure(NOKADIR)
ensure(HEARTBEATS)

local function read_json(path)
    local ok, text = pcall(readfile, path)
    if not ok or type(text) ~= "string" or text == "" then return nil end
    local decoded, value = pcall(HttpService.JSONDecode, HttpService, text)
    if decoded then return value end
    return nil
end

local function valid_marker(m)
    return type(m) == "table"
        and type(m.package) == "string" and m.package ~= ""
        and type(m.token) == "string" and m.token ~= ""
end

local function find_marker()
    local user_marker
    local player = Players.LocalPlayer
    local user_id = player and player.UserId
    if type(user_id) == "number" then
        local m = read_json(NOKADIR .. "/launch_" .. tostring(user_id) .. ".json")
        if valid_marker(m) then
            user_marker = m
        end
    end

    local shared_marker
    local m = read_json(NOKADIR .. "/current_launch.json")
    if valid_marker(m)
        and type(m.launched_at) == "number"
        and math.abs(os.time() - m.launched_at) <= MARKER_MAX_AGE then
        shared_marker = m
    end

    if shared_marker and (not user_marker or shared_marker.package == user_marker.package) then
        return shared_marker
    end
    return user_marker
end

local marker
local deadline = os.time() + MARKER_WAIT
repeat
    marker = find_marker()
    if not marker then
        task.wait(0.5)
    end
until marker or os.time() >= deadline
if not marker then
    warn("[NOKA] launch marker not found; start this clone through Noka")
    return
end

local shared = getgenv and getgenv() or _G
local previous = shared[STATE_KEY]
if type(previous) == "table" then
    previous.running = false
    if previous.connection then
        pcall(previous.connection.Disconnect, previous.connection)
    end
end

local state = {
    running = true,
    sequence = 0,
    current = "loading",
    transition_started_at = os.time(),
    connection = nil,
}
shared[STATE_KEY] = state

local function property(instance, key)
    local ok, value = pcall(function() return instance[key] end)
    if ok then return value end
    return nil
end

local function heartbeat(health)
    state.sequence = state.sequence + 1
    local player = Players.LocalPlayer
    local payload = {
        package = marker.package,
        token = marker.token,
        state = health,
        timestamp = os.time(),
        sequence = state.sequence,
        online = health ~= "disconnected",
        transitioning = health == "loading" or health == "teleporting",
        transition_started_at = state.transition_started_at,
        place_id = tostring(property(game, "PlaceId") or ""),
        job_id = tostring(property(game, "JobId") or ""),
        player = player and property(player, "Name"),
        user_id = player and property(player, "UserId"),
    }
    local encoded, body = pcall(HttpService.JSONEncode, HttpService, payload)
    if not encoded then
        return
    end
    local path = HEARTBEATS .. "/" .. marker.package:gsub("[^%w%._%-]", "_") .. ".json"
    pcall(writefile, path, body)
    pcall(writefile, path .. ".next", body)
end

local function teleporting()
    state.current = "teleporting"
    state.transition_started_at = os.time()
    heartbeat("teleporting")
end

local function error_prompt_visible()
    local core = game:GetService("CoreGui")
    local gui = core:FindFirstChild("RobloxPromptGui")
    local overlay = gui and gui:FindFirstChild("promptOverlay")
    local prompt = overlay and overlay:FindFirstChild("ErrorPrompt")
    return prompt ~= nil and prompt.Visible == true
end

local function ready()
    local ok, loaded = pcall(game.IsLoaded, game)
    return ok and loaded == true and Players.LocalPlayer ~= nil
end

local player = Players.LocalPlayer
if player and player.OnTeleport then
    local connected, connection = pcall(function()
        return player.OnTeleport:Connect(teleporting)
    end)
    if connected then
        state.connection = connection
    end
end

heartbeat("loading")

task.spawn(function()
    while state.running and shared[STATE_KEY] == state do
        task.wait(WRITE_INTERVAL)

        local prompt_ok, prompt = pcall(error_prompt_visible)
        if prompt_ok and prompt then
            state.current = "disconnected"
        elseif ready() then
            state.current = "active"
            state.transition_started_at = nil
        elseif state.current ~= "teleporting" and state.current ~= "disconnected" then
            state.current = "loading"
            state.transition_started_at = state.transition_started_at or os.time()
        end

        heartbeat(state.current)
    end
end)
