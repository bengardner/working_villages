--[[
Registers some useful common tasks.
The "self" passed to the functions is a "villager".
]]
local log = working_villages.require("log")
local pathfinder = working_villages.require("pathfinder")
local func = working_villages.require("jobs/util")

-- require a clear area (non-walkable) with standable below in a 3x3 grid
local function is_resting_spot(pos)
	-- did we already fail to reach this one?
	if working_villages.failed_pos_test(pos) then return false end
	-- we want a 3x3 area to rest on
	for x = -1,1 do
		for z = -1,1 do
			local lpos = vector.new(pos.x+x, pos.y, pos.z+z)
			if not pathfinder.is_node_standable(pos) then
				return false
			end
		end
	end
	return true
end

local rest_searching_range = {x = 10, y = 10, z = 5, h = 5}

local function task_rest(self)
	self:set_displayed_action("enjoying nature")
	self:stand_still()

	local target = func.iterate_surrounding_xz(self.object:get_pos(), rest_searching_range, is_resting_spot)
	if target == nil then
		log.warning("could not find a place to rest")
		return true
	end

	self:sit_down()
	self:delay_seconds(15)
	return true
end
working_villages.register_task("idle_rest", { func = task_rest, priority = 11 })

local function task_wander(self)
	self:set_displayed_action("taking a walk")
	local end_clock = os.clock() + math.random(10, 30)
	while os.clock() < end_clock do
		local target = self:pick_random_location()
		if target ~= nil then
			self:go_to(target)
		end
		self:delay_steps(10)
	end
	return true
end
working_villages.register_task("idle_wander", { func = task_wander, priority = 11 })

-- name = weight
local idle_tasks = {
	--{ name="idle_rest", weight=10 },
	{ name="idle_wander", weight=10 },
	--{ name="idle_rest_at_home", weight=10 },
	--{ name="idle_chat", weight=10 },
}

local function task_idle(self)
	while true do
		self:set_displayed_action("doing nothing")
		-- Randomly select a higher-priority idle task
		self:task_add(func.pick_random(idle_tasks).name)
		-- wait a few seconds before picking the next idle task
		self:delay_seconds(5)
	end
end
working_villages.register_task("idle", { func = task_idle, priority = 10 })

local function task_goto_bed(self)
	while self:is_sleep_time() do
		self:set_displayed_action("going to bed")
		self:sit_down()

		-- TODO:
		--  * if we have a house, head there
		--  * find a nearby bed
		--  * if we have a bed, lay in it
		--  * if sleeping, toss/turn occasionally
		log.action("%s: I am going to bed!", self.product_name)
		self:delay_seconds(5)
	end
	-- done
	return true
end
working_villages.register_task("goto_bed", { func = task_goto_bed, priority = 50 })
