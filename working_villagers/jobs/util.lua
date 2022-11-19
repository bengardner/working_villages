local func = {}
local pathfinder = working_villages.require("nav/pathfinder")
local log = working_villages.require("log")

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

-- vec components can be omitted e.g. vec={y=1}
function func.pos_shift(pos, vec)
	return vector.new(pos.x + (vec.x or 0), pos.y + (vec.y or 0), pos.z + (vec.z or 0))
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
	return func.pos_shift(pos,{y=colbox[2]+0.01}), pos
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
Pick an item from the 'read-only' array.
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

return func
