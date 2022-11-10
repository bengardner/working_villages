--[[
A tool to display the wayzones in a chunk and the exit nodes for each.
Right-click does a single wayzone. Left-click does the whole chunk.
The clicked node must be walkable with two clear nodes above.
]]
local S = default.get_translator

local log = working_villages.require("log")
local pathfinder = working_villages.require("pathfinder")
local wayzone_path = working_villages.require("wayzone_pathfinder")
local wayzone_store = working_villages.require("wayzone_store")
local wayzone_utils = working_villages.require("wayzone_utils")

local waypoint_tool_name = "working_villages:waypoint_tool"

local function do_waypoint_flood(user, pos, all_zones)
	log.action("* waypoint_tool start @ "..minetest.pos_to_string(pos).." "..(all_zones and "full" or "single"))

	local ss = wayzone_store.get()

	local ii = ss:get_pos_info(pos, "tool")

	if all_zones then
		for idx, wz in ipairs(ii.wzc) do
			log.action("* waypoint_tool show "..wz.key)
			wayzone_utils.show_particles_wz(wz)
		end
	else
		if ii.wz ~= nil and ii.wz:inside(pos) then
			log.action("* waypoint_tool show "..ii.wz.key)
			wayzone_utils.show_particles_wz(ii.wz)
		end
	end

	log.action("* waypoint_tool finished @ "..minetest.pos_to_string(pos))
end

local function waypoint_tool_do_stuff(user, pointed_thing, is_use)
	if (pointed_thing.type == "node") then
		local pos = minetest.get_pointed_thing_position(pointed_thing)
		local node_under = minetest.get_node(pointed_thing.under)
		local node_above = minetest.get_node(pointed_thing.above)
		log.action("waypoint_tool: used @ %s above %s '%s', under %s '%s'",
			minetest.pos_to_string(pos),
			minetest.pos_to_string(pointed_thing.above), node_above.name,
			minetest.pos_to_string(pointed_thing.under), node_under.name)

		if pathfinder.can_stand_at(pointed_thing.above, 2) then
			do_waypoint_flood(user, pointed_thing.above, is_use)
		end
	end
end

minetest.register_tool(waypoint_tool_name, {
	description = S("Waypoint Zone Tool"),
	inventory_image = "wayzone_tool.png",
	range = 16,

	on_place = function(itemstack, placer, pointed_thing)
		waypoint_tool_do_stuff(placer, pointed_thing, false)
		return itemstack
	end,

	on_use = function(itemstack, user, pointed_thing)
		waypoint_tool_do_stuff(user, pointed_thing, true)
		return itemstack
	end,
})
