local S = default.get_translator

local pathfinder = working_villages.require("pathfinder")

local waypoint = {}

--[[
waypoint.store[chunk_hash][idx][node_hash] = node_info
]]
waypoint.store = {}

-- hope we don't have more than 8 zones
local wz_colors = {
	{ 255,   0,   0 },
	{   0, 255,   0 },
	{   0,   0, 255 },
	{ 255, 255,   0 },
	{ 255,   0, 255 },
	{   0, 255, 255 },
	{   0,   0,   0 },
	{ 255, 255, 255 },
}

-- show all the particles, @wz_data is am array of hash sets
function waypoint.show_particles(wz_dat)
	local tn = "testpathfinder_waypoint.png"
	for idx, wz in ipairs(wz_dat) do
		local cc = wz_colors[(idx % #wz_colors)+1]
		minetest.log("action", string.format("part cc: %s %d", cc, #cc))

		local t = string.format("%s^[multiply:#%02x%02x%02x", tn, cc[1], cc[2], cc[3])

		for hh, ii in pairs(wz) do
			minetest.log("action", " **"..minetest.pos_to_string(ii.pos).." "..tostring(hh))
			minetest.add_particle({
				pos = {x=ii.pos.x,y=ii.pos.y-0.5+idx/8,z=ii.pos.z},
				expirationtime = 10,
				playername = "singleplayer",
				glow = minetest.LIGHT_MAX,
				texture = t,
				size = 2,
			})
		end
	end
end

local function do_waypoint_click(user, pos)
	--[[
	Get the data for the waypoint and print it out.
	]]
	local gpos = { x=math.floor(pos.x / 16) * 16,
		           y=math.floor(pos.y / 16) * 16,
		           z=math.floor(pos.z / 16) * 16 }
	local ghash = minetest.hash_node_position(gpos)

	local wz_data = waypoint.store[ghash] or {}

	minetest.log("action", string.format("do_waypoint_click: %s %s %x %s %d",
										 minetest.pos_to_string(pos),
										 minetest.pos_to_string(gpos),
										 ghash, wz_data, #wz_data))
	for k, v in pairs(waypoint.store) do
		minetest.log("action",
			string.format("  ++ k=%x %s v=%s c=%d", k,
				minetest.pos_to_string(minetest.get_position_from_hash(k)),
				v, #v))
	end

	waypoint.show_particles(wz_data)
end

-- tab is a table of hash={pos=xx}
-- sort by x+z and pick one half way down the list
local function find_central_pos(tab)

end

-- find the hash/pos in the waypoint zone list
-- return nil (not found) or the zone id
local function wpz_find(wpz_set, pos, hash)
	for zid, wpz in pairs(wpz_set) do
		if wpz[hash] ~= nil then
			return zid
		end
	end
	return nil
end

-- process a chunk. gpos is th node in the -x,-y,-z corner.
function waypoint.process_chunk(gpos)
	local ghash = minetest.hash_node_position(gpos)
	minetest.log("action", string.format("-- process_chunk: %s h=%x", minetest.pos_to_string(gpos), ghash))
	local minp = { x=gpos.x, y=gpos.y, z=gpos.z }
	local maxp = { x=gpos.x + 15, y=gpos.y + 15, z=gpos.z + 15 }

	local wpz_tab = {} -- waypoint zones

	local function inside_area(self,pos,hash)
		-- check the box
		if (pos.x >= self.minp.x and pos.y >= self.minp.y and pos.z >= self.minp.z and
		    pos.x <= self.maxp.x and pos.y <= self.maxp.y and pos.z <= self.maxp.z)
		then
			-- make sure the node isn't in another zone
			return wpz_find(wpz_tab, hash) == nil
		end
		return false
	end

	local area = { minp=minp, maxp=maxp, inside=inside_area }
	local args = { height = 2, fear_height = 2, jump_height = 1 }

	for x=0,15 do
		for z=0,15 do
			local slots = {}
			local clear_cnt = 0
			local air_pos = nil
			local stand_pos = nil
			for y=0,17 do
				local tpos = { x=gpos.x+x, y=gpos.y+y, z=gpos.z+z }
				local node = minetest.get_node(tpos)

				if clear_cnt >= args.height and air_pos ~= nil and stand_pos ~= nil then
					local pp = { x=stand_pos.x, y=stand_pos.y+1, z=stand_pos.z }
					table.insert(slots, pp)
					air_pos = nil
					stand_pos = nil
				end
				if pathfinder.is_node_collidable(node) then
					clear_cnt = 0
				else
					air_pos = tpos
					clear_cnt = clear_cnt + 1
				end
				if pathfinder.is_node_standable(node) then
					stand_pos = tpos
				end
			end
			-- scan in reverse order, since falling can go farther than climbing
			for idx=#slots,1,-1 do
				local tpos = slots[idx]
				--minetest.log("action", string.format(" Probe Slot %s", minetest.pos_to_string(tpos)))
				if wpz_find(wpz_tab, tpos, minetest.hash_node_position(tpos)) == nil then
					local coverage = pathfinder.flood_fill(tpos, nil, area)
					local h, i = next(coverage)
					if h ~= nil then
						table.insert(wpz_tab, coverage)
					end
				end
			end
		end
	end

	minetest.log("action", string.format(" ^^ found %d zones for %s %x tab=%s", #wpz_tab, minetest.pos_to_string(gpos), ghash, tostring(wpz_tab)))

	waypoint.store[ghash] = wpz_tab
end

-- remove all links from a chunk to another
function waypoint.link_clear(from_hash, to_hash)
	minetest.log("action", string.format(" -- waypoint_link_clear: from=%x to=%x", from_hash, to_hash))
end

-- add a link from one waypoint chunk to another
function waypoint.link_add(from_hash, from_idx, to_hash, to_idx)
	minetest.log("action", string.format("waypoint.link_add: from=%x,%d to=%x,%d", from_hash, from_idx, to_hash, to_idx))
end

-- six adjacent chunks
local chunk_adjacent = {
	{ x=-16, y=  0, z=  0 },
	{ x= 16, y=  0, z=  0 },
	{ x=  0, y=-16, z=  0 },
	{ x=  0, y= 16, z=  0 },
	{ x=  0, y=  0, z=-16 },
	{ x=  0, y=  0, z= 16 },
}

--[[
Compute all connections between two adjacent chunks.
We box the search to the two chunks.
We are done when any node in the "to" zone is hit.
]]
function waypoint.link_compute(from_hash, to_hash)
	local from_pos = minetest.get_position_from_hash(from_hash)
	local from_data = waypoint.store[from_hash] or {}
	local to_pos = minetest.get_position_from_hash(to_hash)
	local to_data = waypoint.store[to_hash] or {}
	local minp = { x=math.min(to_pos.x, from_pos.x),
	               y=math.min(to_pos.y, from_pos.y),
	               z=math.min(to_pos.z, from_pos.z) }
	local maxp = { x=math.max(to_pos.x+15, from_pos.x+15),
	               y=math.max(to_pos.y+15, from_pos.y+15),
	               z=math.max(to_pos.z+15, from_pos.z+15) }

	minetest.log("action", string.format("waypoint.link_compute: from=%x %s [%d] to=%x %s [%d]",
										 from_hash, from_pos, #from_data, to_hash, to_pos, #to_data))

	-- first hit and we are done
	local function inside_wzone(self, pos, hash)
		return self.wz[hash] ~= nil
	end

	-- restrict the search to the two chunks
	local function outside_wzone(self, pos, hash)
		return (pos.x < self.minp.x or pos.y < self.minp.y or pos.z < self.minp.z or
		        pos.x > self.maxp.x or pos.y > self.maxp.y or pos.z > self.maxp.z)
	end

	-- start clean
	waypoint.link_clear(from_hash, to_hash)

	for to_idx=1,#to_data do
		local to_wz = to_data[to_idx]
		local _, to_node = next(to_wz)
		-- use the first node as a dummy end pos. any would work. closest to the 'from' would be best
		local endpos = { x=to_node.pos.x, y=to_node.pos.y, z=to_node.pos.z,
		                 wz=to_wz, inside=inside_wzone, outside=outside_wzone,
		                 minp=minp, maxp=maxp }

		for from_idx=1,#from_data do
			local from_wz = from_data[from_idx]
			local _, from_node = next(from_wz)

			-- use any start position, although the closest would be best
			local path = pathfinder.find_path(from_node.pos, endpos, nil, { want_nil=true })
			if path ~= nil then
				waypoint.link_add(from_hash, from_idx, to_hash, to_idx)
			end
		end
	end
end

function waypoint.link_chunks(chunk_pos)
	local chunk_hash = minetest.hash_node_position(chunk_pos)
	local wp_data = waypoint.store[chunk_hash] or {}

	minetest.log("action", "link_chunk: "..minetest.pos_to_string(chunk_pos))

	-- clean internal links, as we will recompute
	waypoint.link_clear(chunk_hash, chunk_hash)

	-- no waypoints means nothing to do
	if #wp_data == 0 then return end

	-- If we have more than 1 waypoint zone, then we need to see if they connect
	-- a lower one cannot go to a higher one (by definition), so we only check
	-- higher-to-lower. We don't need to recompute the path, as we still have
	-- the complete zone info (that may need to be fixed for memory reasons)
	if #wp_data > 1 then
		-- from walks back from the end, down to 2
		for from_idx=#wp_data,2,-1 do
			local from_wz = wp_data[from_idx]
			local found = false
			-- to walks back from from_idx to 1
			for to_idx=from_idx-1,1,-1 do
				local to_wz = wp_data[to_idx]
				for hash, item in pairs(from_wz) do
					if to_wz[hash] ~= nil then
						found = true
						waypoint.link_add(chunk_hash, from_idx, chunk_hash, to_idx)
						break
					end
				end
				if found then
					break
				end
			end
		end
	end

	-- test links with neightbors doing a real find_path
	for _, avec in pairs(chunk_adjacent) do
		local neighbor_pos = vector.add(chunk_pos, avec)
		local neighbor_hash = minetest.hash_node_position(neighbor_pos)

		waypoint.link_compute(chunk_hash, neighbor_hash)
		waypoint.link_compute(neighbor_hash, chunk_hash)
	end
end

local function do_waypoint_flood(user, pos)
	--pos = pathfinder.is_node_standable()
	local gpos = { x=math.floor(pos.x / 16) * 16,
				   y=math.floor(pos.y / 16) * 16,
				   z=math.floor(pos.z / 16) * 16 }

	minetest.log("action", "do_waypoint_flood "..minetest.pos_to_string(pos)
				 .." gp="..minetest.pos_to_string(gpos))

	-- make sure the neighboring waypoints are up-to-date
	waypoint.process_chunk(gpos)
	for _, nvec in pairs(chunk_adjacent) do
		waypoint.process_chunk(vector.add(gpos, nvec))
	end
	waypoint.link_chunks(gpos)
end

minetest.register_node("working_villages:waypoint", {
	description = S("Waypoint Sign for debug"),
	drawtype = "plantlike",
	tiles = {"waypoint_sign.png"}, -- FIXME:
	inventory_image = "waypoint_sign.png", -- FIXME:
	wield_image = "waypoint_sign.png", -- FIXME:
	paramtype = "light",
	sunlight_propagates = true,
	walkable = false,
	selection_box = {
		type = "fixed",
		fixed = {-4 / 16, -0.5, -4 / 16, 4 / 16, 7 / 16, 4 / 16}
	},
	groups = { dig_immediate = 3, waypoint=1 },

	on_use = function(itemstack, user, pointed_thing)
		-- [node under=195,7,-58 above=195,7,-59]
		if (pointed_thing.type == "node") then
			local pos = minetest.get_pointed_thing_position(pointed_thing)

			local node_under = minetest.get_node(pointed_thing.under)
			local node_above = minetest.get_node(pointed_thing.above)
			--minetest.log("action", "waypoint:"
			--			 .."under "..node_under.name.." @ "..minetest.pos_to_string(pointed_thing.under)
			--			 .."above "..node_above.name.." @ "..minetest.pos_to_string(pointed_thing.above)
			--			 )
			if node_under.name == "working_villages:waypoint" then
				do_waypoint_click(user, pointed_thing.under)
			elseif node_above.name == "working_villages:waypoint" then
				do_waypoint_click(user, pointed_thing.above)
			else
				if not pathfinder.is_node_collidable(node_above) then
					do_waypoint_flood(user, pointed_thing.above)
				end
			end
			return itemstack
		end
	end,
})
