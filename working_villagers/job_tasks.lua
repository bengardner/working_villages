--[[
Registers some useful common tasks.
The "self" passed to the functions is a "villager".
Also provides a series of common "check" functions that add tasks to the queue.

Schedule info:
Villagers have a schedule, depending on their job.
minetest.get_timeofday() return a value from 0 to 1 scaled from 0 to 24 h.

Mapped out:
 12 AM = 0 (midnight)
  4 AM = 0.167
  6 AM = 0.250
  8 AM = 0.333
 10 AM = 0.417
  noon = 0.500
  6 PM = 0.750
  8 PM = 0.833
  9 PM = 0.833
 10 PM = 0.917

A typical schedule would be:
 - sleep from 9 PM to 6 AM (loc: home, bed)
 - breakfast at 7 AM (loc: home or pub)
 - start work at 7:30 AM (loc: job site)
 - lunch break around noon (after noon and haven't had lunch yet)
   - field worker finds someplace to sit down and eat
   - shopkeeper goes home? or just stands and eats.
 - end work at 4:30 PM
   - go home to 'wash up' (loc: home) -- bath house?
 - socialize 5 PM - 7 PM, with dinner around 6 PM (loc: tavern or town center or anywhere (boid?) )
 - head home around 8 PM, hang out there (loc: home)
 - go to bed at 9 PM
]]
local log = working_villages.require("log")
local pathfinder = working_villages.require("nav/pathfinder")
local func = working_villages.require("jobs/util")

local tasks = {}

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

local function find_rest_spot(self)
	return func.iterate_surrounding_xz(self.object:get_pos(), rest_searching_range, is_resting_spot)
end

local function task_rest(self)
	self:set_displayed_action("enjoying nature")
	self:stand_still()

	local target = find_rest_spot(self)
	if target ~= nil then
		self:go_to(target)
	end

	self:sit_down()
	self:delay_seconds(15)
	return true
end
working_villages.register_task("idle_rest", { func = task_rest, priority = 11 })

local function task_wander(self)
	local end_clock = os.clock() + math.random(10, 30)
	while os.clock() < end_clock do
		self:stand_still()
		self:set_displayed_action("taking a walk")
		local target = self:pick_random_location()
		if target ~= nil then
			self:go_to(target)
		end
		self:stand_still()
		self:delay_steps(10)
	end
	return true
end
working_villages.register_task("idle_wander", { func = task_wander, priority = 11 })

-- name = weight
local idle_tasks = {
	{ name="idle_rest", weight=10 },
	--{ name="idle_wander", weight=10 },
	--{ name="idle_rest_at_home", weight=10 },
	--{ name="idle_chat", weight=10 },
}

local function task_idle(self)
	while true do
		self:set_state_info("I don't have anything to do.")
		self:set_displayed_action("doing nothing")
		-- Randomly select a higher-priority idle task
		self:task_add(func.pick_random(idle_tasks).name)
		-- wait a few seconds before picking the next idle task
		self:delay_seconds(5)
	end
end
working_villages.register_task("idle", { func = task_idle, priority = 10 })

local function task_goto_bed(self)
	log.action("%s: I am going to bed!", self.inventory_name)
	self:set_displayed_action("going to bed")

	if self.pos_data.home_pos == nil then
		log.action("villager %s is waiting until dawn", self.inventory_name)
		self:set_state_info("I'm waiting for dawn to come.")
		self:set_displayed_action("waiting until dawn")

		-- find a nearby place to rest
		local target = find_rest_spot(self)
		if target ~= nil then
			self:go_to(target)
		end

		while self:is_sleep_time() do
			self:sit_down()
			self:delay_seconds(5)
		end

		self:set_animation(working_villages.animation_frames.STAND)
		self:set_state_info("I'm starting into the new day.")
		self:set_displayed_action("active")
	else
		log.action("villager %s is going home", self.inventory_name)
		self:set_state_info("I'm going home, it's late.")
		self:set_displayed_action("going home")
		self:go_to(self.pos_data.home_pos)
		if self.pos_data.bed_pos == nil then
			log.warning("villager %s couldn't find his bed", self.inventory_name)
			self:set_state_info("I am going to rest soon.\nI would love to have a bed in my home though.")
			self:set_displayed_action("waiting for dusk")

			self:set_state_info("I'm waiting for dawn to come.")
			self:set_displayed_action("waiting until dawn")

			while self:is_sleep_time() do
				self:sit_down()
				self:delay_seconds(5)
			end
		else
			log.info("villager %s bed is at: %s", self.inventory_name, minetest.pos_to_string(self.pos_data.bed_pos))
			self:set_state_info("I'm going to bed, it's late.")
			self:set_displayed_action("going to bed")
			self:go_to(self.pos_data.bed_pos)
			self:set_state_info("I am going to sleep soon.")
			self:set_displayed_action("waiting for dusk")
			local tod = minetest.get_timeofday()
			while (tod > 0.2 and tod < 0.805) do
				coroutine.yield()
				tod = minetest.get_timeofday()
			end
			self:sleep()
			self:go_to(self.pos_data.home_pos)
		end
	end
	return true
end
working_villages.register_task("goto_bed", { func = task_goto_bed, priority = 50 })

local function task_goto(self)
	local target = self.destination
	self.destination = nil
	if target == nil then
		return true
	end

	log.action("%s: I am going to %s", self.inventory_name, minetest.pos_to_string(target))
	self:set_displayed_action("going to location")

	local start_pos = self:get_stand_pos()

	local pp = working_villages.nav:find_standable_y(target, 10, 10)
	if pp ~= nil and working_villages.nav:is_reachable(start_pos, pp) then
		log.action("pick_random_location: %s", minetest.pos_to_string(pp))
		target = pp
	end

	self:go_to(target)
	return true
end
working_villages.register_task("goto", { func = task_goto, priority = 20 })

local function task_wait(self)
	log.action("%s: I am waiting", self.inventory_name)
	self:set_displayed_action("waiting")
	self:stand_still()
	self:delay_seconds(30)
	return true
end
working_villages.register_task("wait", { func = task_wait, priority = 10 })

-------------------------------------------------------------------------------

--[[
Requires @tod_min and @tod_max to set the schedule bounds.
If @name is set and the schedule is active, the name will be included in the
key-val table returned from this function.
If @task is set, this will add or remove the task based on the schedule.
@priority is optional and is passed to self:task_add()
]]
local example_schedule = {
	{ tod_min=0.000, tod_max=0.200, name="sleep", task="goto_bed", priority=nil },
	{ tod_min=0.800, tod_max=1.000, name="sleep", task="goto_bed", priority=nil },
	{ tod_min=0.300, tod_max=0.600, name="work_start" }, -- start work jobs
	{ tod_min=0.700, tod_max=1.000, name="work_stop" },  -- terminate work jobs
}

--[[
Checks the schedule to see what we are supposed to be doing.

Sets self.task_data.work_time=true during work hours.
Queues other tasks as appropriate.
]]
function tasks.check_schedule(self, the_schedule)
	the_schedule = the_schedule or example_schedule
	local tod = minetest.get_timeofday()
	local all_tasks = {} -- need all tasks to know which to disable
	local active = {}    -- enable these tasks
	local names = {}

	--log.action("%s:check_schedule tod=%s", self.inventory_name, tostring(tod))

	for _, ent in ipairs(example_schedule) do
		if ent.task ~= nil then
			all_tasks[ent.task] = true
		end
		if tod >= ent.tod_min and tod <= ent.tod_max then
			names[ent.name] = true
			if ent.task ~= nil then
				active[ent.task] = ent
			end
		end
	end

	for task_name, _ in pairs(all_tasks) do
		local ent = active[task_name]
		if ent ~= nil then
			--log.action("%s: add %s", self.inventory_name, task_name)
			self:task_add(task_name, ent.priority)
		else
			--log.action("%s: del %s", self.inventory_name, task_name)
			self:task_del(task_name, "schedule")
		end
	end

	return names
end

-- Adds the "idle" task if there is no other task
function tasks.check_idle(self)
	if self.task.priority == nil then
		self:task_add("idle")
	end
end

-------------------------------------------------------------------------------

-- gather all the items in self.task_data.gather_items
local function task_gather_items(self)
	while true do
		local item = func.pop_last(self.task_data.gather_items)
		if item == nil then
			break
		end
		self:collect_item(item)
		self:delay_seconds(2)
	end
	return true
end
working_villages.register_task("gather_items", { func = task_gather_items, priority = 40 })

-------------------------------------------------------------------------------

return tasks
