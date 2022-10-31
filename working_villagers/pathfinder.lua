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

local sorted_hash = working_villages.require("sorted_hash")

local pathfinder = {}

-- set to do super verbose around this node (REMOVE)
local debug_position = { x=196, y=0, z=8 }

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
	local distX = math.abs(start_pos.x - end_pos.x)
	local distZ = math.abs(start_pos.z - end_pos.z)

	if distX > distZ then
		return 14 * distZ + 10 * (distX - distZ)
	else
		return 14 * distX + 10 * (distZ - distX)
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
			minetest.log("warning", "no nodedef for "..node.name)
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
		minetest.log("warning", "no nodedef for "..node.name)
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
		local pp = { x=pos.x, y=pos.y+dy, z=pos.z }
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
local function check_clearance(cpos, height, jump_height, start_height)
	local gpos = vector.new(cpos) -- copy for ground location
	local ret = { walk=true, stand=false, climb=true, jump=true, water=0 }
	local stand_cnt = start_height or 0

	--minetest.log("action", string.format("check_clearance: p=%s g=%s, h=%d j=%d s=%d",
	--		minetest.pos_to_string(cpos),
	--		minetest.pos_to_string(gpos),
	--		height, jump_height, stand_cnt))
	-- the 1 is for climbing
	for i=stand_cnt, height + math.max(jump_height, 1) do
		local hpos = {x=cpos.x, y=cpos.y+i, z=cpos.z}
		if is_node_collidable(minetest.get_node(hpos)) then
			--minetest.log("warning", string.format("check_clearance: %s %s, collide @ %s i=%d h=%d j=%d",
			--		minetest.pos_to_string(cpos), minetest.pos_to_string(gpos),
			--		minetest.pos_to_string(hpos), i, height, jump_height))
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
	--minetest.log("action", string.format(" %s clear w=%d s=%s c=%s j=%s",
	--									 minetest.pos_to_string(cpos),
	--									 tostring(ret.walk),
	--									 tostring(ret.stand),
	--									 tostring(ret.climb),
	--									 tostring(ret.jump)))
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

@cpos is the clear position where the MOB is standing
@height is the number of nodes that the MOB occupies
@jump_height is the number of nodes that the MOB can jump
]]
local function scan_neighbor_start(nc, height, jump_height)
	local ret = { stand=true, jump=true, climb_up=false, climb_down=false, swim_up=false, swim_down=false }
	local max_y = height + math.max(jump_height, 1)
	local water_cnt = 0

	local ii = nc:get_dy(0)
	ret.climb_up = ii.climb  -- may get cleared on the clearance check

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
			clear = not is_node_collidable(node),
			stand = is_node_standable(node),
			climb = is_node_climbable(node),
		}
		self.data[hash] = ii
		self.pos_miss = (self.pos_miss or 0) + 1
	else
		self.pos_hit = (self.pos_hit or 0) + 1
	end
	return ii
end

-- set the base for get_dy()
function nodecache:set_pos(pos)
	self.pos = vector.new(pos)
	self.dyc = {}
end

function nodecache:get_dy(dy)
	local ii = self.dyc[dy]
	if ii == nil then
		ii = self:get_at_pos({x=self.pos.x, y=self.pos.y+dy, z=self.pos.z})
		self.dyc[dy] = ii
		self.dy_miss = (self.dy_miss or 0) + 1
		--minetest.log("action", string.format("get_dy(%d) %s water=%s clear=%s stand=%s climb=%s",
		--	dy, minetest.pos_to_string(ii.pos),
		--	tostring(ii.water), tostring(ii.clear), tostring(ii.stand), tostring(ii.climb)))
	else
		self.dy_hit = (self.dy_hit or 0) + 1
	end
	return ii
end

function nodecache:done(dy)
	minetest.log("action",
		string.format("nodecache: dy hit=%d miss=%d, pos hit=%d miss=%d",
			(self.dy_hit or 0), (self.dy_miss or 0),
			(self.pos_hit or 0), (self.pos_miss or 0)))
end

function nodecache.new(pos)
	return setmetatable({ pos=pos, data={}, dyc={} }, { __index = nodecache })
end

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

@npos this is the node position at source height
@height the number of nodes that must be clear to be in this position (2)
@jump_height the height of a jump (1)
@fear_height how far we can drop down (2)
return { can_walk=bool, can_jump=bool, gpos=nil|position }
]]
local function scan_neighbor(nc, height, jump_height, fear_height)
	local ret = { can_walk=true, can_jump=true }

	-- check for the ability to walk into the node
	for dy=0,height-1 do
		if not nc:get_dy(dy).clear then
			--minetest.log("action", "can_walk not clear")
			ret.can_walk = false
			break
		end
	end

	-- check for the ability to jump into the node, starts checking at jump_height
	for dy=0,height-1 do
		if not nc:get_dy(jump_height+dy).clear then
			--minetest.log("action", "can_jump not clear")
			ret.can_jump = false
			break
		end
	end

	-- find ground height
	local gpos
	if not nc:get_dy(0).clear then
		--minetest.log("action", "ground not clear")
		-- same-y is blocked, scan upwards
		local gy
		for dy=1,jump_height do
			if nc:get_dy(dy).clear then
				gy = dy
				break
			end
		end
		if gy ~= nil then
			-- check for clear nodes above gpos.y
			for dy=0,height do
				if not nc:get_dy(gy+dy).clear then
					gy = nil
					break
				end
			end
			if gy ~= nil then
				gpos = {x=nc.pos.x, y=nc.pos.y+gy, z=nc.pos.z}
			end
		end
	else
		--minetest.log("action", "ground is clear")
		local water_cnt = 0
		if nc:get_dy(0).water then
			water_cnt = 1
		end
		for dy=-1,-(fear_height+1),-1 do
			local ii = nc:get_dy(dy)
			if ii.stand then
				gpos = {x=nc.pos.x, y=nc.pos.y+dy+1, z=nc.pos.z}
				break
			elseif ii.water then
				-- We can "stand" at the bottom of @height water nodes
				water_cnt = water_cnt +1
				if water_cnt >= height then
					gpos = {x=nc.pos.x, y=nc.pos.y+dy, z=nc.pos.z}
					break
				end
			end
		end
	end

	if gpos ~= nil then
		-- ensure we are allowed to stand on this node
		if is_node_stand_forbidden(vector.add(gpos, vector.new(0, -1, 0))) then
			--minetest.log("action", "forbidden")
			gpos = nil
		else
			-- scan upward to see if we have height free nodes
			local gdy = gpos.y - nc.pos.y
			for dy=0,height-1 do
				if not nc:get_dy(gdy+dy).clear then
					gpos = nil
					--minetest.log("action", "no headroom")
					break
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
	local tmp_pos = { x=pos.x, y=pos.y, z=pos.z }
	local node = minetest.get_node(tmp_pos)
	local height = 0
	if is_node_collidable(node) then
		-- upward scan looks for a not solid node
		repeat
			height = height + 1
			if height > jump_height then
				--minetest.log("warning", string.format(" ground @ %s %s too high j=%d node=%s", minetest.pos_to_string(pos), minetest.pos_to_string(tmp_pos), jump_height, node.name))
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
				--minetest.log("warning", string.format(" ground @ %s too low f=%d", minetest.pos_to_string(pos), fall_height))
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

--[[
This is called to find the 'stand level' for a neighboring node.
This is similar to ground level, with the following changes:
 - climbable (non-collidable) counts as a standing position
 - 2 nodes of water counts as a standing position
 - @height clear nodes must be above the gound level

If @pos is a collidable, we need to scan upward for the first non-solid node.

If @pos is not collidable, we need to scan downward for the first ground node.
Climbable nodes count as ground when below.

@jump_height is how high the MOB can jump
@fall_height is how far the MOB can fall without damage.
return nil (nothing within range) or the position of the ground.
--]]
local function get_neighbor_stand_level(pos, height, jump_height, fall_height)
	local tmp_pos = { x=pos.x, y=pos.y, z=pos.z }
	local node = minetest.get_node(tmp_pos)
	local height = 0
	if is_node_collidable(node) then
		-- upward scan looks for a not solid node
		repeat
			height = height + 1
			if height > jump_height then
				--minetest.log("warning", string.format(" ground @ %s %s too high j=%d node=%s", minetest.pos_to_string(pos), minetest.pos_to_string(tmp_pos), jump_height, node.name))
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
				--minetest.log("warning", string.format(" ground @ %s too low f=%d", minetest.pos_to_string(pos), fall_height))
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

	if new_args.nc == nil then
		new_args.nc = nodecache.new(current_pos)
	end
	new_args.start = scan_neighbor_start(new_args.nc, args.height, args.jump_height)
	local xx = {}
	for k, v in pairs(new_args.start) do
		table.insert(xx, string.format(" %s=%s", k, tostring(v)))
	end
	minetest.log("warning",
		string.format("start: %s %s", minetest.pos_to_string(current_pos), table.concat(xx, "")))

	-- Check to see if we can jump in the current pos. We can't jump to another
	-- node if we can't jump here.
	-- new_args.clear = check_clearance(current_pos, current_pos, args.height, args.jump_height)

	-- Set the jump height to 0 if we can't jump. May save a few cycles, but
	-- all the neighbors will have clear_walk==clear_jump
	--if not new_args.clear.jump then
	--	new_args.jump_height = 0
	--end
	return new_args
end

-- collect neighbors without diagonals
local function neighbors_collect_no_diag(neighbors, args)
	local nc = args.nc

	for nidx, ndir in ipairs(dir_vectors) do
		if nidx % 2 == 1 then -- no diagonals
			local neighbor_pos = vector.add(args.pos, ndir)

			nc:set_pos(neighbor_pos)
			local info = scan_neighbor(nc, args.height, args.jump_height, args.fear_height)

			if info.gpos ~= nil then
				if args.debug then
					minetest.log("action",
						string.format(" neighbor %s %s can_walk=%s can_jump=%s",
							minetest.pos_to_string(neighbor_pos), minetest.pos_to_string(info.gpos),
							tostring(info.can_walk), tostring(info.can_jump)))
				end
				if (info.gpos.y <= args.pos.y and info.can_walk) or (args.start.jump and info.can_jump) then
					table.insert(neighbors, {
						pos = info.gpos,
						hash = minetest.hash_node_position(info.gpos),
						cost = 10
					})
				end
			else
				if args.debug then
					minetest.log("action",
						string.format(" neighbor %s NONE can_walk=%s can_jump=%s",
							minetest.pos_to_string(neighbor_pos),
							tostring(info.can_walk), tostring(info.can_jump)))
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
		if neighbor_ground ~= nil and is_node_stand_forbidden(vector.add(neighbor_ground, vector.new(0, -1, 0))) then
			--minetest.log("warning", string.format(" ground @ %s not allowed", minetest.pos_to_string(neighbor_ground)))
			neighbor_ground = nil
		end
		local neighbor = {}

		neighbor.clear = check_clearance(neighbor_pos, neighbor_ground or neighbor_pos, args.height, args.jump_height)
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
				if not neighbor.clear.walk then
					-- can't walk into that neighbor
				elseif nidx % 2 == 0 then -- diagonals need to check corners
					local n_ccw = n_info[dir_add(nidx, -1)]
					local n_cw = n_info[dir_add(nidx, 1)]
					if n_ccw.clear.walk and n_cw.clear.walk then
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
						if n_info[dir_add(nidx, dd)].clear.walk ~= true then
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
		-- Check if we can climb and we are in a climbable node
		if args.start.climb_up then
			local npos = {x=args.pos.x, y=args.pos.y+1, z=args.pos.z}
			table.insert(neighbors, {
				pos = npos,
				hash = minetest.hash_node_position(npos),
				cost = 20})
		end

		-- Check if we can climb down
		if args.start.climb_down then
			local npos = {x=args.pos.x, y=args.pos.y-1, z=args.pos.z}
			table.insert(neighbors, {
				pos = npos,
				hash = minetest.hash_node_position(npos),
				cost = 15})
		end
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
	--minetest.log("warning", string.format("collect_path: end=%x start=%x", end_hash, start_index))
	-- trace backwards to the start node to create the reverse path
	local reverse_path = {}
	local cur_hash = end_hash
	for k, v in pairs(closedSet) do
		--minetest.log("warning", string.format(" - k=%x p=%s h=%x", k,
		--	minetest.pos_to_string(v.pos), v.hash))
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

local function nil2def(val, def)
	if val == nil then return def end
	return val
end

local function get_find_path_args(options, entity)
	options = options or {}
	local args = {
		want_diag = nil2def(options.want_diag, true), -- 'or' doesn't work with bool
		want_climb = nil2def(options.want_climb, true),
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
	assert(area ~= nil and area.inside ~= nil)

	local args = get_find_path_args({ want_diag=false })
	local start_node = minetest.get_node(start_pos)
	local start_nodedef = minetest.registered_nodes[start_node.name]
	local below_pos = vector.add(start_pos, {x=0,y=-1,z=0})
	local below_node = minetest.get_node(below_pos)
	args.nc = nodecache.new(start_pos)

	minetest.log("action",
		string.format("wayzone_flood @ %s %s w=%s h=%d j=%d f=%d below=%s %s",
			minetest.pos_to_string(start_pos), start_node.name, tostring(start_nodedef.walkable),
			args.height, args.jump_height, args.fear_height,
			minetest.pos_to_string(below_pos), below_node.name))

	local openSet = {}    -- set of active walkers; openSet[hash] = { pos=pos, hash=hash }
	local visitedSet = {} -- retired "walkers"; visitedSet[hash] = true
	local exitSet = {}    -- outside area or drop by more that jump_height; exitSet[hash] = true

	-- wrap 'add' with a function for logging
	local function add_open(item)
		--minetest.log("action", string.format(" add_open %s %x", minetest.pos_to_string(item.pos), item.hash))
		openSet[item.hash] = item
	end

	-- seed the start_pos
	add_open({ pos=start_pos, hash=minetest.hash_node_position(start_pos) })

	local y_lim = math.min(args.fear_height, args.jump_height)

	-- iterate as long as there are active walkers
	while true do
		local _, item = next(openSet)
		if item == nil then break end

		minetest.log("action", string.format(" process %s %x", minetest.pos_to_string(item.pos), item.hash))

		-- remove from openSet and process
		openSet[item.hash] = nil
		visitedSet[item.hash] = true
		for _, n in pairs(get_neighbors(item.pos, args)) do
			-- skip if already visited or queued
			if visitedSet[n.hash] == nil and openSet[n.hash] == nil then
				minetest.log("action", string.format("   n %s %x", minetest.pos_to_string(n.pos), n.hash))
				local dy = math.abs(n.pos.y - item.pos.y)
				if not area:inside(n.pos, n.hash) or dy > y_lim then
					exitSet[n.hash] = true
				else
					visitedSet[n.hash] = true
					exitSet[n.hash] = nil -- might have been unreachable via another neighbor
					add_open(n)
				end
			end
		end
	end
	args.nc:done()
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

		local s = {}
		for k, v in pairs(nodedef.groups) do
			table.insert(s, string.format("%s=%s", k, tostring(v)))
		end
		minetest.log("warning",
			string.format("can_stand_at: not stand %s name=%s groups=%s",
				minetest.pos_to_string(below),
				node.name,
				table.concat(s, " ")))

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

local function node_check(pos)
	local args = neighbor_args(pos, get_find_path_args({ want_diag=false }))
	local neighbors = {}

	minetest.log("action", "node_check @ "..minetest.pos_to_string(pos))
	if pathfinder.can_stand_at(pos, 2) then
		minetest.log("action", "  can_stand_at = true")
	end
	args.debug = true

	for _, n in pairs(get_neighbors(pos, args)) do
		minetest.log("action", string.format("  n %s", minetest.pos_to_string(n.pos)))
	end

	args.nc:done()
end

pathfinder.node_check = node_check

return pathfinder
