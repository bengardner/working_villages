local log = working_villages.require("log")
local func = working_villages.require("jobs/util")
local tasks = working_villages.require("job_tasks")

-- limited support to two replant definitions
-- if replant contains 1 item, it is planted on soil_wet.
-- if replant contains 2 items, the first is planted on soil_wet, the second on the first
local farming_plants = {
	names = {
		["farming:artichoke_5"]={replant={"farming:artichoke"}},
		["farming:barley_7"]={replant={"farming:seed_barley"}},
		["farming:beanpole_5"]={replant={"farming:beanpole","farming:beans"}},
		["farming:beetroot_5"]={replant={"farming:beetroot"}},
		["farming:blackberry_4"]={replant={"farming:blackberry"}},
		["farming:blueberry_4"]={replant={"farming:blueberries"}},
		["farming:cabbage_6"]={replant={"farming:cabbage"}},
		["farming:carrot_8"]={replant={"farming:carrot"}},
		["farming:chili_8"]={replant={"farming:chili_pepper"}},
		["farming:cocoa_4"]={replant={"farming:cocoa_beans"}},
		["farming:coffe_5"]={replant={"farming:coffe_beans"}},
		["farming:corn_8"]={replant={"farming:corn"}},
		["farming:cotton_8"]={replant={"farming:seed_cotton"}},
		["farming:cucumber_4"]={replant={"farming:cucumber"}},
		["farming:garlic_5"]={replant={"farming:garlic_clove"}},
		["farming:grapes_8"]={replant={"farming:trellis","farming:grapes"}},
		["farming:hemp_8"]={replant={"farming:seed_hemp"}},
		["farming:lettuce_5"]={replant={"farming:lettuce"}},
		["farming:melon_8"]={replant={"farming:melon_slice"}},
		["farming:mint_4"]={replant={"farming:seed_mint"}},
		["farming:oat_8"]={replant={"farming:seed_oat"}},
		["farming:onion_5"]={replant={"farming:onion"}},
		["farming:parsley_3"]={replant={"farming:parsley"}},
		["farming:pea_5"]={replant={"farming:pea_pod"}},
		["farming:pepper_7"]={replant={"farming:peppercorn"}},
		["farming:pineaple_8"]={replant={"farming:pineapple_top"}},
		["farming:potato_4"]={replant={"farming:potato"}},
		["farming:pumpkin_8"]={replant={"farming:pumpkin_slice"}},
		["farming:raspberry_4"]={replant={"farming:raspberries"}},
		["farming:rhubarb_3"]={replant={"farming:rhubarb"}},
		["farming:rice_8"]={replant={"farming:seed_rice"}},
		["farming:rye_8"]={replant={"farming:seed_rye"}},
		["farming:soy_7"]={replant={"farming:soy_pod"}},
		["farming:sunflower_8"]={replant={"farming:seed_sunflower"}},
		["farming:tomato_8"]={replant={"farming:tomato"}},
		["farming:vanilla_8"]={replant={"farming:vanilla"}},
		["farming:wheat_8"]={replant={"farming:seed_wheat"}},
	},
}

do
	-- invert to get a list of all possible things the farmer can plant
	local seeds = {}
	local pickups = {}
	for k, v in pairs(farming_plants.names) do
		if v.replant ~= nil then
			seeds[v.replant[1]] = "farming:soil_wet"
			pickups[v.replant[1]] = true
			if #v.replant > 1 then
				seeds[v.replant[2]] = v.replant[1]
				pickups[v.replant[2]] = true
			end
		end
	end
	farming_plants.seeds = seeds
	--log.warning("seeds: %s", dump(farming_plants.seeds))

	-- scan the harvested nodes to get a list of 'drops' that we should pick up
	for name, _ in ipairs(farming_plants.names) do
		for _, drop_name in func.get_possible_drops(name) do
			pickups[drop_name] = true
		end
	end
	farming_plants.pickups = pickups
	--log.warning("pickups: %s", dump(farming_plants.pickups))
end

-- max desired inventory for each item, default=0
local farming_demands = {
	["farming:beanpole"] = 99,
	["farming:trellis"] = 99,
}

function farming_plants.get_plant(item_name)
	-- check more priority definitions
	for key, value in pairs(farming_plants.names) do
		if item_name==key then
			return value
		end
	end
	return nil
end

-- Is this something we can plant?
function farming_plants.is_seed(item_name)
	return farming_plants.seeds[item_name] ~= nil
end

function farming_plants.is_plant(item_name)
	local data = farming_plants.get_plant(item_name);
	if (not data) then
		return false;
	end
	return true;
end

function farming_plants.is_pickup(item)
	--log.action("is_pickup: %s=%s", dump(item.name), farming_plants.pickups[item.name] == true)
	return farming_plants.pickups[item.name] == true
end

local function find_harvest_node(pos)
	local node = minetest.get_node(pos);
	local data = farming_plants.get_plant(node.name);
	if (not data) then
		return false;
	end
	return true;
end

-- Can plant in air above soil with light in a good range
local function find_plant_node(pos)
	-- the node has to be empty (air) -- FIXME: except for grapes and beans!
	local node = minetest.get_node(pos);
	if node.name ~= "air" then
		return false
	end
	-- node below has to be soil level 3 or higher
	local below = vector.new(pos.x, pos.y - 1, pos.z)
	local below_node = minetest.get_node(below);
	if minetest.get_item_group(below_node.name, "soil") < 3 then
		return false
	end
	-- light level has to be high enough -- should check farming mod for limits
	if minetest.get_node_light(pos) <= 12 then
		return false
	end
	return true
end

local searching_range = {x = 10, y = 3, z = 10}

local function put_func(_,stack)
	-- TODO: check if we have too many in the inventory
	if farming_demands[stack:get_name()] then
		return false
	end
	return true;
end
local function take_func(villager,stack)
	local item_name = stack:get_name()
	if farming_demands[item_name] then
		local inv = villager:get_inventory()
		local itemstack = ItemStack(item_name)
		itemstack:set_count(farming_demands[item_name])
		if (not inv:contains_item("main", itemstack)) then
			return true
		end
	end
	return false
end

-------------------------------------------------------------------------------

local function task_plant_seeds(self)
	while true do
		-- Do we have any seeds?
		local item_cnts = self:count_inventory_items(farming_plants.seeds)
		if next(item_cnts) == nil then
			return true
		end
		log.action("can plant: %s", dump(item_cnts))

		local node_names = {}
		for n, c in pairs(item_cnts) do
			local ss = farming_plants.seeds[n]
			if node_names[ss] == nil then
				node_names[ss] = {}
			end
			table.insert(node_names[ss], n)
		end
		log.action("We need to find %s", dump(node_names))
		-- convert the soil list for find_nodes_in_area_under_air()
		local nnam = {}
		for n, _ in pairs(node_names) do
			table.insert(nnam, n)
		end

		-- check for planting nodes
		local my_pos = vector.round(self.object:get_pos())
		local minp = vector.new(my_pos.x - 10, my_pos.y - 5, my_pos.z - 10)
		local maxp = vector.new(my_pos.x + 10, my_pos.y + 5, my_pos.z + 10)
		local grp_pos = {}
		for _, npos in ipairs(minetest.find_nodes_in_area_under_air(minp, maxp, nnam)) do
			local nn = minetest.get_node(npos).name
			if grp_pos[nn] == nil then
				grp_pos[nn] = {}
			end
			table.insert(grp_pos[nn], npos)
		end
		log.action("find_nodes_in_area_under_air: %s", dump(grp_pos))

		for tgt_name, pos_list in pairs(grp_pos) do
			local inv_set = node_names[tgt_name]
			local seed_to_plant = inv_set[math.random(#inv_set)]
			local target = vector.add(pos_list[1], {x=0,y=1,z=0})

			log.action("plant seed %s seed_to_plant @ %s", seed_to_plant, minetest.pos_to_string(target))
			self:set_displayed_action(string.format("planting %s", seed_to_plant))
			self:go_to(target,2)
			self:stand_still()
			local success, ret = self:place(seed_to_plant, target)
			self:stand_still()
			if not success then
				log.action("plant seed %s seed_to_plant @ %s FAILED %s", seed_to_plant, minetest.pos_to_string(target), ret)
				working_villages.failed_pos_record(target)
				self:set_displayed_action("confused as to why planting failed")
				self:delay_seconds(5)
			end
			self:delay_seconds(2)
		end

		return true
		---- Do we have a spot to plant?
		--local target = self.task_data.plant_pos
		--if target ~= nil then
		--	self.task_data.plant_pos = nil
		--else
		--	target = func.search_surrounding(self.object:get_pos(), find_plant_node, searching_range)
		--	if target == nil then
		--		return true
		--	end
		--end

		-- TODO: scan the surrounding nodes to try to plant the same seeds next
		-- to each other

--		-- pick a random seed to plant
--		local seed_list = {}
--		for k, c in pairs(item_cnts) do
--			table.insert(seed_list, k)
--		end
--		local seed_to_plant = seed_list[math.random(#seed_list)]
--
--		log.action("plant seed %s seed_to_plant @ %s", seed_to_plant, minetest.pos_to_string(target))
--
--		self:set_displayed_action(string.format("planting %s", seed_to_plant))
--		self:go_to(target,2)
--		self.object:set_velocity{x = 0, y = 0, z = 0}
--		local success, ret = self:place(farming_plants.is_seed, target)
--		if not success then
--			working_villages.failed_pos_record(target)
--			self:set_displayed_action("confused as to why planting failed")
--			self:delay_seconds(5)
--		end
--		self:delay_steps(2)
	end
end
working_villages.register_task("plant_seeds", { func = task_plant_seeds, priority = 35 })

local function task_harvest_and_plant(self)
	while true do
		-- Do we have a spot to plant?
		target = func.search_surrounding(self.object:get_pos(), find_harvest_node, searching_range)
		if target == nil then
			return true
		end

		local node = minetest:get_node(target)

		log.action("harvest %s @ %s", node.name, minetest.pos_to_string(target))
		self:set_displayed_action(string.format("harvesting %s @ %s", node.name, minetest.pos_to_string(target)))

		local destination = func.find_adjacent_clear(target)
		if destination then
			destination = func.find_ground_below(destination)
		end
		if destination==false then
			print("failure: no adjacent walkable found")
			destination = target
		end
		self:go_to(destination, 2)
		local plant_data = farming_plants.get_plant(node.name);
		self:dig(target,true)
		if plant_data and plant_data.replant then
			for index, value in ipairs(plant_data.replant) do
				self:place(value, vector.add(target, vector.new(0,index-1,0)))
			end
		end

		self:delay_seconds(2)
	end
end
working_villages.register_task("harvest_and_plant", { func = task_harvest_and_plant, priority = 35 })

-------------------------------------------------------------------------------

local function check_farmer(self, start_work, stop_work)
	if stop_work then
		log.action("%s: stopping work", self.inventory_name)
		self:task_del("harvest_and_plant", "done working")
		self:task_del("plant_seeds", "done working")
		self:task_del("gather_items", "done working")
		return
	end

	-- check work tasks every 5 seconds
	if start_work and func.timer(self, 5) then
		log.action("%s: farmer scan", self.inventory_name)
		-- can we gather farming stuff?
		local items = self:get_nearby_objects_by_condition(farming_plants.is_pickup)
		if #items > 0 then
			self.task_data.gather_items = {}
			for _, item in ipairs(items) do
				table.insert(self.task_data.gather_items, item)
			end
			self:task_add("gather_items")
		else
			log.action("%s: farmer didn't find any pickups", self.inventory_name)
		end

		---- check for soil nodes
		--local my_pos = vector.round(self.object:get_pos())
		--local minp = vector.new(my_pos.x - 10, my_pos.y - 5, my_pos.z - 10)
		--local maxp = vector.new(my_pos.x + 10, my_pos.y + 5, my_pos.z + 10)
		---- these are the 3 things we can plant on
		--local nnam = { "farming:soil_wet", "farming:trellis", "farming:beanpole" }
		--local grp_pos = {}
		--for _, npos in ipairs(minetest.find_nodes_in_area_under_air(minp, maxp, nnam)) do
		--	local nn = minetest.get_node(npos).name
		--	if grp_pos[nn] == nil then
		--		grp_pos[nn] = {}
		--	end
		--	table.insert(grp_pos[nn], npos)
		--end
		--log.action("find_nodes_in_area_under_air: %s", dump(grp_pos))

		---- see if we can plant something
		--local item_cnts = self:count_inventory_items(farming_plants.seeds)
		--if next(item_cnts) ~= nil then
		--	-- We can plant something
		--	local target = func.search_surrounding(self.object:get_pos(), find_plant_node, searching_range)
		--	if target ~= nil then
		--		self.task_data.plant_pos = target
		--		self:task_add("plant_seeds")
		--	else
		--		log.action("%s: farmer didn't find a plant spot", self.inventory_name)
		--	end
		--else
		--	log.action("%s: farmer doesn't have seeds", self.inventory_name)
		--end
		self:task_add("plant_seeds")

		-- see if we can harvest anything
		local target = func.search_surrounding(self.object:get_pos(), find_harvest_node, searching_range)
		if target ~= nil then
			self.task_data.harvest_pos = target
			self:task_add("harvest_and_plant")
		else
			log.action("%s: farmer didn't find anything to harvest", self.inventory_name)
		end
	end

	-- storing in chest if full or day is over and we have some leftover
	if false then
		-- check to see if we have "too much" inventory
		if find_chest(self) ~= nil then
			self:task_add("store_in_chest")
		end
	end
end

-- REVISIT: It is looking like we only need 'check_farmer()' for the job.
-- The other stuff is generic. Maybe a single 'job check' that calls the right
-- function based on the job
local function farmer_logic(self)
	if func.timer(self, 1) then
		local names = tasks.check_schedule(self)

		log.action("%s: work_start=%s work_stop=%s", self.inventory_name, names.work_start, names.work_stop)

		check_farmer(self, names.work_start, names.work_stop)

		-- make sure the idle task is present
		tasks.check_idle(self)
	end
end

working_villages.register_job("working_villages:job_farmer", {
	description			= "farmer (working_villages)",
	long_description = "I look for farming plants to collect and replant them.",
	inventory_image	= "default_paper.png^working_villages_farmer.png",
	logic = farmer_logic,
	jobfunc = function(self)
		self:handle_night()
		self:handle_chest(take_func, put_func)
		self:handle_job_pos()

		self:count_timer("farmer:search")
		self:count_timer("farmer:change_dir")
		self:handle_obstacles()
		if self:timer_exceeded("farmer:search",20) then
			self:collect_nearest_item_by_condition(farming_plants.is_plant, searching_range)
			local target = func.search_surrounding(self.object:get_pos(), find_harvest_node, searching_range)
			if target ~= nil then
				local destination = func.find_adjacent_clear(target)
				if destination then
					destination = func.find_ground_below(destination)
				end
				if destination==false then
					print("failure: no adjacent walkable found")
					destination = target
				end
				self:go_to(destination)
				local plant_data = farming_plants.get_plant(minetest.get_node(target).name);
				self:dig(target,true)
				if plant_data and plant_data.replant then
					for index, value in ipairs(plant_data.replant) do
						self:place(value, vector.add(target, vector.new(0,index-1,0)))
					end
				end
			end
		elseif self:timer_exceeded("farmer:change_dir",50) then
			self:change_direction_randomly()
		end
	end,
})

working_villages.farming_plants = farming_plants
