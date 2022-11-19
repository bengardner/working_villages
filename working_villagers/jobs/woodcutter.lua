--[[
This file defines the unique behaviors for the woodcutter.
]]
local log = working_villages.require("log")
local func = working_villages.require("jobs/util")
local tree_scan = working_villages.require("tree_scan")
local tasks = working_villages.require("job_tasks")
local wayzone = working_villages.require("nav/wayzone")

local function mark_tree_as_failed(tree)
	log.warning("marking tree at %s as failed", minetest.pos_to_string(tree[1]))
	for _, pos in ipairs(tree) do
		working_villages.failed_pos_record(pos)
	end
end

-- check to see if a node is part of a valid tree that can be chopped
local function find_tree(pos, caller_state)
	-- can't chop protected trees
	--if func.is_protected(self, pos) then
	--	return false, fail.protected
	--end
	-- don't try again if we failed to chop it
	if working_villages.failed_pos_test(pos) then
		return false
	end

	local adj_node = minetest.get_node(pos)
	if minetest.get_item_group(adj_node.name, "tree") > 0 then
		local ret, tree_pos, leaves_pos = tree_scan.check_tree(pos)
		if ret ~= true then
			if tree_pos ~= nil then
				mark_tree_as_failed(tree_pos)
			end
			return false
		end

		-- save successful results
		caller_state.tree = tree_pos
		caller_state.leaves = leaves_pos
		return true
	end
	return false
end

-- Check to see if @n refers to a sapling.
-- This is called both for inventory (pos=nil) and for on-ground items.
local function is_sapling(n, pos)
	-- if this is on the ground and we failed to pick it up last time...
	if pos ~= nil and working_villages.failed_pos_test(vector.round(pos)) then
		return false
	end

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

-- Check to see if @pos is good for planting a sapling
local function is_sapling_spot(pos)
	--if func.is_protected(self, pos) then
	--	return false, fail.protected
	--end
	if working_villages.failed_pos_test(pos) then
		return false
	end
	local lpos = vector.new(pos.x, pos.y-1, pos.z)
	local lnode = minetest.get_node(lpos)
	-- saplings only grow on soil
	if minetest.get_item_group(lnode.name, "soil") == 0 then
		return false
	end

	-- saplings require light
	local light_level = minetest.get_node_light(pos)
	if light_level <= 12 then
		return false
	end

	-- A sapling needs room to grow. Require a volume of air around the spot.
	for x = -2,2 do
		for z = -2,2 do
			for y = 0,3 do
				lpos = vector.add(pos, {x=x, y=y, z=z})
				lnode = minetest.get_node(lpos)
				if lnode.name ~= "air" then return false end
			end
		end
	end
	return true
end

-- chest put function
local function put_func(_,stack)
	local name = stack:get_name();
	-- keep 'axe' and 'food'
	if (minetest.get_item_group(name, "axe")~=0)
		or (minetest.get_item_group(name, "food")~=0)
	then
		return false;
	end
	return true;
end

-- chest take function
local function take_func(self,stack,data)
	return not put_func(self,stack,data);
end

local searching_range = {x = 10, y = 10, z = 10, h = 5}

-- This does a quick check whether we should go to bed and queues the task.
-- The task runs as a coroutine until complete. It can be interrupted at any
-- time by a higher-priority task. When resumed, it is restarted.
local function check_night(self)
	local tod = minetest.get_timeofday()

	if self:is_sleep_time() then
		-- self-cancels when no longer sleep-time
		self:task_add("goto_bed")
		self.job_data.manipulated_chest = false
	else
		self:task_del("goto_bed", "not night")
	end
end

-- Add the idle task. It never goes away. Always lurking.
local function check_idle(self)
	if self.task.priority == nil then
		self:task_add("idle")
	end
end

local function task_plant_saplings(self)
	while true do
		-- Do we have any saplings?
		local wield_stack = self:get_wield_item_stack()
		if not (is_sapling(wield_stack:get_name()) or self:has_item_in_main(is_sapling)) then
			return true
		end

		-- Do we have a spot to plant saplings?
		local target = self.task_data.plant_sapling_pos
		self.task_data.plant_sapling_pos = nil
		if target == nil then
			target = func.search_surrounding(self.object:get_pos(), is_sapling_spot, searching_range)
			if target == nil then
				return true
			end
		end

		log.action("plant sapling @ %s", minetest.pos_to_string(target))

		-- local destination = func.find_adjacent_clear(target)
		-- if destination==false then
		-- 	print("failure: no adjacent walkable found")
		-- 	destination = target
		-- end
		self:set_displayed_action("planting a tree")
		self:go_to(target,2)
		self:stand_still()
		local success, ret = self:place(is_sapling, target)
		if not success then
			working_villages.failed_pos_record(target)
			self:set_displayed_action("confused as to why planting failed")
			self:delay_seconds(5)
		end
		self:delay_seconds(2)
	end
end
working_villages.register_task("plant_saplings", { func = task_plant_saplings, priority = 35 })

-- Add the chunk containing the current tree location to the forest_pos store
local function forest_pos_remember(self, target)
	local forest_pos = self:recall("forest_pos")
	if forest_pos == nil then
		forest_pos = {}
	end
	local chunk_pos = wayzone.normalize_pos(target)
	local chunk_hash = minetest.hash_node_position(chunk_pos)
	if forest_pos[chunk_hash] == nil then
		forest_pos[chunk_hash] = true
		self:remember("forest_pos", forest_pos)
		log.action("%s: forest_pos added %x %s", self.inventory_name,
			chunk_hash, minetest.pos_to_string(chunk_pos))
	end
end

-- find the closest forest position, do not remove it
local function forest_pos_recall(self)
	local my_pos = self.object:get_pos()
	local forest_pos = self:recall("forest_pos")
	if forest_pos ~= nil then
		local best
		for hash, _ in pairs(forest_pos) do
			local pos = minetest.get_position_from_hash(hash)
			local dist = vector.distance(my_pos, pos)
			if best == nil or best.dist > dist then
				best = { pos=pos, dist=dist, hash=hash }
			end
		end
		if best ~= nil then
			log.action("%s: forest_pos selected %x %s", self.inventory_name,
				best.hash, minetest.pos_to_string(best.pos))
			return best.pos
		end
	end
	return nil
end

-- Use this to forget a forest. this should be done if there are no trees OR
-- planted saplings in this chunk AND we tried going there from a remembered position.
local function forest_pos_forget(self, target)
	local forest_pos = self:recall("forest_pos")
	if forest_pos ~= nil then
		local chunk_pos = wayzone.normalize_pos(target)
		local chunk_hash = minetest.hash_node_position(chunk_pos)
		if forest_pos[chunk_hash] ~= nil then
			forest_pos[chunk_hash] = nil
			self:remember("forest_pos", forest_pos)
			log.action("%s: forest_pos removed %x %s", self.inventory_name,
				chunk_hash, minetest.pos_to_string(chunk_pos))
		end
	end
end

--local function search_chunk_for_trees(self, cpos)
--	log.action(" -- forest check @ %s", minetest.pos_to_string(cpos))
--	local ret = {}
--	local target = func.search_surrounding(cpos, find_tree, searching_range, ret)
--	if target == nil then
--		return nil -- no trees in this area
--	end
--
--	-- find a valid position near the tree
--	return working_villages.nav:find_standable_near(ret.tree[1], vector.new(3, 2, 3), self.object:get_pos())
--end

--local function task_search_tree(self)
--	log.action("%s: Searching for a forest @ %s", self.inventory_name, minetest.pos_to_string(self.stand_pos))
--
--	while true do
--		self:set_displayed_action("searching for a forest")
--		self:stand_still()
--
--		-- check memory for the last few tree positions
--		while true do
--			local pos = forest_pos_recall(self)
--			if pos == nil then
--				break
--			end
--			self:go_to(pos)
--			local ret = {}
--			local target = func.search_surrounding(self.object:get_pos(), find_tree, searching_range, ret)
--			if target == nil then
--				forest_pos_forget(self, pos)
--			end
--		end
--
--		-- TODO: check village storage for forest locations
--
--		-- do a random walk
--		self:stand_still()
--		self:set_displayed_action("looking for trees")
--		local target = self:pick_random_location(16)
--		if target ~= nil then
--			self:go_to(target)
--		end
--		self:stand_still()
--		self:delay_steps(10)
--	end
--	return true
--end
---- add with priority higher than chop_tree, as this moves to a forest
--working_villages.register_task("search_tree", { func = task_search_tree, priority = 29 })

local function find_nearby_tree(self, pos)
	log.warning("%s: find_nearby_tree %s", self.inventory_name, minetest.pos_to_string(pos))
	local tree_info = {}
	local target = func.search_surrounding(pos, find_tree, searching_range, tree_info)
	if target == nil then
		return nil
	end
	return tree_info
end

-- do the actual tree chopping
-- FIXME: move closer on the XZ plane for each log?
local function chop_down_tree(self, info)
	-- grab the bottom of the tree
	local target = info.tree[1]
	local log_node = minetest.get_node(target)

	-- find a valid standing position near the tree
	local destination = working_villages.nav:find_standable_near(target, vector.new(3, 2, 3), self.object:get_pos())
	if destination == nil then
		log.warning("tree failure: no adjacent walkable found to %s", minetest.pos_to_string(target))
		mark_tree_as_failed(info.tree)
		return
	end

	log.action("selected tree %s @ %s stand=%s tc=%d lc=%d",
		log_node.name,
		minetest.pos_to_string(target),
		minetest.pos_to_string(destination),
		#info.tree,
		#info.leaves)
	self:set_displayed_action("cutting a tree")

	-- We may not be able to reach the log
	--local success, ret = self:go_to(destination, 5)
	local success, msg = self:go_to(destination, 2, 5)
	if not success then
		working_villages.failed_pos_record(target)
		self:set_displayed_action("looking at the unreachable log")
		mark_tree_as_failed(info.tree)
		self:delay_seconds(10)
		return true
	end

	while #info.tree > 0 do
		local log_arr = info.tree
		--if info.tree[#info.tree].y < info.leaves[#info.leaves].y then
		--	log_arr = info.leaves
		--end
		local log_pos = log_arr[#log_arr]
		local log_node = minetest.get_node(log_pos)
		if minetest.get_item_group(log_node.name, "tree") > 0 or
			minetest.get_item_group(log_node.name, "leaves") > 0
		then
			log.action("dig tree %s [%s] @ %s tc=%d lc=%d",
				minetest.pos_to_string(log_pos), log_node.name,
				minetest.pos_to_string(destination),
				#info.tree,
				#info.leaves)

			-- FIXME: we need to adjust the 'dig' time based on the tool
			success, msg = self:dig(log_pos,true,false)
			if not success then
				mark_tree_as_failed(info.tree)
				self:set_displayed_action("confused as to why cutting failed")
				log.action("FAIL dig tree %s @ %s tc=%d lc=%d msg=%s",
					minetest.pos_to_string(log_pos),
					minetest.pos_to_string(destination),
					#info.tree,
					#info.leaves, msg)
				self:delay(100)
				break
			end

			log.action("SUCCESS dig tree %s [%s] @ %s tc=%d lc=%d",
				minetest.pos_to_string(log_pos), log_node.name,
				minetest.pos_to_string(destination),
				#info.tree,
				#info.leaves)
			table.remove(info.tree)
		end
		self:delay_steps(2)
	end
end

local function task_chop_tree(self)
	while true do
		self:set_displayed_action("looking for a tree to cut")

		local cnt = self:count_inventory_group("tree")
		log.action("%s: top of loop, cnt=%d", self.inventory_name, cnt)
		if cnt > 50 then
			log.action("%s: too many trees (%d), need to drop off in chest", self.inventory_name, cnt)
			return true
		end

		-- Do we have any trees nearby?
		local tree_info = self.task_data.chop_tree_info
		if tree_info ~= nil then
			self.task_data.chop_tree_info = nil
		else
			tree_info = find_nearby_tree(self, self.object:get_pos())
			if tree_info == nil then
				local target = self:pick_random_location(16)
				if target ~= nil then
					self:go_to(target)
				end
				self:stand_still()
				self:delay_steps(10)
			end
		end

		if tree_info ~= nil then
			log.action("%s: tree @ %s", self.inventory_name, minetest.pos_to_string(tree_info.tree[1]))
			forest_pos_remember(self, tree_info.tree[1])
			chop_down_tree(self, tree_info)
		else
			log.action("%s: no tree to chop", self.inventory_name)
		end
	end
end
working_villages.register_task("chop_tree", { func = task_chop_tree, priority = 30 })

local function find_chest(self)
	local chest_pos = self.pos_data.chest_pos
	if chest_pos == nil then
		local chest_pos = func.search_surrounding(self.object:get_pos(), func.is_chest, searching_range)
		if chest_pos == nil then
			log.action("%s: I could use a chest", self.inventory_name)
			return nil
		end

		log.action("%s: taking over chest @ %s", self.inventory_name, minetest.pos_to_string(chest_pos))
		self.pos_data.chest_pos = chest_pos
	end
	return chest_pos
end

local function task_store_in_chest(self)
	local chest_pos = self.pos_data.chest_pos
	if chest_pos == nil then
		local target = func.search_surrounding(self.object:get_pos(), func.is_chest, searching_range)
		if target == nil then
			log.action("no chest, no deal")
			return true
		end

		log.action("taking over chest @ %s", minetest.pos_to_string(target))
		self.pos_data.chest_pos = target
	end

	if not func.is_chest(chest_pos) and minetest.get_node_or_nil(chest_pos) ~= nil then
		-- chest was removed...
		self.pos_data.chest_pos = ""
	end

	self.job_data.manipulated_chest = false
	log.action("calling handle_chest @ %s, handled=%s",
		minetest.pos_to_string(self.pos_data.chest_pos), tostring(self.job_data.manipulated_chest))
	self:handle_chest(take_func, put_func)
	-- Do I own a chest? go to it. deposit.
	-- Am I part of a village? it there a village chest? go to it. deposit.
	-- Do I have enough wood to create a chest?
	return true
end
working_villages.register_task("store_in_chest", { func = task_store_in_chest, priority = 25 })

--
local function check_woodcutter(self, start_work, stop_work)
	if stop_work then
		log.action("%s: stopping work", self.inventory_name)
		self:task_del("gather_items")
		self:task_del("plant_saplings")
		self:task_del("chop_tree")
		return
	end

	-- check work tasks every 5 seconds
	if func.timer(self, 5) then
		local grp_cnt = self:count_inventory_groups({"tree", "sapling"})

		-- gather saplings
		if start_work and grp_cnt.sapling < 16 then
			local items = self:get_nearby_objects_by_condition(is_sapling)
			if #items > 0 then
				self.task_data.gather_items = {}
				for _, item in ipairs(items) do
					table.insert(self.task_data.gather_items, item)
				end
				self:task_add("gather_items")
			end
		end

		-- plant saplings
		if start_work and grp_cnt.sapling > 0 then
			local target = func.search_surrounding(self.object:get_pos(), is_sapling_spot, searching_range)
			if target ~= nil then
				self.task_data.plant_sapling_pos = target
				self:task_add("plant_saplings")
			end
		end

		if start_work and grp_cnt.tree < 50 then
			if self.task_data.chop_tree_info == nil then
				self.task_data.chop_tree_info = find_nearby_tree(self, self.object:get_pos())
			end
			if self.task_data.chop_tree_info ~= nil then
				self:task_add("chop_tree")
			end
		end

		-- storing in chest if full or day is over and we have some leftover
		if grp_cnt.tree >= 50 or (grp_cnt.tree > 0 and not start_work) then
			if find_chest(self) ~= nil then
				self:task_add("store_in_chest")
			end
		end
	end
end

--[[
This should activate or disable tasks based on the time of day and the highest
priority task. It runs as part of the on_step() callback, so it should be quick.
]]
local function woodcutter_logic(self)
	if func.timer(self, 1) then
		local names = tasks.check_schedule(self)

		log.action("%s: work_start=%s work_stop=%s", self.inventory_name, names.work_start, names.work_stop)

		-- custom woodcutter tasks
		check_woodcutter(self, names.work_start, names.work_stop)

		-- make sure the idle task is present
		tasks.check_idle(self)
	end
end

working_villages.register_job("working_villages:job_woodcutter", {
	description      = "woodcutter (working_villages)",
	long_description = "I look for any Tree trunks around and chop them down.\
When I find a sappling I'll plant it on some soil near a bright place so a new tree can grow from it.",
	inventory_image  = "default_paper.png^working_villages_woodcutter.png",
	logic = woodcutter_logic,
})
