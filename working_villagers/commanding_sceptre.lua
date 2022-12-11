
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

	if npc._anim == "sit" then
		npc:stand_still(pos)
	end
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
	range = 16,

	on_use = function(itemstack, user, pointed_thing)
		-- return nil to not modify itemstack
		local meta = itemstack:get_meta()
		local invname = meta:get_string("villager")

		if pointed_thing.type == "object" then
			local luaentity = pointed_thing.ref:get_luaentity()
			if not working_villages.is_villager(luaentity.name) then
				if luaentity.name == "__builtin:item" then
					luaentity:on_punch(user)
				end
				return
			end

			log.action("commanding sceptre used on %s", luaentity.inventory_name)
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
			-- need to update the itemstack meta data
			return itemstack

		elseif pointed_thing.type == "node" then
			if invname ~= nil then
				-- villager might be in a chunk that is not be loaded
				local npc = working_villages.active_villagers[invname]
				if npc ~= nil then
					log.action("commanding sceptre: %s -> %s %s", invname,
						minetest.pos_to_string(pointed_thing.under),
						minetest.get_node(pointed_thing.under).name)
					handle_villager_command(npc, pointed_thing)
				else
					log.action("commanding sceptre: %s not found", invname)
				end
			end

		else -- pointed_thing.type == "nothing"
			if invname ~= "" then
				log.action("commanding sceptre: deselected %s", invname)
				meta:set_string("villager", "")
				-- need to update the itemstack meta data
				return itemstack
			end
		end
	end
})
