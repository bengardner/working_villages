--[[
This is a tool to test the pathfinder.
Based off the pathfiner tester used in the dev test.
--]]
local S = minetest.get_translator("testpathfinder")
local log = working_villages.require("log")

local tool_name = "working_villages:testpathfinder"
local marker_name = "working_villages:testpathfinder_dest"

local pathfinder = working_villages.require("nav/pathfinder")
local wayzone_path = working_villages.require("nav/wayzone_pathfinder")
local wayzone_store = working_villages.require("nav/wayzone_store")
local marker_store = working_villages.require("nav/marker_store")
local markers_node = marker_store.new("waypoints", {texture="testpathfinder_waypoint.png", yoffs=0.3, visual_size = {x = 0.3, y = 0.3, z = 0.3}})

local line_store = working_villages.require("nav/line_store")
local path_lines = line_store.new("pathfinder")

local use_coroutine = false

local function co_path(pos1, pos2)
	local wzp = wayzone_path.start(pos1, pos2, {debug=2})

	local path = {}
	local cur_pos = pos1
	while cur_pos ~= nil do
		table.insert(path, cur_pos)
		cur_pos = wzp:next_goal(cur_pos)
	end
	log.action("co return path %d", #path)
	return path
end

local function do_path_find_with_timer(player, pos1, pos2)
	marker_store.clear_all()
	path_lines:clear()

	path_lines:draw_line(pos1, pos2)

	minetest.log("action",
		string.format("Path from %s to %s",
			minetest.pos_to_string(pos1),
			minetest.pos_to_string(pos2)))

	local str = S("Path from @1 to @2:",
		minetest.pos_to_string(pos1),
		minetest.pos_to_string(pos2))
	minetest.chat_send_player(player:get_player_name(), str)

	local time_start = minetest.get_us_time()

	local path
	if use_coroutine == true then
		--local wzp = waypoints.path_start(pos1, pos2)
		local co = coroutine.create(co_path)
		--minetest.log("action", "starting...")
		local ret, val = coroutine.resume(co, pos1, pos2)
		--log.action("  -> %s %s", tostring(ret), tostring(val))
		if ret and val ~= nil then
			path = val
		end
		while coroutine.status(co) ~= "dead" do
			--minetest.log("action", "resuming...")
			ret, val = coroutine.resume(co)
			if ret and val ~= nil then
				path = val
			end
			--log.action("  -> %s %s", tostring(ret), tostring(val))
		end
	else
		path = co_path(pos1, pos2)
	end
	if path == nil then
		minetest.log("action", "done... no path")
		return
	end
	--minetest.log("action", "done..." .. tostring(#path))

	--local c1 = { 0, 255, 100 }
	--local c2 = { 255, 0, 100 }
	local prev = path[1]
	for idx, pos in ipairs(path) do
		local t = "testpathfinder_waypoint.png"
		if idx == #path then
			t = "testpathfinder_waypoint_end.png"
		elseif idx == 1 then
			t = "testpathfinder_waypoint_start.png"
		elseif pos.y ~= prev.y then
			if pos.x == prev.x and pos.z == prev.z then
				if pos.y > prev.y then
					t = "testpathfinder_waypoint_up.png"
				else
					t = "testpathfinder_waypoint_down.png"
				end
			elseif pos.y > prev.y then
				t = "testpathfinder_waypoint_jump.png"
			end
		end
		local c = math.floor(((#path - idx) / #path) * 255)
		markers_node:add(pos, string.format("#%s", idx), {0xff-c, c, 0}, t)
		log.action(" [%d] %s", idx, minetest.pos_to_string(pos))
		prev = pos
	end

	local time_end = minetest.get_us_time()
	local time_diff = time_end - time_start

	minetest.chat_send_player(player:get_player_name(), S("Path length: @1", #path))
	minetest.chat_send_player(player:get_player_name(), S("Time: @1 ms", time_diff/1000))

	--pathfinder.show_particles(path)
end

local function tool_get_position(itemstack)
	local meta = itemstack:get_meta()
	if meta then
		local x = meta:get_int("pos_x")
		local y = meta:get_int("pos_y")
		local z = meta:get_int("pos_z")
		if x and y and z then
			return vector.new(x, y, z)
		end
	end
	return nil
end

local function tool_set_position(itemstack, pos)
	local meta = itemstack:get_meta()
	meta:set_int("pos_x", pos.x)
	meta:set_int("pos_y", pos.y)
	meta:set_int("pos_z", pos.z)
end

local function find_path_for_player(player, itemstack, pos1)
	local pos2 = tool_get_position(itemstack)
	if not pos2 then
		return
	end

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

local function find_path_for_player2(player, itemstack, pos1)
	local meta = itemstack:get_meta()
	if not meta then
		return
	end
	local pos2 = vector.new(meta:get_int("pos_x"), meta:get_int("pos_y"), meta:get_int("pos_z"))
	if not (pos2.x and pos2.y and pos2.z) then
		return
	end
	local gpos1 = pathfinder.get_ground_level(pos1)
	local gpos2 = pathfinder.get_ground_level(pos2)
	if gpos1 == nil or gpos2 == nil then
		log.action("pathfinder tool: invalid positions s=%s e=%s", tostring(gpos1), tostring(gpos2))
		return
	end
	do_path_find_with_timer(player, pos1, pos2)
end

local function set_destination(itemstack, user, pointed_thing)
	if not (user and user:is_player()) then
		return
	end
	if pointed_thing.type == "node" then
		local pos = pointed_thing.above
		tool_set_position(itemstack, pos)
		minetest.chat_send_player(user:get_player_name(), S("Destination set to @1", minetest.pos_to_string(pos)))


		-- TODO: set a marker at the destination (@ pos), save in local
		return itemstack
	end
end

local function find_path_or_set_algorithm(itemstack, user, pointed_thing)
	if not (user and user:is_player()) then
		return
	end
	if pointed_thing.above == nil then
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
minetest.register_tool(tool_name, {
	description = "Pathfinder Tester" .."\n"..
		"Finds path between 2 points" .."\n"..
		"Place on node: Select destination" .."\n"..
		"Punch: Find path from here",
	inventory_image = "testpathfinder_tool.png",
	groups = { testtool = 1, disable_repair = 1 },
	on_use = find_path_or_set_algorithm,
	on_secondary_use = set_destination,
	on_place = set_destination,
	range = 16,
})

-------------------------------------------------------------------------------
-- This creates a pathfinder marker at the destination

minetest.register_entity(marker_name, {
	initial_properties = {
		physical = false,
		visual = "upright_sprite",
		pointable = false,
		collisionbox = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
		visual_size = {x = 1, y = 1, z = 1},
		--textures = {"testpathfinder_marker.png", "testpathfinder_marker.png"},
		textures = {"testpathfinder_tool.png", "testpathfinder_tool.png"},
		glow = 14,
		nametag = "pathfinder\ndestination",
		infotext = "marker",
		static_save = false,
		damage_texture_modifier = "^[brighten",
		show_on_minimap = true,
		automatic_rotate = 0.3,
	},
})

local player_info = {}

local function remove_player_marker(player)
	local pi = player_info[player:get_player_name()]
	if pi and pi.marker then
		local m = pi.marker
		pi.marker = nil
		m:remove()
	end
end

local function refresh_player_marker(player)
	local name = player:get_player_name()
	local pi = player_info[name]
	local pos
	local istack = player:get_wielded_item()

	if istack:get_name() == tool_name then
		pos = tool_get_position(istack)
		if pi == nil then
			pi = {}
			player_info[name] = pi
		end
	end

	if pi then
		if pos then
			if not pi.marker then
				pi.marker = minetest.add_entity(pos, marker_name)
				log.warning("Created pathfinder marker at %s", minetest.pos_to_string(pos))
			else
				pi.marker:set_pos(pos)
			end
		else
			remove_player_marker(player)
		end
	end
end

-- I really want a "on_player_wielditem_change"
minetest.register_globalstep(function(dtime)
	for _, player in ipairs(minetest.get_connected_players()) do
		refresh_player_marker(player)
	end
end)

minetest.register_on_leaveplayer(function(player, timed_out)
	remove_player_marker(player)
end)
