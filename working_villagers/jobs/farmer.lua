local log = working_villages.require("log")
local func = working_villages.require("jobs/util")
local tasks = working_villages.require("job_tasks")
local wayzone_store = working_villages.require("nav/wayzone_store")

-- limited support to two replant definitions
-- if replane contains 0 items, it is harvested and not replanted.
-- if replant contains 1 item, it is planted on soil_wet.
-- if replant contains 2 items, the first is planted on soil_wet, the second on the first
-- if replant is present, it is assumed that the scythe_mithril will work.
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
		-- harvest, but no replant
		["default:blueberry_bush_leaves_with_berries"]={},
		["default:apple"]={},
		["bushes:blackberry_bush"]={},
		["bushes:blueberry_bush"]={},
		["bushes:gooseberry_bush"]={},
		["bushes:raspberry_bush"]={},
		["bushes:strawberry_bush"]={},
	},
}

--[[ This is max desired inventory for each item, default=0.
The farmer will adjust the inventory of each when visiting the chest.
The inventory cannot hold all the various seeds, but the farmer should hold
onto at least a few seeds for planting.
]]
local farming_demands = {
	["farming:beanpole"] = 99,
	["farming:trellis"] = 99,
	["group:hoe"] = 2,
	["farming:scythe_mithril"] = 1,
}

-- add pickups based on farming_demands
local function farmer_add_pickups(pickups)
	local new_fd = {}
	for k, v in pairs(farming_demands) do
		if string.sub(k, 1, 6) == "group:" then
			for _, n in ipairs(func.find_tools_by_group(string.sub(k, 7))) do
				pickups[n] = true
				new_fd[n] = v
			end
		else
			new_fd[k] = v
			pickups[k] = true
		end
	end
	farming_demands = new_fd
end

do
	-- invert to get a list of all possible things the farmer can plant and pickup
	local seeds = {}
	local pickups = {}

	farmer_add_pickups(pickups)
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

function farming_plants.get_plant(item_name)
	return farming_plants.names[item_name]

	---- check more priority definitions
	--for key, value in pairs(farming_plants.names) do
	--	if item_name==key then
	--		return value
	--	end
	--end
	--return nil
end

-- Is this something we can plant?
function farming_plants.is_seed(item_name)
	return farming_plants.seeds[item_name] ~= nil
end

-- note used
function farming_plants.is_plant(item_name)
	return farming_plants.get_plant(item_name) ~= nil
end

-- test if the farmer should pick up item, which is a table ItemStack
function farming_plants.is_pickup(item)
	return farming_plants.pickups[item.name] == true
end

-- tests if this is something we know how to harvest
local function find_harvest_node(pos)
	local node = minetest.get_node(pos);
	return farming_plants.get_plant(node.name) ~= nil
end

local searching_range = {x = 10, y = 3, z = 10}

-- REVISIT: not used yet
local function put_func(_, stack)
	-- TODO: check if we have too many in the inventory
	local max_cnt = farming_demands[stack:get_name()]
	if not max_cnt then
		return false
	end
	return stack:get_count() <= max_cnt
end

-- REVISIT: not used yet
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

--[[ Remember the position as somewhere that we harvested or planted.
The position is rounded to a 8x8x8 node box.
The farmer will revisit the oldest previous locations during working hours and
refresh the position if something was planted or harvested.
These should time out after a few days in game time.
]]
local function remember_farming_pos(self, pos)
	self:remember_area("farming_pos", pos)
end

local function recall_farming_pos(self)
	return self:recall_area("farming_pos")
end

local function forget_farming_pos(self, pos)
	return self:forget_area_pos("farming_pos", pos)
end

-------------------------------------------------------------------------------

local function task_plant_seeds(self)
	while true do
		local did_one = false

		-- Do we have any seeds?
		local item_cnts = self:count_inventory_items(farming_plants.seeds)
		if next(item_cnts) == nil then
			return true
		end
		--log.action("can plant: %s", dump(item_cnts))

		-- collect the node names that we can plant on depending on the seeds.
		-- "soil_wet", "farming:trellis", "farming:beanpole"
		local node_names = {}
		for n, c in pairs(item_cnts) do
			local ss = farming_plants.seeds[n]
			if node_names[ss] == nil then
				node_names[ss] = {}
			end
			table.insert(node_names[ss], n)
		end
		--log.action("We need to find %s", dump(node_names))
		-- convert the soil list for find_nodes_in_area_under_air()
		local nnam = {}
		for n, _ in pairs(node_names) do
			table.insert(nnam, n)
		end

		-- check for planting nodes
		local my_pos = vector.round(self.object:get_pos())
		-- revisit: use searching_range??
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
		--log.action("find_nodes_in_area_under_air: %s", dump(grp_pos))

		-- iterate over the target planting nodes (soil/trellis/beanpole)
		for tgt_name, pos_list in pairs(grp_pos) do
			local inv_set = node_names[tgt_name]
			local target = vector.add(pos_list[1], {x=0,y=1,z=0})

			-- randomly pick a seed to plant
			-- FIXME: We should check which plants are nearby and try to match.
			local seed_to_plant = inv_set[math.random(#inv_set)]

			log.action("plant seed %s seed_to_plant @ %s", seed_to_plant, minetest.pos_to_string(target))
			self:set_displayed_action(string.format("planting %s", seed_to_plant))
			self:go_to(target, 1)
			self:stand_still()
			local success, ret = self:place(seed_to_plant, target)
			self:stand_still()
			if not success then
				log.action("plant seed %s seed_to_plant @ %s FAILED %s", seed_to_plant, minetest.pos_to_string(target), ret)
				working_villages.failed_pos_record(target)
				self:set_displayed_action("confused as to why planting failed")
				self:delay_seconds(5)
			else
				remember_farming_pos(self, self.object:get_pos())
				self:delay_seconds(2)
				did_one = true
			end
		end

		if not did_one then
			return true
		end
	end
end
working_villages.register_task("plant_seeds", { func = task_plant_seeds, priority = 35 })

--[[ This task will harvest and then replant.
It is assumed that the harvesting will drop a seed, so we shouldn't run out.
]]
local function task_harvest_and_plant(self)
	while true do
		-- Do we have a spot to plant?
		local target = func.search_surrounding(self.object:get_pos(), find_harvest_node, searching_range)
		if target == nil then
			return true
		end
		target = vector.round(target)

		local node_name = minetest.get_node(target).name

		log.action("%s: harvest %s @ %s", self.inventory_name, node_name, minetest.pos_to_string(target))
		self:set_displayed_action(string.format("harvesting %s @ %s", node_name, minetest.pos_to_string(target)))

		local destination = func.find_adjacent_clear(target)
		if destination then
			destination = func.find_ground_below(destination)
		end
		if destination==false then
			print("failure: no adjacent walkable found")
			destination = target
		end
		self:go_to(destination, 2)

		local plant_data = farming_plants.get_plant(node_name);
		--log.action("digging node=%s @ %s", node_name, minetest.pos_to_string(target))
		self:dig(target,true)
		remember_farming_pos(self, self.object:get_pos())
		if plant_data and plant_data.replant then
			self:delay_seconds(1)
			for index, value in ipairs(plant_data.replant) do
				log.action("%s: planting %s @ %s", self.inventory_name, value, minetest.pos_to_string(target))
				self:place(value, vector.add(target, vector.new(0,index-1,0)))
			end
		end
		self:stand_still()
		self:delay_seconds(2)
	end
end
working_villages.register_task("harvest_and_plant", { func = task_harvest_and_plant, priority = 40 })

-- test to see if the item is a hoe by checking for the 'hoe' group
local function is_hoe(item)
	local name = func.resolve_item_name(item)
	if name and name ~= "" then
		return minetest.get_item_group(name, "hoe") > 0
	end
	return false
end

--[[ Searches for soil under air that is within 3 nodes of water.
So, find "group:soil" and

"bucket:bucket_empty" => find water source to get water (between 2 water sources)
"bucket:bucket_water" => can use in trenches in dirt to make farmland (need protection!)
"bucket:bucket_river_water" => same as "bucket:bucket_water"

1. Need something to designate farmland.
Build something like this:
 toooooooot
 oXXXXXXXXo
 oXXXXXXXXo
 tXXwwwwXXt
 oXXXXXXXXo
 oXXXXXXXXo
 toooooooot
o=outline (cobblestone or log)
t=torch over the outline
X=dirt/dirt_wet/farmland
w=water in trench (same level as dirt)
]]
local function task_farmer_till(self)
	while true do
		-- try to equip a hoe
		self:move_main_to_wield(is_hoe)
		local tool = self:get_wielded_item()
		if not is_hoe(tool) then
			-- need a hoe to till, so we are done
			log.action("%s: no hoe, no till", self.inventory_name)
			return true
		end
		--log.action("%s: farmer_till wielding %s", self.inventory_name, tool:get_name())

		local my_pos = vector.round(self.object:get_pos())
		local minp = vector.new(my_pos.x - 10, my_pos.y - 5, my_pos.z - 10)
		local maxp = vector.new(my_pos.x + 10, my_pos.y + 5, my_pos.z + 10)
		local nnam = { "group:water" }
		local water_nodes = minetest.find_nodes_in_area_under_air(minp, maxp, nnam)

		-- gather all the potential hoe spots
		local checked_soil = {}
		for _, wpos in ipairs(water_nodes) do
			--log.action("water @ %s", minetest.pos_to_string(wpos))
			minp = vector.offset(wpos, -2, 0, -2)
			maxp = vector.offset(wpos, 2, 0, 2)
			local dirt_nodes = minetest.find_nodes_in_area_under_air(minp, maxp, { "group:soil" })
			for _, dpos in ipairs(dirt_nodes) do
				local hash = minetest.hash_node_position(dpos)
				if checked_soil[hash] == nil then
					checked_soil[hash] = true
				end
			end
		end

		for hash, _ in pairs(checked_soil) do
			local pos = minetest.get_position_from_hash(hash)
			local node = minetest.get_node(pos)
			if minetest.get_item_group(node.name, "soil") == 1 then
				-- under is the soil node, above is the air above the soil
				local pointed_thing = { type="node", above=vector.offset(pos, 0, 1, 0), under=pos }

				log.action("%s: going to till %s @ %s with %s", self.inventory_name,
					node.name, minetest.pos_to_string(pointed_thing.under), tool:get_name())

				self:go_to(pointed_thing.above, 2)
				self:stand_still()

				-- node may have changed during go_to()
				node = minetest.get_node(pos)
				if minetest.get_item_group(node.name, "soil") == 1 then
					-- tool may have changed during go_to() (via sceptre)
					local tool_istack = self:get_wielded_item()
					if is_hoe(tool_istack) then
						local tool_def = minetest.registered_tools[tool_istack:get_name()]
						log.action("%s: punching %s @ %s with %s", self.inventory_name,
							node.name, minetest.pos_to_string(pointed_thing.under), tool_istack:get_name())

						-- face the node and start the animation
						local dist = vector.subtract(pos, self.object:get_pos())
						--self:set_animation(working_villages.animation_frames.MINE)
						self:animate("mine")
						self:set_yaw_by_direction(dist)
						self:delay_seconds(2)
						-- call the on_use() method to do the deed
						self:set_wielded_item(tool_def.on_use(self:get_wielded_item(), self, pointed_thing))
						self:stand_still()
						remember_farming_pos(self, pointed_thing.above)
					end
				end
			end
		end
		return true
	end
end
working_villages.register_task("farmer_till", { func = task_farmer_till, priority = 32 })

--[[
This task cycles through recent job sites.
We should visit each once a day. This will just visit the oldest to the
newest.
]]
local function task_visit_job_sites(self)
	local job_sites = recall_farming_pos(self)

	-- Iterate over all job sites and wait after each goto to allow the
	-- scan to pick up harvest tasks.
	for _, info in ipairs(job_sites) do
		log.warning("jobsite: %s", dump(info))
		local ss = wayzone_store.get()
		local wzc = ss:chunk_get_by_pos(info.pos)

		local pos_valid = false
		for _, wz in ipairs(wzc) do
			local target = wz:get_center_pos()
			log.action("%s: check jobsite at %s", self.inventory_name, target)
			local ret, msg = self:go_to(target, 4)
			if ret == true then
				-- wait long enough for the scan to run at least once
				self:delay_seconds(10)
				pos_valid = true
			end
		end
		if not pos_valid then
			forget_farming_pos(self, info.pos)
		end
	end
	-- nothing to do...
	return true
end
working_villages.register_task("visit_job_sites", { func = task_visit_job_sites, priority = 30 })

-------------------------------------------------------------------------------

local function check_farmer(self, name, active)
	log.action("%s: name=%s active=%s", self.inventory_name, name, tostring(active))
	if not active then
		log.action("%s: stopping work", self.inventory_name)
		self:task_del("harvest_and_plant", "done working")
		self:task_del("plant_seeds", "done working")
		self:task_del("gather_items", "done working")
		self:task_del("visit_job_sites", "done working")
		self:task_del("farmer_till", "done working")
		return
	end

	-- check work tasks every 5 seconds
	if func.timer(self, 5) then
		self:task_add("farmer_till", 45)
		self:task_add("plant_seeds", 50)

		--log.action("%s: farmer scan", self.inventory_name)
		--
		-- can we gather farming stuff?
		local items = self:get_nearby_objects_by_condition(farming_plants.is_pickup)
		if #items > 0 then
			self.task_data.gather_items = {}
			for _, item in ipairs(items) do
				table.insert(self.task_data.gather_items, item)
			end
			-- gather stuff is higher than harvest
			self:task_add("gather_items", 45)
		end

		self:task_add("plant_seeds") -- exits quick, lower than harvest/gather
		self:task_add("visit_job_sites") -- lower priority

		-- See if we can harvest anything
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
	--logic = farmer_logic,
	logic_check = check_farmer,
})

working_villages.farming_plants = farming_plants
