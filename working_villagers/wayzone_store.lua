--[[
Wayzone Store

A container for wayzone_chunks, which contains wayzones.

Instance fields
	chunks (table, key=wayzone_chunk.hash, val=wayzone_chunk)
		Lookup table for the chunks.

	height, jump_height, fear_height, can_climb
		Navigation parameters for building the wayzones.

Functions:
	wayzone_store.get(args) -> wayzone_store
		Get or create a wayzone store with the specified parameters.
		@args may contain (shown with defaults)
			height=2, jump_height=1, fall_height=2, can_climb=true

	wayzone_store:chunk_get_by_pos(pos, no_load) -> wayzone_chunk
	wayzone_store:chunk_get_by_hash(hash, no_load) -> wayzone_chunk
		Get the chunk for the position or hash. Processes the chunk as needed.
		If @no_load=true, this will return nil if the chunk is dirty or not
		loaded.

	wayzone_store:chunk_dirty(pos)
		Mark a chunk as dirty. Called from the on_dignode() and on_placenode()
		callbacks.

	wayzone_store:wayzone_get_by_key(key) -> wayzone
		Get a wayzone by key.

	wayzone_store:find_path(start_pos, target_pos) -> nil|array of wayzone
		Find a chain of wayzones from start_pos to target_pos.
		The first wayzone contains start_pos. The last contains target_pos.
		If the number of wayzones is less than 2, then we can directly do
		a pathfinder.find_path() from the start to the target.
		Returns nil on a failed path.
]]

local wayzone = working_villages.require("wayzone")
local wayzone_chunk = working_villages.require("wayzone_chunk")

local pathfinder = working_villages.require("pathfinder")
local sorted_hash = working_villages.require("sorted_hash")
local wayzone_utils = working_villages.require("wayzone_utils")
local fail = working_villages.require("failures")
local log = working_villages.require("log")
local func = working_villages.require("jobs/util")

local wayzone_store = {}

-- array of stores
wayzone_store.stores = {}

-------------------------------------------------------------------------------

--[[
Create a new wayzone_store with the given parameters. If one already exists,
then that is reused.

Future params:
 - can_swim:  false = never create water wayzones (maybe save some memory)
           true/nil = create water wayzones
            RESIVIT: can_swim seems pointless, as we can forbid entering water
                     at the nav mesh layer.
 - can_climb: false = do not allow climb moves
               true = include climb moves
             "maybe"= climb nodes are a separate wayzone -- may cause wayzone overlap
 - can_door:  false = doors are treated as non-collidable and can be walked through
           true/nil = doors get their own wayzone. the path_find() will determine
                      if the MOB has the ability to traverse the wayzone.
 - walk_leaves: true = allow walking on leaves, leaves in a separate wayzone
           false/nil = do not allow walking on leaves
]]
function wayzone_store.get(args)
	-- args: height, jump_height, fear_height, can_climb
	args = args or {}
	local self = {
		height = args.height or 2,
		jump_height = args.jump_height or 1,
		fear_height = args.fear_height or 2,
		can_climb = (args.can_climb == nil or args.can_climb == true),
		debug = 1
		}

	self.key = string.format("h=%d;j=%d;f=%d;c=%s",
		self.height, self.jump_height, self.fear_height, tostring(self.can_climb))

	local ss = wayzone_store.stores[self.key]
	if ss ~= nil then
		return ss
	end

	self.chunks = {}
	self = setmetatable(self, { __index = wayzone_store })
	wayzone_store.stores[self.key] = self
	log.warning("wayzone_store: created %s", self.key)
	return self
end

-------------------------------------------------------------------------------
--[[
Refresh the links from from_wzc to to_wzc
This is called right before the wayzones are used in wzpath_rebuild()
We are only interested in updating links going from @from_wzc to @to_wzc.

This updates from_wz.links_to and to_wz.links_from.
]]
local function wayzones_refresh_links(from_wzc, to_wzc)
	-- No point in looking at self-links if there are less than 2 wayzones OR
	-- either wayzone chunk is empty (under gound).
	if (from_wzc.hash == to_wzc.hash and #from_wzc < 2) or #from_wzc == 0 or #to_wzc == 0 then
		log.action("wayzones_refresh_links: no point %x (%d) g=%d -> %x (%d) g=%d",
			from_wzc.hash, #from_wzc, from_wzc.generation,
			to_wzc.hash, #to_wzc, to_wzc.generation)
		return
	end

	-- Did we already update the links for the current gen?
	-- nil won't match a number if this is the first time.
	if from_wzc:gen_is_current(to_wzc) then
		log.action("wayzones_refresh_links: already updated  %x (%d) g=%d -> %x (%d) g=%d",
			from_wzc.hash, #from_wzc, from_wzc.generation,
			to_wzc.hash, #to_wzc, to_wzc.generation)
		return
	end

	log.action("wayzones_refresh_links: updating %x (%d) g=%d -> %x (%d) g=%d",
		from_wzc.hash, #from_wzc, from_wzc.generation,
		to_wzc.hash, #to_wzc, to_wzc.generation)

	-- clear existing links: from_wzc -> to_wzc
	-- We don't care about incoming links, as we won't be using them.
	if to_wzc.hash ~= from_wzc.hash then
		for _, wz in ipairs(from_wzc) do
			wz:link_del(to_wzc.hash)
		end
	end

	-- build new links
	for to_idx, to_wz in ipairs(to_wzc) do
		for from_idx, from_wz in ipairs(from_wzc) do
			-- don't link a wayzone to itself (save some CPU cycles of wasted effort)
			if from_wz.key ~= to_wz.key then
				--log.action("wayzones_refresh_links: check %s -> %s",
				--	from_wz.key, to_wz.key)
				-- if from_wz exits into to_wz, then we have a winner
				if from_wz:exited_to(to_wz) then
					log.action(" + wayzone_link %s => %s g=%d",
						from_wz.key, to_wz.key, to_wzc.generation)
					-- FIXME: need to do a pathfinder.find_path() between the node
					-- centers to get the real cost. Important to avoid water.
					local cost = pathfinder.get_estimated_cost(from_wz:get_center_pos(), to_wz:get_center_pos())
					from_wz:link_add_to(to_wz, cost)
					to_wz:link_add_from(from_wz, cost)
				end
			end
		end
	end

	-- note that we updated the links to the adjacent chunk
	from_wzc:gen_update(to_wzc)
end

-------------------------------------------------------------------------------

--[[
Find all the wayzones for a chunk. gpos is th node in the -x,-y,-z corner.
Ie, (0,0,0), (16,0,0), (32,0,0), etc.
Need to revisit this so that we actually align with the chunks.
@self is a wayzone_store
--]]
local function process_chunk(self, chunk_hash)
	local chunk_pos = minetest.get_position_from_hash(chunk_hash)
	local chunk_size = wayzone.chunk_size
	local chunk_mask = chunk_size - 1
	local chunk_maxp = vector.new(chunk_pos.x + chunk_mask, chunk_pos.y + chunk_mask, chunk_pos.z + chunk_mask)

	if self.debug > 0 then
		log.action("-- process_chunk: %s-%s h=%x",
			minetest.pos_to_string(chunk_pos), minetest.pos_to_string(chunk_maxp), chunk_hash)
	end

	local time_start = minetest.get_us_time()

	-- create a new chunk, copying fields from the old one
	local wzc = wayzone_chunk.new(chunk_pos, self.chunks[chunk_hash])

	-- build the allowed area for the flood fill
	local area = {
		minp=vector.new(chunk_pos),
		maxp=chunk_maxp,
		inside=pathfinder.inside_minp_maxp }

	-- Scan upward at every position on the X-Z plane for places we can stand
	local nodes_to_scan = {}
	local nodes_to_scan_cnt = 0
	for x=0,chunk_mask do
		for z=0,chunk_mask do
			local clear_cnt = 0
			local water_cnt = 0
			local last_tpos
			local last_hash
			for y=chunk_size,-1,-1 do
				local tpos = vector.new(chunk_pos.x+x, chunk_pos.y+y, chunk_pos.z+z)
				local hash = minetest.hash_node_position(tpos)
				local node = minetest.get_node(tpos)

				if self.debug > 2 then
					log.action(" %s %s %s x=%d y=%d z=%d clear_cnt=%d",
						minetest.pos_to_string(tpos), node.name, tostring(pathfinder.is_node_water(node)),
						x,y,z,clear_cnt)
				end

				if pathfinder.is_node_standable(node) and clear_cnt >= self.height then
					nodes_to_scan[last_hash] = last_tpos
					nodes_to_scan_cnt = nodes_to_scan_cnt + 1
					if self.debug > 2 then
						log.action("  -- added %x %s",
							last_hash, minetest.pos_to_string(last_tpos))
					end
				end
				if y < 0 then
					break
				end

				if pathfinder.is_node_collidable(node) then
					clear_cnt = 0
					water_cnt = 0
				else
					clear_cnt = clear_cnt + 1
					if y >= 0 and pathfinder.is_node_water(node) then
						water_cnt = water_cnt + 1
						if water_cnt >= self.height then
							nodes_to_scan[hash] = tpos
							nodes_to_scan_cnt = nodes_to_scan_cnt + 1
							if self.debug > 2 then
								log.action("  -- added %x %s",
									hash, minetest.pos_to_string(tpos))
							end
						end
					else
						water_cnt = 0
					end
				end
				last_tpos = tpos
				last_hash = hash
			end
		end
	end
	if self.debug > 0 then
		log.action(" Found %d probe slots", nodes_to_scan_cnt)
	end

	-- process all the stand positions
	for hash, tpos in pairs(nodes_to_scan) do
		--log.action(" Probe Slot %s", minetest.pos_to_string(tpos))
		-- don't process if it is part of another wayzone
		if wzc:get_wayzone_for_pos(tpos) == nil then
			local visitHash, exitHash = pathfinder.wayzone_flood(tpos, area)
			local wz = wzc:new_wayzone()
			for h, _ in pairs(visitHash) do
				local pp = minetest.get_position_from_hash(h)
				--log.action(" visited %12x %s", h, minetest.pos_to_string(pp))
				wz:insert(pp)
			end
			for h, _ in pairs(exitHash) do
				local pp = minetest.get_position_from_hash(h)
				--log.action(" exited  %12x %s", h, minetest.pos_to_string(pp))
				wz:insert_exit(pp)
			end
			wz:finish()

			if self.debug > 0 then
				local aa = {}
				for idx, exitstr in pairs(wz.exited) do
					table.insert(aa, string.format("[%d]=%d", idx, #exitstr))
				end
				log.action("++ wayzone %s cnt=%d center=%s box=%s,%s exit=%s", wz.key, wz.visited_count,
					minetest.pos_to_string(wz.center_pos), minetest.pos_to_string(wz.minp), minetest.pos_to_string(wz.maxp),
					table.concat(aa, ","))
			end
		end
	end

	local time_end = minetest.get_us_time()
	local time_diff = time_end - time_start

	log.action("^^ found %d zones for %s %x in %d ms, gen=%d",
		#wzc, minetest.pos_to_string(chunk_pos), chunk_hash, time_diff / 1000, wzc.generation)

	-- update internal links
	wayzones_refresh_links(wzc, wzc)

	-- add the chunk, replacing any old chunk
	self.chunks[wzc.hash] = wzc

	--wayzones.show_particles(wzc)

	return wzc
end

function wayzone_store:chunk_get_by_hash(hash, no_load)
	local wzc = self.chunks[hash]
	if wzc ~= nil and not wzc:is_dirty() then
		-- no_load implies that we aren't really using it
		if not no_load then
			wzc:mark_used()
		end
		if minetest.get_node_or_nil(wzc.pos) == nil then
			log.warning("Chunk Loaded %x %s", wzc.hash, minetest.pos_to_string(wzc.pos))
			minetest.load_area(wzc.pos)
		end
		return wzc
	end
	if no_load == true then
		return nil
	end
	local pos = minetest.get_position_from_hash(hash)
	if minetest.get_node_or_nil(pos) == nil then
		log.warning("Chunk processed %x %s", hash, minetest.pos_to_string(pos))
		minetest.load_area(pos)
	end
	wzc = process_chunk(self, hash)

	--[[
	Yield if we can to be more friendly to the AI coroutine.
	If we are running from a callback, then we can't yield.
	If we are running in an AI coroutine, then we can. The timer is ~100 ms, so
	that means we can process at most ~10 chunks/sec.
	]]
	if coroutine.isyieldable() then
		coroutine.yield()
	end

	return wzc
end

function wayzone_store:chunk_get_by_pos(pos, no_load)
	local hash = minetest.hash_node_position(wayzone.normalize_pos(pos))
	return self:chunk_get_by_hash(hash, no_load)
end

-- convert a node position to the chunk position
function wayzone_store:chunk_get_pos(pos)
	return wayzone.normalize_pos(pos)
end

-------------------------------------------------------------------------------

-- Grab a wayzone by key. the key contains the chunk hash and the wayzone index.
function wayzone_store:wayzone_get_by_key(key)
	local chash, cidx = wayzone.key_decode(key)
	local wzc = self:chunk_get_by_hash(chash, true)
	if wzc ~= nil then
		return wzc[cidx]
	end
	return nil
end

--[[
Mark the chunk as dirty if loaded.
If the adjacent nodes are in a different chunk, then also mark that as dirty.
]]
function wayzone_store:chunk_dirty(pos)
	--log.warning("wayzone_store:chunk_dirty %s", minetest.pos_to_string(pos))
	-- get the chunk, but don't load it if missing or dirty
	local hash_done = {}
	local function dirty_neighbor(dx, dy, dz)
		local npos = vector.new(pos.x+dx, pos.y+dy, pos.z+dz)
		local cpos = self:chunk_get_pos(npos)
		local chash = minetest.hash_node_position(cpos)
		if hash_done[chash] == nil then
			hash_done[chash] = true
			local wzc = self:chunk_get_by_hash(chash, true)
			if wzc ~= nil then
				log.warning("wzc:mark_dirty %s : %s %x",
					minetest.pos_to_string(pos),
					minetest.pos_to_string(wzc.pos), wzc.hash)
				wzc:mark_dirty()
			end
		end
	end
	local max_y = math.max(self.jump_height, self.fear_height)
	for x=-1,1 do
		for z=-1,1 do
			for y=-max_y,max_y,max_y do
				dirty_neighbor(x,y,z)
			end
		end
	end
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

local function wz_estimated_cost(start_wz, end_wz)
	return pathfinder.get_estimated_cost(start_wz:get_center_pos(), end_wz:get_center_pos())
end

--[[
Get information about the wayzone that @pos is in.
returns {
	pos = pos
	hash = hash of pos
	wzc = wayzone_chunk that contains pos
	wz = the wayzone that contains pos (nil if no match)
	}
]]
function wayzone_store:get_pos_info(pos, where)
	assert(pos ~= nil)
	local info = {}
	info.pos = vector.round(pos) -- rounded to node coordinates
	info.hash = minetest.hash_node_position(info.pos)
	local cpos = wayzone.normalize_pos(info.pos)
	local chash = minetest.hash_node_position(cpos)
	info.wzc = self:chunk_get_by_hash(chash)
	info.wz = info.wzc:get_wayzone_for_pos(info.pos)

	--[[
	If info.wz is nil, then we either have a position that isn't
	"valid" (standable on the ground) OR the chunk data is obsolete.
	Check here to see which applies. If we could stand at pos then
	the data is obsolete and we should re-processing the chunk data.
	]]
	if info.wz == nil then
		if pathfinder.can_stand_at(info.pos, 2) then
			-- should be able to stand at pos, so wayzone data is old
			-- FIXME: warn for now. this should be rare, but noteworthy
			log.warning("waypoint[%s]: reprocessing %x %s", where or "??",
				info.wzc.hash, minetest.pos_to_string(info.wzc.pos))
			info.wzc:mark_dirty()
			info.wzc = self:chunk_get_by_hash(info.wzc.hash)
			info.wz = info.wzc:get_wayzone_for_pos(info.pos)
		else
			-- pos is not a valid standing position
			local node = minetest.get_node(info.pos)
			local pos_below = vector.new(info.pos.x,info.pos.y-1,info.pos.z)
			local node_below = minetest.get_node(pos_below)
			log.warning("waypoint[%s]: cannot stand %s [%s] below %s [%s]", where or "??",
				minetest.pos_to_string(info.pos), node.name,
				minetest.pos_to_string(pos_below), node_below.name)
		end
	end
	return info
end

-- Check if two chunk positions are adjacent.
-- The total diff will be 0 (same chunk) or wayzone.chunk_size
local function chunks_are_adjacent(cpos1, cpos2)
	local dx = math.abs(cpos1.x - cpos2.x)
	local dy = math.abs(cpos1.y - cpos2.y)
	local dz = math.abs(cpos1.z - cpos2.z)
	--log.action("  dx=%d dy=%d dz=%d", dx, dy, dz)
	return (dx + dy + dz) <= wayzone.chunk_size
end

--[[
Estimate the cost to go from one chunk to another.
Since we can only go from one to the next on the 6-adjacent sides, and we
can't do a detailed cost check, we just use the difference in chunk positions.
]]
local function wayzone_est_cost(s_cpos, d_cpos)
	local dx = math.abs(s_cpos.x - d_cpos.x)
	local dy = math.abs(s_cpos.y - d_cpos.y)
	local dz = math.abs(s_cpos.z - d_cpos.z)
	return dx + dy + dz
end

--[[
Find a series of wayzones that contain a path from start_pos to target_pos.
FIXME: The cost estimate calculation sucks. This will not get an optimal path.
       It gets fairly close, though.
FIXME: We need to set some bounds around the search or this could scan a lot
       of chunks! Maybe the whole map. This currently limited to 1000 steps,
       which means up to 2000 chunks can be checked.
]]
function wayzone_store:find_path(start_pos, target_pos)
	-- Grab the wayzone for start_pos and end_pos
	local si = self:get_pos_info(start_pos, "find_path.si")
	local di = self:get_pos_info(target_pos, "find_path.di")

	-- Bail if there isn't a wayzone for both the start and target
	if si.wz == nil or di.wz == nil then
		return nil
	end

	log.action("start: %s %s end: %s %s",
		minetest.pos_to_string(si.pos), si.wz.key,
		minetest.pos_to_string(di.pos), di.wz.key)

	-- If both are in the same wayzone, we return only that wayzone.
	if si.wz.key == di.wz.key then
		--log.action("same wayzone for %s and %s",
		--	minetest.pos_to_string(si.pos), minetest.pos_to_string(di.pos))
		return { si.wz }
	end

	-- If si.wz is directly connected to di.wz, we return just those two.
	if chunks_are_adjacent(si.wzc.pos, di.wzc.pos) then
		-- make sure link info is up-to-date (will not reprocess chunks)
		wayzones_refresh_links(si.wzc, di.wzc)
		if si.wz:link_test_to(di.wz) then
			-- log.warning(" ++ direct link detected")
			return { si.wz, di.wz }
		end
	end

	-- need to try the neighbors until we hit it, the key is the wayzone "hash:idx"
	local fwd = { posSet = wlist_new(), fwd=true }
	local rev = { posSet = wlist_new(), fwd=false }
	local hCost = wz_estimated_cost(si.wz, di.wz)

	-- adds an active walker with logging -- remove logging when tested
	local function add_open(fwd_rev, item)
		--log_table(item)
		--log.warning("add_open: %s pos=%s key=%s hCost=%d gCost=%d",
		--	tostring(fwd_rev.fwd),
		--	minetest.pos_to_string(item.cur.pos),
		--	item.cur.key, item.hCost, item.gCost)

		-- Add the starting wayzone (insert populates sl_key)
		fwd_rev.posSet:insert(item)
	end

	-- Add the starting wayzone to each walker
	add_open(fwd, {
		--parent_key=nil, -- first entry doesn't have a parent
		cur={ pos=si.wzc.pos, hash=si.wzc.hash, index=si.wz.index, key=si.wz.key },
		hCost=hCost, gCost=0 })
	add_open(rev, {
		--parent_key=nil, -- last entry doesn't have a backwards parent
		cur={ pos=di.wzc.pos, hash=di.wzc.hash, index=di.wz.index, key=di.wz.key },
		hCost=hCost, gCost=0 })

	local function log_fwd_rev(name, tab)
		for k, v in pairs(tab.posSet.data) do
			if v.sl_active == true then
				log.action(" %s Open %s gCost=%d hCost=%d p=%s", name, k, v.gCost, v.hCost, tostring(v.parent_key))
			end
		end
		for k, v in pairs(tab.posSet.data) do
			if v.sl_active ~= true then
				log.action(" %s Clos %s gCost=%d hCost=%d p=%s", name, k, v.gCost, v.hCost, tostring(v.parent_key))
			end
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
		--log.action("** dual_rollup ref=%s start=%s target=%s", ref_key, si.wz.key, di.wz.key)
		--log_all()
		--log.action("  dual_rollup - start")
		-- roll up the path and store in wzp.wzpath
		local rev_wzpath = {}
		local cur = fwd.posSet:get(ref_key)
		-- check parent_key because we don't want to add the start wayzone, as that is added below
		-- FIXME: the rev_wzpath/wzpath len checks are to protect against coding error - remove after testing
		while cur ~= nil and cur.parent_key ~= nil and #rev_wzpath < 200 do
			--log.action("  fwd %s p=%s", cur.sl_key, cur.parent_key)
			table.insert(rev_wzpath, self:wayzone_get_by_key(cur.sl_key))
			cur = fwd.posSet:get(cur.parent_key)
		end
		local wzpath = { si.wz }
		for idx=#rev_wzpath,1,-1 do
			table.insert(wzpath, rev_wzpath[idx])
		end
		-- trace forward through rev.closeSet, adding to wzpath
		local cur = rev.posSet:get(ref_key)
		while cur ~= nil and cur.parent_key ~= nil do -- and cur.parent_key ~= di.wz.key and #wzpath < 200 do
			--log.action("  rev %s p=%s", cur.sl_key, cur.parent_key)
			table.insert(wzpath, self:wayzone_get_by_key(cur.parent_key)) -- adding parent, not cur.key
			cur = rev.posSet:get(cur.parent_key)
		end

		--for idx, wz in ipairs(wzpath) do
		--	--wayzone_utils.log_table("wayzone", wz)
		--	log.action("  [%d] %s -- %s %d", idx, wz.key,
		--		minetest.pos_to_string(wz.cpos), wz.index)
		--end
		return wzpath
	end

	-- NOTE: "steps" is to prevent infinite loop/hang due to coding error.
	--       It limits the number of chunks examined. Better would be to set
	--       search limits.
	local steps = 0
	while fwd.posSet.count > 0 and rev.posSet.count > 0 and steps < 1000 do
		steps = steps + 1

		local ff = fwd.posSet:pop_head()
		local rr = rev.posSet:pop_head()

		log.action("wayzone.find_path step fwd=%s rev=%s", ff.cur.key, rr.cur.key)

		-- does the fwd node join a rev closed record?
		if ff.cur.key == di.wz.key or rev.posSet:get(ff.cur.key) ~= nil then
			log.action("FWD done or found in REV -- need rollup")
			return dual_rollup(ff.sl_key)
		end

		-- does the rev node join a fwd closed record?
		if rr.cur.key == si.wz.key or fwd.posSet:get(rr.cur.key) ~= nil then
			log.action("REV done or found in FWD -- need rollup")
			return dual_rollup(rr.sl_key)
		end

		local function do_neighbors(fr, xx, is_fwd)
			local xx_wzc = self:chunk_get_by_hash(xx.cur.hash)
			local xx_wz = xx_wzc[xx.cur.index]

			--log.action("Processing %s fwd=%s fCost=%d", xx_wz.key, tostring(is_fwd), xx.fCost)

			-- iterate over the adjacent chunks, refresh links with this chunk
			local adj_hash = {}
			-- visit the first 6 adjacent items (skip self, as that never needs refresh)
			for aidx=1,6 do
				-- We only care if we have exit nodes on that side
				if xx_wz.exited[aidx] ~= nil then
					local n_cpos = vector.add(xx.cur.pos, wayzone.chunk_adjacent[aidx])
					local n_chash = minetest.hash_node_position(n_cpos)
					log.action("check adjacent %x %s", n_chash, minetest.pos_to_string(n_cpos))
					local n_wzd = self:chunk_get_by_hash(n_chash)
					if n_wzd ~= nil then
						wayzones_refresh_links(xx_wzc, n_wzd)
						wayzones_refresh_links(n_wzd, xx_wzc)
						adj_hash[n_chash] = n_wzd
					end
				end
			end

			local link_tab
			if is_fwd then
				link_tab = xx_wz.link_to
			else
				link_tab = xx_wz.link_from
			end

			-- Add an entry for each link from this wayzone
			for _, link in pairs(link_tab) do
				local link_wzc = adj_hash[link.chash]
				log.action("   + neighbor link %s => %s", xx_wz.key, link.key)
				if link_wzc == nil then
					-- TODO: this is a link to a non-adjacent chunk. We need to check the gen of each
					--       chunk in the chain and make sure they are current.
				else
					--log.action("   + hit")
					-- don't store a worse walker if we already visited this wayzone
					local old_item = fr.posSet:get(link.key)
					if old_item == nil then -- or (old_item.gCost + old_item.hCost) > (n_hCost + n_gCost) then
						--log.action("   + adding link %s", link.key)
						add_open(fr, {
							parent_key=xx.cur.key,
							cur={ pos=link_wzc.pos, hash=link.chash, index=link.index, key=link.key },
							hCost=wz_estimated_cost(di.wz, link_wzc[link.index]),
							gCost=xx.gCost + (link.gCost or wayzone.chunk_size)
						})
					end
				end
			end
		end

		do_neighbors(fwd, ff, true)
		do_neighbors(rev, rr, false)
	end
	log.warning("wayzone path fail: %s -> %s, steps=%d",
		minetest.pos_to_string(si.pos),
		minetest.pos_to_string(di.pos), steps)
	log_all()
	return nil
end

-------------------------------------------------------------------------------

--[[
Find a standable positions (using the wayzone stuff) around @target_pos.
@target_pos is the position to search.
@radius is a number or a vector indicating the distance to search on each axis
@start_pos the villager position. if not nil, this will gather all positions
   with the the same radius and pick the closest one.
@return the best positions
]]
function wayzone_store:find_standable_near(target_pos, radius, start_pos)
	if radius == nil then
		radius = 3
	end
	if type(radius) == "number" then
		radius = vector.new(radius, radius, radius)
	end
	if radius.y == nil then
		radius.y = 2
	end

	-- checks to see if a position
	local function test_standable(pos, state, rank)
		--log.action("test_standable: %s r=%s/%s", minetest.pos_to_string(pos), tostring(rank), tostring(state.rank))
		if state.rank ~= nil and rank > state.rank then
			return true
		end

		local function check_pos(xxpos)
			local wzc = self:chunk_get_by_pos(xxpos)
			return (wzc ~= nil) and (wzc:get_wayzone_for_pos(xxpos) ~= nil)
		end

		for dy=0,radius.y do
			local hpos
			local tpos = vector.new(pos.x, pos.y + dy, pos.z)
			if check_pos(tpos) then
				hpos = tpos
			end
			if hpos == nil and dy > 0 then
				tpos = vector.new(pos.x, pos.y - dy, pos.z)
				if check_pos(tpos) then
					hpos = tpos
				end
			end
			if hpos ~= nil then
				if state.pos == nil then
					state.pos = {}
					state.rank = rank
				end
				table.insert(state.pos, hpos)
				-- only doing one if start_pos==nil
				if start_pos == nil then
					return true
				end
				break -- don't search further up/down
			end
		end
		return false
	end

	-- collect valid positions in state.pos
	local state = {}
	func.iterate_surrounding_xz(target_pos, radius, test_standable, state)
	if state.rank == nil then
		return nil
	end
	local s = {}
	for _, pos in ipairs(state.pos) do
		table.insert(s, minetest.pos_to_string(pos))
	end
	--log.warning("wayzone_store:find_standable_near(%s) => r=%d %s",
	--	minetest.pos_to_string(target_pos), state.rank,
	--	table.concat(s, ","))
	if #state.pos == 1 then
		return state.pos[1]
	end
	local best_d2
	local best_pos
	for _, pos in ipairs(state.pos) do
		local dx = math.abs(pos.x - start_pos.x)
		local dz = math.abs(pos.z - start_pos.z)
		local d2 = dx * dx + dz * dz
		if best_d2 == nil or d2 < best_d2 then
			best_d2 = d2
			best_pos = pos
		end
	end
	return best_pos
end

-------------------------------------------------------------------------------

-- Mark the chunk as dirty in all stores.
local function dirty_chunk_data(pos)
	log.warning("dirty_chunk_data %s", minetest.pos_to_string(pos))
	for _, ss in ipairs(wayzone_store.stores) do
		ss:chunk_dirty(pos)
	end
end

--[[
I need to know when a chunk changes to re-process the cached chunk wayzones.
The only way to do that appears to be to hook into the on_placenode and
on_dignode callbacks. I'm assuming this is for all loaded chunk.
I don't yet know if this handles growing trees.
]]
local function wayzone_store_on_placenode(pos, newnode, placer, oldnode, itemstack, pointed_thing)
	local old_nodedef = minetest.registered_nodes[oldnode.name]
	local new_nodedef = minetest.registered_nodes[newnode.name]
	local imp = (old_nodedef.walkable or new_nodedef.walkable or
	             old_nodedef.climbable or new_nodedef.climbable)
	log.action("wayzones: node %s placed at %s over %s important=%s",
		newnode.name, minetest.pos_to_string(pos), oldnode.name, tostring(imp))
	if imp then
		dirty_chunk_data(pos)
	end
end

local function wayzone_store_on_dignode(pos, oldnode, digger)
	local old_nodedef = minetest.registered_nodes[oldnode.name]
	local imp = old_nodedef.walkable or old_nodedef.climbable
	log.action("wayzones: node %s removed from %s important=%s",
		oldnode.name, minetest.pos_to_string(pos), tostring(imp))
	if imp then
		dirty_chunk_data(pos)
	end
end

minetest.register_on_placenode(wayzone_store_on_placenode)
minetest.register_on_dignode(wayzone_store_on_dignode)

return wayzone_store
