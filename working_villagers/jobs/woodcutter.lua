local func = working_villages.require("jobs/util")

local function find_tree(p)
	local adj_node = minetest.get_node(p)
	if minetest.get_item_group(adj_node.name, "tree") > 0 then
		return true
	end
	return false
end

local function is_sapling(n)
	local name
	if type(n) == "table" then
		name = n.name
	else
		name = n
	end
	if minetest.get_item_group(name, "sapling") > 0 then
		return true
	end
	return false
end

local function is_sapling_spot(pos)
	local node = minetest.get_node(pos)
	if node.name ~= "air" then return false end
	local lpos = vector.add(pos, {x = 0, y = -1, z = 0})
	local lnode = minetest.get_node(lpos)
	if minetest.get_item_group(lnode.name, "soil") == 0 then return false end
	local light_level = minetest.get_node_light(pos)
	if light_level <= 12 then return false end
	return true
end

local searching_range = {x = 10, y = 10, z = 10, h = 5}

working_villages.register_job("working_villages:job_woodcutter", {
	description      = "woodcutter (working_villages)",
	long_description = "I look for any Tree trunks around and chop them down.\
I might also chop down a house. Don't get angry please I'm not the best at my job.\
When I find a sappling I'll plant it on some soil near a bright place so a new tree can grow from it.",
	inventory_image  = "default_paper.png^working_villages_woodcutter.png",
	jobfunc = function(self)
		self:handle_night()
		self:handle_job_pos()

		self:count_timer("woodcutter:search")
		self:count_timer("woodcutter:change_dir")
		self:handle_obstacles()
		if self:timer_exceeded("woodcutter:search",20) then
			self:collect_nearest_item_by_condition(is_sapling, searching_range)
			local wield_stack = self:get_wield_item_stack()
			if is_sapling(wield_stack:get_name()) or self:has_item_in_main(is_sapling) then
				local target = func.search_surrounding(self.object:get_pos(), is_sapling_spot, searching_range)
				if target ~= nil then
					local destination = func.find_adjacent_clear(target)
					if destination==false then
						print("failure: no adjacent walkable found")
						destination = target
					end
					self:set_displayed_action("planting a tree")
					self:go_to(destination)
					self:place(is_sapling, target)
				end
			end
			local target = func.search_surrounding(self.object:get_pos(), find_tree, searching_range)
			if target ~= nil then
				local destination = func.find_adjacent_clear(target)
				destination = func.find_ground_below(destination)
				if destination==false then
					print("failure: no adjacent walkable found")
					destination = target
				end
				self:set_displayed_action("cutting a tree")
				self:go_to(destination)
				self:dig(target,true)
			end
			self:set_displayed_action("looking for work")
		elseif self:timer_exceeded("woodcutter:change_dir",50) then
			self:change_direction_randomly()
		end
	end,
})
