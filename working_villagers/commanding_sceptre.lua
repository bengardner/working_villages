
local log = working_villages.require("log")

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
					npc.destination = pointed_thing.above
					log.action("sending %s to %s", npc.inventory_name, minetest.pos_to_string(npc.destination))
					npc:task_del("goto", "new dest")
					npc:task_add("goto", 100)
					npc:task_add("wait", 99)
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
