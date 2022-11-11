--[[
Registers some useful common tasks.
The "self" passed to the functions is a "villager".
]]
local log = working_villages.require("log")

local function task_idle(self)
	while true do
		-- TODO: randomly select a higher-level task, which is queued above idle priority
		--  * sit down and rest
		--  * wander aimlessly (go for a walk)
		--  * go home and sit
		--  * find another nearby villager and chat
		log.action("%s: I am idle!", self.product_name)
		self:delay_seconds(5)
	end
end
working_villages.register_task("idle", { func = task_idle, priority = 10 })

local function task_goto_bed(self)
	while self:is_sleep_time() do
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
