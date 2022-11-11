local init = os.clock()
minetest.log("action", "["..minetest.get_current_modname().."] loading init")

working_villages={
	modpath = minetest.get_modpath("working_villages"),
}

if not minetest.get_modpath("modutil") then
    dofile(working_villages.modpath.."/modutil/portable.lua")
end

modutil.require("local_require")(working_villages)
local log = working_villages.require("log")

function working_villages.setting_enabled(name, default)
  local b = minetest.settings:get_bool("working_villages_enable_"..name)
  if b == nil then
    if default == nil then
      return false
    end
    return default
  end
  return b
end

working_villages.require("groups")
--TODO: check for which preloading is needed
--content
working_villages.require("forms")
working_villages.require("talking")
--TODO: instead use the building sign mod when it is ready
working_villages.require("building")
working_villages.require("storage")

--base
working_villages.require("api")
working_villages.require("register")
working_villages.require("commanding_sceptre")

working_villages.require("deprecated")

working_villages.require("nav/pathfinder_tester")
working_villages.require("nav/query_tool")
working_villages.require("nav/waypoint_tool")
working_villages.require("nav/wayzone_pathfinder")

--job helpers
working_villages.require("jobs/util")
working_villages.require("jobs/empty")
--base jobs
working_villages.require("jobs/builder")
working_villages.require("jobs/follow_player")
working_villages.require("jobs/guard")
working_villages.require("jobs/plant_collector")
working_villages.require("jobs/farmer")
working_villages.require("jobs/woodcutter")
--testing jobs
working_villages.require("jobs/torcher")
working_villages.require("jobs/snowclearer")

working_villages.require("job_tasks")


if working_villages.setting_enabled("spawn",false) then
  working_villages.require("spawn")
end

if working_villages.setting_enabled("debug_tools",false) then
  working_villages.require("util_test")
end

working_villages.nav = working_villages.require("nav/wayzone_store").get({
	height = 2, jump_height = 1, fear_height = 2, can_climb = true })

--ready
local time_to_load= os.clock() - init
log.action("loaded init in %.4f s", time_to_load)

