--[[
Uses mapblock_info to create an 8x8x8 block of moves.
The "move" data is stored in 1 byte for each node (512 byte string).

Navigation information.
This depends on the map data and is (lazily) recalculated when the mapblock data changes.
We track the 15 neighboring 8x8x8 blocks to see what needs to be recalculated.
When a neighboring chunk changes, the outter edge of the data will need
to be re-evaluated. X-Z are sensitive to 1 node in the neighbors.
Y is sensitive to jump_height+height-1 nodes above and 1+fear_height below.
The wayzones will need to be updated only if the output changes.

The data is as follows:
	b0  : can go north (+Z)
	b1  : can go south (-Z)
	b2  : can go east (+X)
	b3  : can go west (-X)
	b4  : can go up (+Y)
	b5  : can go down (-Y)
	b6  : TBD
	b7  : node is a corner (nav-specific)

The N/S/E/W movements may be a jump up or drop down (y+jump to y-fear).

Strategy:
Coordinates are relative to the chunk corner, so 0-15 in each direction.
 - Iterate over all 256 nodes in the X-Z plane.
   - Scan from y=7 downward to y=0.
     Check if the node is standable.
     Classify the node (standable, walkable, climbable, node_type)
     Cache the stand Y pos and height above ground (cap at height+jump_height)
 - Iterate on all standable nodes (moves)
   - Locate possible standable nodes to the N/S/E/W.
     - check Y=jump_height down to fear_height to find a possible move
     - record if the move is possible
 - Iterate on all standable nodes (corner)
   - examine neighbors to determine if the

First pass, use a custom hash (pack 3 nibbles).
Then flatten that to a ArrayOfU16 or string.

Corners are detected as follows:
 - check the four move directions
   - if two neighboring nodes can be moved to (N+W, N+E, S+E, S+W)
     - see if those nodes can move to the original node's diagonal. (must be 'no')
     - see if those nodes can continue to move in the same direction (one must be 'yes')

A function is needed to find the standable node in the direction.
If should check from pos.y+jump_height down to pos.y-fear_height and take the
first standable node, but only if the bit indicates that movement is possible.

This data is used to create wayzones. It may also be used in the node-based pathfinder.


Y height...
Divide the node into 1/4 (2 bits)? 1/8 (3 bits)?

What about a generic scan for geometry?

b0:1 = collision type node is walkable, can collide with it
b1 = can occupy (node is NOT walkable OR the cbox doesn't fill the whole node)
     if collide is also set, then the cbox must be checked. should be rare. (snow????)
b2 = can stand

if b0:1 = 3
b6:7 =

-------------------------------------------------------------------------------
Node information.
This contains info about the node and should not refer to other nodes, nor
should the info rely on the position in the world.
This information is calculated as needed and can't be calculated until all
registration has completed.

This is cached with the keys set to:
	cache_uses_param2[node.name] = false/number(mask: 0x03 or 0x1f)
	cache_info[node.name][node.param2] = {}
	cache_info[node.name] = {}
If the node isn't "4dir" or "facedir", then param2 is set to 0.

b0:3 : cbox_type enum (0-15)
	0 : not walkable (no collision, not important: "air", "flower", etc)
	1 : solid node (full cbox)
	2 : floor height is in height field (snow=1(0.222), slab=4(0.556))
		cbox = { -0.5, -0.5, -0.5, 0.5, -0.5+height, 0.5 }
	3 : ceiling height is in height field (slab on ceiling)
		cbox = { -0.5, -0.5+height, -0.5, 0.5, 0.5, 0.5 }
	4 : custom cbox (stair, rotated slab (not top or bottom), non-uniform node)
	5 : door or gate (walkable, but treated as non-walkable)
	6 : liquid (b4:6 contains info)
	7 : climbable (ladder, scaffolding, etc) (b4:6 contains info)
	8..14 : TBD
b4:6 : (cbox_type=2,3) node height rounded up to 1/9 increments (0-7 => 1/9-8/9)
	NOTE: height = (1 + val) / 9
	NOTE: height == 0 or 1 is not possible, as a different type would be used
	0=1/9 h=0.111 y=-0.388
	1=2/9 h=0.222 y=-0.288
	2=3/9 h=0.333 y=-0.188
	3=4/9 h=0.444 y=-0.088
	4=5/9 h=0.556 y=0.089
	5=6/9 h=0.667 y=0.189
	6=7/9 h=0.778 y=0.289
	7=8/9 h=0.889 y=0.389
b4:6 : (cbox_type=6) liquid type
	b4  = causes drowning (water vs anti-gravity area?)
	b5  = TBD
	b6  = TBD
b4:6 : (cbox_type=7) describes climbable type
	0-3 = wall mounted ladder facedir (b6=0)
	4   = scaffolding, climbable inside node (b6=1)
b7 : avoid node, don't stand on or be in the node.
	- node causes damage (lava, fire, thorn bush, razorwire, etc.)
	- not allowed to walk/stand on the node ("group:leaves", "group:bed", fence, quicksand)

A hash over the resultant bytes for chunk should be used to detect "real" changes.
For example, changing a node from "default:blueberry_bush_leaves" to
"default:blueberry_bush_leaves_with_berries" should not cause navigation
information to be recomputed.

I don't think we need to keep this data... Except it would be useful to know
which segment changed. Perhaps split the chunk into regions and calculate
several hashes.

Using 8 zones (top view, 4 more under)
+----------------+
|1111111122222222|
|1111111122222222|
|1111111122222222|
|1111111122222222|
|1111111122222222|
|1111111122222222|
|1111111122222222|
|1111111122222222|
|3333333344444444|
|3333333344444444|
|3333333344444444|
|3333333344444444|
|3333333344444444|
|3333333344444444|
|3333333344444444|
|3333333344444444|
+----------------+
Changes in 1 would affect 1, above 1, below 1 and possibly N/S/E/W and their over/under.

-------------------------------------------------------------------------------
Dirty:
When a chunk changes, the "node information" is marked as dirty.
The hash over that is lazily recalculated. If that changes, the navigation
information is marked dirty according to where in the chunk the
all navigation information in that chunk is marked dirty.
When a neighbor chunk changes, navigation infomation in the chunk is marked
dirty depending on adjacent chunk location.
(For now, mark the 6 adjacent and the 4 above and 4 below the side chunks.)
]]
local log = working_villages.require("log")
local node_cbox_cache = working_villages.require("nav/node_cbox_cache")
local mapblock_info = working_villages.require("nav/mapblock_info")
local mapblock_info_store = working_villages.require("nav/mapblock_info_store")
local info_store = mapblock_info_store.new_store(8)

-------------------------------------------------------------------------------
local mapblock_moves = {}

--[[ check to see the amount of clear space at the node at @pos
Limit the search to @max_height nodes
]]
function mapblock_moves.standable_height_at(pos, max_height, can_climb, can_swim)
	max_height = math.min(max_height or 4, 8)
	local ii = mapblock_info.decode(mapblock_info.getat(pos))
	local under = vector.offset(pos, 0, -1, 0)
	local iiu = mapblock_info.decode(mapblock_info.getat(under))

	log.action("start %s => %s", minetest.pos_to_string(pos), dump(ii))
	log.action(" = under %s => %s", minetest.pos_to_string(under), dump(iiu))

	-- don't be in nodes or on nodes that should be avoided
	if ii.avoid or iiu.avoid then
		return 0
	end

	-- can the MOB's feet be in this node? (We don't support height < 1)
	if ii.name == "solid" or ii.name == "ceiling" then
		return 0
	end

	if can_swim and ii.name == "liquid" then
		-- we can be supported in this node regardless of what is under
	elseif can_climb and (ii.name == "climb" or iiu.name == "climb") then
		-- We can "stand" in or on a "climb" node
	elseif iiu.name == "solid" or iiu.name == "ceiling" then
		-- the node under provides a standing surface
	else
		log.action("standable_height_at: cannot stand at %s %s under=%s", minetest.pos_to_string(pos), ii.name, iiu.name)
		return 0
	end

	local floor_h = 0
	if ii.name == "floor" or ii.name == "cbox" then
		floor_h = ii.height -- can be at most 1
	end
	local h = 1 - floor_h
	while h < max_height do
		pos.y = pos.y + 1
		local iy = mapblock_info.decode(mapblock_info.getat(pos))
		log.action(" = check %s => %s", minetest.pos_to_string(pos), dump(iy))
		if iy.avoid then
			break
		end
		if iy.name == "clear" or iy.name == "door" or (can_swim and iy.name == "liquid") or iy.name == "climb" then
			-- the head/body can be here, so keep scanning up
			h = h + 1
		elseif iy.name == "ceiling" then
			h = h + iy.height
			break
		elseif iy.name == "cbox" then
			local cbi = node_cbox_cache.get_node_cbox(minetest.get_node(pos))
			h = h + cbi.miny
			break
		else
			-- no head here
			break
		end
	end
	return h
end


--function mapblock_moves.find_standable_at(x, z, miny, maxy)
--
--
--local function process_chunk(self, chunk_hash)
--	local chunk_pos = minetest.get_position_from_hash(chunk_hash)
--	local chunk_size = wayzone.chunk_size
--	local chunk_mask = chunk_size - 1
--	local chunk_maxp = vector.new(chunk_pos.x + chunk_mask, chunk_pos.y + chunk_mask, chunk_pos.z + chunk_mask)
--
--	if self.debug > 0 then
--		log.action("-- process_chunk: %s-%s h=%x",
--			minetest.pos_to_string(chunk_pos), minetest.pos_to_string(chunk_maxp), chunk_hash)
--	end
--
--	local time_start = minetest.get_us_time()
--
--	-- create a new chunk, copying fields from the old one
--	local wzc = wayzone_chunk.new(chunk_pos, self.chunks[chunk_hash])
--
--	-- build the allowed area for the flood fill
--	local area = {
--		minp=vector.new(chunk_pos),
--		maxp=chunk_maxp,
--		inside=pathfinder.inside_minp_maxp }
--
--	-- Scan upward at every position on the X-Z plane for places we can stand
--	local nodes_to_scan = {}
--	local nodes_to_scan_cnt = 0
--	for x=0,chunk_mask do
--		for z=0,chunk_mask do
--			local clear_cnt = 0
--			local water_cnt = 0
--			local last_tpos
--			local last_hash
--			for y=chunk_size,-1,-1 do
--				local tpos = vector.new(chunk_pos.x+x, chunk_pos.y+y, chunk_pos.z+z)
--				local hash = minetest.hash_node_position(tpos)
--				local node = minetest.get_node(tpos)
--
--				if self.debug > 2 then
--					log.action(" %s %s %s x=%d y=%d z=%d clear_cnt=%d",
--						minetest.pos_to_string(tpos), node.name, tostring(pathfinder.is_node_water(node)),
--						x,y,z,clear_cnt)
--				end
--
--				if pathfinder.is_node_standable(node) and clear_cnt >= self.height then
--					nodes_to_scan[last_hash] = last_tpos
--					nodes_to_scan_cnt = nodes_to_scan_cnt + 1
--					if self.debug > 2 then
--						log.action("  -- added %x %s",
--							last_hash, minetest.pos_to_string(last_tpos))
--					end
--				end
--				if y < 0 then
--					break
--				end
--
--				if pathfinder.is_node_collidable(node) then
--					clear_cnt = 0
--					water_cnt = 0
--				else
--					clear_cnt = clear_cnt + 1
--					if y >= 0 and pathfinder.is_node_water(node) then
--						water_cnt = water_cnt + 1
--						if water_cnt >= self.height then
--							nodes_to_scan[hash] = tpos
--							nodes_to_scan_cnt = nodes_to_scan_cnt + 1
--							if self.debug > 2 then
--								log.action("  -- added %x %s",
--									hash, minetest.pos_to_string(tpos))
--							end
--						end
--					else
--						water_cnt = 0
--					end
--				end
--				last_tpos = tpos
--				last_hash = hash
--			end
--		end
--	end
--	if self.debug > 0 then
--		log.action(" Found %d probe slots", nodes_to_scan_cnt)
--	end
--
--	-- process all the stand positions
--	for hash, tpos in pairs(nodes_to_scan) do
--		-- don't process if it is part of another wayzone
--		if wzc:get_wayzone_for_pos(tpos) == nil then
--			if self.debug > 1 then
--				log.action(" Probe Slot %s", minetest.pos_to_string(tpos))
--			end
--			local visitHash, exitHash, wzFlags, edges = pathfinder.wayzone_flood(tpos, area)
--			local wz = wzc:new_wayzone()
--			for h, _ in pairs(visitHash) do
--				local pp = minetest.get_position_from_hash(h)
--				--log.action(" visited %12x %s", h, minetest.pos_to_string(pp))
--				wz:insert(pp)
--			end
--			for h, _ in pairs(exitHash) do
--				local pp = minetest.get_position_from_hash(h)
--				--log.action(" exited  %12x %s", h, minetest.pos_to_string(pp))
--				wz:insert_exit(pp)
--			end
--			wz:finish(wzFlags)
--
--			-- don't split special zones
--			-- wz.chash == 0x7fa8800081b0 and
--			if not (wzFlags.climb or wzFlags.water or wzFlags.door or wzFlags.fence) then
--				local new_zones = wayzone_utils.wz_split(wz)
--				if new_zones then
--					table.remove(wzc) -- remove wayzone that was split
--					-- build new wayzones
--					log.action("there are %s new zones", #new_zones)
--					for zi, zz in ipairs(new_zones) do
--						local nwz = wzc:new_wayzone()
--						for _, pp in pairs(zz) do
--							nwz:insert(pp)
--						end
--						--nwz:recalc_exit()
--						nwz:finish(wzFlags)
--					end
--				end
--			end
--
--			if self.debug > 0 then
--				log.action("++ wayzone %s cnt=%d center=%s box=%s-%s ", wz.key, wz.visited_count,
--					minetest.pos_to_string(wz.center_pos), minetest.pos_to_string(wz.minp), minetest.pos_to_string(wz.maxp))
--			end
--		end
--	end
--
--	local time_end = minetest.get_us_time()
--	local time_diff = time_end - time_start
--
--	log.action("^^ found %d zones for %s %x in %d ms, gen=%d",
--		#wzc, minetest.pos_to_string(chunk_pos), chunk_hash, time_diff / 1000, wzc.generation)
--
--	-- update internal links
--	wayzones_refresh_links(wzc, wzc)
--
--	-- add the chunk, replacing any old chunk
--	self.chunks[wzc.hash] = wzc
--
--	--wayzones.show_particles(wzc)
--
--	return wzc
--end


return mapblock_moves
