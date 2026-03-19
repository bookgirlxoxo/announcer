local Commands = {}

local PRIV_ANNOUNCE = "announce.announce"
local PRIV_ADD = "announce.add"
local PRIV_REMOVE = "announce.remove"

local function trim(s)
    return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
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

local function send_usage()
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

function Commands.install(core)
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

    local function announce_command(name, param)
        local input = trim(param)
        if input == "" then
            return send_usage()
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
            local ok, add_err = core:add_entry(parsed.name, parsed.msg, delay, repeat_enabled, name)
            if not ok then
                return false, add_err
            end
            local mode = repeat_enabled and "repeat" or "once"
            return true, string.format("Added '%s' (%s, delay=%ds).", core:normalize_name(parsed.name), mode, delay)
        end

        if sub == "edit" then
            if not has_priv(name, PRIV_ADD) then
                return false, "Missing privilege: " .. PRIV_ADD
            end
            local parsed, err = parse_manage_params(rest)
            if not parsed then
                return false, err
            end
            local ok, edit_err = core:edit_entry(
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

            local e = core:get_entry(parsed.name)
            local mode = (e and e.repeat_enabled) and "repeat" or "once"
            local delay = (e and e.interval) or 0
            return true, string.format("Edited '%s' (%s, delay=%ds).", core:normalize_name(parsed.name), mode, delay)
        end

        if sub == "remove" or sub == "delete" then
            if not has_priv(name, PRIV_REMOVE) then
                return false, "Missing privilege: " .. PRIV_REMOVE
            end
            if rest == "" then
                return false, "Usage: /announce " .. sub .. " <name>"
            end
            local ok, rem_err = core:remove_entry(rest)
            if not ok then
                return false, rem_err
            end
            return true, "Removed announcement '" .. core:normalize_name(rest) .. "'."
        end

        if sub == "list" then
            if not has_priv(name, PRIV_ADD) then
                return false, "Missing privilege: " .. PRIV_ADD
            end
            local entries = core:list_entries()
            if #entries == 0 then
                return true, "No announcements scheduled."
            end

            local now = os.time()
            local lines = {"Announcements (" .. tostring(#entries) .. "):"}
            for i = 1, #entries do
                local e = entries[i]
                local secs = math.max(0, (tonumber(e.next_run) or now) - now)
                local mode = e.repeat_enabled and ("every " .. tostring(e.interval) .. "s") or "once"
                lines[#lines + 1] = string.format(
                    "- %s | %s | in %ds | %s",
                    core:normalize_name(e.name),
                    mode,
                    secs,
                    trim(core:strip_color_tokens(e.msg))
                )
            end
            return true, table.concat(lines, "\n")
        end

        if not has_priv(name, PRIV_ANNOUNCE) then
            return false, "Missing privilege: " .. PRIV_ANNOUNCE
        end

        local ok, err = core:broadcast(input)
        if not ok then
            return false, err
        end
        return true, "Announcement sent."
    end

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
end

return Commands
