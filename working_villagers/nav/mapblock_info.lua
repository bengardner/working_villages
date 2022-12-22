--[[
Scans over a mapblock (16x16x16 nodes) and creates 1 byte of data for each node.

This contains info about the node and should not refer to other nodes, nor
should the info rely on the position in the world.
This information is calculated as needed and can't be calculated until all
node registration has completed.

Byte Values
b0:3 : cbox_type enum (0-15) - this holds a brief classification of the node
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
	8 : chair, bench, other node meant for sitting. don't include in path. (avoid?)
	9 : bed, mat, etc, sleep spot. avoid walking. (avoid?)
	10: misc furniture nodes that generally should not be walked on (avoid?)
	11..14 : TBD
b4:6 : param, varies by cbox_type
	cbox_type=2,3 : (number, 0-7) node height rounded up to 1/9 increments (0-7 => 1/9-8/9)
		0=1/9 h=0.111 y=-0.388
		1=2/9 h=0.222 y=-0.288
		2=3/9 h=0.333 y=-0.188
		3=4/9 h=0.444 y=-0.088
		4=5/9 h=0.556 y=0.089
		5=6/9 h=0.667 y=0.189
		6=7/9 h=0.778 y=0.289
		7=8/9 h=0.889 y=0.389
		NOTE: height = (1 + val) / 9
		NOTE: height == 0 or 1 is not possible, as a different type would be used

	cbox_type=6 : liquid type (bit field)
		b0  = causes drowning (water vs anti-gravity area?)
		b1  = TBD
		b2  = TBD

	cbox_type=7 : climbable (enum)
		0-3 = wall mounted ladder facedir (b6=0)
		4   = scaffolding, climbable inside node (b6=1)

b7 : avoid node, don't stand on or be in the node.
	- node causes damage (lava, fire, thorn bush, razorwire, etc.)
	- not allowed to walk/stand on the node ("group:leaves", "group:bed", fence, quicksand, ??)

A hash over the resultant bytes for chunk should be used to detect "real" changes.
For example, changing a node from "default:blueberry_bush_leaves" to
"default:blueberry_bush_leaves_with_berries" should not cause navigation
information to be recomputed.

I don't think we need to keep this data... Except it would be useful to know
which segment changed. Perhaps split the chunk into regions and calculate
several hashes.

PLAN:
Since this is per-node and doesn't care about the map data, we would only
keep a checksum (hash) to detect changes.
We can use any size of area. 16x16x16 or 8x8x8 or 4x4x4, whatever.
We get notification of changes at the chunk level and at node level (dig/place).
Someone has to keep the last checksum for each chunk.
I don't think we want to handle dirty here.

-------------------------------------------------------------------------------
Navigation information.
This depends on the map data and is (lazily) recalculated when the chunk data changes.
When a neighboring chunk changes, the outter edge of the data will need
to be re-evaluated. X-Z are sensitive to 1 node in the neighbors.
Y is sensitive to jump_height+height-1 nodes above and 1+fear_height below.
The wayzones will need to be updated only if the output changes.

	b0  : can go north (+Z)
	b1  : can go south (-Z)
	b2  : can go east (+X)
	b3  : can go west (-X)
	b4  : can go up (+Y)
	b5  : can go down (-Y)
	b6  : TBD
	b7  : node is a corner (nav-specific)

Dirty:
When a chunk changes, the "node information" is marked as dirty.
The hash over that is lazily recalculated. If that changes, the navigation
information is marked dirty according to where in the chunk the
all navigation information in that chunk is marked dirty.
When a neighbor chunk changes, navigation infomation in the chunk is marked
dirty depending on adjacent chunk location.
(For now, mark the 6 adjacent and the 4 above and 4 below the side chunks.)



API:

mapblock_info.get_8x_shasum(pos)
Get the SHA1Sum (string of hex chars) over the 8x8x8 block.
This should be called to see if the data has changed.
The "move" data keeps track of the SHA1Sum of each area to see when the data
needs to be recalculated.
The "move" data is an input to the "wayzone" calculation.
It also has a SHA1sum over the move data.
The "move" data and "wayzone" info could be saved to disk.

mapblock_info.dirty_mapblock(pos)
Mark all areas in a mapblock as dirty.

mapblock_info.dirty_pos(pos)
Mark all areas that contain pos as dirty.
]]
local log = working_villages.require("log")
local node_cbox_cache = working_villages.require("nav/node_cbox_cache")

-------------------------------------------------------------------------------
local mapblock_info = {}

-- cached data
local cache_node_info = {} -- { p2m=3, ni=num, p2ni={ [p2]=num } }

local node_type_enum = {
	[0] = "clear",
	[1] = "solid",
	[2] = "floor",   -- param: "height" 0..1
	[3] = "ceiling", -- param: "height" 0..1
	[4] = "cbox",
	[5] = "door",    -- param: "lockable"
	[6] = "liquid",
	[7] = "climb",   -- param: "full", "4dir"
	[8] = "seat",
	[9] = "bed",
	[10]= "furniture", -- TBD
}

-------------------------------------------------------------------------------

-- decode the info byte to something that is easier to use in code
function mapblock_info.decode(value)
	local ii = {
		evalue=bit.band(value, 0x0f),
		eparam=bit.band(bit.rshift(value, 4), 0x07),
	}
	ii.name = node_type_enum[ii.evalue]
	if not ii.name then
		log.warning("mapblock_info.decode: no name for %s [%s]", ii.evalue, tostring(value))
		return nil
	end
	ii.avoid = bit.band(value, 0x80) ~= 0
	if ii.name == "floor" or ii.name == "ceiling" then
		ii.height = (ii.eparam + 1) / 9.0
	elseif ii.name == "cbox" then
		ii.height = (ii.eparam + 1) / 8.0
	elseif ii.name == "door" then
		ii.lockable = bit.band(ii.eparam, 1) ~= 0
	elseif ii.name == "liquid" then
		ii.drowning = bit.band(ii.eparam, 1) ~= 0
	elseif ii.name == "climb" then
		ii.fullnode = bit.band(ii.eparam, 4) ~= 0
		if not ii.fullnode then
			ii.facedir = bit.band(ii.eparam, 3)
		end
	end
	return ii
end

-- calculate the base info with param2=0
-- returns the node info byte, need_param2
local function node_info_byte_calculate(node)
	local nodedef = minetest.registered_nodes[node.name]
	if not nodedef then
		return 1 -- unknown: solid
	end

	local val_avoid = false -- bit 7

	-- pack the enum, param, avoid flags
	local function build_val(ve, vp)
		local val = ve + bit.lshift(vp, 4)
		if val_avoid then -- use function global
			val = bit.bor(val, 0x80)
		end
		log.action("node_info_byte_calc: %s => 0x%02x (%d) (ve=%s vp=%s, avoid=%s) %s",
			node.name, val, val, ve, vp, tostring(val_avoid), dump(mapblock_info.decode(val)))
		return val
	end

	-- avoid due to damage
	if (nodedef.damage_per_second or 0) > 0 then
		val_avoid = true
	end

	-- avoid due to forbidden
	if minetest.get_item_group(node.name, "leaves") > 0 then
		val_avoid = true
	end

	-- is the node collidable? use "~= false" because default (nil) means true
	if nodedef.walkable ~= false then
		-- yes, the node can collide

		-- check for door
		if string.find(node.name, "doors:door") == 1 then
			-- doors DO use param2, but because they are fake non-walkable we don't care
			return build_val(5, 0) -- door
		end

		if minetest.get_item_group(node.name, "chair") > 0 or
			minetest.get_item_group(node.name, "bench") > 0 or
			string.find(node.name, "chair_") or string.find(node.name, "_chair") or
			string.find(node.name, "bench_") or string.find(node.name, "_bench")
		then
			return build_val(8, 0) -- chair/bench
		end

		-- bed check
		if minetest.get_item_group(node.name, "bed") > 0 then
			return build_val(9, 0) -- bed
		end

		local ni = node_cbox_cache.get_node_cbox(node)
		if ni == nil then
			return build_val(0, 0) -- no collisions
		end
		if ni.top == nil then
			return build_val(1, 0) -- full box
		end
		-- check for a custom cbox (5 probe points don't have same Y value)
		if ni.top_all ~= true or ni.bot_all ~= true then
			-- We need to support a max height of 1, so use /8
			local ry = math.max(0, math.floor(8 * (ni.maxy + 0.5) + 0.5) -1)
			return build_val(4, ry) -- non-uniform cbox
		end

		local maxy00 = math.round(ni.maxy * 100)
		local miny00 = math.round(ni.miny * 100)
		log.action("node %s %s miny=%s maxy=%s", node.name, node.param2, miny00, maxy00)
		if miny00 == -50 then
			log.action("node hits bottom")
			-- compute the floor height (top)
			local ry = math.max(0, math.round(9 * (ni.top + 0.5) - 0.5))
			-- if floor is too high, then it is solid on top, try ceiling
			if ry <= 7 then
				return build_val(2, ry) -- floor height
			end
		end
		if maxy00 == 50 then
			log.action("node hits top")
			-- cap ceiling height at 0.889 (8/9)
			ry = math.min(7, math.round(9 * (ni.bot + 0.5) - 1.5))
			if ry >= 0 then
				return build_val(3, ry) -- ceiling height
			end
		end

		return build_val(1, 0) -- ceiling is too low, call it a solid node
	end

	-- the node cannot collide

	local lt = nodedef.liquidtype
	if lt and lt ~= "none" then
		if (nodedef.drowning or 0) > 0 then
			return build_val(6, 1) -- liquid that causes drowning
		end
		return build_val(6, 0) -- liquid that does not cause drowning ?
	end

	if nodedef.climbable == true then
		-- check for "wallmounted" and "colorwallmounted"
		if nodedef.paramtype2 and string.find(nodedef.paramtype2, "wallmounted") then
			return build_val(7, bit.band(node.param2, 3)) -- climbable, wallmounted (ladder?)
		end
		return build_val(7, 4) -- climbable, full node (scaffolding?)
	end

	return build_val(0, 0) -- "air"
end

--[[
Return the 1-byte node information as described above.
Cached.
]]
local function node_info_get(node)
	-- Grab the cache info. Will be nil if we haven't looked at this node.
	local ci = cache_node_info[node.name]

	if ci == nil then
		ci = {}
		-- save the param2 mask for future calls
		ci.p2m = node_cbox_cache.get_param2_mask(node.name)
		cache_node_info[node.name] = ci

		-- get the node info byte for this rotation
		local ni = node_info_byte_calculate(node)
		if not ci.p2m then
			log.action("node_info: create %s => %s (no p2m)", node.name, ni)
			ci.ni = ni
		else
			local p2 = bit.band(node.param2, ci.p2m)
			log.action("node_info: create %s %s => %s p2=%s", node.name, node.param2, ni, p2)
			ci.p2ni = { [p2] = ni }
		end
		return ni
	end

	if not ci.p2m then
		log.action("node_info: cached %s => %s (no p2m)", node.name, ci.ni)
		return ci.ni
	end

	local p2 = bit.band(node.param2, ci.p2m)
	local ni = ci.p2ni[p2]
	if not ni then
		ni = node_info_byte_calculate(node)
		log.action("node_info: create2 %s %s => %s p2=%s", node.name, node.param2, ni, p2)
		ci.p2ni[p2] = ni
	else
		log.action("node_info: cached %s %s => %s p2=%s", node.name, node.param2, ni, p2)
	end
	return ni
end

-- get the node info for the node at @pos
function mapblock_info.getat(pos)
	local node = minetest.get_node(pos)
	return node_info_get(node)
end

-- get the node info for the @node
function mapblock_info.get(node)
	return node_info_get(node)
end

return mapblock_info
