
local log = working_villages.require("log")
local func = working_villages.require("jobs/util")

local function handle_move_to(npc, pos)
	npc.destination = pos
	log.action("%s: sending to %s", npc.inventory_name, minetest.pos_to_string(pos))
	npc:task_del("goto", "new dest")
	npc:task_add("goto", 100)
	npc:task_add("wait", 99)
end

-- FIXME: this should be available in the "sit_down" function
local function handle_sit(npc, pos)
	local node = minetest.get_node(pos)
	log.action("%s: sitting on %s [rot=%d] @ %s", npc.inventory_name, node.name, node.param2, minetest.pos_to_string(pos))
	npc:task_del("wait_sit", "new target")
	npc:task_del("wait_lay", "new target")

	npc:sit_down(pos)
	npc:task_add("wait_sit", 99)
end

-- FIXME: this should be available in the "sit_down" function
local function handle_lay(npc, pos)
	local node = minetest.get_node(pos)
	log.action("%s: laying on %s [rot=%d] @ %s", npc.inventory_name, node.name, node.param2, minetest.pos_to_string(pos))
	npc:task_del("wait_sit", "new target")
	npc:task_del("wait_lay", "new target")

	npc:lay_down(pos)
	npc:task_add("wait_lay", 99)
end

local function handle_villager_command(npc, pt)
	local na = minetest.get_node(pt.above)
	local nu = minetest.get_node(pt.under)

	log.action("above=%s %s under=%s %s",
		minetest.pos_to_string(pt.above), na.name,
		minetest.pos_to_string(pt.under), nu.name)

	if func.is_bed(na.name) then
		if npc._anim == "sit" then
			handle_lay(npc, pt.above)
		else
			handle_sit(npc, pt.above)
		end
	elseif func.is_bed(nu.name) then
		if npc._anim == "sit" then
			handle_lay(npc, pt.under)
		else
			handle_sit(npc, pt.under)
		end
	elseif func.is_bench(nu.name) or func.is_chair(nu.name) then
		handle_sit(npc, pt.under)
	elseif func.is_bed(na.name) or func.is_bench(na.name) or func.is_chair(na.name) then
		handle_sit(npc, pt.above)
	else
		handle_move_to(npc, pt.above)
	end
end

minetest.register_tool("working_villages:commanding_sceptre", {
	description = "villager commanding sceptre",
	inventory_image = "working_villages_commanding_sceptre.png",
	on_use = function(itemstack, user, pointed_thing)
		if (pointed_thing.type == "object") then
			local obj = pointed_thing.ref
			local luaentity = obj:get_luaentity()
			if not working_villages.is_villager(luaentity.name) then
				if luaentity.name == "__builtin:item" then
					luaentity:on_punch(user)
				end
				return
			end

			log.action("used commanding sceptre on %s", luaentity.inventory_name)
			local meta = itemstack:get_meta()
			meta:set_string("villager", luaentity.inventory_name)

			local job = luaentity:get_job()
			if job ~= nil then
				if luaentity.pause then
					luaentity:set_pause(false)
					if type(job.on_resume)=="function" then
						job.on_resume(luaentity)
					end
					luaentity:set_displayed_action("active")
					luaentity:set_state_info("I'm continuing my job.")
				else
					luaentity:set_pause(true)
					luaentity:set_displayed_action("waiting")
					luaentity:set_state_info("I was asked to wait here.")
					if type(job.on_pause)=="function" then
						job.on_pause(luaentity)
					end
				end
			end

			return itemstack

		elseif pointed_thing.type == "node" then
			local meta = itemstack:get_meta()
			local invname = meta:get_string("villager")
			if invname ~= nil then
				log.action("meta:villager = %s", invname)
				local npc = working_villages.active_villagers[invname]
				if npc ~= nil then
					handle_villager_command(npc, pointed_thing)
				else
					for i, n in pairs(working_villages.active_villagers) do
						log.action("  %s = %s", tostring(i), tostring(n))
					end
				end
			end
		else
			log.action("pointed_thing.type = %s", pointed_thing.type)
		end
	end
})
