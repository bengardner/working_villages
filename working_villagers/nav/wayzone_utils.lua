--[[
Misc utility functions that do not belong anywhere else.
]]
local wayzone = working_villages.require("nav/wayzone")
local log = working_villages.require("log")
local line_store = working_villages.require("nav/line_store")
local lines = line_store.new("visible", {spacing=0.2})
local marker_store = working_villages.require("nav/marker_store")
local corner_markers = marker_store.new("corners", {texture="wayzone_node.png"})

local wayzone_utils = {}

-- Some unique colors for the particles
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

--[[ Put a particle at @pos using args.
Args should contain "texture" OR "name" and "color"
args={texture=text, name=filename, color={r,g,b}, size=4, time=10}
]]
local function put_particle(pos, args)
	local vt = args.texture
	if vt == nil then
		local cc = args.color or {255,255,255}
		local fn = args.name or "wayzone_node.png"
		vt = string.format("%s^[multiply:#%02x%02x%02x", fn, cc[1], cc[2], cc[3])
	end
	minetest.add_particle({
		pos = pos,
		expirationtime = args.time or 10,
		playername = "singleplayer",
		glow = minetest.LIGHT_MAX,
		texture = vt,
		size = args.size or 4,
	})
end
wayzone_utils.put_particle = put_particle

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
wayzone_utils.dir_vectors = dir_vectors

-- adds to the dir index while wrapping around 1 and 8
local function dir_add(dir, delta)
	return 1 + ((dir - 1 + delta) % 8) -- modulo gives 0-7, need 1-8
end
wayzone_utils.dir_add =  dir_add

--[[ Find the Y for a neighbor position that is in the wayzone.
We can only go up or down 1, based on a max jump height of 1.
]]
local function wz_neighbor_pos(wz, node_pos)
	-- See if pos is in the wayzone
	if wz:inside(node_pos) then
		return node_pos
	end
	-- try y-1, y+1
	for dy=-1,1,1 do
		local tp = vector.offset(node_pos, 0, dy, 0)
		if wz:inside(tp) then
			return tp
		end
	end
	return nil
end
wayzone_utils.wz_neighbor_pos = wz_neighbor_pos

--[[ Populate a table with the 8 neighbors to a position that must already
be in the wayzone. This may have gaps, so iterate using pairs().
]]
local function wz_neighbors(wz, node_pos)
	local nn = {}
	for nidx, vec in ipairs(dir_vectors) do
		nn[nidx] = wz_neighbor_pos(wz, vector.add(node_pos, vec))
	end
	return nn
end
wayzone_utils.wz_neighbors = wz_neighbors

--[[ Populate a table with the 8 neighbors to a position that must already
be in the wayzone. This may have gaps, so iterate using pairs().
]]
local function wz_neighbors_nsew(wz, pos)
	local res = {}
	for ii = 1,7,2 do -- do N/S/E/W 1,3,5,7
		local pp = wz_neighbor_pos(wz, vector.add(pos, dir_vectors[ii]))
		if pp then
			table.insert(res, pp)
		end
	end
	-- add up and down
	for dy = -1,1,2 do
		local pp = vector.offset(pos, 0, dy, 0)
		if wz:inside(pp) then
			table.insert(res, pp)
		end
	end
	return res
end
wayzone_utils.wz_neighbors_nsew = wz_neighbors_nsew

--[[
See if we can do a "line" between the two without hitting a node that isn't in
the wayzone.
If we move diagonal, we need to check to see if one corner is open.
If @loose=true, then either node must be clear to do a diagonal.
If @loose=false, then the appropriate node must be clear



Returns nil if the line is blocked or the list of positions.
]]
local function wz_visible_line(wz, spos, dpos, loose, is_ok_to_use)
	local delta = vector.subtract(dpos, spos)
	local steps = math.max(math.abs(delta.x), math.abs(delta.z)) * 2
	local vstep = vector.divide(delta, steps)
	vstep.y = 0

	local vsx = math.abs(vstep.x)
	local vsz = math.abs(vstep.z)

	local pos_list = {}

	if not is_ok_to_use then
		is_ok_to_use = function(pos) return true end
	end

	--log.action("wz_visible_line: %s %s", minetest.pos_to_string(spos), minetest.pos_to_string(dpos))
	local fpos = spos
	local prev = spos
	for _=1,steps do
		local tpos = vector.add(fpos, vstep)
		local rpos = vector.round(tpos)
		local wpos = wz_neighbor_pos(wz, rpos) -- adjust Y to find ground
		if rpos ~= prev then
			if wpos == nil or not is_ok_to_use(wpos) then
				--log.action("wz_visible_line -- bailing on %s", minetest.pos_to_string(rpos))
				return nil
			end
			--log.action("  st: %s", minetest.pos_to_string(wpos))
			table.insert(pos_list, wpos)
			if prev.x ~= rpos.x and prev.z ~= rpos.z then
				local tp1 = vector.new(prev.x, rpos.y, rpos.z)
				local tp2 = vector.new(rpos.x, rpos.y, prev.z)
				if (loose or vsz <= vsx) and wz_neighbor_pos(wz, tp1) and is_ok_to_use(tp1) then
					table.insert(pos_list, tp1)
					--log.action("  st: %s tp1", minetest.pos_to_string(tp1))
				elseif (loose or vsz >= vsx) and wz_neighbor_pos(wz, tp2) and is_ok_to_use(tp2) then
					table.insert(pos_list, tp2)
					--log.action("  st: %s tp2", minetest.pos_to_string(tp2))
				else
					return nil
				end
			end
			prev = rpos
		end
		fpos = vector.new(tpos.x, rpos.y, tpos.z)
	end
	return pos_list
end
wayzone_utils.wz_visible_line = wz_visible_line

-- check if a position hash is in the list of zones
local function hash_in_zone(zones, hash_or_pos)
	if type(hash_or_pos) == "table" then
		hash_or_pos = minetest.hash_node_position(hash_or_pos)
	end
	for zi, zz in ipairs(zones) do
		if zz.nodes then
			if zz.nodes[hash_or_pos] ~= nil then
				--log.action("in_zone %d: %s %x", zi, minetest.get_position_from_hash(hash_or_pos), hash_or_pos)
				return true
			end
		else
			if zz[hash_or_pos] ~= nil then
				--log.action("in_zone %d: %s %x", zi, minetest.get_position_from_hash(hash_or_pos), hash_or_pos)
				return true
			end
		end
	end
	return false
end

--[[
Do a flood fill search on the the wayzone starting at @pos.

@meta_map has key=pos_hash and val="corner", "line", or "done".

if @lines_only is true, then @pos is a "line" node and we should only trace "line"
nodes. If a node that isn't "line" or "corner" is hit, then this fails.

If @lines_only is false, then we can enter any node that isn't "done".

If the flood fill is successful, the all visited nodes are marked "done".
]]
local function flood_fill_pos(wz, all_zones, meta_map, pos, ftype, all_corners)
	log.action("flood_fill_pos %s %s", minetest.pos_to_string(pos), ftype)

	local active = {}   -- nodes to explore
	local visited = {}  -- nodes we looked at
	local visited_cnt = 0
	local corners = {}  -- corners we hit while searching

	table.insert(active, pos)
	while #active > 0 do
		local cur = active[#active] -- pop last to reduce churn
		table.remove(active)

		local c_hh = minetest.hash_node_position(cur)
		if visited[c_hh] == nil then
			visited[c_hh] = cur
			visited_cnt = visited_cnt + 1
		end
		if meta_map[c_hh] == "corner" then
			corners[c_hh] = pos
		end
		--log.action("flood_fill_pos process: %s", minetest.pos_to_string(cur))

		for _, n_pp in ipairs(wz_neighbors_nsew(wz, cur)) do
			local n_hh = minetest.hash_node_position(n_pp)

			if visited[n_hh] or active[n_hh] then
				-- don't revisit a node
			else
				-- record corners that we hit
				if meta_map[n_hh] == "corner" then
					corners[n_hh] = n_pp
				end
				--log.action(" ** %s %s", minetest.pos_to_string(n_pp), meta_map[n_hh])

				if hash_in_zone(all_zones, n_hh) then
					-- but only process if not in another zone
				elseif ftype == "line" then
					if meta_map[n_hh] == "line" then
						table.insert(active, n_pp)
					elseif meta_map[n_hh] == "corner" then
						-- this is OK
					else
						-- FAIL: when tracing lines, we can only hit a line or corner
						-- anything else invalidates the zone
						return nil
					end
				elseif ftype == "corner" then
					if meta_map[n_hh] == "corner" then
						-- can only walk on corners
						table.insert(active, n_pp)
					end
				else
					-- can walk to anything
					table.insert(active, n_pp)
				end
			end
		end
	end

	--[[ We want to specifically avoid creating a zone in a diagonal corner.
	     c
	  XXX
	  XX.c
	  X.c
	   c
	]]
	--if #corners == 2 and math.abs(corners[1].x - corners[2].x) == 1 and math.abs(corners[1].z - corners[2].z) == 1 then
	--	return nil
	--end

	-- mark all the visited nodes as "done"
	--for hh, _ in pairs(visited) do
	--	meta_map[hh] = 'done'
	--end
	local corners_list = {}
	local corners_cnt = 0
	for hh, pp in pairs(corners) do
		table.insert(corners_list, hh)
		corners_cnt = corners_cnt + 1
	end
	-- all the nodes are now in visited
	--log.action("flood_fill_pos visited: %s", dump(visited))
	return visited, visited_cnt, corners, corners_cnt
end

--[[
Eliminate zones that are not needed.
1. An single-node zone that is only bordered by corner zone(s) should be combined
   with the corner zone(s).

]]
local function reduce_zones(wz, in_zones)
	local function log_zz(zz)
		local ss = {}
		table.insert(ss, string.format("type=%s node_cnt=%d corner_cnt=%d corners:", zz.type, zz.count, zz.corners_cnt))
		for hh, pp in pairs(zz.corners) do
			table.insert(ss, minetest.pos_to_string(pp))
		end
		table.insert(ss, "nodes")
		for hh, pp in pairs(zz.nodes) do
			table.insert(ss, minetest.pos_to_string(pp))
		end
		log.action("Zone: %s", table.concat(ss, " "))
	end

	local function find_by_hash(hh)
		-- NOTE: using pairs() because we may punch holes in the array
		for ii, zz in pairs(in_zones) do
			if zz.nodes[hh] ~= nil then
				return zz
			end
		end
		return nil
	end

	local function merge_entries(dst, src, new_type)
		if not src or not dst then
			return
		end
		log.action("Merging")
		log_zz(src)
		log.action("  into")
		log_zz(dst)
		dst.type = new_type
		for h, p in pairs(src.corners) do
			if dst.corners[h] == nil then
				dst.corners[h] = p
				dst.corners_cnt = dst.corners_cnt + 1
			end
		end
		for h, p in pairs(src.nodes) do
			if dst.nodes[h] == nil then
				dst.nodes[h] = p
				dst.count = dst.count + 1
			end
		end
		src.type = "deleted"
		src.corners = {}
		src.corners_cnt = 0
		src.count = 0
		src.nodes = {}
		log.action("Result")
		log_zz(dst)
	end

	-- merge isolated nodes with the corner(s)
	for idx, zz in pairs(in_zones) do
		if zz.count == 1 and zz.corners_cnt > 0 then
			local do_merge = false
			if zz.type == "" then
				do_merge = true
			elseif zz.type == "line" and zz.corners_cnt == 2 then
				-- only merge if the corners are next to each other
				local cx = {}
				for hh, pp in pairs(zz.corners) do
					table.insert(cx, pp)
				end
				if math.abs(cx[1].x - cx[2].x) == 1 and math.abs(cx[1].z - cx[2].z) == 1 then
					log.warning(" doing corner merge")
					do_merge = true
				end
			end
			if do_merge then
				for c_hash, c_pos in pairs(zz.corners) do
					merge_entries(zz, find_by_hash(c_hash), "corner")
				end
			end
		end
	end

	-- merge isolated corners other area(s)
	for idx, zz in pairs(in_zones) do
		if zz.type == "corner" then
			local last_zz = nil
			local can_merge = true
			for c_hash, c_pos in pairs(zz.nodes) do
				if not can_merge then
					break
				end
				for _, n_pp in ipairs(wz_neighbors_nsew(wz, c_pos)) do
					local n_hh = minetest.hash_node_position(n_pp)
					local c_zz = find_by_hash(n_hh)
					if c_zz then
						if last_zz == nil then
							last_zz = c_zz
						elseif last_zz ~= c_zz then
							can_merge = false
							break
						end
					end
				end
			end

			if can_merge then
				merge_entries(zz, last_zz, "")
			end
		end
	end

	--local changed = true
	--while changed do
	--	for idx, zz in pairs(in_zones) do
	--		local zz = in_zones[idx]
	--		if zz.count == 1 and #zz.corners > 0 then
	--			for _, hh in pairs(zz.corners) do
	--				nzz = merge_zone_containing_hash(idx, hh)
	--			end
	--			changed = true
	--			in_zones[idx] = nzz
	--			break -- restart scan
	--		end
	--	end
	--end

	-- convert to final layout
	local out_zones = {}
	for _, zz in ipairs(in_zones) do
		if zz.count > 0 then
			table.insert(out_zones, zz.nodes)
		end
	end
	return out_zones
end

--[[
REVISIT:
 - Put all adjacent "corner" nodes into separate zones
 - flood-fill remaining areas to create new zones
 - any new zone that can only go into the same corner zone should be absorbed
 - any corner area that can only go into one other zone should be absorbed

]]
local function flood_fill_zone(wz, meta_map, fill_unused)
	local all_zones = {}

	-- flood_fill_pos() alters meta_map, so we need to extract lines first
	local lines = {}
	local corners = {}
	local all_corners = {}
	for hh, tt in pairs(meta_map) do
		if tt == "corner" then
			table.insert(corners, hh)
			all_corners[hh] = minetest.get_position_from_hash(hh)
		elseif tt == "line" then
			table.insert(lines, hh)
		end
	end

	local function do_the_fill(pos, mtype)
		local vv, vc, co, cc = flood_fill_pos(wz, all_zones, meta_map, pos, mtype)
		if vv then
			table.insert(all_zones, {nodes=vv, count=vc, corners=co, corners_cnt=cc, type=mtype})
		end
	end

	-- flood fill lines
	for _, hh in ipairs(lines) do
		if not hash_in_zone(all_zones, hh) then
			do_the_fill(minetest.get_position_from_hash(hh), "line")
		end
	end

	-- flood fill corners
	for _, hh in ipairs(corners) do
		if not hash_in_zone(all_zones, hh) then
			local pos = minetest.get_position_from_hash(hh)
			do_the_fill(minetest.get_position_from_hash(hh), "corner")
		end
	end

	-- flood fill everything else
	for pos in wz:iter_visited() do
		local hh = minetest.hash_node_position(pos)
		if not hash_in_zone(all_zones, hh) then
			do_the_fill(minetest.get_position_from_hash(hh), "")
		end
	end

	--for _, hh in ipairs(lines) do
	--	if not hash_in_zone(all_zones, hh) then
	--		local pos = minetest.get_position_from_hash(hh)
	--		local ff, cc = flood_fill_pos(wz, meta_map, pos, "line")
	--		if ff then
	--			--log.action("ff=%s cc=%s", dump(ff), dump(cc))
	--			table.insert(all_zones, ff)
	--		end
	--	end
	--end
	--
	--if fill_unused then
	--	-- try all left-overs
	--	for pos in wz:iter_visited() do
	--		local hh = minetest.hash_node_position(pos)
	--		if not hash_in_zone(all_zones, hh) then
	--			local ff = flood_fill_pos(wz, meta_map, pos, "")
	--			if ff then
	--				table.insert(all_zones, ff)
	--			end
	--		end
	--	end
	--end
	--
	---- log the zones and visually show them
	--log.warning("there are %s zones", #all_zones)
	--if #all_zones > 1 then
	--	for zi, zz in ipairs(all_zones) do
	--		for hh, _ in pairs(zz) do
	--			local pos = minetest.get_position_from_hash(hh)
	--			markers:add(vector.offset(pos, 0, zi, 0), tostring(zi), wz_colors[zi])
	--		end
	--	end
	--	return all_zones
	--end
	return reduce_zones(wz, all_zones)
end

-- Build a list of zones that are made up of "line" nodes.
local function flood_fill_zone_old(wz, meta_map, fill_unused)
	local all_zones = {}

	-- flood_fill_pos() alters meta_map, so we need to extract lines first
	local lines = {}
	for hh, tt in pairs(meta_map) do
		if tt == "line" then
			table.insert(lines, hh)
		end
	end
	for _, hh in ipairs(lines) do
		if not hash_in_zone(all_zones, hh) then
			local pos = minetest.get_position_from_hash(hh)
			local ff, cc = flood_fill_pos(wz, all_zones, meta_map, pos, "line")
			if ff then
				--log.action("ff=%s cc=%s", dump(ff), dump(cc))
				table.insert(all_zones, ff)
			end
		end
	end

	if fill_unused then
		-- try all left-overs
		for pos in wz:iter_visited() do
			local hh = minetest.hash_node_position(pos)
			if not hash_in_zone(all_zones, hh) then
				local ff = flood_fill_pos(wz, all_zones, meta_map, pos, "")
				if ff then
					table.insert(all_zones, ff)
				end
			end
		end
	end

	---- log the zones and visually show them
	--log.warning("there are %s zones", #all_zones)
	--if #all_zones > 1 then
	--	for zi, zz in ipairs(all_zones) do
	--		for hh, _ in pairs(zz) do
	--			local pos = minetest.get_position_from_hash(hh)
	--			markers:add(vector.offset(pos, 0, zi, 0), tostring(zi), wz_colors[zi])
	--		end
	--	end
	--	return all_zones
	--end
	return all_zones
end

--[[
Check if a node looks like a corner.
A diagonal must be blocked/missing and the neighbor NSEW must be clear.
There also must be an additional 1 node clear in the neighbor direction.
]]
local function wz_is_corner(wz, pos)
	local nn = wz_neighbors(wz, pos)
	for ii=2,8,2 do -- check 2,4,6,8 (diagonals)
		local ii_cw = ii - 1
		local ii_ccw = dir_add(ii, 1)
		if (not nn[ii]) and nn[ii_ccw] and nn[ii_cw] then
			-- We need one more good spot in the dir of ii_cw or ii_ccw
			local xpl = { ii_ccw, ii_cw } --np=, enp=, vector.add(nn[ii_cw], dir_vectors[ii_cw]) }
			for _, xp_i in ipairs(xpl) do
				local xp = vector.add(nn[xp_i], dir_vectors[xp_i])
				if wz_neighbor_pos(wz, xp) ~= nil then
					-- and lastly, we must be unable to go to the corner
					local c_pos = vector.add(pos, dir_vectors[ii])
					local yes_cnt = 0
					for _, xp2 in ipairs(xpl) do
						c_pos.y = nn[xp2].y
						log.warning("corner: %s test %s cw=%s ccw=%s",
							minetest.pos_to_string(pos), minetest.pos_to_string(c_pos),
							minetest.pos_to_string(nn[ii_cw]), minetest.pos_to_string(nn[ii_ccw]))
						local d_pos = wz_neighbor_pos(wz, c_pos)
						if d_pos == nil then
							log.action("corner: yes, is a corner")
							yes_cnt = yes_cnt + 1
						else
							log.action("corner: no, not a corner %s", minetest.pos_to_string(d_pos))
						end
					end
					if yes_cnt == 2 then
						return true
					end
				end
			end
		end
	end
	return false
end

local function detect_edges(wz)
	--log.action("detect_edges: %s", tostring(wz.key))
	local edges = {}
	local meta_map = {} -- key=hash, val="edge"

	-- detect and label corners
	for pos in wz:iter_visited() do
		if wz_is_corner(wz, pos) then
			--log.warning("corner %s", minetest.pos_to_string(pos))
			table.insert(edges, {pos=pos})
			meta_map[minetest.hash_node_position(pos)] = "corner"
		end
	end

	-- draw lines between visible corners
	for si=1,#edges do
		local se = edges[si]
		for di=si+1,#edges do
			local de = edges[di]
			local line_pos = wz_visible_line(wz, se.pos, de.pos, false, nil)
			if line_pos then
				table.insert(se, de.pos)
				for _, lp in ipairs(line_pos) do
					local hash = minetest.hash_node_position(lp)
					if not meta_map[hash] then
						meta_map[hash] = "line"
					end
				end
			end
		end
	end
	--do
	--	local p1 = vector.new(417,5,-50)
	--	local p2 = vector.new(422,5,-51)
	--	if wz_visible_line(wz, p1, p2) then
	--		lines:draw_line(p1, p2)
	--	end
	--end

	return edges, meta_map
end

-- see if 2 tables have the same keys
local function same_table_keys(a, b)
	for k, _ in pairs(a) do
		if b[k] == nil then
			--log.action("same_table_keys: a.k %x is not in b", k)
			return false
		end
	end
	for k, _ in pairs(b) do
		if a[k] == nil then
			--log.action("same_table_keys: b.k %x is not in a", k)
			return false
		end
	end
	log.action("same_table_keys: look the same")
	return true
end

--[[
Split the wayzone into smaller chunks to ease planning.

If the wayzone is a "climb" area:
 1. Split the top-most node(s) into its own wayzone
 2. Split the bottom-most node(s) into its own wayzone

If the wayzone is a "fence" area:
 1. split based on visibility will usually end up with 4 zones for a boxed area

It the wayzone is a "water" area:
 1. Do not split, return nil

It the wayzone is a "door" area:
 1. Do not split, return nil

Other (regular ground) area:
Split the wayzone based on corners.
 1. find all corners. if no corners, return nil
 2. draw lines between visible corners and mark nodes as "line"
 3. Find groups of "line" nodes that are surrounded by "corner" and impassible nodes
 4. Group remaining nodes based on the closest corner
 5. If we have only one group, then return nil

@return array of tables of the form: [hash] = pos
]]
function wayzone_utils.wz_split(wz)
	if wz.in_door or wz.in_water then
		return nil
	end
	if wz.on_fence then
		-- TODO: split based on visibility
		return nil
	end
	if wz.in_climb then
		-- TODO: make sure the area is box-like (uniform width, height)
		-- TODO: split off the top-most row
		return nil
	end

	-- splitting "normal" ground wayzone by corners
	local edges, meta_map = detect_edges(wz)

	-- extract corner info
	local corners = {}
	local ncorner = 0
	for hh, mm in pairs(meta_map) do
		if mm == "corner" then
			local cc = { pos=minetest.get_position_from_hash(hh), nodes={}, owned={} }
			corners[hh] = cc
			ncorner = ncorner + 1
			corner_markers:add(cc.pos, "corner", wz_colors[1])
		end
	end
	if not next(corners) then
		-- no corners, cannot split
		return nil
	end

	--log.warning("wz_split[%s] corners: %s", wz.key, tostring(ncorner))

	-- start with chokepoints/doorframes
	local new_zones = flood_fill_zone(wz, meta_map, true)

	---- group the remaining nodes by visible corner
	--for vp in wz:iter_visited() do
	--	local vh = minetest.hash_node_position(vp)
	--	if not hash_in_zone(new_zones, vh) then
	--		for ch, cpi in pairs(corners) do
	--			if cpi.nodes[vh] == nil then
	--				local nlist = wz_visible_line(wz, vp, cpi.pos, false,
	--					function(tpos)
	--						return not hash_in_zone(new_zones, tpos)
	--					end)
	--				if nlist then
	--					-- any node in the line is also visible
	--					cpi.nodes[vh] = vp
	--					for _, lp in ipairs(nlist) do
	--						cpi.nodes[minetest.hash_node_position(lp)] = lp
	--					end
	--				end
	--			end
	--		end
	--	end
	--end
	--
	--local function update_owned()
	--	for _, cpi in pairs(corners) do
	--		cpi.owned = {}
	--	end
	--	-- scan again to find the closest corner for each line
	--	for vp in wz:iter_visited() do
	--		local vh = minetest.hash_node_position(vp)
	--		if not hash_in_zone(new_zones, vh) then
	--			local best = {}
	--			for ch, cpi in pairs(corners) do
	--				if cpi.nodes[vh] ~= nil then
	--					local dist = vector.distance(cpi.pos, vp)
	--					if not best.dist or dist < best.dist then
	--						best.dist = dist
	--						best.cpi = cpi
	--					end
	--				end
	--			end
	--			if best.cpi then
	--				best.cpi.owned[vh] = vp
	--			else
	--				log.warning("ORPHAN: %s", minetest.pos_to_string(vp))
	--			end
	--		end
	--	end
	--end
	--update_owned()
	--
	---- See if ALL the 'owned' nodes are visible from another corner.
	---- If so, we can drop this corner.
	--for oh, ocpi in pairs(corners) do
	--	local remain = {}
	--	for k, v in pairs(ocpi.owned) do
	--		remain[k] = v
	--	end
	--	for ih, icpi in pairs(corners) do
	--		if oh ~= ih then
	--			for k, v in pairs(icpi.nodes) do
	--				if remain[k] then
	--					remain[k] = nil
	--				end
	--			end
	--			if not next(remain) then
	--				break
	--			end
	--		end
	--	end
	--	if not next(remain) then
	--		--log.warning("dropping corner %s", minetest.pos_to_string(ocpi.pos))
	--		ocpi.owned = {}
	--		ocpi.nodes = {}
	--		update_owned()
	--	end
	--end
	--
	---- create new zones
	--for hh, cpi in pairs(corners) do
	--	local new_zone = {}
	--	for nh, np in pairs(cpi.owned) do
	--		new_zone[nh] = np
	--	end
	--	if next(new_zone) then
	--		table.insert(new_zones, new_zone)
	--	end
	--end

	-- need 2 new zones to split the wayzone
	if #new_zones > 1 then
		return new_zones
	end
	-- no need to split, as all nodes are in the same group
	return nil
end

-- show particles for one wayzone
function wayzone_utils.show_particles_wz(wz)
	local vn = "wayzone_node.png"
	local xn = "wayzone_exit.png"
	local xc = "wayzone_center.png"
	local xe = "waypoint_sign.png"
	local cc = wz_colors[(wz.index % #wz_colors)+1]
	local vt = string.format("%s^[multiply:#%02x%02x%02x", vn, cc[1], cc[2], cc[3])
	local xt = string.format("%s^[multiply:#%02x%02x%02x", xn, cc[1]/2, cc[2]/2, cc[3]/2)
	local xcc = string.format("%s^[multiply:#%02x%02x%02x", xc, cc[1], cc[2], cc[3])
	local xec = string.format("%s^[multiply:#%02x%02x%02x", xe, cc[1], cc[2], cc[3])
	local cpos = wz:get_center_pos()
	local dy = -0.25 + (wz.index / 8)

	-- center marker
	put_particle(vector.new(cpos.x, cpos.y+dy, cpos.z), {texture=xcc})

	-- positions that are part of the wayzone
	for pp in wz:iter_visited() do
		put_particle(vector.new(pp.x, pp.y+dy, pp.z), {texture=vt})
	end

	-- exit nodes
	--for pp in wz:iter_exited() do
	--	put_particle(vector.new(pp.x, pp.y+dy, pp.z), {texture=xt})
	--end

	---- split into sub-zones (remove when integrated)
	--local new_zones = wayzone_utils.wz_split(wz)
	--if new_zones then
	--	log.warning("Calculated %s zones", tostring(#new_zones))
	--	for zi, zz in ipairs(new_zones) do
	--		for nh, np in pairs(zz) do
	--			log.action("zone %2d %s", zi, minetest.pos_to_string(np))
	--			markers:add(vector.offset(np, 0, zi/10.0, 0), tostring(zi), wz_colors[zi])
	--		end
	--	end
	--end
end

-- show all the particles, @wzc is a wayzone_chunk or an array of wayzones
function wayzone_utils.show_particles(wzc)
	for _, wz in ipairs(wzc) do
		wayzone_utils.show_particles_wz(wz)
	end
end

-- find the closest location in minp, maxp to pos
local function closest_to_box(pos, minp, maxp)
	local function bound_val(val, vmin, vmax)
		if val < vmin then return vmin end
		if val > vmax then return vmax end
		return val
	end
	return vector.new(
		bound_val(pos.x, minp.x, maxp.x),
		bound_val(pos.y, minp.y, maxp.y),
		bound_val(pos.z, minp.z, maxp.z))
end

-- show particles for a wayzone path, just the center nodes
function wayzone_utils.show_particles_wzpath(wzpath, start_pos, target_pos)
	local xc = "wayzone_center.png"
	local cur_tgt = start_pos

	for idx, wz_key in ipairs(wzpath) do
		local chash, idx = wayzone.key_decode(wz_key)
		local wzd = wayzones.get_chunk_data(chash)
		local wz = wzd[idx]
		local pos = wz:get_center_pos()

		local closest = closest_to_box(cur_tgt, wz.minp, wz.maxp)

		local cc = wz_colors[(idx % #wz_colors)+1]
		local xcc = string.format("%s^[multiply:#%02x%02x%02x", xc, cc[1], cc[2], cc[3])

		local clo_xcc = string.format("%s^[multiply:#%02x%02x%02x", xc, cc[1]/2, cc[2]/2, cc[3]/2)

		log.action("  center=%s target=%s closest=%s",
			minetest.pos_to_string(pos), minetest.pos_to_string(cur_tgt), minetest.pos_to_string(closest))
		minetest.add_particle({
			pos = pos,
			expirationtime = 15,
			playername = "singleplayer",
			glow = minetest.LIGHT_MAX,
			texture = xcc,
			size = 4,
		})
		minetest.add_particle({
			pos = closest,
			expirationtime = 15,
			playername = "singleplayer",
			glow = minetest.LIGHT_MAX,
			texture = clo_xcc,
			size = 6,
		})
		cur_tgt = closest
	end
end

local escape_tab = {
	[0x22] = '\"',   -- escape ", since that is used to surround the string
	[0x5C] = '\\\\', -- escape \, since that is used for escape codes
	[0x00] = '\\0',
	[0x09] = '\\t',
	[0x0a] = '\\n',
	[0x0b] = '\\v',
	[0x0c] = '\\f',
	[0x0d] = '\\r',
}

-- Escape any byte outside of 0x20 - 0x7e so then can be printed in the log.
-- The string is quoted with double-quotes if any escaping was done.
local function escape_unprintable(text)
	-- Scan to see if any character are unprintable
	local need_escape = false
	for idx=1,#text do
		local ch = string.byte(text, idx)
		if ch < 0x20 or ch > 0x7e then
			need_escape = true
			break
		end
	end
	if not need_escape then
		return text
	end
	local tab = {'"'}
	for idx=1,#text do
		local ch = string.byte(text, idx)
		local ee = escape_tab[ch]
		if ee ~= nil then
			table.insert(tab, ee)
		elseif ch < 0x20 or ch > 0x7e then
			table.insert(tab, string.format("\\x%02x", ch))
		else
			table.insert(tab, string.char(ch))
		end
	end
	table.insert(tab, '"')
	return table.concat(tab, '')
end
wayzone_utils.escape_unprintable = escape_unprintable

-- log the content of a table, recurse 1 level
function wayzone_utils.log_table(name, tab)
	log.action("%s content", name)
	for k, v in pairs(tab) do
		if type(v) == 'table' then
			for k2, v2 in pairs(v) do
				if type(v2) == 'table' then
					for k3, v3 in pairs(v2) do
						local pk3 = k3
						if type(pk3) == "number" and pk3 > 50000 then
							pk3 = string.format("%012x", pk3)
						end
						log.action("  | %s.%s.%s = %s", k, k2, pk3, escape_unprintable(tostring(v3)))
					end
				else
					log.action("  | %s.%s = %s", k, k2, escape_unprintable(tostring(v2)))
				end
			end
		else
			log.action("  | %s = %s", k, escape_unprintable(tostring(v)))
		end
	end
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

--[[ Check if two chunk positions are adjacent.
The total diff will be 0 (same chunk) or wayzone.chunk_size
]]
function wayzone_utils.chunks_are_adjacent(cpos1, cpos2)
	local dx = math.abs(cpos1.x - cpos2.x)
	local dy = math.abs(cpos1.y - cpos2.y)
	local dz = math.abs(cpos1.z - cpos2.z)
	--log.action("  dx=%d dy=%d dz=%d", dx, dy, dz)
	return (dx + dy + dz) <= wayzone.chunk_size
end

local marker_def = {
	start = {texture="testpathfinder_waypoint_start.png", size=4, time=5},
	target = {texture="testpathfinder_waypoint_end.png", size=4, time=10},
	node = {texture="testpathfinder_waypoint.png", size=4, time=5},
	center = {texture="wayzone_center.png", size=5, time=5},
}

--[[
Place a marker (particle) for debug.
@pos is any grid-aligned marker
@name may be "start", "target", "node".
]]
function wayzone_utils.put_marker(pos, name)
	local def = marker_def[name]
	if def == nil then
		def = marker_def.node
	end
	put_particle(pos, def)
end

return wayzone_utils
