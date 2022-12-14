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
local marker_store = working_villages.require("nav/marker_store")
local markers_rest = marker_store.new("rest", {texture="testpathfinder_waypoint.png", yoffs=0.3, visual_size = {x = 0.3, y = 0.3, z = 0.3}})

local tasks = {}

-- require a clear area (non-walkable) with standable below in a 3x3 grid
-- 1. Find a chair
-- 2. Find a bed to sit on
-- 3. Find a spot on the ground
local function is_resting_spot(pos)
	-- did we already fail to reach this one?
	if working_villages.failed_pos_test(pos) then return false end

	local node = minetest.get_node(pos)

	if func.is_chair(node.name) or func.is_bench(node.name) then
		return true
	end

	markers_rest:clear()
	-- we want a 3x3 area to rest on
	for x = -1,1 do
		for z = -1,1 do
			local lpos = vector.new(pos.x+x, pos.y, pos.z+z)
			if pathfinder.is_node_collidable(lpos) then
				markers_rest:clear()
				return false
			end
			markers_rest:add(lpos, "standable")
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
		self:set_state_info("I'm waiting for dawn to come.\nI am homeless.")
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

		--self:set_animation(working_villages.animation_frames.STAND)
		self:animate("stand")
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

			-- wait until night time
			-- FIXME: this should depend on the schedule
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

-- go to self.destination as a lower priority task (why?)
-- use self:go_to() to navigate from another task
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

-- waits for self.task_data.wait_seconds, which is not altered
local function task_wait(self)
	local sec_left = self.task_data.wait_seconds or 30
	log.action("%s: I am waiting for %s seconds", self.inventory_name, sec_left)
	self:set_displayed_action("waiting")
	self:stand_still()
	while sec_left > 0 do
		local ds = math.max(1, sec_left)
		self:delay_seconds(ds)
		sec_left = sec_left - ds
	end
	return true
end
working_villages.register_task("wait", { func = task_wait, priority = 10 })

local function task_wait_sit(self)
	local sec_left = self.task_data.wait_seconds or 30
	log.action("%s: I am waiting for %s seconds", self.inventory_name, sec_left)
	self:set_displayed_action("waiting")
	while sec_left > 0 do
		self:sit_down()
		local ds = math.max(1, sec_left)
		self:delay_seconds(ds)
		sec_left = sec_left - ds
	end
	return true
end
working_villages.register_task("wait_sit", { func = task_wait_sit, priority = 10 })

local function task_work_break(self)
	local sec_left = self.task_data.wait_seconds or 10
	log.action("%s: break time! for %s seconds", self.inventory_name, sec_left)
	self:set_displayed_action("waiting")
	tasks.schedule_done(self, "work_break")
	return true
end
working_villages.register_task("work_break", { func = task_work_break, priority = 10 })

local function task_wait_lay(self)
	local sec_left = self.task_data.wait_seconds or 30
	log.action("%s: I am waiting for %s seconds", self.inventory_name, sec_left)
	self:set_displayed_action("waiting")
	while sec_left > 0 do
		--self:lay_down()
		local ds = math.max(1, sec_left)
		self:delay_seconds(ds)
		sec_left = sec_left - ds
	end
	return true
end
working_villages.register_task("wait_lay", { func = task_wait_lay, priority = 10 })

-- waits for self.task_data.wait_seconds, which is not altered
local function task_meal(self)
	local meal_name
	for _, xx in ipairs({"breakfast", "lunch", "dinner"}) do
		if tasks.schedule_is_active(self, xx) then
			meal_name = xx
			break
		end
	end

	if meal_name then
		-- TODO: see if I have any food items and eat one or two

		log.action("%s: I am eating %s", self.inventory_name, meal_name)
		self:set_displayed_action(string.format("eating %s", meal_name))
		self:stand_still()
		self:delay_seconds(10)
		tasks.schedule_done(self, meal_name)
	end
	return true
end
working_villages.register_task("meal", { func = task_meal, priority = 50 })

-------------------------------------------------------------------------------

function tasks.check_work(self, name, active)
	local job = self:get_job()
	--log.action("check_work: job=%s", dump(job))

	if job and job.logic_check then
		job.logic_check(self, name, active)
	end
end

function tasks.check_school(self, name, active)
end

function tasks.check_social(self, name, active)
	-- check for other NPCs around that we haven't visited with in the last
	-- few hours
	-- if found AND the other NPC's priority is low enough, add the "socialize"
	-- task to BOTH NPCs and set the self.task_data.social_target
end

function tasks.check_hometime(self, name, active)
end

function tasks.check_church(self, name, active)
end

-------------------------------------------------------------------------------

--[[
Requires @tod_min and @tod_max to set the schedule bounds.
If @name is set and the schedule is active, the name will be included in the
key-val table returned from this function.
If @task is set, this will add or remove the task based on the schedule.
@priority is optional and is passed to self:task_add()

Schedule names:
 - sleep : head to the bed, sleep in bed or on the ground
 - socialize : head to tavern (evening?)
 - coordinate : morning, go to the town center to get job for day, tools
 - work : do whatever (farmer, woodcutter, etc)
 - breakfast : eat at table in home or at tavern
 - lunch : stop work, sit down, eat something
 - dinner : eat at home or tavern
 - school : head to school building

Note that these may overlap. For example, lunch and work overlap.
Work and school overlap.
]]
local example_schedule = {
	{ tod_min=0.000, tod_max=0.200, name="sleep", task="goto_bed", priority=nil },
	{ tod_min=0.800, tod_max=1.000, name="sleep", task="goto_bed", priority=nil },
	{ tod_min=0.300, tod_max=0.600, name="work_start" }, -- start work jobs
	{ tod_min=0.700, tod_max=1.000, name="work_stop" },  -- terminate work jobs
}

--[[
The key is the schedule/check name. Also the key to self.job_data.complete[key].
@dow is a bitmask for day of week. 1=Sunday, 2=Monday, 4=Tue, 8=Wed, 0x10=Thu, 0x20=Fri, 0x40=Sat
@tmin is the 24-hour clock time for the start of the schedule.
@tmax is the 24-hout clock time for the end of the schedule.
@check is the function to call to check the schedule (optional)
@task is a task to add/remove on schedule (optional)

In any case, self.job_data.schedule_active[name] is set to whether the schedule is active.
]]
local schedule_dayshift = {
	sleep     = { dow=0x7f, tmin=22, tmax=6,  task="goto_bed" },            -- tmin > tmax means wrap-around
	socialize = { dow=0x7f, tmin=6,  tmax=22, check=tasks.check_social },   -- visit with other NPCs
	breakfast = { dow=0x7f, tmin=7,  tmax=8,  task="meal" },
	lunch     = { dow=0x7f, tmin=12, tmax=14, task="meal" },
	dinner    = { dow=0x7f, tmin=17, tmax=19, task="meal" },
	workprep  = { dow=0x7c, tmin=7,  tmax=8,  task="workprep" },            -- head to town center to get assigned a job for the day, get stuff from chest
	work      = { dow=0x7c, tmin=8,  tmax=17, check=tasks.check_work },     -- day shift
	rest      = { dow=0x7c, tmin=10, tmax=11, task="work_break" },          -- morning break
	rest      = { dow=0x7c, tmin=14, tmax=15, task="work_break" },          -- afternoon break
	workdone  = { dow=0x7c, tmin=17, tmax=18, check=tasks.check_work },     -- deposit extra stuff in chest
	school    = { dow=0x7c, tmin=9,  tmax=16, check=tasks.check_school },   -- head to school if young enough
	recess    = { dow=0x7c, tmin=11, tmax=12, check=tasks.check_school },   -- morning recess
	recess    = { dow=0x7c, tmin=14, tmax=15, check=tasks.check_school },   -- afternoon recess
	hometime  = { dow=0x7f, tmin=21, tmax=22, check=tasks.check_hometime }, -- go home
	church    = { dow=0x01, tmin=21, tmax=22, check=tasks.check_church },   -- go to church (if there is one)
}

-- mark a schedule item as complete
function tasks.schedule_done(self, name)
	if self.job_data.schedule_done[name] == nil then
		log.action("%s: schedule %s is done", self.inventory_name, name)
		self.job_data.schedule_done[name] = minetest.get_timeofday() -- true might be sufficient
	end
end

-- mark a schedule item as NOT complete
function tasks.schedule_reset(self, name)
	if self.job_data.schedule_done[name] ~= nil then
		log.action("%s: schedule %s is reset", self.inventory_name, name)
		self.job_data.schedule_done[name] = nil
	end
end

function tasks.schedule_is_active(self, name)
	return self.job_data.schedule_state[name] == "yes"
end

-- call all the check functions for the schedule items
function tasks.schedule_check(self)
	local schedule = self.schedule or schedule_dayshift
	local dow = minetest.get_day_count() % 7
	local dow_mask = bit.lshift(1, dow)
	local tod = minetest.get_timeofday() * 24.0

	--log.action("%s: dow=%d tod=%.2f", self.inventory_name, dow, tod)

	--[[
	First pass to update self.job_data.schedule_state[], which can have 4 values:
		yes  : scheduled time active and not 'done'
		end  : scheduled time just ended (either done or schedule)
		done : schedule is active and done (set by task)
		no   : schedule not active

		transitions:
			no -> yes -> end -> done -> no (if task sets "done")
			no -> yes -> end -> no         (if task does not set "done")
	]]
	for name, info in pairs(schedule) do
		-- determine if this schedule is active based on time/day
		local active -- boolean
		if bit.band(dow_mask, info.dow or 0x7f) == 0 then
			-- not active on this day
			active = false
		elseif info.tmin <= info.tmax then
			active = (tod >= info.tmin) and (tod <= info.tmax)
		else
			active = (tod > info.tmin) or (tod < info.tmax)
		end

		local old_state = self.job_data.schedule_state[name]
		local new_state = old_state
		if active then
			if self.job_data.schedule_done[name] ~= nil then
				if old_state == "yes" then
					new_state = "end"
				else
					new_state = "done"
				end
			else
				new_state = "yes"
			end
		else
			if self.job_data.schedule_done[name] ~= nil then
				self.job_data.schedule_done[name] = nil
			end
			if old_state == "yes" then
				new_state = "end"
			else
				new_state = "no"
			end
		end

		if old_state ~= new_state then
			self.job_data.schedule_state[name] = new_state
			log.action("%s: schedule %s : %s => %s", self.inventory_name, name, old_state, new_state)
		end
	end
	--log.action("schedule_state: %s %s", dump(self.job_data.schedule_state), dump(self.job_data.schedule_done))

	--[[
	Second pass to call functions, add tasks.
	This is in two passes so, say, check_work can see if 'rest' is active.
	]]
	local tasks_to_add = {}
	local tasks_to_del = {}
	for name, info in pairs(schedule) do
		local state = self.job_data.schedule_state[name]

		-- add task if not done
		if info.task then
			if state == "yes" then
				tasks_to_add[info.task] = true
				--self:task_add(info.task)
			else
				tasks_to_del[info.task] = true
				--self:task_del(info.task, "schedule")
			end
		end

		if info.check then
			if state == "yes" or state == "end" then
				local active = (state == "yes")
				--log.action("%s: schedule check(%s, %s)", self.inventory_name, name, tostring(active))
				info.check(self, name, active)
			end
		end
	end

	for tn, _ in pairs(tasks_to_add) do
		self:task_add(tn)
	end
	for tn, _ in pairs(tasks_to_del) do
		if tasks_to_add[tn] == nil then
			self:task_del(tn, "schedule")
		end
	end

	-- add the idle task if there is nothing else going on
	-- the idle task never exits (?)
	if self.task.priority == nil then
		self:task_add("idle")
	end
end

--[[
Checks the schedule to see what we are supposed to be doing.

Sets self.task_data.work_time=true during work hours.
Queues other tasks as appropriate.
]]
function tasks.check_schedule_old(self, the_schedule)
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
