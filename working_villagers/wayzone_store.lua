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
local fail = working_villages.require("failures")

local wayzone_store = {}

-- array of stores
wayzone_store.stores = {}

-------------------------------------------------------------------------------

-- Create a new wayzone_store with the given parameters. If one already exists,
-- then that is reused.
function wayzone_store.get(args)
	-- args: height, jump_height, fear_height, can_climb
	args = args or {}
	local self = {
		height = args.height or 2,
		jump_height = args.jump_height or 1,
		fear_height = args.fear_height or 2,
		can_climb = (args.can_climb == nil or args.can_climb == true),
		debug = 0
		}

	for _, ss in ipairs(wayzone_store.stores) do
		if (ss.height == self.height and
			ss.jump_height == self.jump_height and
			ss.fear_height == self.fear_height and
			ss.can_climb == self.can_climb)
		then
			minetest.log("warning", "wayzone_store: reusing entry")
			return ss
		end
	end

	self.chunks = {}
	self = setmetatable(self, { __index = wayzone_store })
	table.insert(wayzone_store.stores, self)
	minetest.log("warning", string.format("wayzone_store: new entry, now have %d", #wayzone_store.stores))
	return self
end

-------------------------------------------------------------------------------
--[[
Refresh the links from from_wzd to to_wzd
This is called right before the wayzones are used in wzpath_rebuild()
We are only interested in updating links going from @from_wzd to @to_wzd.

This updates from_wz.links_to and to_wz.links_from.
]]
local function wayzones_refresh_links(from_wzc, to_wzc)
	-- No point in looking at self-links if there are less than 2 wayzones OR
	-- either wayzone chunk is empty (under gound).
	if (from_wzc.hash == to_wzc.hash and #from_wzc < 2) or #from_wzc == 0 or #to_wzc == 0 then
		return
	end

	-- Did we already update the links for the current gen?
	-- nil won't match a number if this is the first time.
	if from_wzc:gen_is_current(to_wzc) then
		--minetest.log("action",
		--	string.format("wayzones_refresh_links: already updated %x (%d) -> %x (%d)",
		--		from_wzd.hash, #from_wzd, to_wzd.hash, #to_wzd))
		return
	end

	--minetest.log("action",
	--	string.format("wayzones_refresh_links: %x (%d) -> %x (%d)",
	--		from_wzd.hash, #from_wzd, to_wzd.hash, #to_wzd))

	-- clear existing links: from_wzd -> to_wzd
	-- We don't care about incoming links, as we won't be using them.
	for _, wz in ipairs(from_wzc) do
		wz:link_del(to_wzc.hash)
	end

	-- build new links
	for to_idx, to_wz in ipairs(to_wzc) do
		for from_idx, from_wz in ipairs(from_wzc) do
			-- don't link a wayzone to itself (save some CPU cycles of wasted effort)
			if from_wz.key ~= to_wz.key then
				--minetest.log("action",
				--	string.format("wayzones_refresh_links: check %s -> %s",
				--		from_wz.key, to_wz.key))
				-- if from_wz exits into to_wz, then we have a winner
				if from_wz:exited_to(to_wz) then
					minetest.log("action", string.format(" + wayzone_link %s => %s g=%d",
						from_wz.key, to_wz.key, to_wzc.generation))
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

	if self.debug > 1 then
		minetest.log("action", string.format("-- process_chunk: %s-%s h=%x",
				minetest.pos_to_string(chunk_pos), minetest.pos_to_string(chunk_maxp), chunk_hash))
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
					minetest.log("action", string.format(" %s %s %s x=%d y=%d z=%d clear_cnt=%d",
							minetest.pos_to_string(tpos), node.name, tostring(pathfinder.is_node_water(node)),
							x,y,z,clear_cnt))
				end

				if pathfinder.is_node_standable(node) and clear_cnt >= self.height then
					nodes_to_scan[last_hash] = last_tpos
					nodes_to_scan_cnt = nodes_to_scan_cnt + 1
					if self.debug > 2 then
						minetest.log("action", string.format("  -- added %x %s",
								last_hash, minetest.pos_to_string(last_tpos)))
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
								minetest.log("action", string.format("  -- added %x %s",
										hash, minetest.pos_to_string(tpos)))
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
		minetest.log("action", string.format(" Found %d probe slots", nodes_to_scan_cnt))
	end

	-- process all the stand positions
	for hash, tpos in pairs(nodes_to_scan) do
		--minetest.log("action", string.format(" Probe Slot %s", minetest.pos_to_string(tpos)))
		-- don't process if it is part of another wayzone
		if wzc:get_wayzone_for_pos(tpos) == nil then
			local visitHash, exitHash = pathfinder.wayzone_flood(tpos, area)
			local wz = wzc:new_wayzone()
			for h, _ in pairs(visitHash) do
				local pp = minetest.get_position_from_hash(h)
				--minetest.log("action", string.format(" visited %x %s", h, minetest.pos_to_string(pp)))
				wz:insert(pp)
			end
			for h, _ in pairs(exitHash) do
				local pp = minetest.get_position_from_hash(h)
				--minetest.log("action", string.format(" exited %x %s", h, minetest.pos_to_string(pp)))
				wz:insert_exit(pp)
			end
			wz:finish()

			if self.debug > 0 then
				minetest.log("action",
					string.format("++ wayzone %s cnt=%d center=%s box=%s,%s", wz.key, wz.visited_count,
						minetest.pos_to_string(wz.center_pos), minetest.pos_to_string(wz.minp), minetest.pos_to_string(wz.maxp)))
			end
		end
	end

	local time_end = minetest.get_us_time()
	local time_diff = time_end - time_start

	minetest.log("action", string.format("^^ found %d zones for %s %x in %d ms, gen=%d",
		#wzc, minetest.pos_to_string(chunk_pos), chunk_hash, time_diff / 1000, wzc.generation))

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
		return wzc
	end
	if no_load == true then
		return nil
	end
	return process_chunk(self, hash)
end

function wayzone_store:chunk_get_by_pos(pos, no_load)
	local hash = minetest.hash_node_position(wayzone.normalize_pos(pos))
	return self:chunk_get_by_hash(hash, no_load)
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

-- mark the chunk as dirty if loaded
function wayzone_store:chunk_dirty(pos)
	-- get the chunk, but don't load it if missing or dirty
	local wzc = self:chunk_get_by_pos(pos, true)
	if wzc ~= nil then
		wzc:mark_dirty()
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
function wayzone_store:get_pos_info(pos)
	assert(pos ~= nil)
	local info = {}
	info.pos = vector.floor(pos) -- rounded to node coordinates
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
		if pathfinder.can_stand_at(pos, 2) then
			-- should be able to stand at pos, so wayzone data is old
			-- FIXME: warn for now. this should be rare, but noteworthy
			minetest.log("warning",
				string.format("waypoint: reprocessing %x %s",
					info.wzc.hash, minetest.pos_to_string(info.wzc.pos)))
			info.wzc:mark_dirty()
			info.wzc = self:chunk_get_by_hash(info.wzc.hash)
			info.wz = info.wzc:get_wayzone_for_pos(info.pos)
		else
			-- pos is not a valid standing position
			minetest.log("warning", string.format("waypoint: cannot stand %s", minetest.pos_to_string(pos)))
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
	--minetest.log("action", string.format("  dx=%d dy=%d dz=%d", dx, dy, dz))
	return (dx + dy + dz) <= wayzone.chunk_size
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

--[[
Find a series of wayzones that contain a path from start_pos to target_pos.
FIXME: the cost estimate calculation sucks. This will not get an optimal path.
]]
function wayzone_store:find_path(start_pos, target_pos)
	-- Grab the wayzone for start_pos and end_pos
	local si = self:get_pos_info(start_pos)
	local di = self:get_pos_info(target_pos)

	-- Bail if there isn't a wayzone for both the start and target
	if si.wz == nil or di.wz == nil then
		return nil
	end

	-- We really like the inside() function
	if target_pos.inside == nil then
		target_pos = pathfinder.make_dest(target_pos)
	end

	-- If both are in the same wayzone, we return that wayzone.
	if si.wz.key == di.wz.key then
		minetest.log("action", string.format("same wayzone for %s and %s",
				minetest.pos_to_string(start_pos), minetest.pos_to_string(target_pos)))
		return { si.wz }
	end

	minetest.log("action", string.format("start: %s %s end: %s %s",
			minetest.pos_to_string(start_pos), si.wz.key,
			minetest.pos_to_string(target_pos), di.wz.key))

	-- If si.wz is directly connected to di.wz, we return just those two.
	if chunks_are_adjacent(si.wzc.pos, di.wzc.pos) then
		-- make sure link info is up-to-date
		wayzones_refresh_links(si.wzc, di.wzc)
		if si.wz:link_test_to(di.wz) then
			minetest.log("warning", string.format(" ++ direct link detected"))
			return { si.wz, di.wz }
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
		cur={ pos=si.wzc.pos, hash=si.wzc.hash, index=si.wz.index, key=si.wz.key },
		hCost=hCost, gCost=0 })
	add_open(rev, {
		--parent_key=nil, -- last entry doesn't have a backwards parent
		cur={ pos=di.wzc.pos, hash=di.wzc.hash, index=di.wz.index, key=di.wz.key },
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
		-- NOTE: the rev_wzpath len check is to protect against coding error - remove after testing
		while cur ~= nil and cur.parent_key ~= nil and #rev_wzpath < 200 do
			minetest.log("action", string.format("  fwd %s p=%s", cur.sl_key, cur.parent_key))
			table.insert(rev_wzpath, self:wayzone_get_by_key(cur.sl_key))
			cur = fwd.closedSet:get(cur.parent_key)
		end
		local wzpath = { si.wz }
		for idx=#rev_wzpath,1,-1 do
			table.insert(wzpath, rev_wzpath[idx])
		end
		-- trace forward through rev.closeSet, adding to wzpath
		local cur = rev.closedSet:get(ref_key)
		while cur ~= nil and cur.parent_key ~= nil and cur.parent_key ~= di.wz.key and #wzpath < 200 do
			minetest.log("action", string.format("  rev %s p=%s", cur.sl_key, cur.parent_key))
			table.insert(wzpath, cur.parent_key) -- adding parent, not cur.key
			cur = fwd.closedSet:get(self:wayzone_get_by_key(cur.parent_key))
		end

		minetest.log("action", string.format("  rolling up path start=%s target=%s", si.wz.key, di.wz.key))
		for idx, wz in ipairs(wzpath) do
			minetest.log("action", string.format("  [%d] %s -- %s %d", idx, wz.key,
					minetest.pos_to_string(wz.cpos), wz.index))
		end
		return wzpath
	end

	-- NOTE: steps is to prevent infinite loop/hang due to coding error
	local steps = 0
	while fwd.openSet.count > 0 and rev.openSet.count > 0 and steps < 1000 do
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
			local xx_wzd = self:chunk_get_by_hash(xx.cur.hash)
			local xx_wz = xx_wzd[xx.cur.index]

			-- iterate over the adjacent chunks
			for aidx, avec in ipairs(wayzone.chunk_adjacent) do
				local n_cpos = vector.add(xx.cur.pos, avec)
				local n_chash = minetest.hash_node_position(n_cpos)
				--minetest.log("action", string.format("  aa p=%s h=%x %s", minetest.pos_to_string(n_cpos), n_chash, tostring(is_fwd)))
				local n_wzd = self:chunk_get_by_hash(n_chash)
				-- shouldn't this go
				local n_hCost = wayzone_est_cost(n_cpos, target_pos) -- di.wzc.pos)

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
								gCost=xx.gCost + (nn.gCost or wayzone.chunk_size)
							})
						end
					end
				end
			end
		end

		do_neighbors(fwd, ff, true)
		do_neighbors(rev, rr, false)
	end
	minetest.log("warning", string.format("wayzone path fail: %s -> %s, steps=%d",
			minetest.pos_to_string(start_pos),
			minetest.pos_to_string(self.target_pos), steps))
	log_all()
	return nil
end

-------------------------------------------------------------------------------

-- Mark the chunk as dirty in all stores.
local function dirty_chunk_data(pos)
	for _, ss in ipairs(wayzone_store) do
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
	minetest.log("action",
		string.format("wayzones: node %s placed at %s over %s important=%s",
			newnode.name, minetest.pos_to_string(pos), oldnode.name, tostring(imp)))
	if imp then
		dirty_chunk_data(pos)
	end
end

local function wayzone_store_on_dignode(pos, oldnode, digger)
	local old_nodedef = minetest.registered_nodes[oldnode.name]
	local imp = old_nodedef.walkable or old_nodedef.climbable
	minetest.log("action",
		string.format("wayzones: node %s removed from %s important=%s",
			oldnode.name, minetest.pos_to_string(pos), tostring(imp)))
	if imp then
		dirty_chunk_data(pos)
	end
end

minetest.register_on_placenode(wayzone_store_on_placenode)
minetest.register_on_dignode(wayzone_store_on_dignode)

return wayzone_store
