--[[
A little cache for node collision boxes.

The function `get_node_info(node)` returns the useful info.

There are several keys in the results:
 - top   : floor height for standing in the node
 - top_n : floor height for entering the node from the north (missing=nothing there)
 - top_s, top_e, top_w : other directions
 - bot   : ceiling height for standing in the node
 - bot_x : ceiling height for entering the node from the north
 - bot_s, top_e, top_w : other directions

If top is nil, then this uses the default node (full).
If top is not nil, the all fields should be populated.

The function `get_stand_height(pos, max_height, dir)` uses the above function to
give the Y position of the floor at that node and the height that is empty up to
max_height.
@max_height limits the upward scan, which may involve several nodes.
@dir is nil for the stand height or "n", "s", "e", "w" or a direction vector()
to indicate which side it desired.

The function `can_move_to(pos, dir, height, jump_height, fear_height)` evaluates
whether a transition can be made. It basically calls `get_stand_height()`
a few times to evaluate:
 1. to get the stand height in the start node
 2. to get the stand height in the target node
 3. to get the exit/enter heights in both the start and target (same side)

It then checks the heights against the parameters to determine if the move is
possible.
This function is key to a pathfinder that can handle nodes with custom collision
boxes.
]]
local rotate = working_villages.require("nav/rotate")
local log = working_villages.require("log")

local node_cbox_cache = {}

local function box_tostring(box)
	return string.format("(%s,%s,%s,%s,%s,%s)", box[1], box[2], box[3], box[4], box[5], box[6])
end

--[[
Reduces an array of boxes to the min/max of all.
If @boxes[1] is a number, this returns @boxes unaltered.
Returns nil if @boxes is not a table or it is an empty array.
]]
local function box_minmax(boxes)
	if type(boxes) ~= "table" or #boxes == 0 then
		return nil
	end
	if type(boxes[1]) == "number" then
		return boxes
	end
	local nb = table.copy(boxes[1])
	for idx=2, #boxes do
		local bb = boxes[idx]
		for ii=1,3 do
			nb[ii] = math.min(nb[ii], bb[ii])
			nb[ii+3] = math.max(nb[ii+3], bb[ii+3])
		end
	end
	return nb
end
node_cbox_cache.box_minmax = box_minmax

-- does a box intersection. this returns nil (not overlap) or a valid box
local function box_intersection(box1, box2)
	-- check for any possible overlap
	if box1[1] > box2[4] or box2[1] > box1[4]
	or box1[2] > box2[5] or box2[2] > box1[5]
	or box1[3] > box2[6] or box2[3] > box1[6]
	then
		return nil
	end
	local res = {
		math.max(box1[1], box2[1]),
		math.max(box1[2], box2[2]),
		math.max(box1[3], box2[3]),
		math.min(box1[4], box2[4]),
		math.min(box1[5], box2[5]),
		math.min(box1[6], box2[6])
	}
	log.action("box_inter %s %s => %s", box_tostring(box1), box_tostring(box2), box_tostring(res))
	return res
end

--[[
Find the min and max Y at the x/z coordinates (-0.5 to 0.5)
]]
local function box_y_probe(cboxes, box)
	if type(cboxes) ~= "table" or #cboxes == 0 then
		return nil
	end
	if type(cboxes[1]) == "table" then
		local miny, maxy
		for _, cbox in ipairs(cboxes) do
			local ibox = box_intersection(cbox, box)
			if ibox then
				miny = math.min(miny or 100, ibox[2])
				maxy = math.max(maxy or -100, ibox[5])
			end
		end
		return miny, maxy
	end

	-- return min/max y if x,z fall in the box
	local ibox = box_intersection(cboxes, box)
	if ibox then
		return ibox[2], ibox[5]
	end
	return nil
end
node_cbox_cache.box_y_probe = box_y_probe

-- returns a new box that occupies the whole node (1x1x1)
local function get_full_node_box()
	return {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}
end

local function get_param2_mask(nodedef)
	local p2m
	if type(nodedef) == "string" then
		nodedef = minetest.registered_nodes[nodedef]
	end
	if nodedef then
		if nodedef.paramtype2 == "facedir" or nodedef.paramtype2 == "colorfacedir" then
			p2m = 0x1f
		elseif nodedef.paramtype2 == "4dir" or nodedef.paramtype2 == "color4dir" then
			p2m = 0x03
		elseif nodedef.paramtype2 == "wallmounted" or nodedef.paramtype2 == "colorwallmounted" then
			p2m = 0x03
		end
	end
	return p2m
end
node_cbox_cache.get_param2_mask = get_param2_mask

-- mask the param2 value if used. returns nil if no rotation
local function trim_param2(nodedef, param2)
	local p2
	local p2m = get_param2_mask(nodedef)
	if p2m then
		p2 = bit.band(param2, p2m)
	end
	return p2
end

--[[
Get a rotated collision box.
returns is_full, cbox, p2 or nil
]]
local function node_get_collision_box(node, simplify)
	local nodedef = minetest.registered_nodes[node.name]
	local param2 = node.param2

	-- unknown nodes are fully collidable
	if not nodedef then
		return true, get_full_node_box(), nil
	end

	-- check for no collisions first
	if not nodedef.walkable then
		return false, nil, nil
	end

	-- collision_box and node_box are processed the same
	local function proc_box(cbox)
		if cbox.type == "fixed" then
			local box = cbox.fixed
			if simplify == true then
				box = box_minmax(box)
			end
			local p2 = trim_param2(nodedef, param2)
			if p2 and p2 > 0 then
				box = rotate.box_facedir(box, p2)
			end
			return false, box, p2
		elseif cbox.type == "leveled" and nodedef.paramtype2 == "leveled" then
			local box = func.box_minmax(cbox.fixed)
			box[2] = -0.5
			box[5] = param2 / 64 - 0.5
			return false, box, param2
		else
			return true, get_full_node_box(), nil
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
	return true, get_full_node_box(), nil
end
node_cbox_cache.node_get_collision_box = node_get_collision_box

-------------------------------------------------------------------------------

local info_cache = {}

-- split for edges: 0.2 + 0.6 + 0.2 (left, middle, right)
local box_xy = {
	[""]   = { -0.50, -0.50, -0.50,  0.50, 0.50,  0.50 }, -- full
	["_n"] = { -0.50, -0.50,  0.30,  0.50, 0.50,  0.50 }, -- on north side (+Z)
	["_s"] = { -0.50, -0.50, -0.50,  0.50, 0.50, -0.30 }, -- on sorth side (-Z)
	["_e"] = {  0.30, -0.50, -0.50,  0.50, 0.50,  0.50 }, -- on east side (+X)
	["_w"] = { -0.50, -0.50, -0.50, -0.30, 0.50,  0.50 }, -- on west side (-X)
}

-- accepts a node (table) or a node name (string)
local function get_node_info(node)
	if type(node) == "string" then
		node = { name=node, param2=0 }
	end
	local info = info_cache[node.name]

	-- handle cached results
	if info == true then
		log.action("get_node_info: %s -> true", node.name)
		return {} -- defaults
	elseif info == false then
		log.action("get_node_info: %s -> false", node.name)
		return nil -- no collisions
	elseif info == nil then
		info = {}
		info_cache[node.name] = info
		log.action("get_node_info: %s -> creating", node.name)
	else
		local p2
		if info.norot then
			p2 = 0
		else
			p2 = trim_param2(minetest.registered_nodes[node.name], node.param2)
		end
		local ni = info[p2]
		if ni ~= nil then
			log.action("get_node_info: %s -> cached %s", node.name, p2)
			return ni
		end
	end

	local nodedef = minetest.registered_nodes[node.name]

	-- Did we already calculate the cbox?
	if info.cbox == nil then
		-- get the cbox with no rotation
		local dummy_node = { name = node.name, param1=0, param2=0 }
		local is_full, cbox, p2 = node_get_collision_box(dummy_node, false)
		if is_full then
			info_cache[node.name] = true -- full, no need to mess with cbox
			log.action("get_node_info: %s -> create true", node.name)
			return {}
		elseif not cbox then
			info_cache[node.name] = false -- no cbox
			log.action("get_node_info: %s -> create false", node.name)
			return nil
		end
		if not p2 then
			info.norot = true
			log.action("get_node_info: %s -> create norot", node.name)
		end

		-- double check for a full box (should be done in node_get_collision_box())
		--local cbox_mm = box_minmax(cbox)
		--if cbox_mm[1] <= -0.5 and cbox_mm[2] <= -0.5 and cbox_mm[3] <= -0.5 and
		--   cbox_mm[4] >= 0.5 and cbox_mm[5] >= 0.5 and cbox_mm[6] >= 0.5
		--then
		--	info_cache[node.name] = true
		--	log.action("get_node_info: %s -> create true check", node.name)
		--	return {}
		--end
		info.cbox = cbox
		log.action("get_node_info: %s -> create cbox %s", node.name, dump(cbox))
	end

	local p2
	if info.norot then
		p2 = 0
	else
		p2 = trim_param2(nodedef, node.param2)
	end

	local cbox = info.cbox
	if p2 > 0 then
		cbox = rotate.box_facedir(cbox, p2)
	end
	log.action("get_node_info: %s -> rotate cbox %s", node.name, dump(cbox))

	local ni = {}
	for k, v in pairs(box_xy) do
		log.action("probe %s %s", k, box_tostring(v))
		ni['bot'..k], ni['top'..k] = box_y_probe(cbox, v)
	end
	-- see if we can add "top_all" and "bot_all"
	ni.top_all = true
	for k, v in pairs(ni) do
		if k ~= "top" and string.find(k, "top") == 1 then
			if v ~= ni.top then
				ni.top_all = false
				break
			end
		end
	end
	ni.bot_all = true
	for k, v in pairs(ni) do
		if k ~= "bot" and string.find(k, "bot") == 1 then
			if v ~= ni.bot then
				ni.bot_all = false
				break
			end
		end
	end

	info[p2] = ni
	return ni
end
node_cbox_cache.get_node_info = get_node_info

return node_cbox_cache
