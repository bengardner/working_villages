--[[
This is an implementation of the A* pathfinding alorithm.

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

hCost = estimated remaining cost
gCost = actual cost to this point
fCost = hCost + gCost
]]--
local S = minetest.get_translator("testpathfinder")

local sorted_hash = working_villages.require("sorted_hash")

local pathfinder = {}

pathfinder.debug = true

--print("loading pathfinder")

--[[ This functions gets the minimum estimated cost to go from one position to
another. It ignores the map.
It is important that the estimate is lower than or equal to reality.
If it over-estimates the cost, we won't get an optimal path.

TODO: this will need to be adjusted when end_pos becomes an end_area.
--]]
local function get_estimated_cost(start_pos, end_pos)
	local distX = math.abs(start_pos.x - end_pos.x)
	local distZ = math.abs(start_pos.z - end_pos.z)

	if distX > distZ then
		return 14 * distZ + 10 * (distX - distZ)
	else
		return 14 * distX + 10 * (distZ - distX)
	end
end

-- Get the actual cost to go from one node to the next.
-- FIXME: this isn't used. The cost is built into the neighbor selection.
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

local function resolve_node(node_or_pos)
	if node_or_pos ~= nil then
		if node_or_pos.name ~= nil then
			return node_or_pos
		else
			return minetest.get_node(node_or_pos)
		end
	end
end

--[[
Detect if a node collides with objects (MOB).
This is for clearance tests to see if the MOB can be in that node.
Minetest uses "walkable" to denote that it can collide. However, we need to
specifically allow doors, as we can walk through those.
--]]
local function is_node_collidable(node)
	node = resolve_node(node)
	if node ~= nil then
		-- We can pass through doors, even though they are 'walkable'
		if string.find(node.name,"doors:") then
			-- FIXME: this assumes that the door can be opened by the MOB.
			-- We really need to check if the door is already open and whether the
			-- MOB has the ability to open doors. Doors can be locked and the MOB
			-- may not have the key.
			return false
		else
			-- not a door, so return the 'walkable' field from the nodedef
			local nodedef = minetest.registered_nodes[node.name]
			if nodedef ~= nil then
				return nodedef.walkable
			end
			minetest.log("warning", "no nodedef for "..node.name)
		end
	end
	return true
end

local function is_pos_collidable(pos)
	return is_node_collidable(minetest.get_node(pos))
end

-- inverse of is_node_collidable()
local function is_node_clear(node)
	return not is_node_collidable(node)
end

local function is_pos_clear(pos)
	return is_node_clear(minetest.get_node(pos))
end

--[[
Return the "climbable" field from the node's definition.
--]]
local function is_node_climbable(node)
	node = resolve_node(node)
	if node ~= nil then
		local nodedef = minetest.registered_nodes[node.name]
		if nodedef ~= nil then
			return nodedef.climbable
		end
		minetest.log("warning", "no nodedef for "..node.name)
	end
	return false
end

local function is_pos_climbable(pos)
	return is_node_climbable(minetest.get_node(pos))
end

--[[
Detect if we can stand on the node.
We can stand on walkable and climbable nodes.
--]]
local function is_node_standable(node)
	node = resolve_node(node)
	return is_node_collidable(node) or is_node_climbable(node)
end

--[[
Check if we have clear nodes above cpos.
This is used to see if we can walk into a neighboring node and/or jump into it.

For example, if height=2 and jump_height=2, we will check 4 nodes
starting at cpos and going +y.

max_y = height + math.max(jump_height, 1)

The numbers below represent the nodes to check.
 S = the nodes that must be clear to stand.
 J = the nodes that must be clear to jump.
 C = the nodes that must be clear to climb.

 - 3 J ----- top 2 for jump
 - 2 J C --- bottom 3 for climb
 - 1   C S - bottom 2 for stand
 - 0   C S

To be able to stand in the node, we need to be clear on 0 & 1.
To be able to climb in the node, we need to be clear on 0, 1, 2
To be able to jump in(to) the node, we need to be clear on 2 & 3

@cpos is the position to start checking
@height is the number of nodes that the MOB occupies
@jump_height is how high the MOB can jump
@start_height sets the start of the scan, assuming the nodes are clear
returns { stand=bool, jump=bool, climb=bool }
--]]
local function check_clearance(cpos, height, jump_height, start_height)
	local ret = { stand=true, climb=true, jump=true }
	for i=start_height or 0, height + math.max(jump_height, 1) do
		local hpos = {x=cpos.x, y=cpos.y+i, z=cpos.z}
		if is_node_collidable(minetest.get_node(hpos)) then
			if i < height + 1 then
				ret.climb = false
				if i < height then
					ret.stand = false
				end
			end
			-- jump only cares if above jump_height
			if i >= jump_height then
				ret.jump = false
				if i > height then
					-- can't affect walk or climb, so we are done
					break
				end
			end
		end
	end
	--minetest.log("action", string.format(" %s clear s=%s c=%s j=%s",
	--									 minetest.pos_to_string(cpos),
	--									 tostring(ret.stand),
	--									 tostring(ret.climb),
	--									 tostring(ret.jump)))
	return ret
end

--[[
This is called to find the 'ground level' for a neighboring node.
If we start on a solid node, we need to scan upward for the first non-solid node.
If it is not solid, we need to scan downward for the first ground node.
Climbable nodes count as ground when below.

@jump_height is how high the MOB can jump
@fall_height is how far the MOB can fall without damage.
return nil (nothing within range) or the position of the ground.
--]]
local function get_neighbor_ground_level(pos, jump_height, fall_height)
	local tmp_pos = { x=pos.x, y=pos.y, z=pos.z }
	local node = minetest.get_node(tmp_pos)
	local height = 0
	if is_node_collidable(node) then
		-- upward scan looks for a not solid node
		repeat
			height = height + 1
			if height > jump_height then
				return nil
			end
			tmp_pos.y = tmp_pos.y + 1
			node = minetest.get_node(tmp_pos)
		until not(is_node_collidable(node))
		return tmp_pos
	else
		-- downward scan looks for a 'ground node'
		repeat
			if height > fall_height then
				return nil
			end
			height = height + 1
			tmp_pos.y = tmp_pos.y - 1
			node = minetest.get_node(tmp_pos)
		until is_node_standable(node)
		tmp_pos.y = tmp_pos.y + 1
		return tmp_pos
	end
end

--[[
This table takes a direction and converts it to a vector.
It is used to scan the neighboring nodes on the X-Z plane.
1=up(-z), incr clockwise by 45 deg, even indexes are diagonals.
--]]
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
-- adds to the dir index while wrapping around 1 and 8
local function dir_add(dir, delta)
	return 1 + ((dir - 1 + delta) % 8) -- modulo gives 0-7, need 1-8
end

-------------------------------------------------------------------------------
-- Neighbor operations

-- FIXME: redesign so that we don't need a table copy for each node
-- adds args.pos and args.clear to a new table
local function neighbor_args(current_pos, args)
	local new_args = {}
	for k, v in pairs(args) do
		new_args[k] = v
	end
	new_args.pos = current_pos

	-- Check to see if we can jump in the current pos. We can't jump to another
	-- node if we can't jump here.
	new_args.clear = check_clearance(current_pos, args.height, args.jump_height)

	-- Set the jump height to 0 if we can't jump. May save a few cycles, but
	-- all the neighbors will have clear_walk==clear_jump
	if not new_args.clear.jump then
		new_args.jump_height = 0
	end
	return new_args
end

-- add climbing neighbors (up/down)
local function neighbor_climb(neighbors, args)
	-- Check if we can climb and we are in a climbable node
	if args.clear.climb and is_node_climbable(minetest.get_node(args.pos)) then
		local npos = {x=args.pos.x, y=args.pos.y+1, z=args.pos.z}
		table.insert(neighbors, {
			pos = npos,
			hash = minetest.hash_node_position(npos),
			cost = 20})
	end

	-- Check if we can climb down
	local npos = {x=args.pos.x, y=args.pos.y-1, z=args.pos.z}
	if is_node_climbable(minetest.get_node(npos)) then
		table.insert(neighbors, {
			pos = npos,
			hash = minetest.hash_node_position(npos),
			cost = 15})
	end
end

-- collect neighbors without diagonals
local function neighbor_collect_no_diag(neighbors, current_pos, args)
	for nidx, ndir in ipairs(dir_vectors) do
		if nidx % 2 == 1 then -- no diagonals
			local neighbor_pos = vector.add(current_pos, ndir)
			local neighbor_ground = get_neighbor_ground_level(neighbor_pos, args.jump_height, args.fear_height)
			if neighbor_ground ~= nil then
				local neighbor_clear = check_clearance(neighbor_pos, args.height, args.jump_height)
				if neighbor.pos.y <= current_pos.y or (args.clear.jump and neighbor_clear.jump) then
					table.insert(neighbors, {
						pos = neighbor_ground,
						hash = minetest.hash_node_position(neighbor_ground),
						cost = 10
					})
				end
			end
		end
	end
end

-- collect neighbors with diagonals
local function neighbors_collect_diag(neighbors, args)
	-- collect the neighbor ground position and jump/walk clearance (X-Z plane)
	-- using the neighbor index so we can ref surrounding directions
	local n_info = {}
	for nidx, ndir in ipairs(dir_vectors) do
		local neighbor_pos = vector.add(args.pos, ndir)
		local neighbor_ground = get_neighbor_ground_level(neighbor_pos, args.jump_height, args.fear_height)
		local neighbor = {}

		neighbor.clear = check_clearance(neighbor_pos, args.height, args.jump_height)
		if neighbor_ground ~= nil then
			neighbor.pos = neighbor_ground
			neighbor.hash = minetest.hash_node_position(neighbor_ground)
		end
		n_info[nidx] = neighbor
	end

	-- 2nd pass to evaluate 'clear' info to check diagonals
	for nidx, neighbor in ipairs(n_info) do
		if neighbor.pos ~= nil then
			if neighbor.pos.y > args.pos.y then
				if not (args.clear.jump and neighbor.clear.jump) then
					-- can't jump from current location to neighbor
				elseif nidx % 2 == 0 then -- diagonals need to check corners
					local n_ccw = n_info[dir_add(nidx, -1)]
					local n_cw = n_info[dir_add(nidx, 1)]
					if n_ccw.clear.jump and n_cw.clear.jump then
						neighbor.cost = 14 -- + 15 -- 15 for jump, 14 for diag
					end
				else
					-- not diagonal, can go
					neighbor.cost = 10 -- + 15 -- 15 for jump, 10 for move
				end
			else -- neighbor.pos.y <= args.pos.y
				if not neighbor.clear.stand then
					-- can't walk into that neighbor
				elseif nidx % 2 == 0 then -- diagonals need to check corners
					local n_ccw = n_info[dir_add(nidx, -1)]
					local n_cw = n_info[dir_add(nidx, 1)]
					if n_ccw.clear.stand and n_cw.clear.stand then
						-- 14 for diag, 8 for each node drop
						neighbor.cost = 14 -- + 8 * (current_pos.y - neighbor.pos.y)
					end
				else
					-- 10 for diag, 8 for each node drop
					neighbor.cost = 10 -- + 8 * (current_pos.y - neighbor.pos.y)
				end
			end
			if false and neighbor.cost ~= nil then
				-- double the cost if neighboring cells are not clear
				-- FIXME: this is a misguided attempt to get the MOB to stay away
				--        from corners. Also could try a cost hit for 90 turns.
				--        That would require propagating the direction.
				for dd=-2,2,1 do
					if dd ~= 0 then
						if n_info[dir_add(nidx, dd)].clear.stand ~= true then
							neighbor.cost = neighbor.cost * 2
							break
						end
					end
				end
			end
			if neighbor.cost ~= nil then
				table.insert(neighbors, neighbor)
			end
		end
	end
end

--[[
Compute all moves from the position.
Return as an array of tables with the following members:
	pos = walkable 'floor' position in the neighboring cell. Set to nil if the
		neighbor is not reachable.
	hash = minetest.hash_node_position(pos) or nil if pos is nil
	cost = nil (invalid move) or the cost to move into that node
]]
local function get_neighbors(current_pos, args)
	local args = neighbor_args(current_pos, args)
	local neighbors = {}

	if args.want_diag == true then
		neighbors_collect_diag(neighbors, args)
	else
		neighbors_collect_no_diag(neighbors, args)
	end
	if args.want_climb then
		neighbor_climb(neighbors, args)
	end
	return neighbors
end

-------------------------------------------------------------------------------

--[[
Illustrate the path by creating particles
Adapted from minetest's pathfinder test.
--]]
function pathfinder.show_particles(path)
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
		--minetest.log("action", " **"..minetest.pos_to_string(pos).." "..t)
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

-- the hash is the key
function slist_key_encode(item)
	return item.hash
end

-- Compare the path cost to see if item1 should be before item2 in the list
function slist_item_compare(item1, item2)
	-- Note: fCost = hCost + gCost, so if same fCost, go with the closer one
	return item1.fCost < item2.fCost or (item2.fCost == item1.fCost and item1.hCost < item2.hCost)
end

function slist_new()
	return sorted_hash.new(slist_key_encode, slist_item_compare)
end

local function do_collect_path(closedSet, end_hash, start_index)
	minetest.log("warning", string.format("collect_path: end=%x start=%x", end_hash, start_index))
	-- trace backwards to the start node to create the reverse path
	local reverse_path = {}
	local cur_hash = end_hash
	for k, v in pairs(closedSet) do
		minetest.log("warning", string.format(" - k=%x p=%s h=%x", k,
			minetest.pos_to_string(v.pos), v.hash))
	end
	while start_index ~= cur_hash and cur_hash ~= nil do
		local ref2 = closedSet[cur_hash]
		if ref2 == nil then
			-- FIXME: this is an "impossible" error condition
			minetest.log("warning", string.format("hash error: missing %x", cur_hash))
			for k, v in pairs(closedSet) do
				minetest.log("warning", string.format(" - k=%x p=%s h=%x", k,
					minetest.pos_to_string(v.pos), v.hash))
			end
			return nil
		end
		table.insert(reverse_path, ref2.pos)
		cur_hash = ref2.parent
	end

	-- iterate backwards on reverse_path to build path
	local path = {}
	for idx=#reverse_path,1,-1 do
		table.insert(path, reverse_path[idx])
	end
	--if pathfinder.debug == true then
	--	pathfinder.show_particles(path)
	--end
	return path, reverse_path
end

local function get_find_path_args(options, entity)
	options = options or {}
	local args = {
		want_diag = options.want_diag or true,
		want_climb = options.want_climb or true,
		want_nil = options.want_nil,
		height = options.height or 2,
		fear_height = options.fear_height or 2,
		jump_height = options.jump_height or 1,
	}
	if entity and entity.collisionbox then
		local collisionbox = entity.collisionbox or entity.initial_properties.collisionbox
		args.height = math.ceil(collisionbox[5] - collisionbox[2])
	end
	return args
end

--[[
This is the pathfinder function.
It will always return a pair of paths with at least one position.

@start_pos is the starting position
@end_pos is the ending position or area, must contain x,y,z
@entity a table that provides: collisionbox, fear_height, and jump_height
@option { want_nil = return nil on failure }

If @end_pos has a method "inside(self, pos, hash)", then that is called to test
whether a position is in the end area. That allows the path to end early.
If @end_pos has a method "outside(self, pos, hash)", then that is called to test
whether a walker should be dropped. If that returns true, the location is outside
of the area that we can explore.
--]]
function pathfinder.find_path(start_pos, end_pos, entity, options)
	local args = get_find_path_args(options, entity)
	minetest.log("action", "find_path:"
				 .. "start " .. minetest.pos_to_string(start_pos)
				 .. " dest " .. minetest.pos_to_string(end_pos))
	assert(start_pos ~= nil and start_pos.x ~= nil and start_pos.y ~= nil and start_pos.z ~= nil)
	assert(end_pos ~= nil and end_pos.x ~= nil and end_pos.y ~= nil and end_pos.z ~= nil)
	--print("searching for a path from:"..minetest.pos_to_string(pos).." to:"..minetest.pos_to_string(end_pos))

	local start_hash = minetest.hash_node_position(start_pos)
	local target_hash = minetest.hash_node_position(end_pos)

	if end_pos.inside == nil then
		-- don't modify parameters
		end_pos = { x=end_pos.x, y=end_pos.y, z=end_pos.z, inside=function(self, pos, hash) return hash == target_hash end }
	end

	local openSet = slist_new() -- slist of active "walkers"
	local closedSet = {}        -- retired "walkers"

	local h_start = get_estimated_cost(start_pos, end_pos)
	openSet:insert({hCost = h_start, gCost = 0, fCost = h_start, parent = nil,
	                pos = start_pos, hash = start_hash })

	-- return a path and reverse path consisting of only the dest
	-- this is used for the two "impossible" error paths
	local function failed_path()
		if options.want_nil then return nil end
		local tmp = { vector.new(end_pos) }
		return tmp, tmp
	end

	local function collect_path(end_hash)
		return do_collect_path(closedSet, end_hash, start_hash)
	end

	-- iterate as long as there are active walkers
	while openSet.count > 0 do
		local current_values = openSet:pop_head()
		--  if current_values == nil then
		--  	minetest.log("warning", string.format("slist count is %d, put pop_head() returned nil", openSet.count))
		--  	return nil, fail.no_path
		--  end

		--minetest.log("action", string.format("processing %s %x",
		--	minetest.pos_to_string(current_values.pos), current_values.hash))

		-- add to the closedSet so we don't revisit this location
		closedSet[current_values.hash] = current_values

		-- check for a walker in the destination zone
		if end_pos:inside(current_values.pos, current_values.hash) then
			minetest.log("action", string.format(" walker %s is inside end_pos, hash=%x parent=%s",
				minetest.pos_to_string(current_values.pos), current_values.hash, tostring(current_values.parent)))
			return collect_path(current_values.hash)
		end

		for _, neighbor in pairs(get_neighbors(current_values.pos, args)) do
			if neighbor.cost ~= nil and (end_pos.outside == nil or not end_pos:outside(current_values.pos, current_values.hash))
			then
				--minetest.log("action", string.format(" neightbor %s %x",
				--									 minetest.pos_to_string(neighbor.pos), neighbor.hash))
				local move_cost_to_neighbor = current_values.gCost + neighbor.cost
				-- if we already visited this node, then we only store if the new cost is less (unlikely)
				local old_closed = closedSet[neighbor.hash]
				if old_closed == nil or old_closed.gCost > move_cost_to_neighbor then
					-- We also want to avoid adding a duplicate (worse) open walker
					local old_open = openSet:get(neighbor.hash)
					if old_open == nil or move_cost_to_neighbor < old_open.gCost then
						local hCost = get_estimated_cost(neighbor.pos, end_pos)
						openSet:insert({
							gCost = move_cost_to_neighbor,
							hCost = hCost,
							fCost = move_cost_to_neighbor + hCost,
							parent = current_values.hash,
							pos = neighbor.pos,
							hash = neighbor.hash
						})
					end
				end
			end
		end

		-- In ideal situations, we will bee-line directly towards the dest.
		-- Complex obstacles cause an explosion of open walkers.
		-- Prevent excessive CPU usage by limiting the number of open walkers.
		-- The caller will travel to the end of the path and then try again.
		-- This limit may cause failure where success should be possible.
		if openSet.count > 100 then
			minetest.log("warning", "too many walkers in "..minetest.pos_to_string(start_pos)..' to '..minetest.pos_to_string(end_pos))
			return failed_path()
			-- return collect_path(current_values.hash)
		end

		-- Catch running out of walkers without hitting the end.
		-- This happens when there is no possible path to the target.
		-- The caller should try again after following the path.
		if openSet.count == 0 then
			minetest.log("warning", "no path "..minetest.pos_to_string(start_pos)..' to '..minetest.pos_to_string(end_pos))
			-- FIXME: the unresolved path likely leads away. most common failure
			-- is dest is above start.
			return failed_path()
			-- return collect_path(current_values.hash)
		end
	end

	-- FIXME: this isn't reachable
	return failed_path()
end

-- convert the two radius values into r^2 values
local function sanitize_radius(dest_radius)
	if dest_radius == nil or dest_radius < 1 then
		dest_radius = 1
	end
	return dest_radius
end

-- calculate vector.distance(v1, v2)**2
-- d^2 = dx^2 + dy^2 + dz^2
local function xyz_dist2(v1, v2)
	local d = vector.subtract(v1, v2)
	return d.x * d.x + d.y * d.y + d.z * d.z
end

-- calculate vector.distance(v1, v2)**2, but ignoring dy
-- d^2 = dx^2 + dz^2
local function xz_dist2(v1, v2)
	local dx = v1.x - v2.x
	local dz = v1.z - v2.z
	return dx * dx + dz * dz
end

-- test a single-node dest
-- fields: pos
function pathfinder.inside_pos(self, pos, hash)
	return self.pos.x == pos.x and self.pos.y == pos.y and self.pos.z == pos.z
end

-- test a single-node dest
-- fields: hash
function pathfinder.inside_hash(self, pos, hash)
	return self.hash == hash
end

-- test if pos is within the area for self.minp, self.maxp.
-- fields: minp, maxp
function pathfinder.inside_minp_maxp(self, pos, hash)
	return (pos.x >= self.minp.x and pos.y >= self.minp.y and pos.z >= self.minp.z and
	        pos.x <= self.maxp.x and pos.y <= self.maxp.y and pos.z <= self.maxp.z)
end

-- Test if pos is within a sphere
-- fields: x, y, z, d2
function pathfinder.inside_sphere(self, pos, hash)
	local d2 = xyz_dist2(self, pos)
	return d2 <= self.d2
end

-- Test if pos is within the cyinder with the base at the bottom
-- fields: x, y, z, d2, y_max
function pathfinder.inside_cylinder(self, pos, hash)
	-- check top/bot of cylinder
	if pos.y < self.y or pos.y > self.y_max then
		return false
	end
	local d2 = xz_dist2(self, pos)
	return d2 <= self.d2
end

-- create an end_pos for a single position
function pathfinder.make_dest(center_pos)
	local end_pos = vector.floor(center_pos)
	end_pos.hash = minetest.hash_node_position(end_pos)
	end_pos.inside = pathfinder.inside_hash
	return end_pos
end

-- create an end_pos for a box with an optional center
function pathfinder.make_dest_min_max(center_pos, minp, maxp)
	local end_pos = vector.floor(center_pos)
	end_pos.minp = minp
	end_pos.maxp = maxp
	end_pos.inside = pathfinder.inside_minp_maxp
	return end_pos
end

-- create an end_pos for a sphere
function pathfinder.make_dest_sphere(center_pos, radius)
	local end_pos = vector.floor(center_pos)
	end_pos.d2 = radius * radius
	end_pos.inside = pathfinder.inside_sphere
	return end_pos
end

-- create an end_pos for a cylinder
function pathfinder.make_dest_cylinder(center_pos, radius, height)
	local end_pos = vector.floor(center_pos)
	end_pos.d2 = radius * radius
	end_pos.y_max = end_pos.y + height - 1
	end_pos.inside = pathfinder.inside_cylinder
	return end_pos
end

--[[
Calculate a path to the closest position inside of the sphere.
@start_pos is the staring position of the path
@entity is the entity. See find_path().
@dest_pos is the center of the sphere.
@dest_radius is the radius of the sphere, must be >=1
@dest_radius_min is the minimum radius to create a shell. It should be at least
	two less than dest_radius.
]]
function pathfinder.find_path_sphere(start_pos, entity, dest_pos, dest_radius)
	-- use a simple single-node dest if dest_radius is too small
	local radius = sanitize_radius(dest_radius)
	if radius < 2 then
		return pathfinder.find_path(start_pos, pathfinder.make_dest(dest_pos), entity)
	end
	local endpos = pathfinder.make_dest_sphere(dest_pos, radius)
	return pathfinder.find_path(start_pos, endpos, entity)
end

--[[
Calculate a path to the closest position inside of the cylinder.
@dest_pos is the bottom-center of the cylinder.
@dest_radius is the radius of the cylinder, must be >= 1
@dest_height must be >= 1
]]
function pathfinder.find_path_cylinder(start_pos, entity, dest_pos, dest_radius, dest_height)
	local radius = sanitize_radius(dest_radius)
	if dest_height == nil or dest_height < 1 then
		dest_height = 1
	end
	local endpos = pathfinder.make_dest_cylinder(dest_pos, radius, dest_height)
	return pathfinder.find_path(start_pos, endpos, entity)
end

--[[
Calculate a path to the closest position inside of the box.
@dest_pos1 and @dest_pos2 are corners in the box.
]]
function pathfinder.find_path_box(start_pos, entity, dest_pos1, dest_pos2)
	local minp, maxp = vector.sort(dest_pos1, dest_pos2)
	-- handle the single-node case
	if vector.equals(minp, maxp) then
		return pathfinder.find_path(start_pos, endp, entity)
	end
	local midp = vector.round(
		{x=(minp.x+maxp.x)/2, y=(minp.y+maxp.y)/2, z=(minp.z+maxp.z)/2})

	local endpos = pathfinder.make_dest_min_max(midp, minp, maxp)
	return pathfinder.find_path(pos, endpos, entity)
end

-------------------------------------------------------------------------------

--[[
This does the flood fill for the wayzone stuff.
It returns a table of all visited nodes and a table of exit nodes.
Visited nodes are all nodes that can be accessed with the +/- y limit in the area.
The y limit is min(jump_hight, fear_height).

Exit nodes are the first step out of the area or drop by > y limit (if fall_height
is > jump_height).

@start_pos is a vector that starts the flood. It must be over a standable node.
@area must contain either the function 'inside(self, pos, hash)' or minp and maxp.
   minp/maxp are vectors for the min/max corners of the area.
@args may contain height, jump_height and fear_height. defaults are 2, 1, 2.
@return visited_nodes, exit_nodes
--]]
function pathfinder.wayzone_flood(start_pos, area)
	assert(start_pos ~= nil and start_pos.x ~= nil and start_pos.y ~= nil and start_pos.z ~= nil)
	assert(area ~= nil and (area.inside ~= nil or (area.minp ~= nil and area.maxp ~= nil)))

	local args = get_find_path_args({ want_diag=false })

	-- create a simple minp/maxp 'inside' function if missing.
	if area.inside == nil then
		area = { minp=area.minp, maxp=area.maxp, inside=pathfinder.inside_minp_maxp }
	end

	local openSet = {}    -- set of active walkers; openSet[hash] = { pos=pos, hash=hash, dy=dy }
	local visitedSet = {} -- retired "walkers"; visitedSet[hash] = true
	local exitSet = {}    -- outside area or drop by more that jump_height; exitSet[hash] = true

	-- wrap 'add' with a function for logging
	local function add_open(item)
		--minetest.log("action", string.format(" add_open %s %x dy=%d", minetest.pos_to_string(item.pos), item.hash, item.dy))
		openSet[item.hash] = item
	end

	-- seed the start_pos
	add_open({ pos=start_pos, hash=minetest.hash_node_position(start_pos) })

	local y_lim = math.min(args.fear_height, args.jump_height)

	-- iterate as long as there are active walkers
	while true do
		local _, item = next(openSet)
		if item == nil then break end

		-- remove from openSet and process
		openSet[item.hash] = nil
		for _, n in pairs(get_neighbors(item.pos, args)) do
			-- skip if already visited or queued
			if visitedSet[n.hash] == nil and openSet[n.hash] == nil then
				local dy = math.abs(n.pos.y - item.pos.y)
				if not area:inside(n.pos, n.hash) or dy > y_lim then
					exitSet[n.hash] = true
				else
					visitedSet[n.hash] = true
					exitSet[n.hash] = nil -- might have been unreachable
					add_open({pos = n.pos, hash = n.hash})
				end
			end
		end
	end
	return visitedSet, exitSet
end

-------------------------------------------------------------------------------

-- FIXME: external uses are probably incompatible with climbables
pathfinder.walkable = is_node_collidable
pathfinder.is_node_climbable = is_node_climbable
pathfinder.is_node_standable = is_node_standable
pathfinder.is_node_collidable = is_node_collidable

function pathfinder.can_stand_at(pos, height)
	local pos = vector.floor(pos)
	-- must be able to occupy pos and stand on the node below
	if not is_node_clear(pos) then
		minetest.log("warning", "can_stand_at: not clear " .. minetest.pos_to_string(pos))
		return false
	end

	local below = {x=pos.x, y=pos.y-1, z=pos.z}
	if not pathfinder.is_node_standable(below) then
		local node = minetest.get_node(below)
		local nodedef = minetest.registered_nodes[node.name]

		minetest.log("warning", "can_stand_at: not stand " .. minetest.pos_to_string(below) .. " name="..node.name.." d="..tostring(nodedef))

		return false
	end
	-- if height = 2, we check 1 node above pos (which we already checked)
	for hh = 1, height - 1 do
		local tpos = {x=pos.x, y=pos.y+hh, z=pos.z}
		if not is_node_clear(tpos) then
			minetest.log("warning", "can_stand_at: not clear " .. minetest.pos_to_string(tpos))
			return false
		end
	end
	return true
end

function pathfinder.get_ground_level(pos)
	return get_neighbor_ground_level(pos, 30927, 30927)
end

return pathfinder
