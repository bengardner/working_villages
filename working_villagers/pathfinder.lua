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
]]--
local S = minetest.get_translator("testpathfinder")

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

--[[
Detect if a node collides with objects (MOB).
This is for clearance tests to see if the MOB can be in that node.
Minetest uses "walkable" to denote that it can collide. However, we need to
specifically allow doors, as we can walk through those.
--]]
local function is_node_collidable(node)
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
		else
			return true
		end
	end
end

-- inverse of is_node_collidable()
local function is_node_clear(node)
	return not is_node_collidable(node)
end

--[[
Return the "climbable" field from the node's definition.
--]]
local function is_node_climbable(node)
	if node ~= nil then
		local nodedef = minetest.registered_nodes[node.name]
		if nodedef ~= nil then
			return nodedef.climbable
		end
	end
	return false
end

--[[
Detect if we can stand on the node.
We can stand on walkable and climbable nodes.
--]]
local function is_node_standable(node)
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
			height = height + 1
			if height > fall_height then
				return nil
			end
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

--[[
Compute all moves from the position.
Return as an array of tables with the following members:
	pos = walkable 'floor' position in the neighboring cell. Set to nil if the
		neighbor is not reachable.
	hash = minetest.hash_node_position(pos) or nil if pos is nil
	cost = nil (invalid move) or the cost to move into that node
]]
local function get_neighbors(current_pos, entity_height, entity_jump_height, entity_fear_height)
	-- Check to see if we can jump in the current pos. We can't jump to another
	-- node if we can't jump here. We assume we can walk here because...
	local clear = check_clearance(current_pos, entity_height, entity_jump_height)

	-- Set the jump height to 0 if we can't jump. May save a few cycles, but
	-- all the neighbors will have clear_walk==clear_jump
	local jump_height = entity_jump_height
	if not clear.jump then
		jump_height = 0
	end

	-- collect the neighbor ground position and jump/walk clearance (X-Z plane)
	local neighbors = {}
	for nidx, ndir in ipairs(dir_vectors) do
		local neighbor_pos = {x = current_pos.x + ndir.x, y = current_pos.y, z = current_pos.z + ndir.z}
		local neighbor_ground = get_neighbor_ground_level(neighbor_pos, jump_height, entity_fear_height)
		local neighbor = {}

		neighbor.clear = check_clearance(neighbor_pos, entity_height, jump_height)
		if neighbor_ground ~= nil then
			neighbor.pos = neighbor_ground
			neighbor.hash = minetest.hash_node_position(neighbor_ground)
		end
		neighbors[nidx] = neighbor
	end

	-- 2nd pass to evaluate 'valid' to check diagonals
	for nidx, neighbor in ipairs(neighbors) do
		if neighbor.pos ~= nil then
			if neighbor.pos.y > current_pos.y then
				if not (clear.jump and neighbor.clear.jump) then
					-- can't jump from current location to neighbor
				elseif nidx % 2 == 0 then -- diagonals need to check corners
					local n_ccw = neighbors[dir_add(nidx, -1)]
					local n_cw = neighbors[dir_add(nidx, 1)]
					if n_ccw.clear.jump and n_cw.clear.jump then
						neighbor.cost = 14 -- + 15 -- 15 for jump, 14 for diag
					end
				else
					-- not diagonal, can go
					neighbor.cost = 10 -- + 15 -- 15 for jump, 10 for move
				end
			else -- neighbor.pos.y <= current_pos.y
				if not neighbor.clear.stand then
					-- can't walk into that neighbor
				elseif nidx % 2 == 0 then -- diagonals need to check corners
					local n_ccw = neighbors[dir_add(nidx, -1)]
					local n_cw = neighbors[dir_add(nidx, 1)]
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
						if neighbors[dir_add(nidx, dd)].clear.stand ~= true then
							neighbor.cost = neighbor.cost * 2
							break
						end
					end
				end
			end
		end
	end

	-- Check if we can climb and we are in a climbable node
	if clear.climb and is_node_climbable(minetest.get_node(current_pos)) then
		local npos = {x=current_pos.x, y=current_pos.y+1, z=current_pos.z}
		table.insert(neighbors, {
			pos = npos,
			hash = minetest.hash_node_position(npos),
			cost = 20})
	end

	-- Check if we can climb down
	local npos = {x=current_pos.x, y=current_pos.y-1, z=current_pos.z}
	if is_node_climbable(minetest.get_node(npos)) then
		table.insert(neighbors, {
			pos = npos,
			hash = minetest.hash_node_position(npos),
			cost = 15})
	end

	return neighbors
end

--[[
Illustrate the path by creating particles
Adapted from minetest's pathfinder test.
--]]
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

--[[
A simple sorted hash list thingy for keeping a list of sorted openSets.
Items must have the "hash" member.
The table is modified when added - a field named 'sl_pnext' is added.
]]
local slist = {}

-- remove and return the first item
function slist:pop_head()
	local item = self.sl_pnext
	if item ~= nil then
		self[item.hash] = nil         -- clear from table
		self.sl_pnext = item.sl_pnext -- point head to next
		item.sl_pnext = nil           -- remove link
		self.count = self.count - 1   -- decrement count
	end
	return item
end

-- do a sorted add of an item
function slist:insert(item)
	-- must make sure there isn't already an entry with the hash
	self:del(item.hash)
	-- add it by hash
	self[item.hash] = item
	-- find a spot for it
	local head = self
	while true do
		-- if there is no head.sl_pnext, then set it to item (end of the list)
		local ref = head.sl_pnext
		if ref == nil then
			head.sl_pnext = item
			item.sl_pnext = nil -- to be safe
			self.count = self.count + 1
			return
		end
		-- if item is better than ref, then insert before ref
		if item.fCost < ref.fCost or (ref.fCost == item.fCost and item.hCost < ref.hCost) then
			-- insert item before ref
			item.sl_pnext = ref
			head.sl_pnext = item
			self.count = self.count + 1
			return
		end
		-- use ref as the new head (iterate down the list)
		head = ref
	end
end

function slist:get(hash)
	return self[hash]
end

function slist:del(hash)
	local item = self[hash]
	if item ~= nil then
		self[hash] = nil
		local head = self
		while head.sl_next ~= nil do
			if head.sl_next.hash == item.hash then
				head.sl_next = item.sl_next
				self.count = self.count - 1
				return true
			end
			head = head.sl_next
		end
	end
	return false
end

function slist.new()
	return setmetatable({ count=0 }, {__index = slist})
end

--[[
This is the pathfinder function.
It will always return a pair of paths with at least one position.

@start_pos is the starting position
@end_pos is the ending position or area, must contain x,y,z
@entity a table that provides: collisionbox, fear_height, and jump_height

If @end_pos has a method "inside(self, pos, hash)", then that is called to test
whether a position is in the end area. That allows the path to end early.
--]]
function pathfinder.find_path(start_pos, end_pos, entity)
	minetest.log("action", "find_path:"..minetest.pos_to_string(start_pos))
	assert(start_pos ~= nil and start_pos.x ~= nil and start_pos.y ~= nil and start_pos.z ~= nil)
	assert(end_pos ~= nil and end_pos.x ~= nil and end_pos.y ~= nil and end_pos.z ~= nil)
	--print("searching for a path from:"..minetest.pos_to_string(pos).." to:"..minetest.pos_to_string(end_pos))

	local start_index = minetest.hash_node_position(start_pos)
	local target_index = minetest.hash_node_position(end_pos)

	if end_pos.inside == nil then
		-- don't modify parameters
		end_pos = { x=end_pos.x, y=end_pos.y, z=end_pos.z, inside=function(self, pos, hash) return hash == target_index end }
	end

	local openSet = slist.new() -- slist of active "walkers"
	local closedSet = {}        -- retired "walkers"

	local h_start = get_estimated_cost(start_pos, end_pos)
	openSet:insert({hCost = h_start, gCost = 0, fCost = h_start, parent = nil,
	                pos = start_pos, hash = minetest.hash_node_position(start_pos)})

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

	-- return a path and reverse path consisting of only the dest
	-- this is used for the two "impossible" error paths
	local function failed_path()
		local tmp = { vector.new(end_pos) }
		return tmp, tmp
	end

	local function collect_path(end_hash)
		-- trace backwards to the start node to create the reverse path
		local reverse_path = {}
		local current_index = end_hash
		repeat
			local ref = closedSet[current_index]
			if ref == nil then
				-- FIXME: this is an "impossible" error condition
				minetest.log("warning", "hash error")
				return failed_path()
			end
			table.insert(reverse_path, ref.pos)
			current_index = ref.parent
		until start_index == current_index

		-- iterate backwards on reverse_path to build path
		local path = {}
		for idx=#reverse_path,1,-1 do
			table.insert(path, reverse_path[idx])
		end
		if pathfinder.debug == true then
			show_particles(path)
		end
		return path, reverse_path
	end

	-- iterate as long as there are active walkers
	while openSet.count > 0 do
		local current_values = openSet:pop_head()

		-- add to the closedSet so we don't revisit this location
		closedSet[current_values.hash] = current_values

		-- check for a walker in the destination zone
		if end_pos:inside(current_values.pos, current_values.hash) then
			return collect_path(current_values.hash)
		end

		local neighbors = get_neighbors(current_values.pos, entity_height, entity_jump_height, entity_fear_height)

		for _, neighbor in pairs(neighbors) do
			if neighbor.cost ~= nil then
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
		-- This limit may cause failure where success would be possible.
		if openSet.count > 100 then
			minetest.log("warning", "too many walkers in "..minetest.pos_to_string(start_pos)..' to '..minetest.pos_to_string(end_pos))
			return collect_path(current_values.hash)
		end

		-- Catch running out of walkers without hitting the end.
		-- This happens when there is no possible path to the target.
		-- The caller should try again after following the path.
		if openSet.count == 0 then
			minetest.log("warning", "no path "..minetest.pos_to_string(start_pos)..' to '..minetest.pos_to_string(end_pos))
			return collect_path(current_values.hash)
		end
	end

	-- FIXME: this isn't reachable
	return failed_path()
end

-- convert the two radius values into r^2 values
local function sanatize_radius(dest_radius)
	if dest_radius == nil or dest_radius < 1 then
		dest_radius = 1
	end
	return dest_radius * dest_radius
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
	local r2 = sanatize_radius(dest_radius)
	if r2 < 2 then
		return pathfinder.find_path(start_pos, dest_pos, entity)
	end

	-- do the custom 'inside' function
	local endpos = {
		x=dest_pos.x, y=dest_pos.y, z=dest_pos.z,
		inside=function(self, pos, hash)
			local d2 = xyz_dist2(self, pos)
			return d2 <= r2
		end
	}
	return pathfinder.find_path(start_pos, endpos, entity)
end

--[[
Calculate a path to the closest position inside of the cylinder.
@dest_pos is the bottom-center of the cylinder.
@dest_radius is the radius of the cylinder, must be >= 1
@dest_height must be >= 1
]]
function pathfinder.find_path_cylinder(start_pos, entity, dest_pos, dest_radius, dest_height)
	local r2 = sanatize_radius(dest_radius)
	if dest_height == nil or dest_height < 1 then
		dest_height = 1
	end
	-- must be less than max_y
	local max_y = dest_pos.y + dest_height - 1

	local endpos = {
		x=dest_pos.x, y=dest_pos.y, z=dest_pos.z,
		inside=function(self, pos, hash)
			-- check top/bot of cylinder
			if pos.y < dest_pos.y or pos.y > max_y then
				return false
			end
			local d2 = xz_dist2(self, pos)
			return d2 <= r2
		end
	}
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

	local endpos = {
		x=midp.x, y=midp.y, z=midp.z,
		inside=function(self, pos, hash)
			return (pos.x >= minp.x and pos.x <= maxp.x and
			        pos.y >= minp.y and pos.y <= maxp.y and
			        pos.z >= minp.z and pos.z <= maxp.z)
		end
	}
	return pathfinder.find_path(pos, endpos, entity)
end

-- FIXME: external uses are probably incompatible with climbables
pathfinder.walkable = is_node_collidable
pathfinder.is_node_climbable = is_node_climbable
pathfinder.is_node_standable = is_node_standable
pathfinder.is_node_collidable = is_node_collidable

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
