local S = minetest.get_translator("testpathfinder")

local pathfinder = {}

local debug_pathfinder = true

--[[
minetest.get_content_id(name)
minetest.registered_nodes
minetest.get_name_from_content_id(id)
local ivm = a:index(pos.x, pos.y, pos.z)
local ivm = a:indexp(pos)
minetest.hash_node_position({x=,y=,z=})
minetest.get_position_from_hash(hash)

start_index, target_index, current_index
^ Hash of position

current_value
^ {int:hCost, int:gCost, int:fCost, hash:parent, vect:pos}
]]--


--print("loading pathfinder")

--TODO: route via climbable


local function get_distance(start_pos, end_pos)
	local distX = math.abs(start_pos.x - end_pos.x)
	local distZ = math.abs(start_pos.z - end_pos.z)

	if distX > distZ then
		return 14 * distZ + 10 * (distX - distZ)
	else
		return 14 * distX + 10 * (distZ - distX)
	end
end

local function get_distance_to_neighbor(start_pos, end_pos)
	local distX = math.abs(start_pos.x - end_pos.x)
	local distY = math.abs(start_pos.y - end_pos.y)
	local distZ = math.abs(start_pos.z - end_pos.z)

	if distX > distZ then
		return (14 * distZ + 10 * (distX - distZ)) * (distY + 1)
	else
		return (14 * distX + 10 * (distZ - distX)) * (distY + 1)
	end
end

--[[
Ladder support (and other climbables).
A climbable has to have walkable=false to be usable.
We can stand on top of a climbable.
We can stand inside a climbable.
]]

-- This appears to detect if a node can block occupancy.
-- The uses appear to not be friendly to climbables.
local function walkable(node)
	if string.find(node.name,"doors:") then
		return false
	else
		if minetest.registered_nodes[node.name]~= nil then
			return minetest.registered_nodes[node.name].walkable
		else
			return true
		end
	end
end

-- Detect if a node collides with objects.
-- This is for clearance tests.
local function is_solid_node(node)
	-- We can pass through doors, even though they are 'walkable'
	if string.find(node.name,"doors:") then
		return false
	else
		local nodedef = minetest.registered_nodes[node.name]
		if nodedef ~= nil then
			return nodedef.walkable
		else
			return true
		end
	end
end

-- Detect if we can stand on the node.
-- We can stand on walkable and climbable nodes.
local function is_ground_node(node)
	-- We don't want to stand on a door
	if string.find(node.name,"doors:") then
		return false
	else
		local nodedef = minetest.registered_nodes[node.name]
		if nodedef ~= nil then
			-- climable and walkable can support us
			return nodedef.walkable or nodedef.climbable
		else
			-- unknown nodes are assumed to be solid
			return true
		end
	end
end

local function is_node_climbable(node)
	if node ~= nil then
		local nodedef = minetest.registered_nodes[node.name]
		return nodedef ~= nil and nodedef.climbable
	end
	return false
end

-- Check if we have clear nodes above cpos.
-- We already checked that cpos is clear, so we start at +1.
-- can_stand if it is clear from cpos.y+1 to cpos.y+height
-- can_jump if it is clear from cpos.y+1 to cpos.y+height+jump_height
-- returns can_stand, can_jump
local function check_clearance2(cpos, height, jump_height)
	for i = 1, height + jump_height do
		local hpos = {x=cpos.x, y=cpos.y+i, z=cpos.z}
		local node = minetest.get_node(hpos)
		if is_solid_node(node) then
			return i >= height, false
		end
	end
	return true, true
end

-- This is called to find the 'ground level' for a neighboring node.
-- If it is a solid node, we need to scan upward for the first non-solid node.
-- If it is not solid, we need to scan downward for the first ground node.
local function get_neighbor_ground_level(pos, jump_height, fall_height)
	local tmp_pos = { x=pos.x, y=pos.y, z=pos.z }
	local node = minetest.get_node(tmp_pos)
	local height = 0
	if is_solid_node(node) then
		-- upward scan looks for a not solid node
		repeat
			height = height + 1
			if height > jump_height then
				return nil
			end
			tmp_pos.y = tmp_pos.y + 1
			node = minetest.get_node(tmp_pos)
		until not(is_solid_node(node))
		return tmp_pos
	else
		-- downward scan looks for a 'ground node'
		repeat
			height = height + 1
			if height > fall_height then
				return nil
			end
			tmp_pos.y = tmp_pos.y - 1
			node = minetest.get_node(tmp_pos)
		until is_ground_node(node)
		tmp_pos.y = tmp_pos.y + 1
		return tmp_pos
	end
end

-- 1=up, incr clockwise by 45 deg, even=diagonal
local dir_vectors = {
	[1] = { x=0, y=0, z=-1 }, -- up
	[2] = { x=1, y=0, z=-1 }, -- up/right
	[3] = { x=1, y=0, z=0 },  -- right
	[4] = { x=1, y=0, z=1 },  -- down/right
	[5] = { x=0, y=0, z=1 },  -- down
	[6] = { x=-1, y=0, z=1 }, -- down/left
	[7] = { x=-1, y=0, z=0 }, -- left
	[8] = { x=-1, y=0, z=-1 },-- up/left
}
local function dir_add(dir, delta)
	return 1 + ((dir - 1 + delta) % 8) -- modulo gives 0-7, need 1-8
end

--[[
Compute all moves from the position.
Return as an array of tables with the following members:
	pos = walkable 'floor' position in the neighboring cell. Set to nil if the
		neighbor is not reachable.
	hash = minetest.hash_node_position(pos) or nil if pos is nil
	valid = true if the move is valid
]]
local function get_neighbors(current_pos, entity_height, entity_jump_height, entity_fear_height)
	-- check to see if we can jump in the current pos
	local _, can_jump = check_clearance2(current_pos, entity_height, entity_jump_height)

	-- collect the neighbor ground position and jump/walk clearance
	local neighbors = {}
	for nidx, ndir in ipairs(dir_vectors) do
		local neighbor_pos = {x = current_pos.x + ndir.x, y = current_pos.y, z = current_pos.z + ndir.z}
		local neighbor_ground = get_neighbor_ground_level(neighbor_pos, entity_jump_height, entity_fear_height)
		local neighbor = {}


		if neighbor_ground == nil then
			if nidx % 2 == 1 then
				-- only used for diagonal checks
				neighbor.clear_walk, neighbor.clear_jump = check_clearance2(neighbor_pos, entity_height, entity_jump_height)
			end
		else
			-- record whether we can walk or jump into the neighbor, regarless of whether it is blocked
			if neighbor_ground.y <= current_pos.y then
				neighbor.clear_walk, neighbor.clear_jump = check_clearance2(neighbor_pos, entity_height, entity_jump_height)
			else
				-- have to jump up, so won't be clear at ground level
				neighbor.clear_walk = false
				_, neighbor.clear_jump = check_clearance2(neighbor_ground, entity_height + 1, 0)
			end

			-- record the ground position if there is a valid ground
			neighbor.pos = neighbor_ground
			neighbor.hash = minetest.hash_node_position(neighbor_ground)
		end
		neighbors[nidx] = neighbor
	end

	-- 2nd pass to evaluate 'valid' to check diagonals
	for nidx, neighbor in ipairs(neighbors) do
		if neighbor.pos ~= nil then
			if neighbor.pos.y > current_pos.y then
				if not (can_jump and neighbor.clear_jump) then
					-- can't jump from current location to neighbor
				elseif nidx % 2 == 0 then -- diagonals need to check corners
					local n_ccw = neighbors[dir_add(nidx, -1)]
					local n_cw = neighbors[dir_add(nidx, 1)]
					if n_ccw.clear_jump and n_cw.clear_jump then
						neighbor.cost = 15 + 14 -- 10 for jump, 14 for diag
					end
				else
					-- not diagonal, can go
					neighbor.cost = 15 + 10 -- 15 for jump, 10 for move
				end
			else -- neighbor.pos.y <= current_pos.y
				if not neighbor.clear_walk then
					-- can't walk into that neighbor
				elseif nidx % 2 == 0 then -- diagonals need to check corners
					local n_ccw = neighbors[dir_add(nidx, -1)]
					local n_cw = neighbors[dir_add(nidx, 1)]
					if n_ccw.clear_walk and n_cw.clear_walk then
						-- 14 for diag, 10 for each node drop
						neighbor.cost = 14 + 10 * (current_pos.y - neighbor.pos.y)
					end
				else
					-- 10 for diag, 10 for each node drop
					neighbor.cost = 10 + 10 * (current_pos.y - neighbor.pos.y)
				end
			end
			if neighbor.cost ~= nil then
				-- double the cost if neighboring cells are not clear
				for dd=-2,2,1 do
					if dd ~= 0 then
						if neighbors[dir_add(nidx, dd)].clear_walk ~= true then
							neighbor.cost = neighbor.cost * 2
							break
						end
					end
				end
			end
		end
	end

	-- TODO: add ladder/scaffolding/rope handling to go up or down
	local node = minetest.get_node(current_pos)
	if node ~= nil then
		local nodedef = minetest.registered_nodes[node.name]
		if nodedef ~= nil and nodedef.climbable == true then
			minetest.log("action",
						"ladder check "..minetest.pos_to_string(current_pos)..
						" name:"..node.name ..
						 " p1:"..tostring(node.param1) ..
						 " p2:"..tostring(node.param2) ..
						 " d:"..tostring(minetest.wallmounted_to_dir(node.param2))..
						" climb:"..tostring(nodedef.climbable)..
						" walk:"..tostring(nodedef.walkable)..
						" j:"..tostring(can_jump))
			-- HACK: We already scanned straight up. May break if jump height > 1.
			if can_jump then
				local npos = {x=current_pos.x, y=current_pos.y+1, z=current_pos.z}
				table.insert(neighbors, {
					pos = npos,
					hash = minetest.hash_node_position(npos),
					cost = 20})
			end
		end
	end
	-- go down ladder
	npos = {x=current_pos.x, y=current_pos.y-1, z=current_pos.z}
	if is_node_climbable(minetest.get_node(npos)) then
		table.insert(neighbors, {
			pos = npos,
			hash = minetest.hash_node_position(npos),
			cost = 15})
	end

	-- TODO: add ladder handling to let go (fall)
	return neighbors
end

--TODO: path to the nearest of multiple endpoints
-- or first path nearest to the endpoint

-- illustrate the path -- adapted from minetest's pathfinder test.
local function show_particles(path)
	local prev = path[1]
	for s=1, #path do
		local pos = path[s]
		local t
		if s == #path then
			t = "testpathfinder_waypoint_end.png"
		elseif s == 1 then
			t = "testpathfinder_waypoint_start.png"
		else
			local tn = "testpathfinder_waypoint.png"
			if pos.y ~= prev.y then
				if pos.x == prev.x and pos.z == prev.z then
					if pos.y > prev.y then
						tn = "testpathfinder_waypoint_up.png"
					else
						tn = "testpathfinder_waypoint_down.png"
					end
				elseif pos.y > prev.y then
					tn = "testpathfinder_waypoint_jump.png"
				end
			end
			local c = math.floor(((#path-s)/#path)*255)
			t = string.format("%s^[multiply:#%02x%02x00", tn, 0xFF-c, c)
		end
		minetest.log("action", " **"..minetest.pos_to_string(pos).." "..t)
		minetest.add_particle({
			pos = pos,
			expirationtime = 5 + 0.2 * s,
			playername = "singleplayer",
			glow = minetest.LIGHT_MAX,
			texture = t,
			size = 3,
		})
		prev = pos
	end
end

function pathfinder.find_path(pos, endpos, entity)
	--print("searching for a path to:" .. minetest.pos_to_string(endpos))
	local start_index = minetest.hash_node_position(pos)
	local target_index = minetest.hash_node_position(endpos)
	local count = 1

	local openSet = {}   -- active "walkers"
	local closedSet = {} -- retired "walkers"

	local h_start = get_distance(pos, endpos)
	openSet[start_index] = {hCost = h_start, gCost = 0, fCost = h_start, parent = nil, pos = pos}

	-- Entity values
	local entity_height = 2
	local entity_fear_height = 2
	local entity_jump_height = 1
	if entity then
		local collisionbox = entity.collisionbox or entity.initial_properties.collisionbox
		entity_height = math.ceil(collisionbox[5] - collisionbox[2])
		entity_fear_height = entity.fear_height or 2
		entity_jump_height = entity.jump_height or 1
	end

	repeat
		local current_index
		local current_values

		-- Get one index as reference from openSet
		current_index, current_values = next(openSet)

		-- Search for lowest fCost
		for i, v in pairs(openSet) do
			if v.fCost < current_values.fCost or (v.fCost == current_values.fCost and v.hCost < current_values.hCost) then
				current_index = i
				current_values = v
			end
		end

		-- remove current from the openSet and add to the closedSet
		openSet[current_index] = nil
		closedSet[current_index] = current_values
		count = count - 1

		if current_index == target_index then
			--print("Found path")
			local path = {}
			local reverse_path = {}
			repeat
				if not(closedSet[current_index]) then
					return {endpos} --was empty return
				end
				table.insert(reverse_path, closedSet[current_index].pos)
				current_index = closedSet[current_index].parent
				if #path > 100 then
					--print("path to long")
					return
				end
			until start_index == current_index
			-- iterate backwards and append to reverse_path
			for idx=#reverse_path,1,-1 do
				table.insert(path, reverse_path[idx])
			end
			--print("path length: "..#reverse_path)
			if debug_pathfinder then
				show_particles(path)
			end
			return path, reverse_path
		end

		local current_pos = current_values.pos

		local neighbors = get_neighbors(current_pos, entity_height, entity_jump_height, entity_fear_height)

		for id, neighbor in pairs(neighbors) do
			-- NOTE: assuming that if we already visited a node, then the existing cost is better
			if neighbor.cost ~= nil then
				-- get_distance_to_neighbor(current_values.pos, neighbor.pos)
				local move_cost_to_neighbor = current_values.gCost + neighbor.cost
				local old_closed = closedSet[neighbor.hash]
				if old_closed == nil or old_closed.gCost > move_cost_to_neighbor then
					local old_open = openSet[neighbor.hash]
					if old_open == nil or move_cost_to_neighbor < old_open.gCost then
						if old_open == nil then
							count = count + 1
						end
						local hCost = get_distance(neighbor.pos, endpos)
						openSet[neighbor.hash] = {
								gCost = move_cost_to_neighbor,
								hCost = hCost,
								fCost = move_cost_to_neighbor + hCost,
								parent = current_index,
								pos = neighbor.pos
						}
					end
				end
			end
		end
		if count > 100 then
			--print("failed finding a path to:" minetest.pos_to_string(endpos))
			return
		end
	until count < 1
	--print("count < 1")
	return {endpos}
end

-- FIXME: external uses are probably incompatible with climbables
pathfinder.walkable = walkable
pathfinder.is_node_climbable = is_node_climbable

function pathfinder.get_ground_level(pos)
	return get_neighbor_ground_level(pos, 30927, 30927)
end

-------------------------------------------------------------------------------

-- key=player name, val={ dest_id, src_id }
local path_player_debug = {}

local function find_path_for_player(player, itemstack, pos1)
	local meta = itemstack:get_meta()
	if not meta then
		return
	end
	local x = meta:get_int("pos_x")
	local y = meta:get_int("pos_y")
	local z = meta:get_int("pos_z")
	if x and y and z then
		local pos2 = {x=x, y=y, z=z}
		--local pos1 = vector.round(player:get_pos())
		local str = S("Path from @1 to @2:",
			minetest.pos_to_string(pos1),
			minetest.pos_to_string(pos2))
		minetest.chat_send_player(player:get_player_name(), str)

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
			find_path_for_player(user, itemstack, pointed_thing.above)
		end
	else
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
	inventory_image = "testpathfinder_testpathfinder.png",
	groups = { testtool = 1, disable_repair = 1 },
	on_use = find_path_or_set_algorithm,
	on_secondary_use = set_destination,
	on_place = set_destination,
})

return pathfinder
