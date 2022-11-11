--[[
This file defines the unique behaviors for the woodcutter.
]]
local log = working_villages.require("log")
local func = working_villages.require("jobs/util")
local tree_scan = working_villages.require("tree_scan")
local tasks = working_villages.require("job_tasks")

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

local function task_gather_saplings(self)
	while true do
		local cnt = self:count_inventory_one("sapling")
		if cnt > 16 then
			log.action("too many saplings")
			return true
		end
		-- collect sapling (TODO: also pick up apples, sticks, etc)
		if not self:collect_nearby_items_by_condition(is_sapling, searching_range) then
			return true
		end
		self:delay_steps(2)
	end
end
working_villages.register_task("gather_saplings", { func = task_gather_saplings, priority = 40 })

local function task_plant_saplings(self)
	while true do
		-- Do we have any saplings?
		local wield_stack = self:get_wield_item_stack()
		if not (is_sapling(wield_stack:get_name()) or self:has_item_in_main(is_sapling)) then
			return true
		end

		-- Do we have a spot to plant saplings?
		local target = func.search_surrounding(self.object:get_pos(), is_sapling_spot, searching_range)
		if target == nil then
			return true
		end

		log.action("plant sapling @ %s", minetest.pos_to_string(target))

		-- local destination = func.find_adjacent_clear(target)
		-- if destination==false then
		-- 	print("failure: no adjacent walkable found")
		-- 	destination = target
		-- end
		self:set_displayed_action("planting a tree")
		self:go_to(target,2)
		self.object:set_velocity{x = 0, y = 0, z = 0}
		local success, ret = self:place(is_sapling, target)
		if not success then
			working_villages.failed_pos_record(target)
			self:set_displayed_action("confused as to why planting failed")
			self:delay_seconds(5)
		end
		self:delay_steps(2)
	end
end
working_villages.register_task("plant_saplings", { func = task_plant_saplings, priority = 35 })

local function task_chop_tree(self)
	while true do
		local cnt = self:count_inventory_one("tree")
		if cnt > 50 then
			log.action("too many trees")
			return true
		end

		local my_pos = self.object:get_pos()
		local ret = {}

		-- Do we have any trees nearby?
		local target = func.search_surrounding(my_pos, find_tree, searching_range, ret)
		if target == nil then
			return true -- no, done
		end

		-- grab the bottom of the tree
		target = ret.tree[1]
		local log_node = minetest.get_node(target)

		-- find a valid position near the tree
		local destination = working_villages.nav:find_standable_near(target, vector.new(3, 2, 3), self.object:get_pos())
		if destination == nil then
			log.warning("tree failure: no adjacent walkable found to %s", minetest.pos_to_string(target))
			mark_tree_as_failed(ret.tree)
			return true
		end

		log.action("selected tree %s @ %s stand=%s tc=%d lc=%d",
			log_node.name,
			minetest.pos_to_string(target),
			minetest.pos_to_string(destination),
			#ret.tree,
			#ret.leaves)
		self:set_displayed_action("cutting a tree")

		-- We may not be able to reach the log
		--local success, ret = self:go_to(destination, 5)
		local success, msg = self:go_to(destination, 2, 5)
		if not success then
			working_villages.failed_pos_record(target)
			self:set_displayed_action("looking at the unreachable log")
			mark_tree_as_failed(ret.tree)
			self:delay_seconds(10)
			return true
		end

		while #ret.tree > 0 do
			local log_arr = ret.tree
			--if ret.tree[#ret.tree].y < ret.leaves[#ret.leaves].y then
			--	log_arr = ret.leaves
			--end
			local log_pos = log_arr[#log_arr]
			local log_node = minetest.get_node(log_pos)
			if minetest.get_item_group(log_node.name, "tree") > 0 or
			   minetest.get_item_group(log_node.name, "leaves") > 0
			then
				log.action("dig tree %s [%s] @ %s tc=%d lc=%d",
					minetest.pos_to_string(log_pos), log_node.name,
					minetest.pos_to_string(destination),
					#ret.tree,
					#ret.leaves)

				success, msg = self:dig(log_pos,true,false)
				if not success then
					mark_tree_as_failed(ret.tree)
					self:set_displayed_action("confused as to why cutting failed")
					log.action("FAIL dig tree %s @ %s tc=%d lc=%d msg=%s",
						minetest.pos_to_string(log_pos),
						minetest.pos_to_string(destination),
						#ret.tree,
						#ret.leaves, msg)
					self:delay(100)
					break
				end

				log.action("SUCCESS dig tree %s [%s] @ %s tc=%d lc=%d",
					minetest.pos_to_string(log_pos), log_node.name,
					minetest.pos_to_string(destination),
					#ret.tree,
					#ret.leaves)
				table.remove(ret.tree)
			end
		end
		self:delay_steps(2)
	end
end
working_villages.register_task("chop_tree", { func = task_chop_tree, priority = 30 })


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
local function check_woodcutter(self)
	-- only add the tasks if the active priority is lower than 30
	if (self.task.priority or 0) < 30 then
		self:count_timer("woodcutter:search")
		if self:timer_exceeded("woodcutter:search", 60) then
			local grp_cnt = self:count_inventory({"tree", "sapling"})
			if grp_cnt.sapling < 16 then
				self:task_add("gather_saplings")
			end
			if grp_cnt.sapling > 0 then
				self:task_add("plant_saplings")
			end
			if grp_cnt.tree < 50 then
				self:task_add("chop_tree")
			end
			if grp_cnt.tree >= 50 then
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
	-- handle the night check
	tasks.check_sleeptime(self)

	-- custom woodcutter tasks
	check_woodcutter(self)

	-- make sure the idle task is present
	tasks.check_idle(self)
end

working_villages.register_job("working_villages:job_woodcutter", {
	description      = "woodcutter (working_villages)",
	long_description = "I look for any Tree trunks around and chop them down.\
When I find a sappling I'll plant it on some soil near a bright place so a new tree can grow from it.",
	inventory_image  = "default_paper.png^working_villages_woodcutter.png",
	logic = woodcutter_logic,
})
