--[[
Shim layer to graft the "bgai" stuff onto mobkit.
Take control of a mob by changing the logic() function!
Make a deer cut down trees!
]]

function bgai.mobkit.hq_bgai(self, priority)
	local func = function(self)
		bgai.bot.task_execute(self)
		-- never return true so this is never removed
	end
	mobkit.queue_high(self, func, priority)
end

-- logic or 'brain' function for a mobkit MOB
function bgai.mobkit.logic(self)
	-- check tests various things to see which tasks should be in the queue.
	bgai.bot:schedule_check(self)

	-- make sure a high-queue task is present to run the coroutine
	local prty = mobkit.get_queue_priority(self)
	if prty ~= 500 then
		bgai.mobkit.hq_bgai(self, 500)
	end
end

--[[
Wait for all low queue tasks to finish.
Only call from the coroutine task.

@sec_timeout sets an upper bound for waiting
returns if the low queue is empty (timeout otherwise)
]]
function bgai.mobkit.run_lq_tasks(self, sec_timeout)
	local deadline

	if sec_timeout and sec_timeout >= 0 then
		deadline = minetest.get_gametime() + sec_timeout
	end

	while not mobkit.is_queue_empty_low(self) do
		coroutine.yield()
		if deadline and minetest.get_gametime() > deadline then
			break
		end
	end
	return mobkit.is_queue_empty_low(self)
end
