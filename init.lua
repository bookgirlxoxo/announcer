local MODNAME = minetest.get_current_modname() or "announcer"
local STORAGE = minetest.get_mod_storage()
local STORAGE_KEY = "schedules"

local PRIV_ANNOUNCE = "announce.announce"
local PRIV_ADD = "announce.add"
local PRIV_REMOVE = "announce.remove"

local PREFIX = minetest.colorize("#ffd15c", "[Announcement] ")
local C = rawget(_G, "color_lib")

local schedules = {}

local function trim(s)
    return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_name(name)
    return trim(name):lower()
end

local function to_bool_token(v)
    local t = tostring(v or ""):lower()
    if t == "true" or t == "1" or t == "yes" or t == "on" then
        return true, true
    end
    if t == "false" or t == "0" or t == "no" or t == "off" then
        return false, true
    end
    return false, false
end

local function strip_color_tokens(text)
    local raw = tostring(text or "")
    if C and type(C.strip_minecraft_hex_tokens) == "function" then
        return C.strip_minecraft_hex_tokens(raw)
    end
    return raw
end

local function render_message(text)
    local raw = trim(text)
    if raw == "" then
        return nil, "Message cannot be empty."
    end

    if C and type(C.render_minecraft_hex_text) == "function" then
        local rendered, _, err = C.render_minecraft_hex_text(raw, {
            allow_newlines = false,
            append_white = true,
        })
        if rendered and not err then
            return rendered
        end
    end

    return minetest.colorize("#ffffff", raw)
end

local function save_schedules()
    STORAGE:set_string(STORAGE_KEY, minetest.write_json(schedules))
end

local function load_schedules()
    local raw = STORAGE:get_string(STORAGE_KEY)
    if raw == "" then
        return
    end

    local ok, parsed = pcall(minetest.parse_json, raw)
    if not ok or type(parsed) ~= "table" then
        minetest.log("warning", "[announcer] invalid schedule storage; resetting")
        schedules = {}
        save_schedules()
        return
    end

    local now = os.time()
    local out = {}
    for key, entry in pairs(parsed) do
        if type(entry) == "table" then
            local name = trim(entry.name or key)
            local msg = trim(entry.msg)
            local interval = math.max(0, math.floor(tonumber(entry.interval) or 0))
            local repeat_enabled = entry.repeat_enabled == true
            local next_run = math.floor(tonumber(entry.next_run) or now)

            if name ~= "" and msg ~= "" then
                local normalized = normalize_name(name)
                if repeat_enabled and interval <= 0 then
                    repeat_enabled = false
                end
                out[normalized] = {
                    name = name,
                    msg = msg,
                    interval = interval,
                    repeat_enabled = repeat_enabled,
                    next_run = next_run,
                    created_by = trim(entry.created_by),
                    created_at = math.floor(tonumber(entry.created_at) or now),
                }
            end
        end
    end

    schedules = out
    save_schedules()
end

local function broadcast_announcement(message)
    local rendered, err = render_message(message)
    if not rendered then
        return false, err
    end
    minetest.chat_send_all(PREFIX .. rendered)
    return true
end

local function list_entries()
    local out = {}
    for _, entry in pairs(schedules) do
        out[#out + 1] = {
            name = entry.name,
            msg = entry.msg,
            interval = entry.interval,
            repeat_enabled = entry.repeat_enabled,
            next_run = entry.next_run,
            created_by = entry.created_by,
            created_at = entry.created_at,
        }
    end
    table.sort(out, function(a, b)
        return normalize_name(a.name) < normalize_name(b.name)
    end)
    return out
end

local function add_entry(name, msg, delay_seconds, repeat_enabled, actor)
    local display_name = trim(name)
    if display_name == "" then
        return false, "Name cannot be empty."
    end

    local message = trim(msg)
    if message == "" then
        return false, "Message cannot be empty."
    end

    local delay = math.floor(tonumber(delay_seconds) or 0)
    if delay < 0 then
        return false, "Time must be 0 or higher."
    end

    local repeat_flag = repeat_enabled == true
    if repeat_flag and delay <= 0 then
        return false, "Repeat requires time > 0."
    end

    local key = normalize_name(display_name)
    local now = os.time()

    schedules[key] = {
        name = display_name,
        msg = message,
        interval = delay,
        repeat_enabled = repeat_flag,
        next_run = now + delay,
        created_by = trim(actor),
        created_at = now,
    }

    save_schedules()
    return true
end

local function edit_entry(name, msg, delay_seconds, has_delay, repeat_enabled, has_repeat, actor)
    local key = normalize_name(name)
    if key == "" then
        return false, "Name cannot be empty."
    end

    local existing = schedules[key]
    if type(existing) ~= "table" then
        return false, "Announcement not found: " .. key
    end

    local message = trim(msg)
    if message == "" then
        return false, "Message cannot be empty."
    end

    local new_delay = existing.interval
    if has_delay then
        local d = math.floor(tonumber(delay_seconds) or 0)
        if d < 0 then
            return false, "Time must be 0 or higher."
        end
        new_delay = d
    end

    local new_repeat = existing.repeat_enabled
    if has_repeat then
        new_repeat = repeat_enabled == true
    end

    if new_repeat and new_delay <= 0 then
        return false, "Repeat=true requires a time greater than 0."
    end

    existing.msg = message
    existing.interval = new_delay
    existing.repeat_enabled = new_repeat
    existing.next_run = os.time() + new_delay
    existing.updated_by = trim(actor)
    existing.updated_at = os.time()

    save_schedules()
    return true
end

local function remove_entry(name)
    local key = normalize_name(name)
    if key == "" then
        return false, "Name cannot be empty."
    end
    if not schedules[key] then
        return false, "Announcement not found: " .. key
    end
    schedules[key] = nil
    save_schedules()
    return true
end

local API = {}

function API.broadcast(msg)
    return broadcast_announcement(msg)
end

function API.add(name, msg, time_seconds, repeat_enabled, actor)
    return add_entry(name, msg, time_seconds, repeat_enabled, actor or "api")
end

function API.remove(name)
    return remove_entry(name)
end

function API.edit(name, msg, time_seconds, repeat_enabled, has_time, has_repeat, actor)
    return edit_entry(name, msg, time_seconds, has_time == true, repeat_enabled, has_repeat == true, actor or "api")
end

function API.list()
    return list_entries()
end

function API.get(name)
    local key = normalize_name(name)
    if key == "" then
        return nil
    end
    local e = schedules[key]
    if type(e) ~= "table" then
        return nil
    end
    return {
        name = e.name,
        msg = e.msg,
        interval = e.interval,
        repeat_enabled = e.repeat_enabled,
        next_run = e.next_run,
        created_by = e.created_by,
        created_at = e.created_at,
    }
end

function API.exists(name)
    local key = normalize_name(name)
    return key ~= "" and schedules[key] ~= nil
end

function API.describe()
    return table.concat({
        "announcer API:",
        "- announcer.broadcast(msg)",
        "- announcer.add(name, msg, time_seconds, repeat_enabled[, actor])",
        "- announcer.edit(name, msg[, time_seconds][, repeat_enabled][, has_time][, has_repeat][, actor])",
        "- announcer.remove(name)",
        "- announcer.list()",
        "- announcer.get(name)",
        "- announcer.exists(name)",
    }, "\n")
end

rawset(_G, MODNAME, API)

local function has_priv(player_name, priv)
    return minetest.check_player_privs(player_name, {[priv] = true})
end

local function parse_manage_params(raw)
    local name, tail = tostring(raw or ""):match("^(%S+)%s+(.+)$")
    if not name or not tail then
        return nil, "Usage: /announce add|edit <name> <msg> [time] [repeat]"
    end

    local words = {}
    for token in tostring(tail):gmatch("%S+") do
        words[#words + 1] = token
    end
    if #words == 0 then
        return nil, "Message is required."
    end

    local repeat_enabled = false
    local has_repeat = false
    local last_bool, is_bool = to_bool_token(words[#words])
    if is_bool then
        repeat_enabled = last_bool
        has_repeat = true
        table.remove(words)
    end

    local delay = nil
    local has_delay = false
    if #words > 0 and words[#words]:match("^%-?%d+$") then
        delay = math.floor(tonumber(words[#words]) or 0)
        has_delay = true
        table.remove(words)
    end

    local msg = table.concat(words, " ")
    if trim(msg) == "" then
        return nil, "Message is required."
    end

    if delay ~= nil and delay < 0 then
        return nil, "Time must be 0 or higher."
    end

    if has_repeat and repeat_enabled and (delay == nil or delay <= 0) then
        return nil, "Repeat=true requires a time greater than 0."
    end

    return {
        name = name,
        msg = msg,
        delay = delay,
        has_delay = has_delay,
        repeat_enabled = repeat_enabled,
        has_repeat = has_repeat,
    }
end

local function send_usage(name)
    return true, table.concat({
        "Usage:",
        "/announce <msg>",
        "/announce add <name> <msg> [time] [repeat]",
        "/announce edit <name> <msg> [time] [repeat]",
        "/announce remove <name>",
        "/announce delete <name>",
        "/announce list",
        "Alias: /annunce <same as /announce>",
    }, "\n")
end

local function announce_command(name, param)
    local input = trim(param)
    if input == "" then
        return send_usage(name)
    end

    local sub, rest = input:match("^(%S+)%s*(.*)$")
    sub = tostring(sub or ""):lower()
    rest = trim(rest)

    if sub == "add" then
        if not has_priv(name, PRIV_ADD) then
            return false, "Missing privilege: " .. PRIV_ADD
        end
        local parsed, err = parse_manage_params(rest)
        if not parsed then
            return false, err
        end
        local delay = parsed.has_delay and parsed.delay or 0
        local repeat_enabled = parsed.has_repeat and parsed.repeat_enabled or false
        local ok, add_err = add_entry(parsed.name, parsed.msg, delay, repeat_enabled, name)
        if not ok then
            return false, add_err
        end
        local mode = repeat_enabled and "repeat" or "once"
        return true, string.format("Added '%s' (%s, delay=%ds).", normalize_name(parsed.name), mode, delay)
    end

    if sub == "edit" then
        if not has_priv(name, PRIV_ADD) then
            return false, "Missing privilege: " .. PRIV_ADD
        end
        local parsed, err = parse_manage_params(rest)
        if not parsed then
            return false, err
        end
        local ok, edit_err = edit_entry(
            parsed.name,
            parsed.msg,
            parsed.delay,
            parsed.has_delay,
            parsed.repeat_enabled,
            parsed.has_repeat,
            name
        )
        if not ok then
            return false, edit_err
        end

        local e = schedules[normalize_name(parsed.name)]
        local mode = (e and e.repeat_enabled) and "repeat" or "once"
        local delay = (e and e.interval) or 0
        return true, string.format("Edited '%s' (%s, delay=%ds).", normalize_name(parsed.name), mode, delay)
    end

    if sub == "remove" or sub == "delete" then
        if not has_priv(name, PRIV_REMOVE) then
            return false, "Missing privilege: " .. PRIV_REMOVE
        end
        if rest == "" then
            return false, "Usage: /announce " .. sub .. " <name>"
        end
        local ok, rem_err = remove_entry(rest)
        if not ok then
            return false, rem_err
        end
        return true, "Removed announcement '" .. normalize_name(rest) .. "'."
    end

    if sub == "list" then
        if not has_priv(name, PRIV_ADD) then
            return false, "Missing privilege: " .. PRIV_ADD
        end
        local entries = list_entries()
        if #entries == 0 then
            return true, "No announcements scheduled."
        end

        local now = os.time()
        local lines = {"Announcements (" .. tostring(#entries) .. "):"}
        for i = 1, #entries do
            local e = entries[i]
            local secs = math.max(0, (tonumber(e.next_run) or now) - now)
            local mode = e.repeat_enabled and ("every " .. tostring(e.interval) .. "s") or "once"
            lines[#lines + 1] = string.format("- %s | %s | in %ds | %s",
                normalize_name(e.name),
                mode,
                secs,
                trim(strip_color_tokens(e.msg)))
        end
        return true, table.concat(lines, "\n")
    end

    if not has_priv(name, PRIV_ANNOUNCE) then
        return false, "Missing privilege: " .. PRIV_ANNOUNCE
    end

    local ok, err = broadcast_announcement(input)
    if not ok then
        return false, err
    end
    return true, "Announcement sent."
end

minetest.register_privilege(PRIV_ANNOUNCE, {
    description = "Send immediate announcements.",
    give_to_singleplayer = false,
})

minetest.register_privilege(PRIV_ADD, {
    description = "Add/list automatic or scheduled announcements.",
    give_to_singleplayer = false,
})

minetest.register_privilege(PRIV_REMOVE, {
    description = "Remove scheduled announcements.",
    give_to_singleplayer = false,
})

minetest.register_chatcommand("announce", {
    params = "<msg> | add <name> <msg> [time] [repeat] | edit <name> <msg> [time] [repeat] | remove <name> | delete <name> | list",
    description = "Send or manage server announcements.",
    privs = {},
    func = announce_command,
})

minetest.register_chatcommand("annunce", {
    params = minetest.registered_chatcommands["announce"].params,
    description = "Alias for /announce.",
    privs = {},
    func = announce_command,
})

load_schedules()

local accumulator = 0
minetest.register_globalstep(function(dtime)
    accumulator = accumulator + dtime
    if accumulator < 1 then
        return
    end
    accumulator = 0

    local now = os.time()
    local changed = false

    for key, entry in pairs(schedules) do
        local due = tonumber(entry.next_run)
        if due and due <= now then
            broadcast_announcement(entry.msg)

            if entry.repeat_enabled and tonumber(entry.interval) and tonumber(entry.interval) > 0 then
                local interval = math.floor(tonumber(entry.interval) or 0)
                local next_run = due
                while next_run <= now do
                    next_run = next_run + interval
                end
                entry.next_run = next_run
                changed = true
            else
                schedules[key] = nil
                changed = true
            end
        end
    end

    if changed then
        save_schedules()
    end
end)
