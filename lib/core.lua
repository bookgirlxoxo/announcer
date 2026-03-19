local Core = {}
Core.__index = Core

local STORAGE_KEY = "schedules"
local CONFIG_PATH = "data/config.json"
local DEFAULT_PREFIX = "&#ffd15c[Announcement] "
local SQL_FILENAME = "announcer.sqlite3"

local function trim(s)
    return tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_name(name)
    return trim(name):lower()
end

local function load_json_file(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end

    local raw = f:read("*a")
    f:close()
    if raw == nil or trim(raw) == "" then
        return nil
    end

    local ok, parsed = pcall(minetest.parse_json, raw)
    if not ok or type(parsed) ~= "table" then
        return nil
    end

    return parsed
end

function Core.new(opts)
    local self = setmetatable({}, Core)
    self.modname = tostring(opts and opts.modname or minetest.get_current_modname() or "announcer")
    self.modpath = tostring(opts and opts.modpath or minetest.get_modpath(self.modname) or "")
    self.storage = minetest.get_mod_storage()
    self.color_lib = rawget(_G, "color_lib")
    self.schedules = {}
    self.accumulator = 0
    self.config = self:load_config()
    self.prefix = self:build_prefix(self.config.prefix)
    self.sql = self:open_sql_backend()

    self:load_schedules()
    self:register_api()
    self:register_shutdown()
    return self
end

function Core:trim(s)
    return trim(s)
end

function Core:normalize_name(name)
    return normalize_name(name)
end

function Core:strip_color_tokens(text)
    local raw = tostring(text or "")
    if self.color_lib and type(self.color_lib.strip_minecraft_hex_tokens) == "function" then
        return self.color_lib.strip_minecraft_hex_tokens(raw)
    end
    return raw
end

function Core:render_message(text)
    local raw = trim(text)
    if raw == "" then
        return nil, "Message cannot be empty."
    end

    if self.color_lib and type(self.color_lib.render_minecraft_hex_text) == "function" then
        local rendered, _, err = self.color_lib.render_minecraft_hex_text(raw, {
            allow_newlines = false,
            append_white = true,
        })
        if rendered and not err then
            return rendered
        end
    end

    return minetest.colorize("#ffffff", raw)
end

function Core:load_config()
    local path = self.modpath .. "/" .. CONFIG_PATH
    local parsed = load_json_file(path)
    if type(parsed) ~= "table" then
        return {prefix = DEFAULT_PREFIX}
    end
    local prefix = tostring(parsed.prefix or "")
    if trim(prefix) == "" then
        prefix = DEFAULT_PREFIX
    end
    return {prefix = prefix}
end

function Core:build_prefix(raw_prefix)
    local raw = tostring(raw_prefix or DEFAULT_PREFIX)
    if self.color_lib and type(self.color_lib.render_minecraft_hex_text) == "function" then
        local rendered = self.color_lib.render_minecraft_hex_text(raw, {
            trim = false,
            allow_newlines = false,
            append_white = false,
        })
        if type(rendered) == "string" and rendered ~= "" then
            return rendered
        end
    end
    return raw
end

function Core:save_schedules()
    if self.sql and self.sql.db and type(self.sql.db.set_root) == "function" then
        local ok, err = pcall(function()
            self.sql.db:set_root("schedules", self.schedules)
        end)
        if ok then
            return
        end
        minetest.log("warning", "[announcer] sql save failed, using mod storage fallback: " .. tostring(err))
    end
    self.storage:set_string(STORAGE_KEY, minetest.write_json(self.schedules))
end

function Core:load_schedules()
    local function sanitize_rows(parsed)
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
                        updated_by = trim(entry.updated_by),
                        updated_at = math.floor(tonumber(entry.updated_at) or 0),
                    }
                end
            end
        end
        return out
    end

    local parsed = nil
    local migrated_from_storage = false

    if self.sql and self.sql.db and type(self.sql.db.root) == "table" and type(self.sql.db.root.schedules) == "table" then
        parsed = self.sql.db.root.schedules
    end

    if type(parsed) ~= "table" or next(parsed) == nil then
        local raw = self.storage:get_string(STORAGE_KEY)
        if raw ~= "" then
            local ok_json, parsed_json = pcall(minetest.parse_json, raw)
            if ok_json and type(parsed_json) == "table" then
                parsed = parsed_json
                migrated_from_storage = self.sql ~= nil
            end
        end
    end

    if type(parsed) ~= "table" then
        self.schedules = {}
        self:save_schedules()
        return
    end

    self.schedules = sanitize_rows(parsed)
    self:save_schedules()
    if migrated_from_storage then
        self.storage:set_string(STORAGE_KEY, "")
    end
end

function Core:broadcast(message)
    local rendered, err = self:render_message(message)
    if not rendered then
        return false, err
    end
    minetest.chat_send_all(self.prefix .. rendered)
    return true
end

function Core:list_entries()
    local out = {}
    for _, entry in pairs(self.schedules) do
        out[#out + 1] = {
            name = entry.name,
            msg = entry.msg,
            interval = entry.interval,
            repeat_enabled = entry.repeat_enabled,
            next_run = entry.next_run,
            created_by = entry.created_by,
            created_at = entry.created_at,
            updated_by = entry.updated_by,
            updated_at = entry.updated_at,
        }
    end
    table.sort(out, function(a, b)
        return normalize_name(a.name) < normalize_name(b.name)
    end)
    return out
end

function Core:add_entry(name, msg, delay_seconds, repeat_enabled, actor)
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

    self.schedules[key] = {
        name = display_name,
        msg = message,
        interval = delay,
        repeat_enabled = repeat_flag,
        next_run = now + delay,
        created_by = trim(actor),
        created_at = now,
        updated_by = "",
        updated_at = 0,
    }

    self:save_schedules()
    return true
end

function Core:edit_entry(name, msg, delay_seconds, has_delay, repeat_enabled, has_repeat, actor)
    local key = normalize_name(name)
    if key == "" then
        return false, "Name cannot be empty."
    end

    local existing = self.schedules[key]
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

    self:save_schedules()
    return true
end

function Core:remove_entry(name)
    local key = normalize_name(name)
    if key == "" then
        return false, "Name cannot be empty."
    end
    if not self.schedules[key] then
        return false, "Announcement not found: " .. key
    end
    self.schedules[key] = nil
    self:save_schedules()
    return true
end

function Core:get_entry(name)
    local key = normalize_name(name)
    if key == "" then
        return nil
    end
    local e = self.schedules[key]
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
        updated_by = e.updated_by,
        updated_at = e.updated_at,
    }
end

function Core:exists(name)
    local key = normalize_name(name)
    return key ~= "" and self.schedules[key] ~= nil
end

function Core:run_entry(name)
    local key = normalize_name(name)
    if key == "" then
        return false, "Name cannot be empty."
    end
    local e = self.schedules[key]
    if type(e) ~= "table" then
        return false, "Announcement not found: " .. key
    end
    return self:broadcast(e.msg)
end

function Core:describe_api()
    return table.concat({
        "announcer API:",
        "- announcer.broadcast(msg)",
        "- announcer.add(name, msg, time_seconds, repeat_enabled[, actor])",
        "- announcer.edit(name, msg[, time_seconds][, repeat_enabled][, has_time][, has_repeat][, actor])",
        "- announcer.run(name)",
        "- announcer.remove(name)",
        "- announcer.list()",
        "- announcer.get(name)",
        "- announcer.exists(name)",
    }, "\n")
end

function Core:register_api()
    local self_ref = self
    local API = {}

    function API.broadcast(msg)
        return self_ref:broadcast(msg)
    end

    function API.add(name, msg, time_seconds, repeat_enabled, actor)
        return self_ref:add_entry(name, msg, time_seconds, repeat_enabled, actor or "api")
    end

    function API.edit(name, msg, time_seconds, repeat_enabled, has_time, has_repeat, actor)
        return self_ref:edit_entry(
            name,
            msg,
            time_seconds,
            has_time == true,
            repeat_enabled,
            has_repeat == true,
            actor or "api"
        )
    end

    function API.remove(name)
        return self_ref:remove_entry(name)
    end

    function API.run(name)
        return self_ref:run_entry(name)
    end

    function API.list()
        return self_ref:list_entries()
    end

    function API.get(name)
        return self_ref:get_entry(name)
    end

    function API.exists(name)
        return self_ref:exists(name)
    end

    function API.describe()
        return self_ref:describe_api()
    end

    rawset(_G, self.modname, API)
end

function Core:process_due(now)
    local changed = false

    for key, entry in pairs(self.schedules) do
        local due = tonumber(entry.next_run)
        if due and due <= now then
            self:broadcast(entry.msg)

            if entry.repeat_enabled and tonumber(entry.interval) and tonumber(entry.interval) > 0 then
                local interval = math.floor(tonumber(entry.interval) or 0)
                local next_run = due
                while next_run <= now do
                    next_run = next_run + interval
                end
                entry.next_run = next_run
                changed = true
            else
                self.schedules[key] = nil
                changed = true
            end
        end
    end

    if changed then
        self:save_schedules()
    end
end

function Core:register_globalstep()
    local self_ref = self
    minetest.register_globalstep(function(dtime)
        self_ref.accumulator = self_ref.accumulator + dtime
        if self_ref.accumulator < 1 then
            return
        end
        self_ref.accumulator = 0
        self_ref:process_due(os.time())
    end)
end

function Core:open_sql_backend()
    local modlib = rawget(_G, "modlib")
    local persistence = type(modlib) == "table" and modlib.persistence or nil
    local sqlite_factory = type(persistence) == "table" and persistence.sqlite3 or nil
    if type(sqlite_factory) ~= "function" then
        return nil
    end

    local ok_mod, sqlite_mod = pcall(sqlite_factory)
    if not ok_mod or type(sqlite_mod) ~= "table" or type(sqlite_mod.new) ~= "function" then
        minetest.log("warning", "[announcer] sqlite backend unavailable: " .. tostring(sqlite_mod))
        return nil
    end

    local db_path = minetest.get_worldpath() .. "/" .. SQL_FILENAME
    local ok_db, db = pcall(sqlite_mod.new, db_path, {schedules = {}})
    if not ok_db or type(db) ~= "table" then
        minetest.log("warning", "[announcer] sqlite open failed: " .. tostring(db))
        return nil
    end

    local ok_init, init_err = pcall(function()
        db:init()
        if type(db.root) ~= "table" then
            db.root = {}
        end
        if type(db.root.schedules) ~= "table" then
            db:set_root("schedules", {})
        end
    end)
    if not ok_init then
        pcall(function()
            db:close()
        end)
        minetest.log("warning", "[announcer] sqlite init failed: " .. tostring(init_err))
        return nil
    end

    minetest.log("action", "[announcer] using sqlite storage: " .. db_path)
    return {db = db, path = db_path}
end

function Core:register_shutdown()
    local sql = self.sql
    if not sql or not sql.db or type(sql.db.close) ~= "function" then
        return
    end
    minetest.register_on_shutdown(function()
        pcall(function()
            sql.db:close()
        end)
    end)
end

return Core
