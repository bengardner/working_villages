--[[
Scans a tree.
Identifies all 'tree' and 'leaves' nodes.
]]
local tree_scan = {}

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
function tree_scan.check_tree(start_pos)
	-- This is essentially a flood-fill pathfinder on the tree.
	local trunk_pos = {}
	local leaves_pos = {}
	local other_maxy
	local tree_miny

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
					--minetest.log("warning", string.format("tree: %s %s", minetest.pos_to_string(pos), item.node.name))
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
					table.insert(leaves_pos, pos)
				elseif item.node.name == "air" then
					-- ignore air
				else
					local nodedef = minetest.registered_nodes[item.node.name]
					if nodedef.walkable then
						--minetest.log("warning", string.format("tree: NOT %s %s", minetest.pos_to_string(pos), item.node.name))
						if other_maxy == nil or pos.y > other_maxy then
							other_maxy = pos.y
						end
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

	minetest.log("action", string.format("tree: %s other_maxy=%d tree=%d leaves=%d",
			minetest.pos_to_string(trunk_pos[1]),
			tostring(other_maxy), #trunk_pos, #leaves_pos))

	-- If we have leaves or the "ground" is at the same level or lower than walkable nodes
	if other_maxy == nil or #leaves_pos > 0 or other_maxy <= trunk_pos[1].y then
		return true, trunk_pos, leaves_pos
	end
	-- probably part of a building, farm wall, etc
	return false, trunk_pos
end

return tree_scan
