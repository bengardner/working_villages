local func = {}
local pathfinder = working_villages.require("nav/pathfinder")
local log = working_villages.require("log")
local rotate = working_villages.require("nav/rotate")

-- used in the physics stuff copied from mobkit
func.gravity = -9.8
func.friction = 0.4 -- less is more

func.terminal_velocity = math.sqrt(2 * -func.gravity * 20) -- 20 meter fall = dead
func.safe_velocity = math.sqrt(2 * -func.gravity * 5) -- 5 m safe fall

-- return -1 or 1, depending on whether (x < 0)
local function sign(x)
	return (x < 0) and -1 or 1
end
func.sign = sign

-- returns true approx every @sec seconds
function func.timer(self, sec)
	local t1 = math.floor(self.time_total)
	local t2 = math.floor(self.time_total + self.dtime)
	return (t2 > t1) and ((t2 % sec) == 0)
end

-- return the center of the node that contains @pos
function func.get_node_pos(pos)
	return vector.round(pos)
end

function func.nodeatpos(pos)
	local node = minetest.get_node_or_nil(pos)
	if node then
		return minetest.registered_nodes[node.name]
	end
end

-- thing can be luaentity or objectref.
function func.get_stand_pos(thing)
	local pos = {}
	local colbox = {}
	if type(thing) == 'table' then
		pos = thing.object:get_pos()
		colbox = thing.object:get_properties().collisionbox
	elseif type(thing) == 'userdata' then
		pos = thing:get_pos()
		colbox = thing:get_properties().collisionbox
	else
		return false
	end
	return vector.offset(pos, 0, colbox[2]+0.01, 0), pos
end

function func.get_box_height(thing)
	if type(thing) == 'table' then
		thing = thing.object
	end
	local colbox = thing:get_properties().collisionbox
	local height
	if colbox then
		height = colbox[5] - colbox[2]
	else
		height = 0.1
	end
	return height > 0 and height or 0.1
end


function func.find_path_toward(pos, villager)
	local dest = vector.round(pos)
	--TODO: spiral outward from pos and try to find reverse paths
	if func.walkable_pos(dest) then
		dest = pathfinder.get_ground_level(dest)
	end
	local val_pos = func.validate_pos(villager.object:get_pos())
	--FIXME: this also reverses jump height and fear height
	local _, rev = pathfinder.find_path(dest, val_pos, villager)
	return rev
end

--TODO:this is used as a workaround
-- it has to be replaced by routing
--  to the nearest possible position
function func.find_ground_below(position)
	local pos = vector.new(position)
	local height = 0
	local node
	repeat
		height = height + 1
		pos.y = pos.y - 1
		node = minetest.get_node(pos)
		if height > 10 then
			return false
		end
	until pathfinder.walkable(node)
	pos.y = pos.y + 1
	return pos
end

--[[
This adjusts pos up by 1 if we are on stairs or another walkable node that
doesn't fill the whole node.
For example, the MOB will usually be at, say, y=10.5, which is on top of node
at y=10. The position for pathfinding purposes is y=11. round() is correct.
However, if on stairs or a slab, we might be at y=10.25. That would round to
y=10, which is invalid for pathfinding.
]]
function func.validate_pos(pos)
	local resultp = vector.round(pos)
	local node = minetest.get_node(resultp)
	-- Are we inside a walkable node? then go up by 1
	if minetest.registered_nodes[node.name].walkable then
		resultp = vector.subtract(pos, resultp)
		resultp = vector.round(resultp)
		resultp = vector.add(pos, resultp)
		return vector.round(resultp)
	else
		return resultp
	end
end

--[[
This adjusts pos to the nearest likely stand position.
There are two problems:
 1. Stairs and slabs cause round() to drop down, so that the current position
    is inside a walkable node. We need to bump y+1.
 2. We might be standing over air, but are really standing on a neighbor node.
    For this, we need to check the other 1-3 nodes in the 4-block area.

In either case, we probably could get some of that info from the collision
info passed to on_step(). Needs further investigation.
]]
function func.adjust_stand_pos(pos)
	local rpos = vector.round(pos)

	-- 1. If inside a walkable node, we go up by 1
	local node = minetest.get_node(rpos)
	if minetest.registered_nodes[node.name].walkable then
		rpos.y = rpos.y + 1
	end

	-- 2. If over air, we need to shift a bit to over a neighbor node
	local bpos = vector.new(rpos.x, rpos.y-1, rpos.z)
	node = minetest.get_node(bpos)
	if not minetest.registered_nodes[node.name].walkable then
		local ret = {}
		local function try_dpos(dpos)
			if ret.pos ~= nil then
				return
			end
			local tpos = vector.add(rpos, dpos)
			--log.action("trying %s for %s", minetest.pos_to_string(tpos), pos)
			node = minetest.get_node(tpos)
			if not minetest.registered_nodes[node.name].walkable then
				node = minetest.get_node(vector.new(tpos.x, tpos.y - 1, tpos.z))
				if minetest.registered_nodes[node.name].walkable then
					ret.pos = tpos
					return true
				end
			end
		end

		local dpos = vector.subtract(pos, rpos) -- should be -0.5 to 0.5 on each axis
		local arr_pos = {}

		--log.action("  === pos=%s rpos=%s dpos=%s", minetest.pos_to_string(pos), minetest.pos_to_string(rpos), minetest.pos_to_string(dpos))

		local sx = sign(dpos.x)
		local sz = sign(dpos.z)
		-- We try side, side, diagonal
		if math.abs(dpos.x) > 0.1 then
			table.insert(arr_pos, vector.new(sx,0,0))
		end
		if math.abs(dpos.z) > 0.1 then
			table.insert(arr_pos, vector.new(0,0,sz))
		end
		if #arr_pos == 2 then
			-- reverse the two if dz was bigger
			if math.abs(dpos.x) < math.abs(dpos.z) then
				arr_pos[1], arr_pos[2] = arr_pos[2], arr_pos[1]
			end
			-- add the diagonal
			table.insert(arr_pos, vector.new(sx,0,sz))
		end

		-- try the positions in order
		for _, dp in ipairs(arr_pos) do
			if try_dpos(dp) then
				break
			end
		end
		if ret.pos ~= nil then
			return ret.pos
		end
	end
	return rpos
end

--TODO: look in pathfinder whether defining this is even necessary
-- Checks to see if a MOB can stand in the location.
function func.clear_pos(pos)
	local node = minetest.get_node(pos)
	local above_node = minetest.get_node(vector.new(pos.x, pos.y + 1, pos.z))
	return not (pathfinder.is_node_collidable(node) or pathfinder.is_node_collidable(above_node))
end

function func.walkable_pos(pos)
	local node = minetest.get_node(pos)
	return pathfinder.walkable(node)
end

function func.find_adjacent_clear(pos)
	if not pos then
		error("didn't get a position")
	end
	local found = func.find_adjacent_pos(pos, func.clear_pos)
	if found ~= false then
		return found
	end
	found = vector.new(pos.x, pos.y - 2, pos.z)
	if func.clear_pos(found) then
		return found
	end
	return false
end

local find_adjacent_clear = func.find_adjacent_clear

-- search in an expanding box around pos in the XZ plane
-- first hit would be closest
-- TODO: rework to use iterate_surrounding_xz()
local function search_surrounding(pos, pred, searching_range, caller_state)
	pos = vector.round(pos)
	local max_xz = math.max(searching_range.x, searching_range.z)
	local mod_y
	if searching_range.h == nil then
		if searching_range.y > 3 then
			mod_y = 2
		else
			mod_y = 0
		end
	else
		mod_y = searching_range.h
	end

	local ret = {}

	local function check_column(dx, dz)
		if ret.pos ~= nil then
			return
		end
		for j = mod_y - searching_range.y, searching_range.y do
			local p = vector.add({x = dx, y = j, z = dz}, pos)
			if pred(p, caller_state) and find_adjacent_clear(p) ~= false then
				ret.pos = p
				return
			end
		end
	end

	-- "i" is the radius
	for i = 0, max_xz do
		for k = 0, i do
			-- hit the 8 points of symmetry, bound check and skip duplicates
			if k <= searching_range.x and i <= searching_range.z then
				check_column(k, i)
				if i > 0 then
					check_column(k, -i)
				end
				if k > 0 then
					check_column(-k, i)
					if k ~= i then
						check_column(-k, -i)
					end
				end
			end

			if i <= searching_range.x and k <= searching_range.z then
				if i > 0 then
					check_column(-i, k)
				end
				if k ~= i then
					check_column(i, k)
					if k > 0 then
						check_column(-i, -k)
						check_column(i, -k)
					end
				end
			end
			if ret.pos ~= nil then
				break
			end
		end
	end
	return ret.pos
end

func.search_surrounding = search_surrounding

--[[
Iterate node positions in an expanding box around pos in the XZ plane.
Returns the first position for which @func returns a true value.

@pos is the start position, first called on that position
@search_range contains the radius for each axis. only x and z are used.
@func is called on each as func(pos, state). If func() returns true, we stop and
  return that position.
@state passed as the second parameter to func (might be nil)
]]
local function iterate_surrounding_xz(pos, searching_range, func, state)
	pos = vector.round(pos)
	local max_xz = math.max(searching_range.x, searching_range.z)
	local ret = {}

	local function check_column(dx, dz, rad)
		if ret.pos ~= nil then
			return
		end
		--log.action("check x=%d z=%d r=%d", dx, dz, rad)
		local cpos = vector.new(pos.x + dx, pos.y, pos.z + dz)
		if func(cpos, state, rad) then
			ret.pos = cpos
		end
	end

	-- "i" is the radius
	for i = 0, max_xz do
		for k = 0, i do
			-- hit the 8 points of symmetry, bound check and skip duplicates
			if k <= searching_range.x and i <= searching_range.z then
				check_column(k, i, i)
				if i > 0 then
					check_column(k, -i, i)
				end
				if k > 0 then
					check_column(-k, i, i)
					if k ~= i then
						check_column(-k, -i, i)
					end
				end
			end

			if i <= searching_range.x and k <= searching_range.z then
				if i > 0 then
					check_column(-i, k, i)
				end
				if k ~= i then
					check_column(i, k, i)
					if k > 0 then
						check_column(-i, -k, i)
						check_column(i, -k, i)
					end
				end
			end
			if ret.pos ~= nil then
				break
			end
		end
	end
	return ret.pos
end

func.iterate_surrounding_xz = iterate_surrounding_xz

-- defines the 6 adjacent positions
local adjacent_pos = {
	vector.new(0, 1, 0),
	vector.new(0, -1, 0),
	vector.new(1, 0, 0),
	vector.new(-1, 0, 0),
	vector.new(0, 0, 1),
	vector.new(0, 0, -1)
}

-- Call @pred on @pos and the six adjacent positions
-- Returns the position (vector) if @pred returns non-nil.
-- Returns false if @pred does not return non-nil.
function func.find_adjacent_pos(pos, pred)
	if pred(pos) then
		return pos
	end
	for _, dpos in ipairs(adjacent_pos) do
		local dest_pos = vector.add(pos, dpos)
		if pred(dest_pos) then
			return dest_pos
		end
	end
	return false
end

-- check the 4 adjacent positions in the x-z plane
function func.find_adjacent_pos_xz(pos, pred)
	-- start at 3 to skip Y
	for idx=3,#adjacent_pos do
		local dest_pos = vector.add(pos, adjacent_pos[idx])
		if pred(dest_pos) then
			return dest_pos
		end
	end
	return false
end

-------------------------------------------------------------------------------

-- Activating owner griefing settings departs from the documented behavior
-- of the protection system, and may break some protection mods.
local owner_griefing = minetest.settings:get("working_villages_owner_protection")
local owner_griefing_lc = owner_griefing and string.lower(owner_griefing)

if not owner_griefing or owner_griefing_lc == "false" then
	-- Villagers may not grief in protected areas.
	func.is_protected_owner = function(_, pos) -- (owner, pos)
		return minetest.is_protected(pos, "")
	end
else
	if owner_griefing_lc == "true" then
		-- Villagers may grief in areas protected by the owner.
		func.is_protected_owner = function(owner, pos)
			local myowner = owner or ""
			if myowner == "working_villages:self_employed" then
				myowner = ""
			end
			return minetest.is_protected(pos, myowner)
		end
	else
		if owner_griefing_lc == "ignore" then
			-- Villagers ignore protected areas.
			func.is_protected_owner = function()
				return false
			end
		else
			-- Villagers may grief in areas where "[owner_protection]:[owner_name]" is allowed.
			-- This makes sense with protection mods that grant permission to
			-- arbitrary "player names."
			func.is_protected_owner = function(owner, pos)
				local myowner = owner or ""
				if myowner == "" then
					myowner = ""
				else
					myowner = owner_griefing .. ":" .. myowner
				end
				return minetest.is_protected(pos, myowner)
			end

			-- Patch areas to support this extension
			local prefixlen = #owner_griefing
			local areas = rawget(_G, "areas")
			if areas then
				local areas_player_exists = areas.player_exists
				function areas.player_exists(area, name)
					local myname = name
					if string.sub(name, prefixlen + 1, prefixlen + 1) == ":" and string.sub(name, prefixlen + 2) and
						string.sub(name, 1, prefixlen) == owner_griefing
					 then
						myname = string.sub(name, prefixlen + 2)
						if myname == "working_villages:self_employed" then
							return true
						end
					end
					return areas_player_exists(area, myname)
				end
			end
		end
	end
end -- else else else

function func.is_protected(self, pos)
	return func.is_protected_owner(self.owner_name, pos)
end

-------------------------------------------------------------------------------

-- chest manipulation support functions
function func.is_chest(pos)
	local node = minetest.get_node_or_nil(pos)
	if node == nil then
		return false
	end
	if node.name == "default:chest" then
		return true
	end
	return (minetest.get_item_group(node.name, "chest") > 0)
end

--[[
Pick an item from the 'read-only' weighted array.
If you change the array, remove 'total_weight' from the table.
The value should be a table with a 'weight' field. Default 1.
weight must be an integer
returns the selected item
]]
function func.pick_random(tab)
	-- calculate the total_weight on the first call
	if tab.total_weight == nil then
		local total_weight = 0
		for _, val in ipairs(tab) do
			total_weight = total_weight + (val.weight or 1)
		end
		tab.total_weight = total_weight
	end

	-- pick an entry
	if tab.total_weight > 0 then
		local sel = math.random(1, tab.total_weight)
		for idx, val in ipairs(tab) do
			local w = (val.weight or 1)
			if sel <= w then
				return val
			end
			sel = sel - w
		end
	end
	return nil
end

function func.minmax(v,m)
	return math.min(math.abs(v), m) * sign(v)
end

function func.set_acceleration(thing, vec, limit)
	limit = limit or 100
	if type(thing) == 'table' then
		thing = thing.object
	end
	vec.x = func.minmax(vec.x, limit)
	vec.y = func.minmax(vec.y, limit)
	vec.z = func.minmax(vec.z, limit)
	thing:set_acceleration(vec)
end

function func.pop_last(tab)
	if #tab > 0 then
		local item = tab[#tab]
		table.remove(tab)
		return item
	end
	return nil
end

-- get a list of all possible drops from a node name
function func.get_possible_drops(node_name)
	local out_tab = {}
	local function get_items_from_table(val)
		if type(val) == "string" then
			local idx = string.find(val, " ")
			if idx then
				val = string.sub(val, 1, idx-1)
			end
			out_tab[val] = true
		elseif type(val) == "table" then
			for k, v in pairs(val) do
				--get_strings_from_table(k, out_tab)
				get_items_from_table(v)
			end
		end
	end

	local nodedef = minetest.registered_nodes[node_name]
	if nodedef then
		if nodedef.drop then
			get_items_from_table(nodedef.drop)
		else
			out_tab[node_name] = true
		end
	end
	local out_list = {}
	for k, _ in pairs(out_tab) do
		table.insert(out_list, k)
	end
	return out_list
end

function func.find_tools_by_group(group)
	local tools = {}
	for name, def in pairs(minetest.registered_tools) do
		if def.groups and def.groups[group] then
			table.insert(tools, name)
		end
	end
	return tools
end

--[[
Get the name of the item, which may be:
 * a string: "default:cobblestone"
 * an InvRef in table form: { name="default:cobblestone", count=1, ... }, uses item.name
 * ItemStack : uses item:get_name()
]]
function func.resolve_item_name(item)
	if type(item) == "string" then
		return item
	elseif type(item) == "table" then
		if item.name then
			return item.name
		end
	else
		return item:get_name() -- assuming ItemStack
	end
end

function func.is_bed(name)
	-- catch the default game notation first
	if minetest.get_item_group(name, "bed") > 0 then
		return true
	end
	-- other beds:
	if string.find(name, "cottages:bed_") then
		return true
	end
	-- worth a shot
	if name == "cottages:straw_mat"
	or name == "cottages:sleeping_mat_head"
	or name == "cottages:sleeping_mat"
	then
		return true
	end
	return false
end

function func.is_stair(name)
	return minetest.get_item_group(name, "stair") > 0
end

function func.is_chair(name)
	-- really should bug the mod authors to add a "chair" group
	return string.find(name, "chair_") or string.find(name, "_chair")
end

function func.is_bench(name)
	-- really should bug the mod authors to add a "chair" or "bench" group
	return string.find(name, "bench_") or string.find(name, "_bench") or string.find(name, "cottages:bench")
end

--[[
This adjusts the starting sit position for the MOB.
Generally, only y and Z are set.
Positions are relative to the node center, which works for most surfaces.
  +Z moves towards the feet, (forward, sit on edge)
  -Z sits furhter back
  +X is to the right (of the MOB)
  -X is to the left

The sitting stuff relies on collision detection to actually sit.
We could use the collision box to find the top... then we only need Z.
]]
--local seat_adjustments = {
--	{ "furniture:chair_thick_",        vector.new(0, 0, -0.15) },
--	{ "furniture:chair_",              vector.new(0, 0.05, 0) },
--	{ "ts_furniture:default_.*_bench", vector.new(0, 0, -0.2) },
--	{ "cottages:bench",                vector.new(0, 0, -0.3) },
--	{ "cottages:bed_head",             vector.new(0, 0.2, 0) },
--	{ "cottages:bed_foot",             vector.new(0, 0.2, 0) },
--}

local cache_seat_pos = {}
local cache_node_height = {}

-- calculate the area on the XZ plane
local function box_xz_area(box)
	return (box[4] - box[1]) * (box[6] - box[3])
end

-- return a vector with the center - top position
local function box_center_top(box)
	return vector.new((box[1] + box[4]) / 2, box[5], (box[3] + box[6]) / 2)
end

--[[
Find the best 'seat' spot based on the collision_box or node_box
Find the box with the largest XZ area and use that as the seat.
]]
function func.find_seat_center(nodedef)
	local geom
	local function decode_geom(xbox)
		if xbox.type == "fixed" then
			geom = xbox.fixed
		elseif xbox.type == "regular" then
			geom = vector.new(0, 0.5, 0)
		end
	end

	if nodedef.collision_box then
		decode_geom(nodedef.collision_box)
	elseif nodedef.node_box then
		decode_geom(nodedef.node_box)
	else
		-- assume regular, full box
		return vector.new(0, 0.5, 0)
	end
	if geom == nil or vector.check(geom) then
		return geom
	end

	-- find the largest area
	local best = {}
	local function check_best(box)
		local aa = box_xz_area(box)
		if not best.area or aa > best.area or (aa == best.area and box[5] > best.abox[5]) then
			best.abox = box
			best.area = aa
		end
	end

	if #geom > 0 and type(geom[1]) == "number" then
		check_best(geom)
	else
		for _, box in ipairs(geom) do
			check_best(box)
		end
	end
	if not best.abox then
		return nil
	end
	return box_center_top(best.abox)
end

function func.get_seat_offset(name)
	local pos = cache_seat_pos[name]
	if pos == nil then
		local nodedef = minetest.registered_nodes[name]
		if nodedef then
			pos = func.find_seat_center(nodedef)
			if pos then
				cache_seat_pos[name] = pos
				return pos
			end
		end
		cache_seat_pos[name] = true -- tried, but failed
	end
	if vector.check(pos) then
		return vector.new(pos.x, pos.y, -pos.z)
	end
	return vector.zero()
end

--[[
Reduces an array of boxes to the min/max of all.
If @boxes[1] is a number, this returns @boxes unaltered.
Returns nil if @boxes is not a table or it is an empty array.
]]
function func.box_minmax(boxes)
	if type(boxes) ~= "table" or #boxes == 0 then
		return nil
	end
	if type(boxes[1]) == "number" then
		return boxes
	end
	local nb = table.copy(boxes[1])
	for idx=2, #box do
		local bb = boxes[idx]
		for ii=1,3 do
			nb[ii] = math.min(nb[ii], bb[ii])
			nb[ii+3] = math.max(nb[ii+3], bb[ii+3])
		end
	end
	return nb
end

local function get_full_node_box()
	return {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}
end

--[[
Get a rotated collision box.
returns:
 - nil if no collision box info available
 - or a collision box and param2. param2 should be nil if not used.
]]
function func.nodedef_get_collision_box(nodedef, param2)
	-- check for no collisions first
	if not nodedef.walkable then
		return nil
	end

	-- collision_box and node_box are processed the same
	local function proc_box(cbox)
		if cbox.type == "fixed" then
			local box = func.box_minmax(cbox.fixed)
			local p2
			if nodedef.paramtype2 == "facedir" or nodedef.paramtype2 == "colorfacedir" then
				p2 = bit.band(param2, 0x1f)
				box = rotate.box_facedir(box, p2)
			end
			return box, p2
		elseif cbox.type == "leveled" and nodedef.paramtype2 == "leveled" then
			local box = func.box_minmax(cbox.fixed)
			box[2] = -0.5
			box[5] = param2 / 64 - 0.5
			return box, param2
		else
			return get_full_node_box()
		end
	end

	-- collision_box takes priority
	if nodedef.collision_box then
		return proc_box(nodedef.collision_box)
	end

	if nodedef.drawtype == 'nodebox' then
		return proc_box(nodedef.node_box)
	end

	-- unknown, assume full node
	return get_full_node_box()
end

--[[
Grab some node information.
Returns:
 - top Y position (0..1) of any nodebox in the node
 - full node: 0=can stand in it, 1=fully occupied, -1=water
 - liquid flag: true=node is liquid, false=not liquid

NOTE: this uses node.param2 if paramtype2 one of "leveled", "colorfacedir", "facedir".
]]
-- function func.get_node_height(node)
-- 	local npos = vector.round(pos)
-- 	local node = minetest.get_node(npos)
-- 	local nodedef = minetest.registered_nodes[node.name]
-- 	if nodedef == nil then
-- 		return nil
-- 	end
--
-- 	if nodedef.walkable then
-- 		if nodedef.drawtype == 'nodebox' then
-- 			if nodedef.node_box and nodedef.node_box.type == 'fixed' then
-- 				local box = func.nodedef_get_box(nodedef, node.param2)
-- 				return npos.y + box[5], 0, false
--
-- 				if type(nodedef.node_box.fixed[1]) == 'number' then
-- 					return npos.y + nodedef.node_box.fixed[5], 0, false
-- 				elseif type(nodedef.node_box.fixed[1]) == 'table' then
-- 					return npos.y + nodedef.node_box.fixed[1][5], 0, false
-- 				else
-- 					-- TODO: handle table of boxes
-- 					return npos.y + 0.5, 1, false
-- 				end
-- 			elseif nodedef.node_box and nodedef.node_box.type == 'leveled' then
-- 				return minetest.get_node_level(npos) / 64 + npos.y - 0.5, 0, false
-- 			else
-- 				-- assume type="regular" or "connected", covers the full node
-- 				return npos.y + 0.5, 1, false
-- 			end
-- 		else
-- 			-- assume full node (type=regular)
-- 			return npos.y + 0.5, 1, false
-- 		end
-- 	else
-- 		return npos.y - 0.5, -1, (node.drawtype == 'liquid')
-- 	end
-- end

--[[
Get the seat position and facing direction for a node.
@node_pos is supposed to be the rounded position of the MOB, which is the node
that contains the legs when standing.

The node could be air, in which case, we sit in air and fall down to ground level.
The node may contain a chair/bench, in which case we will sit with a potential
adjustment to the butt position. The NPC will fall and hopefully collide with
the chair.
If the node is a bed, then we need to sit sideways on it, depending on which side
of the bed is clear.
@returns one of the following:
 - { pos=pos }               # single position, don't care the facing dir
 - { pos=pos, footvec=dir }  # single position with a single footvec
 - { { ... }, { ... } }      # array of one of the above

A position entry is returned if sitting on the ground.
A position with a facedir is returned if sitting on a chair or stair.
An array of positions with facedirs can be returned for:
 - a bench (same pos, 2 facedirs)
 - a bed (up to 5 entries)

NOTE: face_dir is nil if it doesn't matter (don't set the MOB facing direction)
If not nil, then call "self:set_yaw_by_direction(face_dir)"
]]
function func.get_seat_pos(node_pos)
	local node = minetest.get_node(node_pos)
	local butt_pos = node_pos

	-- Not collidable, so we are sitting on the node below
	if not pathfinder.is_node_collidable(node) then
		-- TODO: See if there is a low table on any of the four sides and add
		-- entries to face those. But then there should be a matt or something
		-- where we would sit.
		return {{ pos=butt_pos, npos=node_pos }}
	end

	-- See if we may need to set face_dir (chairs, benches, beds, stairs)
	local nodedef = minetest.registered_nodes[node.name]
	if nodedef.paramtype2 ~= "facedir" or bit.band(node.param2, 0x1c) ~= 0 then
		-- sit above the node, as the MOB will fall on it
		butt_pos.y = butt_pos.y + 1
		return {{ pos=butt_pos, npos=node_pos }}
	end

	-- flip 180 degrees so that this is the offset of the FEET
	local feet_p2  = bit.band(node.param2 + 2, 3)
	local foot_vec = minetest.facedir_to_dir(feet_p2)
	local head_pos = vector.subtract(node_pos, foot_vec)

	local vec = func.get_seat_offset(node.name)
	butt_pos = vector.add(butt_pos, rotate.vec_facedir(vec, feet_p2))
	local is_bed = func.is_bed(node.name)
	--log.action("func.get_seat_pos: node_pos=%s butt_pos=%s foot_vec=%s is_bed=%s head=%s",
	--	minetest.pos_to_string(node_pos),
	--	minetest.pos_to_string(butt_pos),
	--	minetest.pos_to_string(foot_vec), tostring(is_bed),
	--	minetest.pos_to_string(head_pos))

	if not is_bed then
		-- NOTE that chairs and benches are likely blocked by a table.
		-- if we check for blockage, we will need to exclude tables.
		return {{ pos=butt_pos, npos=node_pos, footvec=foot_vec }}
	end

	local results = {}

	-- rotate 90 and calc the foot-node pos (right side, bottom)
	foot_vec = rotate.vec_facedir(foot_vec, 1)
	local fpos = vector.add(node_pos, foot_vec)
	if not pathfinder.is_node_collidable(fpos) then
		table.insert(results, { pos=butt_pos, npos=node_pos, footvec=foot_vec })
	end

	-- rotate 180 and try again (left side, bottom)
	foot_vec = rotate.vec_facedir(foot_vec, 2)
	fpos = vector.add(node_pos, foot_vec)
	if not pathfinder.is_node_collidable(fpos) then
		--log.action(" -- %s %s not collidable", minetest.pos_to_string(fpos), minetest.get_node(fpos).name)
		table.insert(results, { pos=butt_pos, npos=node_pos, footvec=foot_vec })
	end
	--log.action(" -- %s %s IS collidable", minetest.pos_to_string(fpos), minetest.get_node(fpos).name)
	-- move to the head position

	-- rotate 180 and move to the bed head (right side, top)
	foot_vec = rotate.vec_facedir(foot_vec, 2)
	fpos = vector.add(head_pos, foot_vec)
	if not pathfinder.is_node_collidable(fpos) then
		--log.action(" -- %s %s not collidable", minetest.pos_to_string(fpos), minetest.get_node(fpos).name)
		table.insert(results, { pos=head_pos, npos=head_pos, footvec=foot_vec })
	end

	-- rotate 180 and move to the bed head (left side, top)
	foot_vec = rotate.vec_facedir(foot_vec, 2)
	fpos = vector.add(head_pos, foot_vec)
	if not pathfinder.is_node_collidable(fpos) then
		--log.action(" -- %s %s not collidable", minetest.pos_to_string(fpos), minetest.get_node(fpos).name)
		table.insert(results, { pos=head_pos, npos=head_pos, footvec=foot_vec })
	end

	-- rotate -90 so that feet face the bottom of the bed
	-- see if we can hang off the bottom of the bed
	foot_vec = rotate.vec_facedir(foot_vec, 1)
	fpos = vector.add(node_pos, foot_vec)
	if not pathfinder.is_node_collidable(fpos) then
		--log.action(" -- %s %s not collidable", minetest.pos_to_string(fpos), minetest.get_node(fpos).name)
		table.insert(results, { pos=node_pos, npos=node_pos, footvec=foot_vec })
	end

	-- add sitting completely on the bed, always last (as sometimes that is wanted)
	table.insert(results, { pos=head_pos, npos=head_pos, footvec=foot_vec })

	return results
end

--[[
Get all valid sit positions on the node.
For a chair, this returns func.get_seat_pos()
For a bed, this can return up to 5 entries, in this order:
 - foot, right
 - foot, left
 - head, right
 - head, left
 - head, down (fully on the bed)
The only certain sit position on a bed is the last, as it only covers the two
bed nodes. However, it will exclude any other MOB from sitting.
]]
function func.get_sit_positions(node_pos, npc)

end

local bed_head_tail = {
	-- these should have been registered with beds.register_bed()
	{ head="cottages:bed_head", tail="cottages:bed_foot" },
	{ head="cottages:sleeping_mat_head", tail="cottages:sleeping_mat" },
	-- this is not really a bed, but I wanted to try it
	{ head="cottages:straw_mat", tail="cottages:straw_mat", anydir=true },
}

local function find_adjacent_name(pos, name)
	local res = {}
	local dir = vector.new(1, 0, 0)
	-- start at 3 to skip y
	for _=3,#adjacent_pos do
		local apos = vector.add(pos, dir)
		local node = minetest.get_node(apos)
		if node.name == name then
			table.insert(res, apos)
		end
		dir = rotate.vec_facedir(dir, 1)
	end
	return res
end

--[[
Find the bottom and top of the bed. The head goes on the top_pos node.
This would be really easy.. if.. beds.register()
@return bot_pos, top_pos
]]
local function bed_find_node_pos(pos)
	local node = minetest.get_node(pos)
	if not func.is_bed(node.name) then
		--log.action("bed_find_node_pos: not bed h=%s", node.name)
		return nil, nil
	end

	local dir = minetest.facedir_to_dir(node.param2)
	--log.action("bed_find_node_pos: %s h=%s d=%s",
	--	minetest.pos_to_string(pos), node.name, minetest.pos_to_string(dir))
	for _, ii in ipairs(bed_head_tail) do
		-- special handling for old, broken bed stuff
		if node.name == ii.head then
			local bot_pos = vector.subtract(pos, dir)
			local bot_node = minetest.get_node(bot_pos)
			--log.action("bed_find_node_pos: try %s h=%s b=%s",
			--	minetest.pos_to_string(bot_pos),
			--	node.name, bot_node.name)
			if bot_node.name == ii.tail then
				--log.action("bed_find_node_pos: table h=%s b=%s", node.name, bot_node.name)
				return bot_pos, pos
			end
			if ii.anydir then
				for _=1,3 do
					dir = rotate.vec_facedir(dir, 1)
					bot_pos = vector.subtract(pos, dir)
					bot_node = minetest.get_node(bot_pos)
					--log.action("bed_find_node_pos: anydir try %s h=%s b=%s",
					--	minetest.pos_to_string(bot_pos),
					--	node.name, bot_node.name)
					if bot_node.name == ii.tail then
						--log.action("bed_find_node_pos: anydir h=%s b=%s", node.name, bot_node.name)
						return bot_pos, pos
					end
				end
			end
			--log.action("bed_find_node_pos: no tail h=%s b=%s", node.name, bot_node.name)
			return nil

		elseif node.name == ii.tail then
			-- find the associated head node
			for _, hpos in ipairs(find_adjacent_name(pos, ii.head)) do
				local hnode = minetest.get_node(hpos)
				if hnode.name == ii.head then
					-- FIXME: should make sure the head node points to the bottom
					--log.action("bed_find_node_pos: backwards h=%s b=%s", hnode.name, node.name)
					return pos, hpos
				end
			end
		end
	end

	-- explicitly disallow stray nodes
	for _, ii in ipairs(bed_head_tail) do
		if node.name == ii.head or node.name == ii.tail then
			--log.action("bed_find_node_pos: NO-stray h=%s", node.name)
			return nil
		end
	end

	-- default beds are OK, as we can only select the head/top
	--log.action("bed_find_node_pos: default h=%s", node.name)
	return pos, vector.add(pos, dir)
end

--[[
Lay down on the node at node_pos.
Better be a bed of some sort.
TODO: handle non-bed surfaces, like ground. Both nodes have to be the same height.

@return butt_pos, face_pos

NOTE: butt_pos is nil if we can't lay down at node_pos
NOTE: face_pos is nil if it doesn't matter which way we align.
]]
function func.get_lay_pos(node_pos)
	--log.warning("get_lay_pos: %s", minetest.pos_to_string(node_pos))
	-- shift pos to the bed bottom if we are on a bed top
	local bot_pos, top_pos = bed_find_node_pos(node_pos)
	if not (bot_pos and top_pos) then
		log.action("get_lay_pos: not a bed %s", minetest.pos_to_string(node_pos))
		return nil, nil
	end

	local face_dir = vector.subtract(bot_pos, top_pos)
	local node = minetest.get_node(bot_pos)
	local butt_pos = bot_pos

	--log.warning("get_lay_pos: bot=%s top=%s dir=%s",
	--	minetest.pos_to_string(bot_pos),
	--	minetest.pos_to_string(top_pos),
	--	minetest.pos_to_string(face_dir))

	-- See if we may need to set face_dir
	local nodedef = minetest.registered_nodes[node.name]
	if not nodedef or nodedef.paramtype2 ~= "facedir" or bit.band(node.param2, 0x1c) ~= 0 then
		return nil
	end

	-- shift a bit towards the head of the bed
	return vector.subtract(butt_pos, vector.multiply(face_dir, 0.4)), face_dir
end

--[[
Find the top-center of the box.
]]
function func.box_top_center(box)
	-- box = { x1, y1, z1, x2, y2, z2 }
	local function find_top_center(box)
		if box[1] > 0.2 or box[3] > 0.2 or box[4] < 0.2 or box[6] < 0.2 then
			return nil
		else
			return box
		end
	end

	local function log_center_top(def)
		local geom
		if def.collision_box and def.collision_box.type == "fixed" then
			geom = def.collision_box.fixed
		elseif def.node_box and def.node_box.type == "fixed" then
			geom = def.node_box.fixed
		end
		if not geom then
			return
		end
		log.warning("geom %s", dump(geom))
		local y_max
		if #geom > 0 and type(geom[1]) == "table" then
			-- nest table
			for _, box in ipairs(geom) do
				local yt = find_top_center(box)
				if yt and (not y_max or yt > y_max) then
					y_max = yt
				end
			end
		else
			y_max = find_top_center(geom)
		end
		log.warning("geom max_y=%s for %s", tostring(y_max), dump(geom))
	end
end
return func
