--[[
This is an implementation of the A* pathfinding algorithm.
There are two main interfaces: "find_path" and "wayzone_flood"
There are also quite a few useful node classification functions.

As a note, the A* uses the following cost values when evaluating the path.
 hCost = estimated remaining cost (0 at end)
 gCost = actual cost to this point (0 at start, full cost at end)
 fCost = hCost + gCost

"find_path()" searches for a series of positions going from the start_pos to
end center of the end_pos. It will fail horribly if the end_pos is not reachable.
By "fail horribly", I mean it will spend a lot of CPU failing to find a path.
A failed path typically takes much longer than a successful path.
That function should only be called if it is fairly certain that there is a
valid path.

"wayzone_flood()" does a flood-fill neighbor search within a limited area and
finds all nodes that are mutually reachable. If a neighbor falls outside of the
search area or it is an asymmetric move (due to fall_height ~= jump_height), or
it transitions from water/non-water, then it is added to a set of "exit nodes".
A higher level (waypoint_zones) uses this to precompute waypoint zones (wayzones)
for quicker, longer paths.

The meat of a pathfinder is in the "get_neighbor" function.
This finds all possible moves (new positions) from from the current position.
It has to handle the following move types:
 - walk to a neighbor node (with a potential fall of up to fear_height nodes)
 - jump to a neighbor node (can go up jump_height nodes)
 - climb up (1 node up)
 - climb down (1 node down)
 - swim up/down
 - swim horizontal

With the typical entity config (height=2, jump_height=1, fear_height=2), we scan
a column of up to 6 nodes at each neighbor position to find the stand level and
to check for clearance.
]]--
local S = minetest.get_translator("pathfinder")

local log = working_villages.require("log")
local sorted_hash = working_villages.require("sorted_hash")

local pathfinder = {}

-- set to do super verbose around this node (REMOVE)
local debug_position = vector.new(196, 0, 8)

-- show particles along the path
pathfinder.debug = true

--[[
This functions gets the minimum estimated cost to go from start to end.
It ignores the map.
It is important that the estimate is lower than or equal to reality.
If it over-estimates the cost, we won't get an optimal path.

As end_pos may be an area, this can overestimate the cost. However, that
shouldn't matter, as the path ends as soon as the walker hits the end area.
--]]
local function get_estimated_cost(start_pos, end_pos)
	if false then
		return 1
	elseif true then
		return vector.distance(start_pos, end_pos) * 10
	else
		local distX = math.abs(start_pos.x - end_pos.x)
		local distZ = math.abs(start_pos.z - end_pos.z)

		if distX > distZ then
			return 14 * distZ + 10 * (distX - distZ)
		else
			return 14 * distX + 10 * (distZ - distX)
		end
	end
end
pathfinder.get_estimated_cost = get_estimated_cost

-- This allows passing a position instead of a node in some functions.
-- FIXME: add "pos" variants of the functions?
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
			log.warning("no nodedef for %s", node.name)
		end
	end
	return true
end

--[[ Inverse of is_node_collidable()
FIXME: We really need a "can be in" test that would return false for lava or
other walkable nodes that cause damage.
]]
local function is_node_clear(node)
	return not is_node_collidable(node)
end

--[[
Return the "climbable" field from the node's definition.
]]
local function is_node_climbable(node)
	node = resolve_node(node)
	if node ~= nil then
		local nodedef = minetest.registered_nodes[node.name]
		if nodedef ~= nil then
			return nodedef.climbable
		end
		log.warning("no nodedef for %s", node.name)
	end
	return false
end

-- Is this a solid node that we are not allowed to stand on?
-- Right now, this is just "leaves", but we may also want any nodes that cause
-- damage to MOBs that stand on them.
local function is_node_stand_forbidden(node)
	node = resolve_node(node)
	if minetest.get_item_group(node.name, "leaves") > 0 then
		return true
	end
	return false
end

--[[
Detect if we can stand on the node.
We can stand on walkable and climbable nodes.
--]]
local function is_node_standable(node)
	node = resolve_node(node)
	if is_node_stand_forbidden(node) then
		return false
	end
	return is_node_collidable(node) or is_node_climbable(node)
end

local function is_node_water(node)
	node = resolve_node(node)
	return minetest.get_item_group(node.name, "water") > 0
end
pathfinder.is_node_water = is_node_water

local function is_node_door(node)
	node = resolve_node(node)
	return string.find(node.name, "doors:") ~= nil
end
pathfinder.is_node_door = is_node_door

--[[
Check to see how many clear nodes are at and above @pos.
Start checking at @start_height (usually 0 or 1).
Stop at pos.y+max_height-1.
Returns the number of clear nodes, which can be at most max_height.
For example if start_height=1 and max_height=3, it will check +1 and +2.
 dy
 +3
 +2 x
 +1 x
 +0   @pos

]]
local function check_clear_height(pos, max_height, start_height)
	start_height = start_height or 0
	local wcount = 0
	for dy = start_height, max_height-1 do
		local pp = vector.new(pos.x, pos.y+dy, pos.z)
		local node = minetest.get_node(pp)
		if is_node_collidable(node) then
			return dy, wcount
		end
		if minetest.get_item_group(node.name, "water") > 0 then
			wcount = wcount + 1
		end
	end
	return max_height-1, wcount
end

--[[
Check if we have clear nodes above cpos.
This is used to see if we can walk into a neighboring node and/or jump into it.
It also checks the ground level at the neighbor position.

For example, if height=2 and jump_height=2, we will check 4 nodes
starting at cpos and going +y.

max_y = height + math.max(jump_height, 1)

The numbers below represent the nodes to check.
 S = the nodes that must be clear to stand.
 J = the nodes that must be clear to jump.
 C = the nodes that must be clear to climb.

 - 3 S     J ----- top 2 for jump
 - 2 S S   J C --- bottom 3 for climb
 - 1   S S    C W - bottom 2 for walk
 - 0     S    C W - stand=walk or

To be able to walk into the node, we need to be clear on 0 & 1.
To be able to climb in the node, we need to be clear on 0, 1, 2
To be able to jump in(to) the node, we need to be clear on 2 & 3

@cpos is the position to start checking
@height is the number of nodes that the MOB occupies
@jump_height is how high the MOB can jump
@start_height sets the start of the scan, assuming the nodes are clear
returns { walk=bool, stand=bool, jump=bool, climb=bool }
--]]
-- FIXME: not used again...
local function check_clearance(cpos, height, jump_height, start_height)
	local gpos = vector.new(cpos) -- copy for ground location
	local ret = { walk=true, stand=false, climb=true, jump=true, water=0 }
	local stand_cnt = start_height or 0

	--log.action("check_clearance: p=%s g=%s, h=%d j=%d s=%d",
	--	minetest.pos_to_string(cpos),
	--	minetest.pos_to_string(gpos),
	--	height, jump_height, stand_cnt)
	-- the 1 is for climbing
	for i=stand_cnt, height + math.max(jump_height, 1) do
		local hpos = vector.new(cpos.x, cpos.y+i, cpos.z)
		if is_node_collidable(minetest.get_node(hpos)) then
			--log.warning("check_clearance: %s %s, collide @ %s i=%d h=%d j=%d",
			--	minetest.pos_to_string(cpos), minetest.pos_to_string(gpos),
			--	minetest.pos_to_string(hpos), i, height, jump_height)
			stand_cnt = 0
			if i < height + 1 then
				ret.climb = false
				if i < height then
					ret.walk = false
				end
			end
			-- jump only cares if above jump_height
			if i >= jump_height then
				if i < jump_height + height then
					ret.jump = false
				end
				if i > height then
					-- can't affect walk or climb, so we are done
					break
				end
			end
		else
			stand_cnt = stand_cnt + 1
			if stand_cnt >= height then
				ret.stand = true
			end
		end
	end
	--log.action(" %s clear w=%d s=%s c=%s j=%s",
	--	minetest.pos_to_string(cpos),
	--	tostring(ret.walk),
	--	tostring(ret.stand),
	--	tostring(ret.climb),
	--	tostring(ret.jump))
	return ret
end

--[[
This function scans the current location before evaluating neighbors.
It needs to determine the following:
 - Can the MOB stand at this location?
 - Can the MOB jump in this location?
 - Can the MOB climb up in this location (go up by 1, requires climbable node)?
 - Can the MOB climb down in this location (requires climbable node below)?
 - Can the MOB swim up? (water at full body @height)
 - Can the MOB swim down? (water below)

@nc is the node cache, since we will likely check the same nodes multiple times
    the node cache has the current position set as get_dy(0)
@height is the number of nodes that the MOB occupies
@jump_height is the number of nodes that the MOB can jump
]]
local function scan_neighbor_start(nc, height, jump_height)
	local ret = { stand=true, jump=true, climb_up=false, climb_down=false, swim_up=false, swim_down=false, in_water=false }
	local max_y = height + math.max(jump_height, 1)
	local water_cnt = 0

	local ii = nc:get_dy(0)
	ret.climb_up = ii.climb  -- may get cleared on the clearance check
	ret.in_water = ii.water

	if ii.water then
		water_cnt = 1
	end

	-- Scan upward for the remaining nodes
	for dy=1,max_y do
		ii = nc:get_dy(dy)
		if not ii.clear then
			if dy < height + jump_height then
				ret.jump = false
			end
			if dy < height + 1 then
				ret.climb_up = false
				if dy < height then
					ret.stand = false
				end
			end
		end
		if ii.water then
			water_cnt = water_cnt + 1
		end
	end

	-- if we can climb, then we don't swim (can a node be climbable and water?)
	if water_cnt >= height and not ret.climb_up then
		ret.swim_up = true
	end

	-- check the node below
	ii = nc:get_dy(-1)
	ret.climb_down = ii.climb
	ret.swim_down = ii.water
	ret.water = water_cnt
	return ret
end

-------------------------------------------------------------------------------
-- Stupid node cache to avoid repetitive node queries when finding neighbors.
-- Create when making a path, discard when done.
local nodecache = {}

function nodecache:get_at_pos(pos)
	local hash = minetest.hash_node_position(pos)
	local ii = self.data[hash]
	if ii == nil then
		local node = minetest.get_node(pos)
		ii = {
			pos = pos,
			hash = hash,
			node = node,
			water = is_node_water(node),
			door = is_node_door(node),
			clear = not is_node_collidable(node),
			stand = is_node_standable(node),
			climb = is_node_climbable(node),
		}
		self.data[hash] = ii
	end
	return ii
end

-- set the base for get_dy()
function nodecache:set_pos(pos)
	self.pos = vector.copy(pos)
	self.dyc = {}
end

function nodecache:get_dy(dy)
	local ii = self.dyc[dy]
	if ii == nil then
		local npos = vector.new(self.pos.x, self.pos.y+dy, self.pos.z)
		ii = self:get_at_pos(npos)
		self.dyc[dy] = ii
	end
	return ii
end

function nodecache.new(pos)
	return setmetatable({ pos=pos, data={}, dyc={} }, { __index = nodecache })
end
pathfinder.nodecache = nodecache

-------------------------------------------------------------------------------

--[[
This function is responsible for gathering information required to move *into*
a neighbor location.

There are three things that we need to know:
 - can_walk - requires @height clear nodes above @npos, regardless or ground level
 - can_jump - requires @height clear nodes above @gpos and gpos.y > npos.y.
 - ground_pos - (gpos) position of ground that has @height clear nodes above and
   is at most jump_height above @npos or fear_height below @npos.

Questions that have to be answered:
 - Position of the ground, if within +jump_height or -fear_height
 - Can the MOB walk into the position from the current location?
   - this requires @height clear (non-collidable) nodes at @npos
   - this covers transitions that require falling down a few levels
   - if the MOB must jump, then the answer is 'no'.
 - Can the MOB jump into the position from the current location?
   - this requires @height clear nodes above the gpos
 - Can the MOB jump in the current node?
   - this requires @height+@jump_height clear nodes above ground level.

j     z
h     z
o     z
XXX   z
  X   z
  XXX z
Start scanning nodes at npos.y+height+jump_height.
Scan down until a non-clear node is found.
If the node is standable (and allowed), then that is the ground position.

Scan neighbor. We start with the same-Y location moved +/-X or +/-Z.
Then we find the ground level and check how many empty spaces we have above.
If there is no valid ground position, then we check for clear

	walk=MOB can walk into the node (clear from npos.y to npos.y+height)
	stand=MOB can stand at gpos.y
	climb=MOB can stand at gpos.y with 1 clear above
	jump=MOB can jump in the node (clear to gpos.y+height+jump_height)
	clear=number of clear nodes above gpos
	water=number of water nodes above gpos (max=clear)

To walk into the neighbor node, we test:
 - the current position can stand (assumed true, since we are standing there)
 - the neighbor can stand
 - the neighbor gpos.y <= cpos.y

To jump into the neighbor node, we test:
 - the current position can jump
 - the neighbor can stand
 - the neighbor gpos.y > cpos.y

@nc node cache, with the pos set to the current neighbor
@height the number of nodes that must be clear to be in this position (2)
@jump_height the height of a jump (1)
@fear_height how far we can drop down (2)
return { npos=nc.pos, can_walk=bool, can_jump=bool, in_water=bool, gpos=nil|position }
]]
local function scan_neighbor(nc, height, jump_height, fear_height)
	local ret = { npos=nc.pos, can_walk=true, can_jump=true, in_water=false }

	-- check for the ability to walk into the node
	for dy=0,height-1 do
		if not nc:get_dy(dy).clear then
			--log.action("can_walk not clear")
			ret.can_walk = false
			break
		end
	end

	-- check for the ability to jump into the node, starts checking at jump_height
	for dy=0,height-1 do
		if not nc:get_dy(jump_height+dy).clear then
			--log.action("can_jump not clear")
			ret.can_jump = false
			break
		end
	end

	-- find ground height
	local gpos
	if not nc:get_dy(0).clear then
		--log.action("ground not clear")
		-- same-y is blocked, scan upwards
		local gy
		for dy=1,jump_height do
			if nc:get_dy(dy).clear then
				--log.action("ground clear @ %d", dy)
				gy = dy
				break
			end
		end
		if gy ~= nil then
			-- check for clear nodes above gpos.y
			for dy=0,height-1 do
				if not nc:get_dy(gy+dy).clear then
					gy = nil
					break
				end
			end
			if gy ~= nil then
				gpos = vector.new(nc.pos.x, nc.pos.y+gy, nc.pos.z)
			end
		end
	else
		--log.action("ground is clear")
		local water_cnt = 0
		if nc:get_dy(0).water then
			water_cnt = 1
		end
		for dy=-1,-(fear_height+1),-1 do
			local ii = nc:get_dy(dy)
			if ii.stand then
				gpos = vector.new(nc.pos.x, nc.pos.y+dy+1, nc.pos.z)
				break
			elseif ii.water then
				-- We can "stand" at the bottom of @height water nodes
				water_cnt = water_cnt +1
				if water_cnt >= height then
					gpos = vector.new(nc.pos.x, nc.pos.y+dy+1, nc.pos.z)
					break
				end
			end
		end
	end

	if gpos ~= nil then
		-- ensure we are allowed to stand on this node
		if is_node_stand_forbidden(vector.add(gpos, vector.new(0, -1, 0))) then
			--log.action("forbidden")
			gpos = nil
		else
			-- scan upward to see if we have height free nodes
			local gdy = gpos.y - nc.pos.y
			for dy=0,height-1 do
				local ii = nc:get_dy(gdy+dy)
				if not ii.clear then
					gpos = nil
					--log.action("no headroom")
					break
				end
				if ii.water then
					ret.in_water = true
				end
			end
		end
	end
	ret.gpos = gpos
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
	jump_height = jump_height or 1
	fall_height = fall_height or 2
	local tmp_pos = vector.new(pos.x, pos.y, pos.z)
	local node = minetest.get_node_or_nil(tmp_pos)
	if node == nil then
		minetest.load_area(tmp_pos)
		node = minetest.get_node(tmp_pos)
	end
	local height = 0
	if is_node_collidable(node) then
		-- upward scan looks for a not solid node
		repeat
			height = height + 1
			if height > jump_height then
				--log.warning(" ground @ %s %s too high j=%d node=%s", minetest.pos_to_string(pos), minetest.pos_to_string(tmp_pos), jump_height, node.name)
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
				--log.warning(" ground @ %s too low f=%d", minetest.pos_to_string(pos), fall_height)
				return nil
			end
			height = height + 1
			tmp_pos.y = tmp_pos.y - 1
			node = minetest.get_node(tmp_pos)
		until is_node_collidable(node) or is_node_climbable(node)
		tmp_pos.y = tmp_pos.y + 1
		return tmp_pos
	end
end
pathfinder.get_neighbor_ground_level = get_neighbor_ground_level

--[[
This table takes a direction and converts it to a vector.
It is used to scan the neighboring nodes on the X-Z plane.
1=up(-z), incr clockwise by 45 deg, even indexes are diagonals.
--]]
local dir_vectors = {
	[1] = vector.new( 0, 0, -1), -- up
	[2] = vector.new( 1, 0, -1), -- up/right
	[3] = vector.new( 1, 0,  0), -- right
	[4] = vector.new( 1, 0,  1), -- down/right
	[5] = vector.new( 0, 0,  1), -- down
	[6] = vector.new(-1, 0,  1), -- down/left
	[7] = vector.new(-1, 0,  0), -- left
	[8] = vector.new(-1, 0, -1), -- up/left
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

	if new_args.nc == nil then
		new_args.nc = nodecache.new(current_pos)
	else
		new_args.nc:set_pos(current_pos)
	end
	new_args.start = scan_neighbor_start(new_args.nc, args.height, args.jump_height)

	if args.debug > 1 then
		local xx = {}
		for k, v in pairs(new_args.start) do
			table.insert(xx, string.format(" %s=%s", k, tostring(v)))
		end
		log.action("start: %s %s", minetest.pos_to_string(current_pos), table.concat(xx, ""))
	end
	return new_args
end

-- collect neighbors without diagonals
local function neighbors_collect_no_diag(neighbors, args)
	local nc = args.nc

	for nidx, ndir in ipairs(dir_vectors) do
		if nidx % 2 == 1 then -- no diagonals
			local neighbor_pos = vector.add(args.pos, ndir)

			nc:set_pos(neighbor_pos)
			-- NOTE: ==> { npos=nc.pos, can_walk=bool, can_jump=bool, in_water=bool, gpos=nil|position }
			local info = scan_neighbor(nc, args.height, args.jump_height, args.fear_height)

			if info.gpos ~= nil then
				if (info.gpos.y <= args.pos.y and info.can_walk) or (args.start.jump and info.can_jump) then
					local cost = 10
					if info.gpos.y ~= args.pos.y then
						cost = cost + 10
					end
					if args.start.in_water or info.in_water then
						cost = cost * 5
					end
					if args.debug > 1 then
						log.action(" neighbor %s %s cost=%d can_walk=%s can_jump=%s in_water=%s",
							minetest.pos_to_string(info.npos), minetest.pos_to_string(info.gpos),
							cost, tostring(info.can_walk), tostring(info.can_jump), tostring(info.in_water))
					end
					table.insert(neighbors, {
						pos = info.gpos,
						hash = minetest.hash_node_position(info.gpos),
						cost = cost
					})
				end
			else
				if args.debug > 1 then
					log.action(" neighbor %s NONE can_walk=%s can_jump=%s",
						minetest.pos_to_string(info.npos),
						tostring(info.can_walk), tostring(info.can_jump))
				end
			end
		end
	end
end

--[[
Collect neighbors with diagonals.
This is a two-step process. First we gather all the column info and then
we check if we can go in that direction.
In the 4 direction in the XZ plane (N/S/E/W) we can jump up, go flat or drop down.
In the 4 diagonals, we can only go flat. It requires a flat or drop on both sides.
For example, to go NE, both N and E must be clear at ground level.
The neighbor structure is { pos=pos, hash=hash, cost=num }
]]
local function neighbors_collect_diag(neighbors, args)
	local nc = args.nc

	-- collect the neighbor ground position and jump/walk clearance (X-Z plane)
	-- using the neighbor index so we can ref surrounding directions
	local n_info = {}
	for nidx, ndir in ipairs(dir_vectors) do
		nc:set_pos(vector.add(args.pos, ndir))
		n_info[nidx] = scan_neighbor(nc, args.height, args.jump_height, args.fear_height)
	end

	if args.debug > 3 then
		for nidx, info in ipairs(n_info) do
			log.action("  -- [%d] pos=%s gnd=%s walk=%s jump=%s water=%s", nidx,
				minetest.pos_to_string(info.npos),
				minetest.pos_to_string(info.gpos or vector.zero()),
				tostring(info.can_walk),
				tostring(info.can_jump),
				tostring(info.in_water))
		end
	end

	-- 2nd pass to evaluate 'clear' info to check diagonals
	for nidx, info in ipairs(n_info) do
		-- NOTE: info: { npos=nc.pos, can_walk=bool, can_jump=bool, in_water=bool, gpos=nil|position }
		if info.gpos ~= nil then
			local cost = 0
			local dy = args.pos.y - info.gpos.y
			if dy < 0 then -- jumping up
				if not (args.start.jump and info.can_jump) then
					-- can't jump from current location to neighbor
				elseif nidx % 2 == 0 then -- diagonals need to check corners
					-- can't jump on the diagonals
					--local n_ccw = n_info[dir_add(nidx, -1)]
					--local n_cw = n_info[dir_add(nidx, 1)]
					--if n_ccw.can_jump and n_cw.can_jump then
					--	cost = 14 + 15 -- 15 for jump, 14 for diag
					--end
				else
					-- not diagonal, can go
					cost = 10 + 15 -- 15 for jump, 10 for move
				end
			else -- dy >= 0, flat or falling
				if not info.can_walk then
					-- can't walk into that neighbor
				elseif nidx % 2 == 0 then -- diagonals need to check corners
					local n_ccw = n_info[dir_add(nidx, -1)]
					local n_cw = n_info[dir_add(nidx, 1)]
					if n_ccw.can_walk and n_cw.can_walk then
						-- 14 for diag, 8 for each node drop
						cost = 14 + (8 * dy)
					end
				else
					-- 10 for diag, 8 for each node drop
					cost = 10 + (8 * dy)
				end
			end
			if cost ~= nil then
				-- double the cost if neighboring cells are not clear
				-- FIXME: this is an attempt to get the MOB to stay away
				--        from corners and ledges.
				-- add a cost 10 penalty for each edge that isn't walkable
				for dd=1,7,2 do
					if n_info[dd].gpos == nil then
						cost = cost + 10
					elseif n_info[dd].can_walk ~= true then
						cost = cost + 5
					end
				end
			end
			if cost > 0 then
				if args.start.in_water or info.in_water then
					cost = cost * 5
				end

				table.insert(neighbors, {
					pos = info.gpos,
					hash = minetest.hash_node_position(info.gpos),
					cost = cost
				})
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
		--neighbors_collect_no_diag(neighbors, args)
	else
		neighbors_collect_no_diag(neighbors, args)
	end

	-- Check if we can climb or swim up
	if (args.want_climb and args.start.climb_up) or (args.want_swim and args.start.swim_up) then
		local npos = vector.new(args.pos.x, args.pos.y+1, args.pos.z)
		local cost = 20
		if args.start.swim_up and not args.start.climb_up then
			cost = cost * 5
		end
		table.insert(neighbors, {
			pos = npos,
			hash = minetest.hash_node_position(npos),
			cost = cost})
	end

	-- Check if we can climb or swim down
	if (args.want_climb and args.start.climb_down) or (args.want_swim and args.start.swim_down) then
		local npos = vector.new(args.pos.x, args.pos.y-1, args.pos.z)
		local cost = 15
		if args.start.swim_down and not args.start.climb_down then
			cost = cost * 5
		end
		table.insert(neighbors, {
			pos = npos,
			hash = minetest.hash_node_position(npos),
			cost = cost})
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
		--log.action(" ** %s %s", minetest.pos_to_string(pos), t)
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

--[[
Roll up the path from end_hash back to start_index. Since we trace back from the
end position, the path is reversed.
]]
local function do_collect_path(posSet, end_hash, start_index)
	--log.warning("collect_path: end=%x start=%x", end_hash, start_index)
	-- trace backwards to the start node to create the reverse path
	local reverse_path = {}
	local cur_hash = end_hash
	while start_index ~= cur_hash and cur_hash ~= nil do
		local ref = posSet:get(cur_hash)
		table.insert(reverse_path, ref.pos)
		cur_hash = ref.parent
	end

	-- iterate backwards on reverse_path to build the forward path
	local path = {}
	for idx=#reverse_path,1,-1 do
		table.insert(path, reverse_path[idx])
	end
	--if pathfinder.debug == true then
	--	pathfinder.show_particles(path)
	--end
	-- return both forward and reverse paths, since we have both
	return path, reverse_path
end

local function nil2def(val, def)
	if val == nil then return def end
	return val
end

-- normalize the options/args used with the pathfinder, populating defaults
local function get_find_path_args(options, entity)
	options = options or {}
	local args = {
		want_diag = nil2def(options.want_diag, true), -- 'or' doesn't work with bool
		want_climb = nil2def(options.want_climb, true),
		want_swim = nil2def(options.want_swim, true),
		want_nil = options.want_nil,
		debug = options.debug or 0,
		height = options.height or 2,
		fear_height = options.fear_height or 2,
		jump_height = options.jump_height or 1,
	}
	-- pull the height from the collisionbox, if available
	if entity and entity.collisionbox then
		local collisionbox = entity.collisionbox or entity.initial_properties.collisionbox
		args.height = math.ceil(collisionbox[5] - collisionbox[2])
	end
	return args
end

local function debug_dot(pos)
	minetest.add_particle({
		pos = pos,
		expirationtime = 15,
		playername = "singleplayer",
		glow = minetest.LIGHT_MAX,
		texture = "wayzone_node.png",
		size = 3,
	})
end

--[[
This is the pathfinder function.
It will always return a pair of paths with at least one position.

@start_pos is the starting position
@target_area is the target area. It must contain x,y,z, which describes a position
  inside the target area, usually the center.
  It may contain "inside" and "outside" functions.
@entity a table that provides: collisionbox, fear_height, and jump_height
@option { want_nil = return nil on failure }

If @target_area has a method "inside(self, pos, hash)", then that is called to test
whether a position is in the target area. That allows the path to end early.

If @target_area has a method "outside(self, pos, hash)", then that is called to test
whether a walker should be dropped. If that returns true, the location is outside
of the area that we can explore.

returns an array of waypoint positions and a reversed array (why??)
--]]
function pathfinder.find_path(start_pos, target_area, entity, options)
	-- start_pos is usually the current position, which isn't grid-aligned
	local start_pos = vector.floor(start_pos)
	local args = get_find_path_args(options, entity)
	assert(start_pos ~= nil and start_pos.x ~= nil and start_pos.y ~= nil and start_pos.z ~= nil)
	assert(target_area ~= nil and target_area.x ~= nil and target_area.y ~= nil and target_area.z ~= nil)

	local start_hash = minetest.hash_node_position(start_pos)
	local target_pos = vector.new(target_area.x, target_area.y, target_area.z)
	local target_hash = minetest.hash_node_position(target_pos)
	local target_inside = target_area.inside

	local h_start = get_estimated_cost(start_pos, target_pos)

	log.action("find_path: start %s dest %s hCost=%d",
		minetest.pos_to_string(start_pos),
		minetest.pos_to_string(target_pos), h_start)

	-- create a custom inside function if there is none defined
	if target_inside == nil then
		target_inside = function(self, pos, hash) return hash == target_hash end
	end

	local posSet = slist_new() -- position storage

	local function add_open(item)
		debug_dot(item.pos)
		posSet:insert(item)
	end

	add_open({ hCost = h_start, gCost = 0, fCost = h_start, parent = nil,
	           pos = start_pos, hash = start_hash })

	-- return a path and reverse path consisting of a single waypoint set to
	-- target_pos. This is used for the failure paths.
	local function failed_path()
		if options.want_nil then return nil end
		local tmp = { vector.new(target_pos) }
		return tmp, tmp
	end

	local function collect_path(end_hash)
		return do_collect_path(posSet, end_hash, start_hash)
	end

	-- iterate as long as there are active walkers
	local max_walker_cnt = 1
	while true do
		local current_values = posSet:pop_head()
		if current_values == nil then break end
		max_walker_cnt = math.max(max_walker_cnt, posSet.count)

		if args.debug > 1 then
			log.action("processing %s %x fCost=%d gCost=%d hCost=%d wCnt=%d vCnt=%d",
				minetest.pos_to_string(current_values.pos), current_values.hash,
				current_values.fCost, current_values.gCost, current_values.hCost, posSet.count, posSet.total)
		end

		-- Check for a walker in the destination zone.
		-- Note that we only check the "best" walker.
		if target_inside(target_area, current_values.pos, current_values.hash) then
			log.action(" walker %s is inside end_pos, hash=%x parent=%x gCost=%d",
				minetest.pos_to_string(current_values.pos), current_values.hash,
				current_values.parent or 0, current_values.gCost)
			return collect_path(current_values.hash)
		end

		-- process possible moves (neighbors)
		for _, neighbor in pairs(get_neighbors(current_values.pos, args)) do
			-- do not process if outside of the search zone
			if (target_area.outside == nil or
			    not target_area:outside(current_values.pos, current_values.hash))
			then
				local new_gCost = current_values.gCost + neighbor.cost
				-- if we already visited this node, then we only store if the new cost is less (unlikely)
				local old_item = posSet:get(neighbor.hash)
				if old_item == nil or new_gCost < old_item.gCost then
					local new_hCost = get_estimated_cost(neighbor.pos, target_pos)
					if args.debug > 2 then
						log.action(" walker %s %x cost=%d fCost=%d gCost=%d hCost=%d parent=%x",
							minetest.pos_to_string(neighbor.pos), neighbor.hash, neighbor.cost, new_gCost+new_hCost, new_gCost, new_hCost, current_values.hash)
					end
					add_open({
						gCost = new_gCost,
						hCost = new_hCost,
						fCost = new_gCost + new_hCost,
						parent = current_values.hash,
						pos = neighbor.pos,
						hash = neighbor.hash
					})
				end
			end
		end

		-- In ideal situations, we will bee-line directly towards the dest.
		-- Complex obstacles cause an explosion of open walkers.
		-- Prevent excessive memory/CPU usage by limiting the number of open walkers.
		-- The caller will travel to the end of the path and then try again.
		-- This limit may cause failure where success should be possible.
		if posSet.count > 200 then
			log.warning("too many walkers in %s to %s",
				minetest.pos_to_string(start_pos), minetest.pos_to_string(target_pos))
			return failed_path()
		end
	end

	-- We ran out of walkers without hitting the target.
	-- This happens when there is no possible path to the target.
	log.warning("no path in %s to %s count=%d total=%d",
		minetest.pos_to_string(start_pos), minetest.pos_to_string(target_pos), posSet.count, posSet.total)
	minetest.add_particle({
		pos = target_pos,
		expirationtime = 15,
		playername = "singleplayer",
		glow = minetest.LIGHT_MAX,
		texture = "wayzone_exit.png",
		size = 5,
	})
	local texture = "wayzone_node.png"
	for hh, ii in pairs(posSet.data) do
		--log.action(" visited %s", minetest.pos_to_string(ii.pos))
		minetest.add_particle({
			pos = ii.pos,
			expirationtime = 15,
			playername = "singleplayer",
			glow = minetest.LIGHT_MAX,
			texture = texture,
			size = 3,
		})
	end

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
	local midp = vector.round(vector.new((minp.x+maxp.x)/2, (minp.y+maxp.y)/2, (minp.z+maxp.z)/2))

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
@debug is a verbosity indicator 0=none (default), 1+=log stuff
@return visited_nodes, exit_nodes
--]]
function pathfinder.wayzone_flood(start_pos, area, debug)
	assert(start_pos ~= nil and start_pos.x ~= nil and start_pos.y ~= nil and start_pos.z ~= nil)
	assert(area ~= nil and area.inside ~= nil)

	local args = get_find_path_args({ want_diag=false })
	args.debug = debug or 0
	local start_node = minetest.get_node(start_pos)
	local start_nodedef = minetest.registered_nodes[start_node.name]
	local below_pos = vector.new(start_pos.x, start_pos.y - 1, start_pos.z)
	local below_node = minetest.get_node(below_pos)
	local in_water = is_node_water(start_node)
	local in_door = is_node_door(start_node)
	args.nc = nodecache.new(start_pos)

	if args.debug > 0 then
		log.action("wayzone_flood @ %s %s walk=%s h=%d j=%d f=%d below=%s %s water=%s door=%s",
			minetest.pos_to_string(start_pos), start_node.name, tostring(start_nodedef.walkable),
			args.height, args.jump_height, args.fear_height,
			minetest.pos_to_string(below_pos), below_node.name, tostring(in_water), tostring(in_door))
	end

	-- NOTE: We don't need sorting, so just use tables
	local openSet = {}    -- set of active walkers; openSet[hash] = { pos=pos, hash=hash }
	local visitedSet = {} -- retired "walkers"; visitedSet[hash] = true
	local exitSet = {}    -- outside area or drop by more that jump_height; exitSet[hash] = true

	-- Wrap 'add' with a function for logging
	local function add_open(item)
		--log.action(" add_open %s %x", minetest.pos_to_string(item.pos), item.hash)
		openSet[item.hash] = item
	end

	-- seed the start_pos
	add_open({ pos=start_pos, hash=minetest.hash_node_position(start_pos) })

	local y_lim = math.min(args.fear_height, args.jump_height)

	-- iterate as long as there are active walkers
	while true do
		local _, item = next(openSet)
		if item == nil then break end
		if args.debug > 1 then
			log.action(" process %s %x", minetest.pos_to_string(item.pos), item.hash)
		end

		-- remove from openSet and process
		openSet[item.hash] = nil
		visitedSet[item.hash] = true
		for _, n in pairs(get_neighbors(item.pos, args)) do
			-- skip if already visited or queued
			if visitedSet[n.hash] == nil and openSet[n.hash] == nil then
				local ii = args.nc:get_at_pos(n.pos)
				local dy = math.abs(n.pos.y - item.pos.y)
				if not area:inside(n.pos, n.hash) or dy > y_lim or ii.water ~= in_water or ii.door ~= in_door then
					exitSet[n.hash] = true
					if args.debug > 1 then
						log.action("   n %s %x w=%s/%s d=%s/%s EXIT",
							minetest.pos_to_string(n.pos), n.hash, tostring(ii.water), tostring(in_water),
							tostring(ii.door), tostring(in_door))
					end
				else
					if args.debug > 1 then
						log.action("   n %s %x w=%s/%s d=%s/%s VISITED",
							minetest.pos_to_string(n.pos), n.hash, tostring(ii.water), tostring(in_water),
							tostring(ii.door), tostring(in_door))
					end
					visitedSet[n.hash] = true
					exitSet[n.hash] = nil -- might have been unreachable via another neighbor
					add_open(n)
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

function pathfinder.can_stand_at(orig_pos, height, who_called)
	local pos = vector.round(orig_pos)
	-- must be able to occupy pos and stand on the node below
	local node = minetest.get_node(pos)
	if not is_node_clear(node) then
		log.warning("can_stand_at:%s: not clear %s %s", who_called, minetest.pos_to_string(pos), node.name)
		return false
	end

	local below = vector.new(pos.x, pos.y-1, pos.z)
	--local node = minetest.get_node_or_nil(below)
	--while node ~= nil and is_node_clear(node) == true do
	--	below.y = below.y - 1
	--	node = minetest.get_node_or_nil(below)
	--end
	--if node == nil then
	--	return false
	--end
	--below.y = below.y + 1
	if not pathfinder.is_node_standable(below) then
		local node = minetest.get_node_or_nil(below)
		local nodedef = minetest.registered_nodes[node.name]

		local s = {}
		for k, v in pairs(nodedef.groups) do
			table.insert(s, string.format("%s=%s", k, tostring(v)))
		end
		log.warning("can_stand_at:%s: not stand %s pos=%s below=%s name=%s groups=%s",
			who_called,
			minetest.pos_to_string(orig_pos),
			minetest.pos_to_string(pos),
			minetest.pos_to_string(below),
			node.name,
			table.concat(s, " "))

		return false
	end
	-- if height = 2, we check 1 node above pos (which we already checked)
	for hh = 1, height - 1 do
		local tpos = vector.new(pos.x, pos.y+hh, pos.z)
		if not is_node_clear(tpos) then
			log.warning("can_stand_at:%s: not clear %s", who_called, minetest.pos_to_string(tpos))
			return false
		end
	end
	log.warning("can_stand_at:%s: yes %s below %s", who_called, minetest.pos_to_string(pos), minetest.pos_to_string(below))
	return true
end

function pathfinder.get_ground_level(pos)
	return get_neighbor_ground_level(pos, 30927, 30927)
end

-- this is called upon use of a tool for debug
local function node_check(pos)
	local args = neighbor_args(pos, get_find_path_args({ want_diag=true, want_climb=true, want_swim=true }))
	local neighbors = {}

	-- args.start={ stand=true, jump=true, climb_up=false, climb_down=false, swim_up=false, swim_down=false, in_water=false }

	log.action("node_check @ %s diag=%s climb=%s swim=%s start.stand=%s jump=%s climb_up=%s climb_down=%s swim_up=%s swim_down=%s in_water=%s",
		minetest.pos_to_string(pos),
		tostring(args.want_diag),
		tostring(args.want_climb),
		tostring(args.want_swim),
		tostring(args.want_swim),
		tostring(args.start.stand),
		tostring(args.start.jump),
		tostring(args.start.climb_up),
		tostring(args.start.climb_down),
		tostring(args.start.swim_up),
		tostring(args.start.swim_down),
		tostring(args.start.in_water))

	if pathfinder.can_stand_at(pos, 2, "node_check") then
		log.action("  can_stand_at = true")
	end
	args.debug = 2

	for _, n in pairs(get_neighbors(pos, args)) do
		log.action("  n %s", minetest.pos_to_string(n.pos))
	end
end

pathfinder.node_check = node_check

return pathfinder
