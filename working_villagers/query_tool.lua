--[[
A tool to display information about a node.
]]
local wayzone_utils = working_villages.require("wayzone_utils")

local tool_name = "working_villages:query_tool"

local function expand_bounds(bounds, pos)
	if bounds.minp == nil then
		bounds.minp = vector.new(pos)
	else
		bounds.minp.x = math.min(bounds.minp.x, pos.x)
		bounds.minp.y = math.min(bounds.minp.y, pos.y)
		bounds.minp.z = math.min(bounds.minp.z, pos.z)
	end

	if bounds.maxp == nil then
		bounds.maxp = vector.new(pos)
	else
		bounds.maxp.x = math.max(bounds.maxp.x, pos.x)
		bounds.maxp.y = math.max(bounds.maxp.y, pos.y)
		bounds.maxp.z = math.max(bounds.maxp.z, pos.z)
	end
end


--[[
Determine if the node @ pos is part of a real tree or if someone built a
house out of it.

Find all the trunk nodes and explore all neighbors.
If we have tree nodes AND we have leave nodes then it is a tree.
If we have tree nodes AND NO leave nodes AND collidable nodes are at or below
the base, then it is a tree.

TODO: the woodcutter will call this when searching for a tree.
It will save the trunk and leave position tables.
It will then go to the base of the tree and do the cutting action.
If will randomly cut a leaves or tree node from the end of the lists until
both are empty. Then it will discard the tree info.
]]
local function query_check_tree(start_pos)
	-- This is essentially a flood-fill pathfinder on the tree.
	local trunk_pos = {}
	local leaves_pos = {}
	local tree_bounds = {}
	local other_bounds = {}

	local openSet = {}
	local visitedSet = {}

	-- add a neighbor 'tree' to further explore
	local function add_open(npos)
		local hash = minetest.hash_node_position(npos)
		if visitedSet[hash] == nil and openSet[hash] == nil then
			openSet[hash] = { pos=npos, node=minetest.get_node(npos) }
		end
	end

	add_open(start_pos)
	while next(openSet) ~= nil do
		local workset = openSet
		openSet = {}

		for hash, item in pairs(workset) do
			if visitedSet[hash] == nil then
				visitedSet[hash] = true
				local node = item.node
				local pos = item.pos

				if minetest.get_item_group(node.name, "tree") > 0 then
					--minetest.log("warning", string.format("tree: %s %s", minetest.pos_to_string(item.pos), item.node.name))
					expand_bounds(tree_bounds, pos)
					table.insert(trunk_pos, pos)

					-- Explore 26 neighbors
					for dx = -1, 1 do
						for dy = -1, 1 do
							for dz = -1, 1 do
								if dx ~= 0 or dy ~= 0 or dz ~= 0 then
									add_open(vector.new(pos.x+dx, pos.y+dy, pos.z+dz))
								end
							end
						end
					end
				elseif minetest.get_item_group(node.name, "leaves") > 0 then
					expand_bounds(tree_bounds, pos)
					table.insert(leaves_pos, pos)
				elseif item.node.name == "air" then
					-- ignore air
				else
					local nodedef = minetest.registered_nodes[item.node.name]
					if nodedef.walkable then
						--minetest.log("warning", string.format("tree: NOT %s %s", minetest.pos_to_string(item.pos), item.node.name))
						expand_bounds(other_bounds, item.pos)
					end
				end
			end
		end
	end

	-- Shouldn't have been called on a non-tree node, but whatever.
	if #trunk_pos == 0 then
		return false
	end

	-- sort by Y, X, Z (lesser first)
	local function pos_sort(n1, n2)
		if n1.y < n2.y then return true end
		if n1.y > n2.y then return false end
		if n1.x < n2.x then return true end
		if n1.x > n2.x then return false end
		return n1.z < n2.z
	end
	table.sort(trunk_pos, pos_sort)
	table.sort(leaves_pos, pos_sort)

	-- Check for floating tree first, as we can't do the next log if minp=nil
	if other_bounds.minp == nil then
		return true, trunk_pos, leaves_pos
	end

	minetest.log("action", string.format("tree: %s min=%s max=%s logs=%d leaves=%d other=%s-%s",
			minetest.pos_to_string(trunk_pos[1]),
			minetest.pos_to_string(tree_bounds.minp),
			minetest.pos_to_string(tree_bounds.maxp),
			#trunk_pos, #leaves_pos,
			minetest.pos_to_string(other_bounds.minp),
			minetest.pos_to_string(other_bounds.maxp)))

	-- If we have leaves or the "ground" is at the same level or lower than walkable nodes
	if #leaves_pos > 0 or other_bounds.maxp.y <= tree_bounds.minp.y then
		return true, trunk_pos, leaves_pos
	end
	-- probably part of a building, farm wall, etc
	return false, trunk_pos
end

local function query_tool_do_stuff(user, pointed_thing, is_use)
	if (pointed_thing.type == "node") then
		local pos = minetest.get_pointed_thing_position(pointed_thing)
		local node = minetest.get_node(pos)
		local nodedef = minetest.registered_nodes[node.name]
		minetest.log("action",
			string.format("query_tool: node @ %s name='%s' param1=%s param2=%s",
				minetest.pos_to_string(pos), node.name, node.param1, node.param2))
		if not is_use then
			wayzone_utils.log_table("query_tool: node def", nodedef)
		end
		if minetest.get_item_group(node.name, "tree") > 0 then
			local ret, trunk_pos, leave_pos = query_check_tree(pos)
			if ret == true then
				minetest.log("action",
					string.format("query_tool: part of a tree @ %s with %d trunk and %d leaves nodes",
						minetest.pos_to_string(trunk_pos[1]), #trunk_pos, #leave_pos))
			end
		end

	elseif (pointed_thing.type == "object") then
		local ent = pointed_thing.ref:get_luaentity()
		minetest.log("action",
			string.format("query_tool: object @ %s [%s]",
				minetest.pos_to_string(ent.object:get_pos()),
				ent.itemstring or ent.product_name or "unknown"))
		if not is_use then
			wayzone_utils.log_table("query_tool: luaentity", ent)
		end
	else
		minetest.log("action", string.format("query_tool: type=%s", pointed_thing.type))
	end
end

minetest.register_tool(tool_name, {
	description = "Working Villagers Query Tool",
	inventory_image = "query_tool.png",
	range = 16,

	on_place = function(itemstack, placer, pointed_thing)
		query_tool_do_stuff(placer, pointed_thing, false)
		return itemstack
	end,

	on_use = function(itemstack, user, pointed_thing)
		query_tool_do_stuff(user, pointed_thing, true)
		return itemstack
	end,

	on_secondary_use = function(itemstack, user, pointed_thing)
		query_tool_do_stuff(user, pointed_thing, false)
		return itemstack
	end,
})
