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

working_villages.registered_villagers = {}
working_villages.active_villagers = {}

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
	if working_villages.registered_villagers[name] then
		return true
	end
	return false
end

---------------------------------------------------------------------

working_villages.villager = working_villages.require("villager")

working_villages.require("async_actions")

---------------------------------------------------------------------

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

--------------------------------------------------------------------

-- register empty item entity definition.
-- this entity may be hold by villager's hands.
do
	minetest.register_craftitem("working_villages:dummy_empty_craftitem", {
		wield_image = "working_villages_dummy_empty_craftitem.png",
	})

	local function on_activate(self)
		-- attach to the nearest villager.
		local all_objects = minetest.get_objects_inside_radius(self.object:get_pos(), 0.1)
		for _, obj in ipairs(all_objects) do
		local luaentity = obj:get_luaentity()

		if working_villages.is_villager(luaentity.name) then
			self.object:set_attach(obj, "Arm_R", {x = 0.065, y = 0.50, z = -0.15}, {x = -45, y = 0, z = 0})
			self.object:set_properties{textures={"working_villages:dummy_empty_craftitem"}}
			return
		end
		end
	end

	local function on_step(self)
		local all_objects = minetest.get_objects_inside_radius(self.object:get_pos(), 0.1)
		for _, obj in ipairs(all_objects) do
			local luaentity = obj:get_luaentity()

			if working_villages.is_villager(luaentity.name) then
				local stack = luaentity:get_wield_item_stack()

				if stack:get_name() ~= self.itemname then
					if stack:is_empty() then
						self.itemname = ""
						self.object:set_properties{textures={"working_villages:dummy_empty_craftitem"}}
					else
						self.itemname = stack:get_name()
						self.object:set_properties{textures={self.itemname}}
					end
				end
				return
			end
		end
		-- if cannot find villager, delete empty item.
		self.object:remove()
		return
	end

	minetest.register_entity("working_villages:dummy_item", {
		hp_max		    = 1,
		visual		    = "wielditem",
		visual_size	  = {x = 0.025, y = 0.025},
		collisionbox	= {0, 0, 0, 0, 0, 0},
		physical	    = false,
		textures	    = {"air"},
		on_activate	  = on_activate,
		on_step       = on_step,
		itemname      = "",
	})
end

---------------------------------------------------------------------

working_villages.job_inv = minetest.create_detached_inventory("working_villages:job_inv", {
	on_take = function(inv, listname, _, stack) --inv, listname, index, stack, player
		inv:add_item(listname,stack)
	end,

	on_put = function(inv, listname, _, stack)
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
local forms = working_villages.require("forms")

-- copied from mobkit
local function sensors()
	local timer = 2
	local pulse = 1
	return function(self)
		timer = timer - self.dtime
		if timer < 0 then
			pulse = pulse + 1 -- do full range every third scan
			local range = self.view_range
			if pulse > 2 then
				pulse = 1
			else
				range = self.view_range * 0.5
			end

			local pos = self.object:get_pos()
			self.nearby_objects = minetest.get_objects_inside_radius(pos, range)
			-- remove self from the list
			for i,obj in ipairs(self.nearby_objects) do
				if obj == self.object then
					table.remove(self.nearby_objects, i)
					break
				end
			end
			timer = 2
		end
	end
end

-- working_villages.register_villager registers a definition of a new villager.
function working_villages.register_villager(product_name, def)
	local name = cmnp(product_name)
	working_villages.registered_villagers[name] = def

	-- initialize manufacturing number of a new villager.
	if working_villages.manufacturing_data[name] == nil then
		working_villages.manufacturing_data[name] = 0
	end

	-- create_inventory creates a new inventory, and returns it.
	local function create_inventory(self)
		self.inventory_name = self.product_name .. "_" .. tostring(self.manufacturing_number)
		local inventory = minetest.create_detached_inventory(self.inventory_name, {
			on_put = function(_, listname, _, stack) --inv, listname, index, stack, player
				if listname == "job" then
					local job_name = stack:get_name()
					local job = working_villages.registered_jobs[job_name]
					if type(job.logic)=="function" then
						log.warning("Set job %s", job_name)
						self.logic = job.logic
					elseif type(job.on_start)=="function" then
						job.on_start(self)
						self.job_thread = coroutine.create(job.on_step)
					elseif type(job.jobfunc)=="function" then
						self.job_thread = coroutine.create(job.jobfunc)
					end
					self:set_displayed_action("active")
					self:set_state_info(("I started working as %s."):format(job.description))
				end
			end,

			allow_put = function(inv, listname, _, stack) --inv, listname, index, stack, player
				-- only jobs can put to a job inventory.
				if listname == "main" then
					return stack:get_count()
				elseif listname == "job" and working_villages.is_job(stack:get_name()) then
					if not inv:is_empty("job") then
						inv:remove_item("job", inv:get_list("job")[1])
					end
					return stack:get_count()
				elseif listname == "wield_item" then
					return 0
				end
				return 0
			end,

			on_take = function(_, listname, _, stack) --inv, listname, index, stack, player
				if listname == "job" then
					local job_name = stack:get_name()
					local job = working_villages.registered_jobs[job_name]
					self.time_counters = {}
					if job then
						if type(job.logic)=="function" then
							log.warning("Set job %s", job_name)
							self.logic = job.logic
						elseif type(job.on_stop)=="function" then
							job.on_stop(self)
						elseif type(job.jobfunc)=="function" then
							self.job_thread = false
						end
					end
					self:set_state_info("I stopped working.")
					self:update_infotext()
				end
			end,

			allow_take = function(_, listname, _, stack) --inv, listname, index, stack, player
				if listname == "wield_item" then
					return 0
				end
				return stack:get_count()
			end,

			on_move = function(inv, from_list, _, to_list, to_index)
				--inv, from_list, from_index, to_list, to_index, count, player
				if to_list == "job" or from_list == "job" then
					local job_name = inv:get_stack(to_list, to_index):get_name()
					local job = working_villages.registered_jobs[job_name]

					if to_list == "job" then
						if type(job.logic)=="function" then
							log.warning("Set job %s", job_name)
							self.logic = job.logic
							self:task_clear()
						elseif type(job.on_start)=="function" then
							job.on_start(self)
							self.job_thread = coroutine.create(job.on_step)
						elseif type(job.jobfunc)=="function" then
							self.job_thread = coroutine.create(job.jobfunc)
						end
					elseif from_list == "job" then
						if type(job.logic)=="function" then
							log.warning("Set job %s", job_name)
							self.logic = job.logic
							self:task_clear()
						elseif type(job.on_stop)=="function" then
							job.on_stop(self)
						elseif type(job.jobfunc)=="function" then
							self.job_thread = false
						end
					end

					self:set_displayed_action("active")
					self:set_state_info(("I started working as %s."):format(job.description))
				end
			end,

			allow_move = function(inv, from_list, from_index, to_list, _, count)
				--inv, from_list, from_index, to_list, to_index, count, player
				if to_list == "wield_item" then
					return 0
				end

				if to_list == "main" then
					return count
				elseif to_list == "job" and working_villages.is_job(inv:get_stack(from_list, from_index):get_name()) then
					return count
				end
				return 0
			end,
		})

		inventory:set_size("main", 16)
		inventory:set_size("job",  1)
		inventory:set_size("wield_item", 1)

		return inventory
	end

	local function fix_pos_data(self)
		if self:has_home() then
			-- share some data from building sign
			local sign = self:get_home()
			self.pos_data.home_pos = sign:get_door()
			self.pos_data.bed_pos = sign:get_bed()
		end
		if self.village_name then
			-- TODO: share pos data from central village data
			--local village = working_villages.get_village(self.village_name)
			--if village then
				--self.pos_data = village:get_villager_pos_data(self.inventory_name)
			--end
			-- remove this later
			return -- do semething for luacheck
		end
	end

	-- on_activate is a callback function that is called when the object is created or recreated.
	local function on_activate(self, staticdata)
		log.warning("on_activate: product=[%s] name=[%s]", self.product_name, name)
		-- parse the staticdata, and compose a inventory.
		if staticdata == "" then
			self.product_name = name
			self.manufacturing_number = working_villages.manufacturing_data[name]
			working_villages.manufacturing_data[name] = working_villages.manufacturing_data[name] + 1
			create_inventory(self)

			-- attach dummy item to new villager.
			minetest.add_entity(self.object:get_pos(), "working_villages:dummy_item")
		else
			-- if static data is not empty string, this object has beed already created.
			local data = minetest.deserialize(staticdata)

			self.product_name = data.product_name
			self.manufacturing_number = data.manufacturing_number
			self.nametag = data.nametag
			self.owner_name = data.owner_name
			self.pause = data.pause
			self.job_data = data.job_data
			self.state_info = data.state_info
			self.pos_data = data.pos_data
			self.memory = data.memory

			local inventory = create_inventory(self)
			for list_name, list in pairs(data["inventory"]) do
				inventory:set_list(list_name, list)
			end
			fix_pos_data(self)
		end

		if type(self.memory) ~= "table" then
			self.memory = {}
		end

		working_villages.active_villagers[self.inventory_name] = self

		log.warning("on_activate: (below) inventory_name=%s", self.inventory_name)
		self.sensefunc = sensors()

		--hp
		self.max_hp = self.max_hp or 10
		self.hp = self.hp or self.max_hp
		self.time_total = 0
		self.water_drag = self.water_drag or 1

		--armor
		if type(self.armor_groups) ~= 'table' then
			self.armor_groups={}
		end
		--self.armor_groups.immortal = 1
		--self.object:set_armor_groups(self.armor_groups)

		self.buoyancy = self.buoyancy or 0
		self.oxygen = self.oxygen or self.lung_capacity
		self.lastvelocity = {x=0,y=0,z=0}
		self.sensefunc=sensors()

		-- create task stuff
		self.task_queue = {} -- queue of tasks to run
		self.task_data = {}  -- misc data for the task
		self.task = {}       -- active task name and priority

		self:set_displayed_action("active")

		self.object:set_nametag_attributes{
			text = self.nametag
		}

		self.object:set_velocity{x = 0, y = 0, z = 0}
		self.object:set_acceleration{x = 0, y = func.gravity, z = 0}

		--legacy
		if type(self.pause) == "string" then
			self.pause = (self.pause == "resting")
		end

		local job = self:get_job()
		if job ~= nil then
			if type(job.logic)=="function" then
				self.logic = job.logic
				self:task_clear()
			elseif type(job.on_start)=="function" then
				job.on_start(self)
				self.job_thread = coroutine.create(job.on_step)
			elseif type(job.jobfunc)=="function" then
				self.job_thread = coroutine.create(job.jobfunc)
			end
			if self.pause then
				if type(job.on_pause)=="function" then
					job.on_pause(self)
				end
				self:set_displayed_action("resting")
			end
		end
	end

	local function on_deactivate(self, removal)
		log.warning("deactivate %s removal=%s", self.inventory_name, tostring(removal))
		working_villages.active_villagers[self.inventory_name] = nil
	end

	-- get_staticdata is a callback function that is called when the object is destroyed.
	-- it is used to save any instance data that needs to be preserved
	local function get_staticdata(self)
		local inventory = self:get_inventory()
		local data = {
			product_name = self.product_name,
			manufacturing_number = self.manufacturing_number,
			nametag = self.nametag,
			owner_name = self.owner_name,
			inventory = {},
			pause = self.pause,
			job_data = self.job_data,
			state_info = self.state_info,
			pos_data = self.pos_data,
			memory = self.memory,
		}

		-- set lists.
		for list_name, list in pairs(inventory:get_lists()) do
			data["inventory"][list_name] = {}
			for i, item in ipairs(list) do
				data["inventory"][list_name][i] = item:to_string()
			end
		end

		return minetest.serialize(data)
	end

	-- on_step is a callback function that is called every delta times.
	local function on_step(self, dtime, colinfo)
		-- copied from mobkit
		self.dtime = math.min(dtime,0.2)
		self.colinfo = colinfo
		self.height = func.get_box_height(self)

		local need_jump = false

		-- physics comes first
		local vel = self.object:get_velocity()
		if colinfo then
			self.isonground = colinfo.touching_ground
			-- get the node that we are standing on
			local logit = #colinfo.collisions > 1
			for _, ci in ipairs(colinfo.collisions) do
				if ci.type == "node" then
					if logit then
						log.action("collide %s axis %s", minetest.pos_to_string(ci.node_pos), tostring(ci.axis))
					end
					if ci.axis == 'y' then
						local rpos = vector.round(ci.node_pos)
						if self.stand_pos == nil or not vector.equals(self.stand_pos, rpos) then
							-- FIXME: why is this logging constantly? is something else clearing it?
							--log.action("set stand_pos=%s", minetest.pos_to_string(rpos))
							self.stand_pos = rpos
						end
						break
					else
						need_jump = true
					end
				end
			end
		else
			if self.lastvelocity.y==0 and vel.y==0 then
				self.isonground = true
			else
				self.isonground = false
			end
		end
		self:physics()

		if need_jump then
			vel.y = 4
			self.object:set_velocity(vel)
		end

		if not self.pause then
			-- pickup surrounding item.
			self:pickup_items()

			if self.logic then
				if self.view_range then
					self:sensefunc()
				end
				self:logic()
				self:task_execute()
			end
		end

		self.lastvelocity = self.object:get_velocity()
		self.time_total = self.time_total + self.dtime
	end

	-- on_rightclick is a callback function that is called when a player right-click them.
	local function on_rightclick(self, clicker)
		local wielded_stack = clicker:get_wielded_item()
		if wielded_stack:get_name() == "working_villages:commanding_sceptre"
			and (self.owner_name == "working_villages:self_employed"
			or clicker:get_player_name() == self.owner_name or
			minetest.check_player_privs(clicker, "debug"))
		then
			forms.show_formspec(self, "working_villages:inv_gui", clicker:get_player_name())
		else
			forms.show_formspec(self, "working_villages:talking_menu", clicker:get_player_name())
		end
	end

	-- on_punch is a callback function that is called when a player punches a villager.
	local function on_punch()--self, puncher, time_from_last_punch, tool_capabilities, dir
		--TODO: aggression (add player ratings table)
	end

	-- register a definition of a new villager.

	local villager_def = working_villages.villager:new({
		-- these are the required minetest "Object properties"
		initial_properties = {
			hp_max                      = def.hp_max, -- valid, unused
			mesh                        = def.mesh,
			textures                    = def.textures,

			--TODO: put these into working_villagers.villager
			physical                    = true,
			visual                      = "mesh",
			visual_size                 = {x = 1, y = 1},
			collisionbox                = {-0.25, 0, -0.25, 0.25, 1.75, 0.25},
			pointable                   = true,
			stepheight                  = 0.6,
			is_visible                  = true,
			makes_footstep_sound        = true,
			automatic_face_movement_dir = false,
			infotext                    = "",
			nametag                     = "hello",
			static_save                 = true,
			show_on_minimap             = true,
			damage_texture_modifier     = "^[brighten",
		},

		-- extra initial properties
		weight                      = def.weight, -- ??
		max_hp                      = def.hp_max or 10,

		pause                       = false,
		disp_action                 = "inactive\nNo job",
		state                       = "job",
		state_info                  = "I am doing nothing particular.",
		job_thread                  = false,
		product_name                = product_name,
		manufacturing_number        = -1,
		owner_name                  = "",
		time_counters               = {},
		destination                 = vector.new(0,0,0),
		job_data                    = {},
		pos_data                    = {},
		new_job                     = "",

		view_range                  = 10, -- can see objects in this range
		lung_capacity               = 30, -- seconds

		-- callback methods
		on_activate                 = on_activate,
		on_deactivate               = on_deactivate,
		on_step                     = on_step,
		on_rightclick               = on_rightclick,
		on_punch                    = on_punch,
		get_staticdata              = get_staticdata,

		-- storage methods
		get_stored_table            = working_villages.get_stored_villager_table,
		set_stored_table            = working_villages.set_stored_villager_table,
		clear_cached_table          = working_villages.clear_cached_villager_table,

		-- home methods
		get_home                    = working_villages.get_home,
		has_home                    = working_villages.is_valid_home,
		set_home                    = working_villages.set_home,
		remove_home                 = working_villages.remove_home,
	})

	minetest.register_entity(name, villager_def)
	log.warning("registered %s", name)

	-- register villager egg.
	working_villages.register_egg(name .. "_egg", {
		description     = name .. " egg",
		inventory_image = def.egg_image,
		product_name    = name,
	})
end
