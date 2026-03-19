# announcer

Server-wide announcements with manual and scheduled modes.

## Commands

- `/announce <msg>`
- `/announce add <name> <msg> [time] [repeat]`
- `/announce edit <name> <msg> [time] [repeat]`
- `/announce run <name>`
- `/announce remove <name>`
- `/announce delete <name>`
- `/announce list`
- `/annunce ...` (alias for `/announce`)

Notes:

- `time` is seconds.
- `repeat` supports `true/false`, `1/0`, `yes/no`, `on/off`.
- If `add` omits time/repeat, it creates a one-time immediate announcement.
- `edit` updates message and optionally time/repeat; omitted time/repeat keep existing values.
- `run` sends a saved announcement immediately.

Examples:

- `/announce Hello miners!`
- `/announce add welcome Hello world 900 true`
  - sends `Hello world` every 900 seconds
- `/announce edit welcome Hello miners, check /mine 120 true`

## Privileges

- `announce.announce`: manual `/announce <msg>` and `/announce run <name>`
- `announce.add`: `/announce add`, `/announce edit`, `/announce list`
- `announce.remove`: `/announce remove|delete`

## Color Support

If `color_lib` is installed, announcement message text supports color tokens like:

- `&#RRGGBB`
- `&#RRGGBB;`
- `<&#RRGGBB>`

## Config

- `prefix`: prefix shown before every announcement message.

```json
{
  "prefix": "&#ffd15c[Announcement] "
}
```

## API

Global table: `announcer`

- `announcer.broadcast(msg)`
- `announcer.add(name, msg, time_seconds, repeat_enabled[, actor])`
- `announcer.edit(name, msg, time_seconds, repeat_enabled[, has_time][, has_repeat][, actor])`
- `announcer.run(name)`
- `announcer.remove(name)`
- `announcer.list()`
- `announcer.get(name)`
- `announcer.exists(name)`

Schedules persist in mod storage.

## API Hook Example

```lua
minetest.register_on_mods_loaded(function()
    local A = rawget(_G, "announcer")
    if type(A) ~= "table" then
        return
    end

    -- Add or update a repeating server reminder every 15 minutes.
    if A.exists("smell_reminder") then
        A.edit("smell_reminder", "You smell, go shower!", 900, true, true, true, "my_mod")
    else
        A.add("smell_reminder", "You smell, go shower!", 900, true, "my_mod")
    end

    -- Send a one-time startup message.
    A.broadcast("Server online, have fun!")
end)
```
