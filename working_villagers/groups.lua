--[[
Add some groups to certain nodes.
]]

local function add_group(node_name, node_def, group_name, value)
	local groups = table.copy(node_def.groups)
	groups[group_name] = value
	minetest.override_item(node_name, {groups=groups})
end

local function fixup_groups()
	-- search all nodes for matches
	for name, def in pairs(minetest.registered_nodes) do
		if string.find(name, "chair_") or string.find(name, "_chair") then
			add_group(name, def, "chair", 1)
		elseif string.find(name, "bench_") or string.find(name, "_bench") then
			add_group(name, def, "bench", 1)
		elseif string.find(name, "furniture") and string.find(name, "_table") then
			add_group(name, def, "table", 1)
		end
		-- TODO: mark other furniture or things used by villagers...
		-- Examples: plantable objects? harvestable?
	end

	-- add groups for some nodes to be managed by working_villagers
	local list_of_doors = {
		"doors:door_wood_a",
		"doors:door_wood_c"
	}

	for _,name in pairs(list_of_doors) do
		local item_def = minetest.registered_items[name]
		if (item_def~=nil) then
			local groups = table.copy(item_def.groups)
			groups.villager_door = 1
			minetest.override_item(name, {groups=groups})
		end
	end

	local list_of_chests = {
		"default:chest"
	}

	for _,name in pairs(list_of_chests) do
		local item_def = minetest.registered_items[name]
		if (item_def~=nil) then
			local groups = table.copy(item_def.groups)
			groups.villager_chest = 1
			minetest.override_item(name, {groups=groups})
		end
	end

	local list_of_bed_top = {
		"beds:bed_top"
	}
	for _,name in pairs(list_of_bed_top) do
		local item_def = minetest.registered_items[name]
		if (item_def~=nil) then
			local groups = table.copy(item_def.groups)
			groups.villager_bed_top = 1
			minetest.override_item(name, {groups=groups})
		end
	end

	local list_of_bed_bottom = {
		"beds:bed_bottom"
	}
	for _,name in pairs(list_of_bed_bottom) do
		local item_def = minetest.registered_items[name]
		if (item_def~=nil) then
			local groups = table.copy(item_def.groups)
			groups.villager_bed_bottom = 1
			minetest.override_item(name, {groups=groups})
		end
	end
end

-- call the function after all mods have been loaded
minetest.register_on_mods_loaded(fixup_groups)
