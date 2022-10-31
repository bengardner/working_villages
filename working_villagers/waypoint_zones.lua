--[[
Wayzone Overview

A waypoint zone or wayzone is an area where every node in the zone is reachable
from every other node in the zone. Only symmetric transitions are allowed.
That means jump_height==fear_height.

A chunk is scanned to find all the zones by starting a new flood fill at every
standable position that isn't part of another zone.
Most commonly, there will be 0 or 1 zones. 0=all air or all solid. 1=flat surface.
At worst case, there could be ~1280 (5*256) zones.

Each zone also has a set of 'exit nodes', which may go outside of the chunk by
one move and allow fear_height=2.

Zones are linked by checking the 'exit nodes' against the another zone's members.
If there is an overlap, then there is a zone->zone link.
The exit nodes are

The initial flood fill is bound by the chunk area (16x16x16). The position is at
ground level. This search bleeds into the top-chunk by 1 to establish if there
is room to stand on the next to top node.

The nodes on the

Flood fill pseudo code/logic:
	height = 2
	jump_height = 2
	fear_height = 2
	openSet = wlist.new()  -- active walkers
	closedSet = {} -- visited nodes with +/-1 y limit, key=hash
	exitSet = {} -- visited nodes with a -2y limit OR step outside of the zone
	openSet.insert(position to be scanned)
	while openSet not empty do
		item = openSet:pop()
		if not inside_chunk(item) or abs(item.delta.y) > 1 then
			-- We are done with this walker
			exitSet:insert(item)
		else
			exitSet:remove(item)  -- another path to get there
			closeSet:insert(item) -- note that we visited this node
			neighbors = find_neighbors(item)
			for _, neighbor in pairs(neighbors) do
				if neighbor.cost ~= nil then
					-- need to expand this location if we haven't been there or haven't already queued it
					if closeSet[neighbor.hash] == nil and openSet[neighbor.hash] == nil then
						openSet:insert(neighbor)
					end
				end
			end
		end
	end
	return closedSet, exitSet
]]
local S = default.get_translator

local pathfinder = working_villages.require("pathfinder")
local sorted_hash = working_villages.require("sorted_hash")
local fail = working_villages.require("failures")
local wayzone = working_villages.require("wayzone")

local wayzones = {}

--[[
-- the store keeps the wayzone_data for each chunk.
wayzones.store[chunk_hash] = wayzone_data
wayzone_data = {            -- abbreviated "wzd"
	hash = chunk_hash       -- the chunk_hash (same as key)
	gen_clock = os.clock(), -- updated whenever the scan is done, may be used to time out the data
	use_clock = os.clock(), -- last time this was used, for discarding unused data
	generation = number,    -- bumped up every time we recalculate to re-do links
	                        -- if the chunk layer provided a generation, that would be used.
	adjacent = table with key=chunk_hash, val=generation for neighboring chunks
	[1] = wayzone,     -- array of the "wayzone" class
	..
	[n] = wayzone
}
The generation matches the generation in wayzone_data. The index is the index
to the linked wayzone in wayzone_data.
The neighbors is where I can go from here. Only the 6 adjacent chunks
can be are here, but each may have multiple indexes.

If the generation doesn't match, then the links have to be re-computed.
Links are checked by testing my exited hashes against the other wayzones's
visited hashes.
]]
wayzones.store = {}

-- Some unique colors for the zones
local wz_colors = {
	{ 255,   0,   0 },
	{   0, 255,   0 },
	{   0,   0, 255 },
	{ 255, 255,   0 },
	{ 255,   0, 255 },
	{   0, 255, 255 },
	{   0,   0,   0 },
	{ 255, 255, 255 },
	{ 128, 128, 128 },
	{ 255, 128,   0 },
	{ 128, 255,   0 },
	{ 255,   0, 128 },
	{ 128,   0, 255 },
	{   0, 255, 128 },
	{   0, 128, 255 },
}

-- show particles for one wayzone
function wayzones.show_particles_wz(wz)
	local vn = "wayzone_node.png"
	local xn = "wayzone_exit.png"
	local xc = "wayzone_center.png"
	local cc = wz_colors[(wz.index % #wz_colors)+1]
	local vt = string.format("%s^[multiply:#%02x%02x%02x", vn, cc[1], cc[2], cc[3])
	local xt = string.format("%s^[multiply:#%02x%02x%02x", xn, cc[1]/2, cc[2]/2, cc[3]/2)
	local xcc = string.format("%s^[multiply:#%02x%02x%02x", xc, cc[1], cc[2], cc[3])
	local cpos = wz:get_center_pos()
	local dy = -0.25 + (wz.index / 8)
	-- minetest.log("action", " center "..minetest.pos_to_string(cpos))
	minetest.add_particle({
		pos = {x=cpos.x, y=cpos.y+dy, z=cpos.z},
		expirationtime = 10,
		playername = "singleplayer",
		glow = minetest.LIGHT_MAX,
		texture = xcc,
		size = 4,
	})

	for pp in wz:iter_visited() do
		minetest.add_particle({
			pos = {x=pp.x, y=pp.y+dy, z=pp.z},
			expirationtime = 10,
			playername = "singleplayer",
			glow = minetest.LIGHT_MAX,
			texture = vt,
			size = 4,
		})
	end

	for pp in wz:iter_exited() do
		minetest.add_particle({
			pos = {x=pp.x, y=pp.y+dy, z=pp.z},
			expirationtime = 10,
			playername = "singleplayer",
			glow = minetest.LIGHT_MAX,
			texture = xt,
			size = 4,
		})
	end
end

-- show all the particles, @wz_data is (wayzone_data), an array of hash sets
function wayzones.show_particles(wz_dat)
	for _, wz in ipairs(wz_dat) do
		wayzones.show_particles_wz(wz)
	end
end

-- show particles for a wayzone path, just the center nodes
function wayzones.show_particles_wzpath(wzpath)
	local xc = "wayzone_center.png"

	for _, wz_key in ipairs(wzpath) do
		local chash, idx = wayzone.key_decode(wz_key)
		local wzd = wayzones.get_chunk_data(chash)
		local wz = wzd[idx]
		local pos = wz:get_center_pos()

		local cc = wz_colors[(wz.index % #wz_colors)+1]
		local xcc = string.format("%s^[multiply:#%02x%02x%02x", xc, cc[1], cc[2], cc[3])

		minetest.log("action", " center "..minetest.pos_to_string(pos))
		minetest.add_particle({
			pos = pos,
			expirationtime = 15,
			playername = "singleplayer",
			glow = minetest.LIGHT_MAX,
			texture = xcc,
			size = 5,
		})
	end
end

local function log_table(tab)
	minetest.log("action", string.format("log_table %s", tostring(tab)))
	for k, v in pairs(tab) do
		if type(v) == 'table' then
			for k2, v2 in pairs(v) do
				minetest.log("action", string.format("  | %s.%s = %s", k, k2, v2))
			end
		else
			minetest.log("action", string.format("  | %s = %s", k, v))
		end
	end
end

local function wz_estimated_cost(start_wz, end_wz)
	return pathfinder.get_estimated_cost(start_wz:get_center_pos(), end_wz:get_center_pos())
end

-- find the hash/pos in the waypoint zone list
-- return nil (not found) or the wayzone key
local function wpz_find_visited_hash(wzd, hash)
	local pos = minetest.get_position_from_hash(hash)
	for idx, wz in ipairs(wzd) do
		if wz:inside(pos) then
			return idx, wz
		end
	end
	return nil
end

--[[
Check to see if the wayzone @from_wz links into @to_wz
Wrapper for from_wz:exited_to(to_wz)
]]
local function wpz_check_link(from_wz, to_wz)
	minetest.log("action", string.format("wpz_check_link: %s:%d %s -> %s:%d %s",
		minetest.pos_to_string(from_wz.cpos), from_wz.index, from_wz.key,
		minetest.pos_to_string(to_wz.cpos), to_wz.index, to_wz.key))

	return from_wz:exited_to(to_wz)
end

-- discard all links going to "to_wzd"
local function wayzones_link_clear(from_wzd, to_wzd)
	for _, wz in ipairs(from_wzd) do
		wz:link_del(to_wzd.hash)
	end
end

-- refresh the links from from_wzd to to_wzd
local function wayzones_refresh_links(from_wzd, to_wzd)
	-- No point in looking at self-links if there are less than 2 wayzones or
	-- if either chunk has 0 wayzones
	if (from_wzd.hash == to_wzd.hash and #from_wzd < 2) or #from_wzd == 0 or #to_wzd == 0 then
		return
	end

	-- did we already update the links?
	if from_wzd.adjacent[to_wzd.hash] == to_wzd.generation then
		--  minetest.log("action",
		--  			 string.format("wayzones_refresh_links: already updated %x (%d) -> %x (%d)",
		--  						   from_wzd.hash, #from_wzd, to_wzd.hash, #to_wzd))
		return
	end

	--  minetest.log("action",
	--  		  string.format("wayzones_refresh_links: %x (%d) -> %x (%d)",
	--  						from_wzd.hash, #from_wzd, to_wzd.hash, #to_wzd))

	-- clear existing links: from_wzd -> to_wzd
	wayzones_link_clear(from_wzd, to_wzd)

	-- build new links
	for to_idx, to_wz in ipairs(to_wzd) do
		for from_idx, from_wz in ipairs(from_wzd) do
			-- don't link a wayzone to itself
			if from_wz.key ~= to_wz.key then
				--  minetest.log("action",
				--  	string.format("wayzones_refresh_links: check %s -> %s",
				--  				  from_wz.key, to_wz.key))
				-- if from_wz exits into to_wz, then we have a winner
				if from_wz:exited_to(to_wz) then
					minetest.log("action", string.format(" + wayzone_link %s => %s g=%d",
						from_wz.key, to_wz.key, to_wzd.generation))
					from_wz:link_add_to(to_wz)
					to_wz:link_add_from(from_wz)
				end
			end
		end
	end

	-- note that we updated the links to the adjacent chunk
	from_wzd.adjacent[to_wzd.hash] = to_wzd.generation
end

-- private function to get or regen the chunk data
local function get_chunk_data(hash, noload)
	local wzd = wayzones.store[hash]
	if wzd ~= nil and wzd.dirty ~= true then
		return wzd
	end
	if noload == true then
		return nil
	end
	return wayzones.process_chunk(minetest.get_position_from_hash(hash))
end
wayzones.get_chunk_data = get_chunk_data

-- Set the dirty flag on a in-memory chunk so that it will be reloaded on the
-- next get_chunk_data() call.
local function dirty_chunk_data(pos)
	local cpos = wayzone.normalize_pos(pos)
	local chash = minetest.hash_node_position(cpos)
	local wzd = wayzones.store[chash]
	if wzd ~= nil and wzd.dirty ~= true then
		wzd.dirty = true
		minetest.log("action", string.format("wayzone: %s %x is now dirty", minetest.pos_to_string(cpos), chash))
	end
end

-- refresh the links between two adjacent chunks
function wayzones.refresh_links(chunk1_hash, chunk2_hash)
	local wzd1 = get_chunk_data(chunk1_hash)
	local wzd2 = get_chunk_data(chunk2_hash)
	wayzones_refresh_links(wzd1, wzd2)
	wayzones_refresh_links(wzd2, wzd1)
end

--[[
Find all the wayzones for a chunk. gpos is th node in the -x,-y,-z corner.
Ie, (0,0,0), (16,0,0), (32,0,0), etc.
Need to revisit this so that we actually align with the chunks.
--]]
function wayzones.process_chunk(pos)
	local chunk_pos = wayzone.normalize_pos(pos)
	local chunk_maxp = { x=chunk_pos.x + 15, y=chunk_pos.y + 15, z=chunk_pos.z + 15 }
	local chunk_hash = minetest.hash_node_position(chunk_pos)
	minetest.log("action", string.format("-- process_chunk: %s-%s h=%x",
			minetest.pos_to_string(chunk_pos), minetest.pos_to_string(chunk_maxp), chunk_hash))

	local time_start = minetest.get_us_time()

	local chunk_wzd = {} -- waypoint zones data

	local area = {
		minp={ x=chunk_pos.x, y=chunk_pos.y, z=chunk_pos.z },
		maxp=chunk_maxp,
		inside=pathfinder.inside_minp_maxp }
	local args = { height = 2, fear_height = 2, jump_height = 1 }

	-- Scan upward at every position on the X-Z plane for places we can stand
	for x=0,15 do
		for z=0,15 do
			local slots = {}
			local clear_cnt = 0
			local air_pos = nil
			local stand_pos = nil
			for y=-1,16 do
				local tpos = { x=chunk_pos.x+x, y=chunk_pos.y+y, z=chunk_pos.z+z }
				local node = minetest.get_node(tpos)

				if clear_cnt >= args.height and air_pos ~= nil and stand_pos ~= nil then
					local pp = { x=stand_pos.x, y=stand_pos.y+1, z=stand_pos.z }
					table.insert(slots, pp)
					air_pos = nil
					stand_pos = nil
				end
				if pathfinder.is_node_collidable(node) then
					clear_cnt = 0
					stand_pos = nil
				else
					air_pos = tpos
					clear_cnt = clear_cnt + 1
				end
				if pathfinder.is_node_standable(node) then
					stand_pos = tpos
				end
			end

			-- process all the stand positions
			for idx, tpos in ipairs(slots) do
				--minetest.log("action", string.format(" Probe Slot %s", minetest.pos_to_string(tpos)))
				-- don't process if it is part of another wayzone
				if wpz_find_visited_hash(chunk_wzd, minetest.hash_node_position(tpos)) == nil then
					--minetest.log("action", string.format("   wayzone_flood %s", minetest.pos_to_string(tpos)))
					-- REVISIT: We probably want to exclude certain nodes, like "leaves" from being standable
					--          Those come and go regularly...
					local visitHash, exitHash = pathfinder.wayzone_flood(tpos, area)
					local h, _ = next(visitHash)
					if h ~= nil then
						local wz = wayzone.new(chunk_pos, 1+#chunk_wzd)
						for h, _ in pairs(visitHash) do
							local ppp = minetest.get_position_from_hash(h)
							--minetest.log("action", string.format("   p=%s %x", minetest.pos_to_string(ppp), h))
							wz:insert(ppp)
						end
						for h, _ in pairs(exitHash) do
							wz:insert_exit(minetest.get_position_from_hash(h))
						end
						wz:finish()
						table.insert(chunk_wzd, wz)
					end
				end
			end
		end
	end

	local time_end = minetest.get_us_time()
	local time_diff = time_end - time_start

	-- update the new wayzone data with old values (generation and use_clock)
	local wpz_tab_old = wayzones.store[chunk_hash]
	-- keep use_clock, update generation
	if wpz_tab_old ~= nil then
		chunk_wzd.generation = wpz_tab_old.generation + 1
		chunk_wzd.use_clock = wpz_tab_old.use_clock
	else
		chunk_wzd.generation = 1
		-- wpz_tab.use_clock = nil
	end
	chunk_wzd.gen_clock = os.clock()
	chunk_wzd.hash = chunk_hash
	chunk_wzd.adjacent = {} -- start with no adjacent info
	wayzones.store[chunk_hash] = chunk_wzd

	minetest.log("action", string.format("^^ found %d zones for %s %x in %d ms, gen=%d",
		#chunk_wzd, minetest.pos_to_string(chunk_pos), chunk_hash, time_diff / 1000, chunk_wzd.generation))

	-- update internal links
	wayzones_refresh_links(chunk_wzd, chunk_wzd)

	--wayzones.show_particles(chunk_wzd)

	return chunk_wzd
end

-------------------------------------------------------------------------------

-- Use the wayzone key
local function wlist_key_encode(item)
	return item.cur.key
end

-- compare the total + estimated costs
local function wlist_item_compare(item1, item2)
	return (item1.gCost + item1.hCost) < (item2.gCost + item2.hCost)
end

-- create a new wlist
local function wlist_new()
	return sorted_hash.new(wlist_key_encode, wlist_item_compare)
end

-------------------------------------------------------------------------------
--[[
This code uses the wayzones to create a position-by-position path.

wayzones.path_start(start_pos, end_pos) returns a wayzone_path.

This will find the chunk/wayzone for the start_pos and the end_pos.
It will scan the chunks until a wayzone path is found.
It will then use pathfinder.find_path() to go from start_pos to the 1st wayzone.
Each call to next_goal will pop and remove the first position in the path.
When the path is empty, it will pop off the first wayzone and call find_path()
to go to the new 1st wayzone. When there are no more wayzones, find_path() is
used with the original end_pos.
The current position must be passed to each call to next_goal() so that a proper
path can be constructed. Each wayzone is an area, so the exact position isn't
known.

Usage example:
	local wzp = wayzones.path_start(self.object:get_pos(), target)
	while true do
		local next_goal = wzp:next_goal(self.object:get_pos())
		if next_goal == nil then
			break
		end

		while not close_enough(next_goal, self.object:get_pos()) do
			-- set direction and velocity
			-- yield to wait for the MOB to move
		end
	end

If you just wanted to print each stop along the full path:
	local wzp = wayzones.path_start(start_pos, end_pos)
	local cur_pos = start_pos
	while cur_pos ~= nil do
		print_position(cur_pos)
		cur_pos = wzp:next_goal(cur_pos)
	end
--]]
local wayzone_path = {}

--[[
Get information about the wayzone that @pos is in.
returns {
	pos = pos
	hash = hash of pos
	cpos = chunk position
	chash = hash of cpos
	wzd = wayzone data for the chunk
	wz_idx = the index of the wayzone info, nil if no match
	wz = the wayzone info (wzd[wz_id]), nil if no match
	key = copy of wz.key (REVISIT: do we need this?)
	}
]]
local function get_pos_info(pos)
	assert(pos ~= nil)
	local info = {}
	info.pos = vector.floor(pos) -- rounded to node coordinates
	info.hash = minetest.hash_node_position(info.pos)
	info.cpos = wayzone.normalize_pos(info.pos)
	info.chash = minetest.hash_node_position(info.cpos)
	info.wzd = get_chunk_data(info.chash)
	info.wz_idx, info.wz = wpz_find_visited_hash(info.wzd, info.hash)
	--[[
	If info.wz is nil, then we either have a position that isn't
	"valid" (standable on the ground) OR the chunk data is obsolete.
	We could check here to see which applies. If we could stand at pos then
	the data is obsolete and we should re-processing the chunk data.
	]]
	if info.wz == nil then
		if pathfinder.can_stand_at(pos, 2) then
			-- should be able to stand at pos, so wayzone data is old
			-- FIXME: warn for now. this should be rare, but noteworthy
			minetest.log("warning",
				string.format("waypoint: reprocessing %x %s",
					info.wzd.hash,
					minetest.pos_to_string(minetest.get_position_from_hash(info.wzd.hash))))
			info.wzd.dirty = true
			info.wzd = get_chunk_data(info.chash)
			info.wz_idx, info.wz = wpz_find_visited_hash(info.wzd, info.hash)
		else
			-- pos is not a valid standing position
			minetest.log("warning", string.format("waypoint: cannot stand %s", minetest.pos_to_string(pos)))
		end
	end

	if info.wz ~= nil then
		info.key = info.wz.key
	end
	return info
end

wayzones.get_pos_info = get_pos_info

-------------------------------------------------------------------------------

-- Get the next position goal and remove it from the path.
function wayzone_path:next_goal(cur_pos)
	-- is navigation 100% complete?
	if self.end_pos:inside(cur_pos) then
		minetest.log("action", "next_goal: inside end_pos "..minetest.pos_to_string(cur_pos))
		return nil
	end

	-- return the next pos on the path, if there are any left
	if self.path ~= nil then
		self.path_idx = (self.path_idx or 0) + 1
		if self.path_idx < #self.path then
			local pp = self.path[self.path_idx]
			minetest.log("action",
				string.format("next_goal: idx %d %s", self.path_idx, minetest.pos_to_string(pp)))
			return pp
		end
		self.path = nil
		self.path_idx = 0
	end

	-- rebuild the path after finishing the last leg (is this needed? only if self.wzpath is empty?)
	minetest.log("action", string.format("calling wzpath_rebuild(%s)", minetest.pos_to_string(cur_pos)))
	if not self:wzpath_rebuild(cur_pos) then
		minetest.log("action", string.format("rebuild at %s fail", minetest.pos_to_string(cur_pos)))
	 	return nil
	end

	-- if the path is empty, that means we are in the same zone as the dest
	-- Create one final path.
	if #self.wzpath == 0 then
		minetest.log("action", string.format("wzpath is empty, final leg"))
		self.path = pathfinder.find_path(cur_pos, self.end_pos, nil, {want_nil=true})
		if self.path == nil then
			minetest.log("action", string.format("find_path %s -> %s failed", minetest.pos_to_string(cur_pos), minetest.pos_to_string(self.end_pos)))
			return nil
		end
		minetest.log("action", string.format("find_path %s -> %s len %d",
			minetest.pos_to_string(cur_pos),
			minetest.pos_to_string(self.end_pos), #self.path))
		self.path_idx = 1
		return self.path[1]
	end

	wayzones.show_particles_wzpath(self.wzpath)
	for idx, wz_key in ipairs(self.wzpath) do
		minetest.log("action", string.format(" wzpath[%d] = %s", idx, wz_key))
	end

	-- We need to create a path to the next wayzone
	local si = get_pos_info(cur_pos)
	local wz_hash, wz_idx = wayzone.key_decode(self.wzpath[1])
	local wz_wzd = get_chunk_data(wz_hash)
	local wz_wz = wz_wzd[wz_idx]
	local wz_dest = wz_wz:get_dest(si.cpos)

	minetest.log("action", string.format("find_path to next wayzone %s -> %s",
		minetest.pos_to_string(cur_pos), minetest.pos_to_string(wz_dest)))

	-- Create a path to the next wayzone
	self.path = pathfinder.find_path(cur_pos, wz_dest, nil, {want_nil=true})
	if self.path == nil then
		minetest.log("action", string.format("find_path %s -> %s failed",
			minetest.pos_to_string(cur_pos), minetest.pos_to_string(wz_dest)))
		return nil
	end
	minetest.log("action", string.format("find_path %s -> %s len %d",
		minetest.pos_to_string(cur_pos),
		minetest.pos_to_string(wz_dest), #self.path))
	self.path_idx = 1
	return self.path[1]
end

--[[
Estimate the cost to go from one chunk to another.
Since we can only go from one to the next on the 6-adjacent sides, and we
can't do a detailed cost check, and the chunks are 16x16x16, we use a cost
of 16 per chunk.
]]
local function wayzone_est_cost(s_cpos, d_cpos)
	local dx = math.abs(s_cpos.x - d_cpos.x)
	local dy = math.abs(s_cpos.y - d_cpos.y)
	local dz = math.abs(s_cpos.z - d_cpos.z)
	return dx + dy + dz
end

-- check if two chunk positions are adjacent. the total diff will be 16 or 0
local function chunks_are_adjacent(cpos1, cpos2)
	local dx = math.abs(cpos1.x - cpos2.x)
	local dy = math.abs(cpos1.y - cpos2.y)
	local dz = math.abs(cpos1.z - cpos2.z)
	--minetest.log("action", string.format("  dx=%d dy=%d dz=%d", dx, dy, dz))
	return (dx + dy + dz) <= 16
end

--[[
Rebuild the wayzone path.
returns whether the path is possible. (true=yes, false=no)
This goes forwards and backwards at the same time, alternating which queue is
processed. If either path ends or hits a common node, then we are done.
]]
function wayzone_path:wzpath_rebuild(start_pos)
	-- grab the wayzone for start_pos and end_pos
	local si = get_pos_info(start_pos)
	local di = get_pos_info(self.end_pos)

	-- bail if there isn't a wayzone for each
	if si.wz == nil or di.wz == nil or si.cpos == nil then
		-- Either the position is floating above ground or the chunk data is
		-- no longer accurate.
		-- TODO: set a flag to re-scan the chunk
		if si.wz == nil then
			minetest.log("warning",
				string.format("no wayzone for s=%s c=%s",
					minetest.pos_to_string(start_pos),
					minetest.pos_to_string(si.cpos)))
		end
		if di.wz == nil then
			minetest.log("warning", string.format("no wayzone for %s", minetest.pos_to_string(self.end_pos)))
		end
		self.wzpath = nil
		return false
	end

	-- Check for an empty path, which triggers a path_find(cur, end_pos) on next next_goal()
	-- This happens if the start and end are in the same wayzone.
	if si.wz.key == di.wz.key then
		minetest.log("action", string.format("same wayzone for %s and %s",
				minetest.pos_to_string(start_pos), minetest.pos_to_string(self.end_pos)))
		self.wzpath = {}
		return true
	end

	minetest.log("action", string.format("start: %s %s end: %s %s",
			minetest.pos_to_string(start_pos), si.wz.key,
			minetest.pos_to_string(self.end_pos), di.wz.key))

	-- See if si.wz is directly connected to di.wz
	if chunks_are_adjacent(si.cpos, di.cpos) then
		wayzones_refresh_links(si.wzd, di.wzd)
		if si.wz:link_test_to(di.wz) then
			-- minetest.log("warning", string.format(" ++ direct link detected"))
			self.wzpath = { di.wz.key }
			return true
		end
	end

	-- need to try the neighbors until we hit it, the key is the wayzone "hash:idx"
	local fwd = { openSet = wlist_new(), closedSet = wlist_new(), fwd=true }
	local rev = { openSet = wlist_new(), closedSet = wlist_new(), fwd=false }
	local hCost = wz_estimated_cost(si.wz, di.wz)

	local function add_open(fwd_rev, item)
		--log_table(item)
		--minetest.log("warning",
		--	string.format("add_open: %s pos=%s key=%s hCost=%d gCost=%d",
		--		tostring(fwd_rev.fwd),
		--		minetest.pos_to_string(item.cur.pos),
		--		item.cur.key, item.hCost, item.gCost))

		-- Add the starting wayzone (insert populates sl_key)
		fwd_rev.openSet:insert(item)
	end

	-- Add the starting wayzone to each walker
	add_open(fwd, {
		--parent_key=nil, -- first entry doesn't have a parent
		cur={ pos=si.cpos, hash=si.chash, index=si.wz.index, key=si.wz.key },
		hCost=hCost, gCost=0 })
	add_open(rev, {
		--parent_key=nil, -- last entry doesn't have a backwards parent
		cur={ pos=di.cpos, hash=di.chash, index=di.wz.index, key=di.wz.key },
		hCost=hCost, gCost=0 })

	local function log_fwd_rev(name, tab)
		for k, v in pairs(tab.openSet.data) do
			minetest.log("warning", string.format(" %s Open %s gCost=%d hCost=%d p=%s", name, k, v.gCost, v.hCost, tostring(v.parent_key)))
		end
		for k, v in pairs(tab.closedSet.data) do
			minetest.log("warning", string.format(" %s Clos %s gCost=%d hCost=%d p=%s", name, k, v.gCost, v.hCost, tostring(v.parent_key)))
		end
	end
	local function log_all()
		log_fwd_rev("FWD", fwd)
		log_fwd_rev("REV", rev)
	end

	-- rollup in both directions
	-- rollup fwd (trace back to start)
	-- reverse sequence
	-- append ref to end
	local function dual_rollup(ref_key)
		--minetest.log("action", string.format("  dual_rollup - start"))
		-- roll up the path and store in wzp.wzpath
		local rev_wzpath = {}
		local cur = fwd.closedSet:get(ref_key)
		-- check parent_key because we don't want to add the start wayzone
		while cur ~= nil and cur.parent_key ~= nil and #rev_wzpath < 100 do
			--minetest.log("action", string.format("  fwd %s p=%s", cur.sl_key, cur.parent_key))
			table.insert(rev_wzpath, cur.sl_key)
			cur = fwd.closedSet:get(cur.parent_key)
		end
		local wzpath = {}
		for idx=#rev_wzpath,1,-1 do
			table.insert(wzpath, rev_wzpath[idx])
		end
		-- trace forward through rev.closeSet, adding to wzpath
		local cur = rev.closedSet:get(ref_key)
		while cur ~= nil and cur.parent_key ~= nil and cur.parent_key ~= di.wz.key and #wzpath < 100 do
			--minetest.log("action", string.format("  rev %s p=%s", cur.sl_key, cur.parent_key))
			table.insert(wzpath, cur.parent_key) -- adding parent, not cur.key
			cur = fwd.closedSet:get(cur.parent_key)
		end
		self.wzpath = wzpath
		--minetest.log("action", string.format("  rolling up path - done"))
		--for idx, key in ipairs(self.wzpath) do
		--	minetest.log("action", string.format("  [%d] %s", idx, key))
		--end
		return true
	end

	local steps = 0
	while fwd.openSet.count > 0 and rev.openSet.count > 0 and steps < 100 do
		steps = steps + 1

		local ff = fwd.openSet:pop_head()
		local rr = rev.openSet:pop_head()
		--minetest.log("warning", string.format("looking at FWD %s %s gCost=%d hCost=%d p=%s (o=%d c=%d steps=%d)",
		--	ff.cur.key, minetest.pos_to_string(ff.cur.pos), ff.gCost, ff.hCost, tostring(ff.parent_key), fwd.openSet.count, fwd.closedSet.count, steps))
		--minetest.log("warning", string.format("looking at REV %s %s gCost=%d hCost=%d p=%s (o=%d c=%d steps=%d)",
		--	rr.cur.key, minetest.pos_to_string(rr.cur.pos), rr.gCost, rr.hCost, tostring(rr.parent_key), rev.openSet.count, rev.closedSet.count, steps))

		-- add to fwd.closedSet() if a better path to the same wayzone is not present
		local cc = fwd.closedSet:get(ff.sl_key)
		if cc == nil or cc.gCost > ff.gCost then
			fwd.closedSet:insert(ff)
		end

		-- add to rev.closedSet() if a better path to the same wayzone is not present
		cc = rev.closedSet:get(rr.sl_key)
		if cc == nil or cc.gCost > rr.gCost then
			rev.closedSet:insert(rr)
		end

		--log_all()

		-- does the fwd node join a rev closed record?
		if ff.cur.key == di.wz.key or rev.closedSet[ff.cur.key] ~= nil then
			-- trace back to the dest, adding to the fwd.closedSet() then roll up
			--minetest.log("warning", string.format("FWD found in REV -- need rollup"))
			return dual_rollup(ff.sl_key)
		end

		-- does the rev node join a fwd closed record?
		if rr.cur.key == si.wz.key or fwd.closedSet[rr.cur.key] ~= nil then
			return dual_rollup(rr.sl_key)
		end

		local function do_neighbors(fr, xx, is_fwd)
			local xx_wzd = get_chunk_data(xx.cur.hash)
			local xx_wz = xx_wzd[xx.cur.index]

			-- iterate over the adjacent chunks
			for aidx, avec in ipairs(wayzone.chunk_adjacent) do
				local n_cpos = vector.add(xx.cur.pos, avec)
				local n_chash = minetest.hash_node_position(n_cpos)
				--minetest.log("action", string.format("  aa p=%s h=%x %s", minetest.pos_to_string(n_cpos), n_chash, tostring(is_fwd)))
				local n_wzd = get_chunk_data(n_chash)
				local n_hCost = wayzone_est_cost(n_cpos, di.cpos)
				local n_gCost = xx.gCost + ((aidx == 7) and 0 or 16)

				-- refresh links from xx_wzd to n_wzd
				wayzones_refresh_links(xx_wzd, n_wzd)
				wayzones_refresh_links(n_wzd, xx_wzd)
				local link_tab
				if is_fwd then
					link_tab = xx_wz.link_to
				else
					link_tab = xx_wz.link_from
				end

				-- Add an entry for each link that points into the chunk.
				for _, nn in pairs(link_tab) do
					--minetest.log("action", string.format("   + links hash=%x idx=%d key=%s", nn.chash, nn.index, nn.key))
					if nn.chash == n_chash then
						--minetest.log("action", string.format("   + hit"))
						-- don't store a worse walker if we already visited this wayzone
						local oo = fr.openSet:get(nn.key)
						local cc = fr.closedSet:get(nn.key)
						if oo == nil and cc == nil then -- or (oo.gCost + oo.hCost) > (n_hCost + n_gCost) then
							--minetest.log("action", string.format("  + not in openSetlinks hash=%x idx=%d key=%s", nn.chash, nn.index, nn.key))
							add_open(fr, {
								parent_key=xx.cur.key,
								cur={ pos=n_cpos, hash=n_chash, index=nn.index, key=nn.key },
								hCost=wz_estimated_cost(di.wz, n_wzd[nn.index]),
								gCost=xx.gCost + wz_estimated_cost(xx_wz, n_wzd[nn.index])
							})
						end
					end
				end
			end
		end

		do_neighbors(fwd, ff, true)
		do_neighbors(rev, rr, false)
	end
	minetest.log("warning", string.format("never reached goal for %s", minetest.pos_to_string(self.end_pos)))
	log_all()
	return false
end

--[[
Start a wayzone path.
1. Find the chunk for both ends.
2. Grab the wayzone data

We need to find the wayzone for both the start and end.
The start wayzone isn't needed past this function, as we don't store the starting
location. The wzpath array contains the next steps up to and including the
wayzone that contains end_pos.
--]]
function wayzones.path_start(start_pos, end_pos)
	assert(start_pos ~= nil)
	assert(end_pos ~= nil)

	if end_pos.inside == nil then
		end_pos = pathfinder.make_dest(end_pos)
	end

	-- NOTE end_pos must have a center point. It may have inside/outside functions.
	-- the original end_pos structure will be kept around for the final leg.
	local wzp = {
		di = get_pos_info(end_pos),
		end_pos = end_pos, -- keep the original end_pos, as it might be an area
		}
	setmetatable(wzp, { __index = wayzone_path })

	-- -- build the wayzone path for a quick check if the path is possible
	-- if not wzp:wzpath_rebuild(start_pos) then
	-- 	-- failed to find a wayzone for the start or dest
	-- 	return nil, fail.no_path
	-- end

	return wzp
end

--[[
I need to know when a chunk changes to re-process the cached chunk wayzones.
The only way to do that appears to be to hook into the on_placenode and
on_dignode callbacks. I'm assuming this is for all loaded chunk.
I don't yet know if this handles growing trees.
]]
local function wayzones_on_placenode(pos, newnode, placer, oldnode, itemstack, pointed_thing)
	local old_nodedef = minetest.registered_nodes[oldnode.name]
	local new_nodedef = minetest.registered_nodes[newnode.name]
	local imp = (old_nodedef.walkable or new_nodedef.walkable or
	             old_nodedef.climbable or new_nodedef.climbable)
	minetest.log("action",
		string.format("wayzones: node %s placed at %s over %s important=%s",
			newnode.name, minetest.pos_to_string(pos), oldnode.name, tostring(imp)))
	if imp then
		dirty_chunk_data(pos)
	end
end

local function wayzones_on_dignode(pos, oldnode, digger)
	local old_nodedef = minetest.registered_nodes[oldnode.name]
	local imp = old_nodedef.walkable or old_nodedef.climbable
	minetest.log("action",
		string.format("wayzones: node %s removed from %s important=%s",
			oldnode.name, minetest.pos_to_string(pos), tostring(imp)))
	if imp then
		dirty_chunk_data(pos)
	end
end

minetest.register_on_placenode(wayzones_on_placenode)
minetest.register_on_dignode(wayzones_on_dignode)

return wayzones
