--[[
A tool to display the wayzones in a chunk and the exit nodes for each.
Right-click does a single wayzone. Left-click does the whole chunk.
The clicked node must be walkable with two clear nodes above.
]]
local S = default.get_translator

local log = working_villages.require("log")
local pathfinder = working_villages.require("nav/pathfinder")
local wayzone = working_villages.require("nav/wayzone")
local wayzone_path = working_villages.require("nav/wayzone_pathfinder")
local wayzone_store = working_villages.require("nav/wayzone_store")
local wayzone_utils = working_villages.require("nav/wayzone_utils")
local line_store = working_villages.require("nav/line_store")
local from_lines = line_store.new("wzcenter_from", {spacing = 0.2, color1={255,64,64}, color2={255,64,64} })
local to_lines = line_store.new("wzcenter_to", {spacing = 0.2, color1={64,64,255}, color2={64,64,255} })
local both_lines = line_store.new("wzcenter_both", {spacing = 0.2, color1={255,128,255}, color2={255,128,255} })

local waypoint_tool_name = "working_villages:waypoint_tool"

local function refresh_links(ss, pos)
	local wzc = ss:chunk_get_by_pos(pos)
	if wzc == nil then
		return
	end
	local chunk_size = wayzone.chunk_size
	for x = wzc.pos.x - chunk_size, wzc.pos.x + chunk_size, chunk_size do
		for y = wzc.pos.y - chunk_size, wzc.pos.y + chunk_size, chunk_size do
			for z = wzc.pos.z - chunk_size, wzc.pos.z + chunk_size, chunk_size do
				local other_pos = vector.new(x,y,z)
				local other_wzc = ss:chunk_get_by_pos(other_pos)
				ss:refresh_links(wzc, other_wzc)
			end
		end
	end
end

local function do_waypoint_flood(user, pos, all_zones)
	log.action("* waypoint_tool start @ "..minetest.pos_to_string(pos).." "..(all_zones and "full" or "single"))

	local ss = wayzone_store.get()

	refresh_links(ss, pos)

	local ii = ss:get_pos_info(pos, "tool")
	local upos = user:get_pos()

	if all_zones then
		for idx, wz in ipairs(ii.wzc) do
			log.action("* waypoint_tool show %s : %s-%s", wz.key, minetest.pos_to_string(wz.minp), minetest.pos_to_string(wz.maxp))
			wayzone_utils.show_particles_wz(wz)
			--local close_pos = wz:get_closest(upos)
			--if close_pos ~= nil then
			--	wayzone_utils.put_marker(close_pos, "target")
			--end
		end
	else
		if ii.wz ~= nil and ii.wz:inside(pos) then
			local wz = ii.wz
			log.action("* waypoint_tool show %s : %s-%s", wz.key, minetest.pos_to_string(wz.minp), minetest.pos_to_string(wz.maxp))
			wayzone_utils.show_particles_wz(wz)
			from_lines:clear()
			both_lines:clear()
			to_lines:clear()
			local p1 = wz:get_center_pos()
			--log.action("* wz: %s", dump(wz))
			for k, v in pairs(wz.link_to) do
				log.action("  link_to:   %s xcnt=%d", v.key, v.xcnt)
				local wz2 = ss:wayzone_get_by_key(v.key)
				if wz2 then
					if wz.link_from[k] ~= nil then
						both_lines:draw_line(p1, wz2:get_center_pos())
					else
						to_lines:draw_line(p1, wz2:get_center_pos())
					end
				end
			end
			for k, v in pairs(wz.link_from) do
				log.action("  link_from: %s xcnt=%d", v.key, v.xcnt)
				local wz2 = ss:wayzone_get_by_key(v.key)
				if wz2 then
					if wz.link_to[k] == nil then
						from_lines:draw_line(p1, wz2:get_center_pos())
					end
				end
			end
			--log.action("* link_to: %s", dump(wz.link_to))
			--log.action("* link_from: %s", dump(wz.link_from))
			--wz:split()
			--local close_pos = wz:get_closest(upos)
			--if close_pos ~= nil then
			--	wayzone_utils.put_marker(close_pos, "target")
			--end
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

		local ss = wayzone_store.get()
		refresh_links(ss, pos)

		if ss:get_wayzone_for_pos(pointed_thing.above) then
			do_waypoint_flood(user, pointed_thing.above, is_use)
		elseif ss:get_wayzone_for_pos(pointed_thing.under) then
			do_waypoint_flood(user, pointed_thing.under, is_use)
		end
		--if pathfinder.can_stand_at(pointed_thing.above, 2, "tool") then
		--	do_waypoint_flood(user, pointed_thing.above, is_use)
		--end
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
