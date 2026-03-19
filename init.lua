local modname = minetest.get_current_modname() or "announcer"
local modpath = minetest.get_modpath(modname)

local Core = dofile(modpath .. "/lib/core.lua")
local Commands = dofile(modpath .. "/lib/commands.lua")

local core = Core.new({
    modname = modname,
})

Commands.install(core)
core:register_globalstep()
