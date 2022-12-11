local log = working_villages.require("log")
local cmnp = modutil.require("check_prefix","venus")
local pathfinder = working_villages.require("nav/pathfinder")
local wayzone_utils = working_villages.require("nav/wayzone_utils")
local func = working_villages.require("jobs/util")

working_villages.animation_frames = {
	STAND     = { x=  0, y= 79, },
	LAY       = { x=162, y=166, },
	WALK      = { x=168, y=187, },
	MINE      = { x=189, y=198, },
	WALK_MINE = { x=200, y=219, },
	SIT       = { x= 81, y=160, },
}

working_villages.active_villagers = {}
working_villages.registered_villagers = {}
working_villages.registered_jobs = {}
working_villages.registered_eggs = {}
working_villages.registered_tasks = {}

-- records failed node place attempts to prevent repeating mistakes
-- key=minetest.pos_to_string(pos) val=(os.clock()+180)
local failed_pos_data = {}
local failed_pos_time = 0

-- remove old positions
local function failed_pos_cleanup()
	-- build a list of all items to discard
	local discard_tab = {}
	local now = os.clock()
	for key, val in pairs(failed_pos_data) do
		if now >= val then
			discard_tab[key] = true
		end
	end
	-- discard the old entries
	for key, _ in pairs(discard_tab) do
		failed_pos_data[key] = nil
	end
end

-- add a failed place position
function working_villages.failed_pos_record(pos)
	local key = minetest.hash_node_position(pos)
	failed_pos_data[key] = os.clock() + 180 -- mark for 3 minutes

	-- cleanup if more than 1 minute has passed since the last cleanup
	if os.clock() > failed_pos_time then
		failed_pos_time = os.clock() + 60
		failed_pos_cleanup()
	end
end

-- check if a position is marked as failed and hasn't expired
function working_villages.failed_pos_test(pos)
	local key = minetest.hash_node_position(pos)
	local exp = failed_pos_data[key]
	return exp ~= nil and exp >= os.clock()
end

-- working_villages.is_job reports whether a item is a job item by the name.
function working_villages.is_job(item_name)
	if working_villages.registered_jobs[item_name] then
		return true
	end
	return false
end

-- working_villages.is_villager reports whether a name is villager's name.
function working_villages.is_villager(name)
	if name and working_villages.registered_villagers[name] then
		return true
	end
	return false
end

---------------------------------------------------------------------

working_villages.villager = working_villages.require("villager")
local villager = working_villages.villager
working_villages.require("async_actions")

---------------------------------------------------------------------

-- REVISIT: use "minetest.get_mod_storage()" ? There is no need to keep the
--          various villagers separate.
-- working_villages.manufacturing_data represents a table that contains manufacturing data.
-- this table's keys are product names, and values are manufacturing numbers
-- that has been already manufactured.
working_villages.manufacturing_data = (function()
	local file_name = minetest.get_worldpath() .. "/working_villages_data"

	minetest.register_on_shutdown(function()
		local file = io.open(file_name, "w")
		file:write(minetest.serialize(working_villages.manufacturing_data))
		file:close()
	end)

	local file = io.open(file_name, "r")
	if file ~= nil then
		local data = file:read("*a")
		file:close()
		return minetest.deserialize(data)
	end
	return {}
end) ()

function working_villages.next_manufacturing_number(name)
	local num = working_villages.manufacturing_data[name] or 1
	working_villages.manufacturing_data[name] = num + 1
	return num
end

--------------------------------------------------------------------

-- register empty item entity definition.
-- this entity may be hold by villager's hands.
do
	local function on_step(self)
		-- get the villager. the villager on_deactivate() removes this object
		local mob = self.object:get_attach()
		if not mob then
			return
		end
		local ent = mob:get_luaentity()
		if not ent then
			return
		end
		local wield_item = self.object:get_properties().wield_item
		local wield_name = ent:get_wielded_item():get_name()
		local is_visible = true
		if wield_name == "" then
			wield_name = "air"
			is_visible = false
		end
		if wield_name ~= wield_item then
			self.object:set_properties({wield_item=wield_name, is_visible=is_visible})
			log.action("%s: change wield_item from %s to %s", ent.inventory_name, wield_item, wield_name)
		end
	end

	-- this is created and attached when the villager is activated
	minetest.register_entity("working_villages:wield_entity", {
		visual        = "wielditem",
		wield_item    = "air",
		--visual_size   = {x = 0.025, y = 0.025},
		visual_size   = {x=0.25, y=0.25},
		collisionbox  = {0, 0, 0, 0, 0, 0},
		physical      = false,
		pointable     = false,
		static_save   = false,
		is_visible    = false,
		on_step       = on_step,
	})
end

---------------------------------------------------------------------

working_villages.job_inv = minetest.create_detached_inventory("working_villages:job_inv", {
	on_take = function(inv, listname, listidx, stack) --inv, listname, index, stack, player
		log.action("on_take %s %s", listname, stack:get_name())
		inv:add_item(listname, stack)
	end,

	on_put = function(inv, listname, _, stack)
		log.action("on_put %s %s", listname, stack:get_name())
		if inv:contains_item(listname, stack:peek_item(1)) then
			--inv:remove_item(listname, stack)
			stack:clear()
		end
	end,
})
working_villages.job_inv:set_size("main", 32)

-- working_villages.register_job registers a definition of a new job.
function working_villages.register_job(job_name, def)
	local name = cmnp(job_name)
	working_villages.registered_jobs[name] = def
	if def.logic == nil then
		def.logic = def.logic_default
	end

	minetest.register_tool(name, {
		stack_max       = 1,
		description     = def.description,
		inventory_image = def.inventory_image,
		groups          = {not_in_creative_inventory = 1}
	})

	--working_villages.job_inv:set_size("main", #working_villages.registered_jobs)
	working_villages.job_inv:add_item("main", ItemStack(name))
end

function working_villages.register_task(task_name, def)
	if working_villages.registered_tasks[task_name] ~= nil then
		log.warning("register_task: exists %s", task_name)
	end
	if def.func == nil then
		log.warning("register_task: %s missing func", task_name)
		return
	end
	if def.priority == nil then
		log.warning("register_task: %s missing priority", task_name)
		return
	end
	def.name = task_name
	working_villages.registered_tasks[task_name] = def
end

-- working_villages.register_egg registers a definition of a new egg.
function working_villages.register_egg(egg_name, def)
	local name = cmnp(egg_name)
	working_villages.registered_eggs[name] = def

	minetest.register_tool(name, {
		description     = def.description,
		inventory_image = def.inventory_image,
		stack_max       = 1,

		on_use = function(itemstack, user, pointed_thing)
			if pointed_thing.above ~= nil and def.product_name ~= nil then
				-- set villager's direction.
				local new_villager = minetest.add_entity(pointed_thing.above, def.product_name)
				new_villager:get_luaentity():set_yaw_by_direction(
					vector.subtract(user:get_pos(), new_villager:get_pos())
				)
				new_villager:get_luaentity().owner_name = user:get_player_name()
				new_villager:get_luaentity():update_infotext()

				itemstack:take_item()
				return itemstack
			end
			return nil
		end,
	})
end

local job_coroutines = working_villages.require("job_coroutines")

-- working_villages.register_villager registers a definition of a new villager.
function working_villages.register_villager(product_name, def)
	local name = cmnp(product_name)
	def.product_name = name
	working_villages.registered_villagers[name] = def

	-- register a definition of a new villager.
	minetest.register_entity(name, working_villages.villager.new(def))
	log.warning("registered %s", name)

	-- register villager egg.
	working_villages.register_egg(name .. "_egg", {
		description     = name .. " egg",
		inventory_image = def.egg_image,
		product_name    = name,
	})
end

working_villages.tasks = working_villages.require("job_tasks")
