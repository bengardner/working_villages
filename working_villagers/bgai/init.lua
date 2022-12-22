--[[
Some AI stuff, pulled from working_villagers and others.
]]
-- setup bgai with modutil
bgai = {
	modpath = minetest.get_modpath("bgai"),
}

modutil.require("local_require")(bgai)
bgai.log = bg_beds.require("log")

bgai.registered_jobs = {}
bgai.registered_tasks = {}
bgai.bot = {}
bgai.mobkit = {}

-- include lua files to populate the above structures
bgai.require("bgai_api.lua")
bgai.require("bgai_bot.lua")
bgai.require("bgai_mobkit.lua")
