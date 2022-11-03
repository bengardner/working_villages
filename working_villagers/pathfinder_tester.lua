--[[
This is a tool to test the pathfinder.
Based off the pathfiner tester used in the dev test.
--]]
local S = minetest.get_translator("testpathfinder")
local log = working_villages.require("log")

local pathfinder = working_villages.require("pathfinder")
local waypoints = working_villages.require("waypoint_zones")
local wayzone_path = working_villages.require("wayzone_pathfinder")

local function find_path_for_player(player, itemstack, pos1)
	local meta = itemstack:get_meta()
	if not meta then
		return
	end
	local x = meta:get_int("pos_x")
	local y = meta:get_int("pos_y")
	local z = meta:get_int("pos_z")
	if x and y and z then
		local pos2 = vector.new(x, y, z)
		local p1_g = pathfinder.get_ground_level(pos1)
		local p2_g = pathfinder.get_ground_level(pos2)
		--local pos1 = vector.round(player:get_pos())
		local str = S("Tool: Path from @1 @2 to @3 @4:",
			minetest.pos_to_string(pos1), minetest.pos_to_string(p1_g),
			minetest.pos_to_string(pos2), minetest.pos_to_string(p2_g))
		minetest.chat_send_player(player:get_player_name(), str)
		minetest.log("action",
			string.format("Path %s/%s -> %s/%s",
				minetest.pos_to_string(pos1), minetest.pos_to_string(p1_g),
				minetest.pos_to_string(pos2), minetest.pos_to_string(p2_g)))

		local time_start = minetest.get_us_time()
		local path = pathfinder.find_path(pos1, pos2, nil)
		local time_end = minetest.get_us_time()
		local time_diff = time_end - time_start
		str = ""
		if not path then
			minetest.chat_send_player(player:get_player_name(), S("No path!"))
			minetest.chat_send_player(player:get_player_name(), S("Time: @1 ms", time_diff/1000))
			return
		end
		minetest.chat_send_player(player:get_player_name(), str)
		minetest.chat_send_player(player:get_player_name(), S("Path length: @1", #path))
		minetest.chat_send_player(player:get_player_name(), S("Time: @1 ms", time_diff/1000))
	end
end

local function find_path_for_player2(player, itemstack, pos1)
	local meta = itemstack:get_meta()
	if not meta then
		return
	end
	local pos2 = vector.new(meta:get_int("pos_x"), meta:get_int("pos_y"), meta:get_int("pos_z"))
	if not (pos2.x and pos2.y and pos2.z) then
		return
	end
	local pos1 = pathfinder.get_ground_level(pos1)
	local pos2 = pathfinder.get_ground_level(pos2)
	if pos1 == nil or pos2 == nil then
		minetest.log("action", string.format("pathfinder tool: invalid positions s=%s e=%s", tostring(pos1), tostring(pos2)))
		return
	end
	minetest.log("action",
		string.format("Path from %s to %s",
			minetest.pos_to_string(pos1),
			minetest.pos_to_string(pos2)))

	local str = S("Path from @1 to @2:",
		minetest.pos_to_string(pos1),
		minetest.pos_to_string(pos2))
	minetest.chat_send_player(player:get_player_name(), str)

	local time_start = minetest.get_us_time()

	--local wzp = waypoints.path_start(pos1, pos2)
	local wzp = wayzone_path.start(pos1, pos2)

	local time_end = minetest.get_us_time()
	local time_diff = time_end - time_start

	if not wzp then
		minetest.chat_send_player(player:get_player_name(), S("No path!"))
		minetest.chat_send_player(player:get_player_name(), S("Time: @1 ms", time_diff/1000))
		return
	end

	local path = {}
	local cur_pos = pos1
	while cur_pos ~= nil do
		table.insert(path, cur_pos)
		cur_pos = wzp:next_goal(cur_pos)
	end

	time_end = minetest.get_us_time()
	time_diff = time_end - time_start

	minetest.chat_send_player(player:get_player_name(), S("Path length: @1", #path))
	minetest.chat_send_player(player:get_player_name(), S("Time: @1 ms", time_diff/1000))

	pathfinder.show_particles(path)
end

local function set_destination(itemstack, user, pointed_thing)
	if not (user and user:is_player()) then
		return
	end
	local name = user:get_player_name()
	local obj
	local meta = itemstack:get_meta()
	if pointed_thing.type == "node" then
		local pos = pointed_thing.above
		meta:set_int("pos_x", pos.x)
		meta:set_int("pos_y", pos.y)
		meta:set_int("pos_z", pos.z)
		minetest.chat_send_player(user:get_player_name(), S("Destination set to @1", minetest.pos_to_string(pos)))
		-- TODO: set a marker at the destination (@ pos), save in local
		return itemstack
	end
end

local function find_path_or_set_algorithm(itemstack, user, pointed_thing)
	if not (user and user:is_player()) then
		return
	end
	local ctrl = user:get_player_control()
	-- No sneak: Find path
	if not ctrl.sneak then
		if pointed_thing.type == "node" then
			find_path_for_player2(user, itemstack, pointed_thing.above)
		end
	else
		pathfinder.node_check(pointed_thing.above)
		-- TODO: toggle debug?
		return itemstack
	end
end

-- Punch: Find path
-- Sneak+punch: Select pathfinding algorithm
-- Place: Select destination node
minetest.register_tool("working_villages:testpathfinder", {
	description = "Pathfinder Tester" .."\n"..
		"Finds path between 2 points" .."\n"..
		"Place on node: Select destination" .."\n"..
		"Punch: Find path from here",
	inventory_image = "testpathfinder_tool.png",
	groups = { testtool = 1, disable_repair = 1 },
	on_use = find_path_or_set_algorithm,
	on_secondary_use = set_destination,
	on_place = set_destination,
})
