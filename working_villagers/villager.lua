--[[
This file should contain everything needed for a dumb villager.
No logic/brain stuff here.
 - creation
 - egg
 - physic
 - utility functions
]]
local log = working_villages.require("log")
local cmnp = modutil.require("check_prefix","venus")
local pathfinder = working_villages.require("nav/pathfinder")
local func = working_villages.require("jobs/util")
local forms = working_villages.require("forms")
--local tasks = working_villages.tasks -- require("job_tasks")

---------------------------------------------------------------------

-- villager represents a table that contains common methods
-- for villager object.
-- this table must be contains by a metatable.__index of villager self tables.
-- minetest.register_entity set initial properties as a metatable.__index, so
-- this table's methods must be put there.
local villager = {}

-- create_inventory creates a new inventory, and returns it.
function villager:create_inventory()
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
			-- removing a wield_item may break the AI scripts
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

-- villager.get_inventory returns a inventory of a villager.
function villager:get_inventory()
	return minetest.get_inventory {
		type = "detached",
		name = self.inventory_name,
	}
end

-- Same as object:get_wield_list()
function villager:get_wield_list()
	return "wield_item"
end

-- Same as object:get_wield_index()
function villager:get_wield_index()
	return 1
end

-- Same as object:get_wielded_item()
function villager:get_wielded_item()
	return self:get_inventory():get_stack("wield_item", 1)
end

-- Same as object:set_wielded_item(item)
function villager:set_wielded_item(item)
	self:get_inventory():set_stack("wield_item", 1, item)
	return true
end

--[[
Add up all the inventory items by group for the list of groups.
For example, the woodcutter would want { "tree", "sapling" } to see if
it over the carry limit.

REVISIT: maybe a key/value pair where the key is the variable to set and the
   val is either a group name, a table of group names or a function to call to
   determine if it should be counted.
]]
function villager:count_inventory_groups(groups)
	local inv = self:get_inventory()

	local grp_cnt = {}
	for _, gname in ipairs(groups) do
		grp_cnt[gname] = 0
	end
	for _, stack in pairs(inv:get_lists()) do
		for _, istack in ipairs(stack) do
			local node_name = istack:get_name()
			for _, gname in ipairs(groups) do
				if minetest.get_item_group(node_name, gname) > 0 then
					grp_cnt[gname] = grp_cnt[gname] + istack:get_count()
				end
			end
		end
	end
	return grp_cnt
end

-- REVISIT: probably going to remove this
function villager:count_inventory_group(group_name)
	return self:count_inventory_groups({group_name})[group_name]
end

--[[
Count the matching inventory item names.
If an item in @items isn't present, it won't be in the return value.

@items is a map with key=item name, val=don't care
]]
function villager:count_inventory_items(items)
	local inv = self:get_inventory()

	local item_cnt = {}
	for _, stack in pairs(inv:get_lists()) do
		for _, istack in ipairs(stack) do
			local name = istack:get_name()
			if items[name] ~= nil then
				item_cnt[name] = (item_cnt[name] or 0) + istack:get_count()
			end
		end
	end
	return item_cnt
end

-- villager.get_job_name returns a name of a villager's current job.
function villager:get_job_name()
	local inv = self:get_inventory()

	local new_job = self.object:get_luaentity().new_job
	if new_job ~= "" then
		self.object:get_luaentity().new_job = ""
		local job_stack = ItemStack(new_job)
		inv:set_stack("job", 1, job_stack)
		return new_job
	end

	return inv:get_stack("job", 1):get_name()
end

-- villager.get_job returns a villager's current job definition.
function villager:get_job()
	local name = self:get_job_name()
	if name ~= "" then
		return working_villages.registered_jobs[name]
	end
	return nil
end

-- villager.is_enemy returns if an object is an enemy.
function villager:is_enemy(obj)
	log.verbose("villager %s checks if %s is hostile",self.inventory_name,obj)
	--TODO
	return false
end

-- villager.get_nearest_player returns a player object who
-- is the nearest to the villager, the position of and the distance to the player.
function villager:get_nearest_player(range_distance,pos)
	local min_distance = range_distance
	local player,ppos
	local position = pos or self.object:get_pos()

	local all_objects = minetest.get_objects_inside_radius(position, range_distance)
	for _, object in pairs(all_objects) do
		if object:is_player() then
			local player_position = object:get_pos()
			local distance = vector.distance(position, player_position)

			if distance < min_distance then
				min_distance = distance
				player = object
				ppos = player_position
			end
		end
	end
	return player,ppos,min_distance
end

-- villager.get_nearest_enemy returns an enemy who is the nearest to the villager.
function villager:get_nearest_enemy(range_distance)
	local enemy
	local min_distance = range_distance
	local position = self.object:get_pos()

	local all_objects = minetest.get_objects_inside_radius(position, range_distance)
	for _, object in pairs(all_objects) do
		if self:is_enemy(object) then
			local object_position = object:get_pos()
			local distance = vector.distance(position, object_position)

			if distance < min_distance then
				min_distance = distance
				enemy = object
			end
		end
	end
	return enemy
end

-- villager.get_nearest_item_by_condition returns the position of
-- an item that returns true for the condition
function villager:get_nearest_item_by_condition(cond, range_distance)
	local max_distance=range_distance
	if type(range_distance) == "table" then
		max_distance=math.max(math.max(range_distance.x,range_distance.y),range_distance.z)
	end
	local item = nil
	local min_distance = max_distance
	local position = self.object:get_pos()

	local all_objects = minetest.get_objects_inside_radius(position, max_distance)
	for _, object in pairs(all_objects) do
		if not object:is_player() and object:get_luaentity() and object:get_luaentity().name == "__builtin:item" then
			local found_item = ItemStack(object:get_luaentity().itemstring):to_table()
			if found_item then
				local item_position = object:get_pos()
				if cond(found_item, item_position) then
					local distance = vector.distance(position, item_position)

					if distance < min_distance then
						min_distance = distance
						item = object
					end
				end
			end
		end
	end
	return item;
end

-- villager.get_nearest_item_by_condition returns the position of
-- an item that returns true for the condition
function villager:get_items_by_condition(cond, range_distance)
	local max_distance=range_distance
	if type(range_distance) == "table" then
		max_distance=math.max(math.max(range_distance.x,range_distance.y),range_distance.z)
	end
	local items = {}
	local min_distance = max_distance
	local position = self.object:get_pos()

	local all_objects = minetest.get_objects_inside_radius(position, max_distance)
	for _, object in pairs(all_objects) do
		if not object:is_player() and object:get_luaentity() and object:get_luaentity().name == "__builtin:item" then
			local found_item = ItemStack(object:get_luaentity().itemstring):to_table()
			if found_item ~= nil and cond(found_item, object:get_pos()) then
				table.insert(items, object)
			end
		end
	end
	return items
end

-- Scans the list of self.nearby_objects and returns matches
function villager:get_nearby_objects_by_condition(cond)
	local items = {}
	if self.nearby_objects ~= nil then
		for _, object in pairs(self.nearby_objects) do
			if not object:is_player() and object:get_luaentity() and object:get_luaentity().name == "__builtin:item" then
				local found_item = ItemStack(object:get_luaentity().itemstring):to_table()
				if found_item ~= nil and cond(found_item, object:get_pos()) then
					table.insert(items, object)
				end
			end
		end
	end
	return items
end

-- villager.get_front returns a position in front of the villager.
function villager:get_front()
	local direction = self:get_look_direction()
	if math.abs(direction.x) >= 0.5 then
		if direction.x > 0 then
			direction.x = 1
		else
			direction.x = -1
		end
	else
		direction.x = 0
	end

	if math.abs(direction.z) >= 0.5 then
		if direction.z > 0 then
			direction.z = 1
		else
			direction.z = -1
		end
	else
		direction.z = 0
	end

	--direction.y = direction.y - 1

	return vector.add(vector.round(self.object:get_pos()), direction)
end

-- villager.get_front_node returns a node that exists in front of the villager.
function villager:get_front_node()
	local front = self:get_front()
	return minetest.get_node(front)
end

-- villager.get_back returns a position behind the villager.
function villager:get_back()
	local direction = self:get_look_direction()
	if math.abs(direction.x) >= 0.5 then
		if direction.x > 0 then
			direction.x = -1
		else
			direction.x = 1
		end
	else
		direction.x = 0
	end

	if math.abs(direction.z) >= 0.5 then
		if direction.z > 0 then
			direction.z = -1
		else
			direction.z = 1
		end
	else
		direction.z = 0
	end

	--direction.y = direction.y - 1

	return vector.add(vector.round(self.object:get_pos()), direction)
end

-- villager.get_back_node returns a node that exists behind the villager.
function villager:get_back_node()
	local back = self:get_back()
	return minetest.get_node(back)
end

-- villager.get_look_direction returns a normalized vector that is
-- the villagers's looking direction.
function villager:get_look_direction()
	local yaw = self.object:get_yaw()
	return vector.normalize{x = -math.sin(yaw), y = 0.0, z = math.cos(yaw)}
end

local function calc_lay_collision_box(self)
	local dir = self:get_look_direction()
	local dirx = math.abs(dir.x) * 0.5
	local dirz = math.abs(dir.z) * 0.5
	return { -0.5 - dirx, 0, -0.5 - dirz, 0.5 + dirx, 0.5, 0.5 + dirz }
end

function villager:get_animation()
	return self._anim
end

function villager:animate(anim)
	if self.animation and self.animation[anim] then
		if self._anim == anim then
			return
		end
		log.action("%s: animate %s", self.inventory_name, anim)

		local aparms = self.animation[anim]
		if #aparms > 0 and aparms.range == nil then
			log.warning("multiple animations for %s", anim)
			aparms = self.animation[anim][math.random(#self.animation[anim])]
		end

		self.object:set_animation(aparms.range, aparms.speed or 15, aparms.frame_blend or 0, aparms.loop)

		local cbox
		if type(aparms.collisionbox) == "table" then
			cbox = aparms.collisionbox
		elseif type(aparms.collisionbox) == "function" then
			cbox = aparms.collisionbox(self)
		else
			cbox = self.initial_properties.collisionbox
		end

		self.object:set_properties({collisionbox=cbox, selectionbox=cbox})
		self._anim = anim
	else
		self._anim = nil
	end
end

-- villager.set_animation sets the villager's animation.
-- this method is wrapper for self.object:set_animation.
-- deprecated
function villager:set_animation(frame)
	self.object:set_animation(frame, 15, 0)
	if frame == working_villages.animation_frames.LAY then
		local dir = self:get_look_direction()
		local dirx = math.abs(dir.x)*0.5
		local dirz = math.abs(dir.z)*0.5
		self.object:set_properties({collisionbox=calc_lay_collision_box(self)})
	else
		self.object:set_properties({collisionbox=self.initial_properties.collisionbox})
	end
end

-- villager.set_yaw_by_direction sets the villager's yaw
-- by a direction vector.
function villager:set_yaw_by_direction(direction)
	self.object:set_yaw(math.atan2(direction.z, direction.x) - math.pi / 2)
end

-- villager.add_item_to_main add item to main slot.
-- and returns leftover.
function villager:add_item_to_main(stack)
	local inv = self:get_inventory()
	return inv:add_item("main", stack)
end

function villager:replace_item_from_main(rstack, astack)
	local inv = self:get_inventory()
	inv:remove_item("main", rstack)
	inv:add_item("main", astack)
end

-- villager.move_main_to_wield moves itemstack from main to wield.
-- if this function fails then returns false, else returns true.
function villager:move_main_to_wield(pred)
	local inv = self:get_inventory()
	local main_size = inv:get_size("main")

	for i = 1, main_size do
		local stack = inv:get_stack("main", i)
		if pred(stack:get_name()) then
			local wield_stack = inv:get_stack("wield_item", 1)
			inv:set_stack("wield_item", 1, stack)
			inv:remove_item("main", stack)
			inv:add_item("main", wield_stack)
			return true
		end
	end
	return false
end

-- Move the wield itemstack to main, clearing the wielded item.
function villager:move_wield_to_main()
	local inv = self:get_inventory()
	local wield_stack = inv:get_stack("wield_item", 1)
	if wield_stack:get_name() ~= "" then
		inv:add_item("main", wield_stack)
		inv:set_stack("wield_item", 1, ItemStack())
	end
end

-- villager.has_item_in_main reports whether the villager has item.
function villager:has_item_in_main(pred)
	local inv = self:get_inventory()
	local stacks = inv:get_list("main")

	for _, stack in ipairs(stacks) do
		local itemname = stack:get_name()
		if pred(itemname) then
			return true
		end
	end
end

--[[
Equip the best tool for digging the given node.
If there is nothing suitable, the 'hand' is equipped.

There are a few damage groups: crumbly, cracky, choppy, fleshy, and snappy.
And there is "oddly_breakable_by_hand".

But we are going with brute force here.
@return whether the wielded item changed, info {diggable, time, wear}
]]
function villager:wield_best_for_dig(node_name)
	local nodedef = minetest.registered_nodes[node_name]
	local inv = self:get_inventory()
	local old_wield = inv:get_stack("wield_item", 1):get_name()

	-- TODO: remember the previous results and use the same tool
	-- memory.dig_tool[node][tool] = gametime

	local istack_none = ItemStack()
	local hand = minetest.get_tool_capabilities

	local best = {}
	local function check_tool(istack, skip_tool_check)
		local name = istack:get_name()
		--log.action("check_tool %s", name)
		if not skip_tool_check then
			local tool = minetest.registered_tools[name]
			if not (tool and tool.tool_capabilities) then
				return
			end
		end
		local ii = minetest.get_dig_params(nodedef.groups, istack:get_tool_capabilities())
		log.action("check_tool: %s", dump(ii))
		if ii.diggable and (best.time == nil or best.time > ii.time) then
			best.name = istack:get_name()
			best.istack = istack
			best.time = ii.time
			best.wear = ii.wear
		end
	end

	for _, stack in pairs(inv:get_lists()) do
		-- We only need to scan "wield_item" and "main" (not job), but whatever
		for _, istack in ipairs(stack) do
			if istack:get_name() ~= "" then
				check_tool(istack, false)
			end
		end
	end
	-- try using the hand
	if best.istack == nil then
		check_tool(ItemStack())
	end

	local changed = false
	if best.istack == nil or best.name == "" then
		log.action("%s: wielding my fist", self.inventory_name)
		if old_wield ~= "" then
			self:move_wield_to_main()
			changed = true
		end
	else
		log.action("%s: wielding %s", self.inventory_name, best.name)
		if best.tool ~= old_wield then
			self:move_main_to_wield(function (name) return name == best.name end)
			changed = true
		end
	end
	return changed, best
end

-- villager.is_named reports the villager is still named.
function villager:is_named()
	return self.nametag ~= ""
end

-- villager.change_direction change direction to destination and velocity vector.
function villager:change_direction(destination)
	local position = self.object:get_pos()
	local direction = vector.subtract(destination, position)

	--log.action("change_direction %s to %s dir=%s dist=%s",
	--	minetest.pos_to_string(position),
	--	minetest.pos_to_string(destination),
	--	minetest.pos_to_string(direction), tostring(vector.length(direction)))

	local function do_climb(node, dy)
		local rpos = vector.round(position)
		self.object:set_velocity{ x=0, y=dy, z=0 }

		-- center on and face the ladder
		self.object:set_pos{x=rpos.x, y=position.y, z=rpos.z}
		self:set_yaw_by_direction(minetest.wallmounted_to_dir(node.param2))
	end

	if direction.y > 0 then
		local node = minetest.get_node(position)
		if pathfinder.is_node_climbable(node) then
			log.action("climbing up from %s to %s dy=%s",
				minetest.pos_to_string(position),
				minetest.pos_to_string(destination),
				tostring(direction.y))
			do_climb(node, 1)
			return
		end
	elseif direction.y < 0 then
		local node = minetest.get_node({x=position.x, y=position.y-1, z=position.z})
		if pathfinder.is_node_climbable(node) then
			log.action("climbing down from %s to %s dy=%s",
				minetest.pos_to_string(position),
				minetest.pos_to_string(destination),
				tostring(direction.y))
			do_climb(node, -1)
			return
		end
	end

	direction.y = 0
	local velocity = vector.multiply(vector.normalize(direction), 1.5)
	log.action("change_direction %s to %s dir=%s dist=%s vel=%s",
		minetest.pos_to_string(position),
		minetest.pos_to_string(destination),
		minetest.pos_to_string(direction), tostring(vector.length(direction)),
		minetest.pos_to_string(velocity))

	self.object:set_velocity(velocity)
	self:set_yaw_by_direction(direction)
end

-- villager.change_direction_randomly change direction randonly.
function villager:change_direction_randomly()
	local direction = {
		x = math.random(0, 5) * 2 - 5,
		y = 0,
		z = math.random(0, 5) * 2 - 5,
	}
	local velocity = vector.multiply(vector.normalize(direction), 1.5)
	self.object:set_velocity(velocity)
	self:set_yaw_by_direction(direction)
	--self:set_animation(working_villages.animation_frames.WALK)
	self:animate("walk")
end

-- villager.get_timer get the value of a counter.
function villager:get_timer(timerId)
	return self.time_counters[timerId]
end

-- villager.set_timer set the value of a counter.
function villager:set_timer(timerId,value)
	assert(type(value)=="number","timers need to be countable")
	self.time_counters[timerId]=value
end

-- villager.clear_timers set all counters to 0.
function villager:clear_timers()
	for timerId,_ in pairs(self.time_counters) do
		self.time_counters[timerId] = 0
	end
end

-- villager.count_timer count a counter up by 1.
function villager:count_timer(timerId)
	if not self.time_counters[timerId] then
		log.info("villager %s timer %q was not initialized", self.inventory_name,timerId)
		self.time_counters[timerId] = 0
	end
	self.time_counters[timerId] = self.time_counters[timerId] + 1
end

-- villager.count_timers count all counters up by 1.
function villager:count_timers()
	for id, counter in pairs(self.time_counters) do
		self.time_counters[id] = counter + 1
	end
end

-- villager.timer_exceeded if a timer exceeds the limit it will be reset and true is returned
function villager:timer_exceeded(timerId,limit)
	if self:get_timer(timerId)>=limit then
		self:set_timer(timerId,0)
		return true
	else
		return false
	end
end

-- villager.update_infotext updates the infotext of the villager.
function villager:update_infotext()
	local infotext = ""
	local job_name = self:get_job()

	if job_name ~= nil then
		job_name = job_name.description
		infotext = infotext .. job_name .. "\n"
	else
		infotext = infotext .. "no job\n"
		self.disp_action = "inactive"
	end
	infotext = infotext .. "[Owner] : " .. self.owner_name
	infotext = infotext .. "\nthis villager is " .. self.disp_action
	if self.pause then
		infotext = infotext .. ", [paused]"
	end
	if self.task.name ~= nil then
		infotext = infotext .. string.format("\ntask %s pri=%d", self.task.name, self.task.priority)
	end

	self.object:set_properties{infotext = infotext}
end

-- villager.is_near checks if the villager is within the radius of a position
function villager:is_near(pos, distance)
	local p = self.object:get_pos()
	p.y = p.y + 0.5 -- need node center ?
	return vector.distance(p, pos) < distance
end

function villager:handle_liquids()
	local ctrl = self.object
	local pos = self.object:get_pos()
	local inside_node = minetest.get_node(pos)
	-- perhaps only when changed
	if minetest.get_item_group(inside_node.name,"liquid") > 0 then
		-- swim
		local viscosity = minetest.registered_nodes[inside_node.name].liquid_viscosity
		ctrl:set_acceleration{x = 0, y = -self.initial_properties.weight/(100*viscosity), z = 0}
	elseif pathfinder.is_node_climbable(inside_node) then
		--go down slowly
		--ctrl:set_acceleration{x = 0, y = -0.1, z = 0}
		ctrl:set_acceleration{x = 0, y = 0, z = 0}
	else
		-- Mobs can stand on climbable nodes, but the engine doesn't collide, so
		-- they fall. Stop that.
		if pathfinder.is_node_climbable(minetest.get_node({x=pos.x, y=pos.y-1, z=pos.z})) then
			ctrl:set_acceleration{x = 0, y = 0, z = 0}
		else
			-- fall. If standing on a walkable node, the engine will stop the fall.
			ctrl:set_acceleration{x = 0, y = -self.initial_properties.weight, z = 0}
		end
	end
end

function villager:jump()
	local ctrl = self.object
	local below_node = minetest.get_node(vector.subtract(ctrl:get_pos(),{x=0,y=1,z=0}))
	local velocity = ctrl:get_velocity()
	if below_node.name == "air" then
		return false
	end
	log.action("%s: Jumping", self.inventory_name)
	--local jump_force = math.sqrt(self.initial_properties.weight) * 1.5
	local jump_force = 22 -- -func.gravity * 1.5
	if minetest.get_item_group(below_node.name,"liquid") > 0 then
		local viscosity = minetest.registered_nodes[below_node.name].liquid_viscosity
		jump_force = jump_force/(viscosity*100)
	end
	ctrl:set_velocity{x = velocity.x, y = jump_force, z = velocity.z}
end

--[[
villager.handle_obstacles(ignore_fence,ignore_doors)
if the villager hits a walkable he will jump
if ignore_fence is false the villager will not jump over fences
if ignore_doors is false and the villager hits a door he opens it
]]
function villager:handle_obstacles(ignore_fence, ignore_doors)
	local velocity = self.object:get_velocity()
	local front_diff = self:get_look_direction()
	for i,v in pairs(front_diff) do
		local front_pos = vector.new(0,0,0)
		front_pos[i] = v
		front_pos = vector.add(front_pos, vector.round(self.object:get_pos()))
		front_pos.y = math.floor(self.object:get_pos().y)+0.5
		local above_node = vector.new(front_pos)
		local front_node = minetest.get_node(front_pos)
		above_node = vector.add(above_node,{x=0,y=1,z=0})
		above_node = minetest.get_node(above_node)
		if minetest.get_item_group(front_node.name, "fence") > 0 and not(ignore_fence) then
			self:change_direction_randomly()
		elseif string.find(front_node.name,"doors:door") and not(ignore_doors) then
			local door = doors.get(front_pos)
			local door_dir = vector.apply(minetest.facedir_to_dir(front_node.param2),math.abs)
			local villager_dir = vector.round(vector.apply(front_diff,math.abs))
			if vector.equals(door_dir,villager_dir) then
				if door:state() then
					door:close()
				else
					door:open()
				end
			end
		elseif minetest.registered_nodes[front_node.name].walkable
		and not(minetest.registered_nodes[above_node.name].walkable) then
			log.action("%s: need jump? vel=%s", self.inventory_name, minetest.pos_to_string(velocity))
			if velocity.y == 0 then
				local nBox = minetest.registered_nodes[front_node.name].node_box
				if (nBox == nil) then
					nBox = {-0.5,-0.5,-0.5,0.5,0.5,0.5}
				else
					nBox = nBox.fixed
				end
				if type(nBox[1])=="number" then
					nBox = {nBox}
				end
				log.action(" nBox=%s", dump(nBox))
				for _,box in pairs(nBox) do --TODO: check rotation of the nodebox
					local nHeight = (box[5] - box[2]) + front_pos.y
					--if nHeight > self.object:get_pos().y + .5 then
						--self:jump()
					--end
				end
			end
		end
	end
	if not ignore_doors then
		local back_pos = self:get_back()
		if string.find(minetest.get_node(back_pos).name,"doors:door") then
			local door = doors.get(back_pos)
			door:close()
		end
	end
end

-- villager.pickup_item pickup items placed and put it to main slot.
function villager:pickup_item(obj)
	if not obj:is_player() and obj:get_luaentity() and obj:get_luaentity().itemstring then
		local itemstring = obj:get_luaentity().itemstring
		local stack = ItemStack(itemstring)
		if stack ~= nil then
			local tab = stack:to_table()
			if tab ~= nil  then
				local name = tab.name

				if minetest.registered_items[name] ~= nil then
					local inv = self:get_inventory()
					local leftover = inv:add_item("main", stack)

					minetest.add_item(obj:get_pos(), leftover)
					obj:get_luaentity().itemstring = ""
					obj:remove()
				end
			end
		end
	end
end

-- villager.pickup_item pickup items placed and put it to main slot.
function villager:pickup_items()
	local pos = self.object:get_pos()
	local radius = 1.0
	local all_objects = minetest.get_objects_inside_radius(pos, radius)

	for _, obj in ipairs(all_objects) do
		self:pickup_item(obj)
	end
end

-- villager.get_job_data get a job data field
function villager:get_job_data(key)
	local actual_job_data = self.job_data[self:get_job_name()]
	if actual_job_data == nil then
		return nil
	end
	return actual_job_data[key]
end

-- villager.set_job_data set a job data field
function villager:set_job_data(key, value)
	local actual_job_data = self.job_data[self:get_job_name()]
	if actual_job_data == nil then
		actual_job_data = {}
		self.job_data[self:get_job_name()] = actual_job_data
	end
	actual_job_data[key] = value
end

-- compatibility with like player object
function villager:get_player_name()
	return self.object:get_player_name()
end

function villager:is_player()
	return false
end

--------------------------------------------------------------------

function villager:set_pause(state)
	assert(type(state) == "boolean","pause state must be a boolean")
	self.pause = state
	if state then
		self:stand_still()
	end
end

-- villager.set_displayed_action sets the text to be displayed after "this villager is "
function villager:set_displayed_action(action)
	assert(type(action) == "string","action info must be a string")
	if self.disp_action ~= action then
		self.disp_action = action
		self:update_infotext()
	end
end

-- set the text describing what the villager currently does
-- the text should be a detailed information
function villager:set_state_info(text)
	assert(type(text) == "string","state info must be a string")
	self.state_info = text
end

--------------------------------------------------------------------
-- Tasks

-- Add a task by name, with an optional priority override
function villager:task_add(name, priority)
	-- If we already added this task by name, we can only change the priority
	local info = self.task_queue[name]
	if info ~= nil then
		if priority ~= nil and info.priority ~= priority then
			info.priority = priority
		end
		return true
	end

	-- get the registered task
	info = working_villages.registered_tasks[name]
	if info == nil then
		log.warning("villager:task_add: unknown task %s", name)
		return false
	end

	local new_info = { name=name, func=info.func, priority=priority or info.priority }
	self.task_queue[name] = new_info
	log.action("%s: added task %s priority %d", self.inventory_name, new_info.name, new_info.priority)
	return true
end

-- Remove a task by name, @reason is for logging
function villager:task_del(name, reason)
	local info = self.task_queue[name]
	if info ~= nil then
		log.action("%s: removed task %s priority %d reason=%s",
			self.inventory_name, info.name, info.priority, reason)
		self.task_queue[name] = nil
	end
end

--[[ Clear all tasks, making the villager stupid for a tick
the logic() function should add something on the next tick.
This is mainly useful when changing jobs externally.
]]
function villager:task_clear()
	self.task_queue = {}
end

-- check if the named task is on the queue
function villager:task_present(name)
	return self.task_queue[name] ~= nil
end

-- get the best task
function villager:task_best()
	local best_info
	for _, info in pairs(self.task_queue) do
		if best_info == nil or info.priority > best_info.priority then
			best_info = info
		end
	end
	return best_info
end

-- this executes the best task as a coroutine
function villager:task_execute(dtime)
	local best = self:task_best()
	-- Does the coroutine exist?
	if self.task.thread ~= nil then
		local co = self.task.thread
		-- Clean up dead task or cancel no-longer-best task
		if coroutine.status(co) == "dead" then
			-- Remove the task from the queue if it returned true
			if self.task.ret == true then
				self:task_del(self.task.name, "complete")
			end
			self.task = {}
			best = self:task_best()
		elseif best == nil or best.name ~= self.task.name then
			if coroutine.close ~= nil then
				coroutine.close(co)
			end
			self.task = {}
			best = self:task_best()
		end
	end

	-- start or resume the task
	if best ~= nil then
		if self.task.thread == nil then
			self.task.name = best.name
			self.task.priority = best.priority
			self.task.thread = coroutine.create(best.func)
		end

		-- this should always be true
		if coroutine.status(self.task.thread) == "suspended" then
			local ret = {coroutine.resume(self.task.thread, self, dtime)}
			if ret[1] == true then
				self.task.ret = ret[2]
			else
				error("error in job_thread " .. ret[2]..": "..debug.traceback(self.task.thread))
				--log.warning("task %s failed: %s", self.task.name, tostring(ret[2]))
				-- remove it from the queue
				self:task_del(self.task.name, "failed")
			end
		end
	end
end

-- this is a villager function because some may work different shifts (guard?)
-- or go to bed early (farmer) or later (tarvern)
-- but for now, just dawn-to-dusk.
function villager:is_sleep_time()
	return working_villages.tasks.schedule_is_active(self, "sleep")
	--local daytime = minetest.get_timeofday()
	--return (daytime < 0.2 or daytime > 0.8)
end

-- stop moving and set the animation to STAND
function villager:stand_still()
	self.object:set_velocity{x = 0, y = 0, z = 0}
	--self:set_animation(working_villages.animation_frames.STAND)
	self:animate("stand")
end

function get_villagers_around_node(node_pos, exclude_inv_name)
	local minp = vector.new(node_pos.x - 1.5, node_pos.y - 1.5, node_pos.z - 1.5)
	local maxp = vector.new(node_pos.x + 1.5, node_pos.y + 2, node_pos.z + 1.5)
	local objs = minetest.get_objects_in_area(minp, maxp)

	local occupiers = {} -- key=inventory_name, val=lua_entity
	local blockages = {} -- key=node_pos hash, val=lua_entity
	--log.action("get_villagers_around_node: %s - %s count=%d",
	--	minetest.pos_to_string(minp), minetest.pos_to_string(maxp), #objs)
	for idx, obj in ipairs(objs) do
		local ent = obj:get_luaentity()
		if ent and working_villages.is_villager(ent.name) then
			if not exclude_inv_name or ent.inventory_name ~= exclude_inv_name then
				local hash = minetest.hash_node_position(vector.round(obj:get_pos()))
				occupiers[ent.inventory_name] = ent
				blockages[hash] = ent
				--log.action(" -- [%d] %s @ %s", idx, ent.inventory_name, minetest.pos_to_string(obj:get_pos()))
			end
		end
	end
	return occupiers, blockages
end


-- See which villagers are in a 3x3x3 node zone centered on node_pos.
-- This is used to avoid sitting in the same seat or on the same spot on the bed.
function villager:node_occupiers_around(node_pos)
	local minp = vector.new(node_pos.x - 1.5, node_pos.y - 1.5, node_pos.z - 1.5)
	local maxp = vector.new(node_pos.x + 1.5, node_pos.y + 1.5, node_pos.z + 1.5)
	local objs = minetest.get_objects_in_area(minp, maxp)

	local occupiers = {} -- key=inventory_name, val=lua_entity
	log.action("node_occupiers: %s - %s",
		minetest.pos_to_string(minp), minetest.pos_to_string(maxp))
	for idx, obj in ipairs(objs) do
		local ent = obj:get_luaentity()
		if working_villages.is_villager(ent.name) and ent.inventory_name ~= self.inventory_name then
			occupiers[ent.inventory_name] = ent
			log.action(" -- [%d] %s @ %s", idx, ent.inventory_name, minetest.pos_to_string(obj:get_pos()))
		end
	end
	return occupiers
end

local function is_occupied(occupiers)
end

-- stop moving and set the animation to SIT
function villager:sit_down(node_pos)
	log.warning("%s: called sit_down() %s",
		self.inventory_name, minetest.pos_to_string(node_pos or vector.zero()))

	if self._anim == "sit" then
		log.warning("%s: already sitting @ %s",
			self.inventory_name, minetest.pos_to_string(self.object:get_pos()))
		return false, "already sitting"
	end
	-- TODO: make sure we are close enough
	--if node_pos and not close enough then walk to the location

	node_pos = node_pos or vector.round(self.object:get_pos())

	-- get all possible sitting positions based on the node_pos
	local seats = func.get_seat_pos(node_pos)

	for idx, seat in ipairs(seats) do
		local node = minetest.get_node(seat.pos)
		log.action("%s: sit_down() [%d] on %s @ %s node %s feet %s",
			self.inventory_name, idx, node.name,
			minetest.pos_to_string(seat.pos),
			minetest.pos_to_string(seat.npos),
			minetest.pos_to_string(seat.footvec or vector.zero()))
	end

	-- get villagers around the target to see if it is free
	local occ, hsh = get_villagers_around_node(node_pos, self.inventory_name)
	--for hash, ent in pairs(hsh) do
	--	local pp = minetest.get_position_from_hash(hash)
	--	log.warning("%s: %12x nearby %s @ %s %s", self.inventory_name, hash, ent.inventory_name,
	--		minetest.pos_to_string(pp),
	--		minetest.pos_to_string(ent.object:get_pos()))
	--end

	-- try all the sitting positions
	for _, seat in ipairs(seats) do
		local above = vector.offset(seat.npos, 0, 1, 0)
		log.action("%s: trying seat @ %s butt=%s feet=%s",
			self.inventory_name, minetest.pos_to_string(seat.npos),
			minetest.pos_to_string(seat.pos),
			minetest.pos_to_string(seat.footvec or vector.zero()))
		if pathfinder.is_node_collidable(above) then
			log.warning("%s: cannot sit_down @ %s, as node above is %s",
				self.inventory_name, minetest.pos_to_string(node_pos), minetest.get_node(above).name)
		else
			-- make sure the seat isn't blocked
			local hash = minetest.hash_node_position(seat.npos)
			log.action(" -- checking hash %12x %s", hash, minetest.pos_to_string(seat.npos))
			if hsh[hash] ~= nil then
				log.warning("%s: cannot sit_down @ %s, as %s is there",
					self.inventory_name, minetest.pos_to_string(seat.npos), hsh[hash].inventory_name)
			else
				self.object:set_velocity{x = 0, y = 0, z = 0}
				self.object:set_pos(seat.pos)
				local node = minetest.get_node(seat.npos)
				self._sit_info = { pos=seat.pos, npos=seat.npos, name=node.name, param2=node.param2 }
				if seat.footvec then
					self:set_yaw_by_direction(seat.footvec)
				end
				self:animate("sit")
				return true
			end
		end
	end


	for invname, luae in pairs(occ) do
		log.warning("%s: cannot sit_down @ %s, as %s is there",
			self.inventory_name, minetest.pos_to_string(node_pos), invname)
		return false, "object blocking"
	end

	return false, "invalid position"
end

function villager:lay_down(node_pos)
	node_pos = node_pos or vector.round(self.object:get_pos())
	local pos, face_dir = func.get_lay_pos(node_pos)

	local occ = get_villagers_around_node(node_pos, self.inventory_name)
	for invname, luae in pairs(occ) do
		log.warning("%s: cannot lay_down @ %s, as %s is there",
			self.inventory_name, minetest.pos_to_string(node_pos), invname)
		return false, "object blocking"
	end

	if not pos then
		return
	end

	local node = minetest.get_node(pos)

	local nodedef = minetest.registered_nodes[node.name]
	local butt_pos
	if nodedef and nodedef.collisionbox then
		log.action("coll adjusting butt_pos by %s", nodedef.collisionbox[5])
		butt_pos = vector.offset(pos, 0, nodedef.collisionbox[5], 0)
	else
		butt_pos = vector.offset(pos, 0, 0.5, 0)
	end

	log.action("%s: lay_down() on %s [p2=%d] @ %s node %s face %s",
		self.inventory_name, node.name, node.param2,
		minetest.pos_to_string(butt_pos),
		minetest.pos_to_string(pos),
		minetest.pos_to_string(face_dir or vector.zero()))

	self.object:set_velocity{x = 0, y = 0, z = 0}
	self.object:set_pos(butt_pos)
	self._sit_info = { pos=butt_pos, npos=pos, name=node.name, param2=node.param2 }
	if face_dir then
		self:set_yaw_by_direction(face_dir)
	end
	self:animate("lay")
end

function villager:pick_random_location(radius)
	radius = radius or 50
	local start_pos = self.stand_pos
	if not start_pos then
		return nil
	end
	-- pick a random reachable location
	for _=1,10 do
		local dx = math.random(-radius, radius)
		local dz = math.random(-radius, radius)
		local target_pos = vector.new(start_pos.x + dx, start_pos.y, start_pos.z + dz)

		local pp = working_villages.nav:find_standable_y(target_pos, 10, 10)
		if pp ~= nil and working_villages.nav:is_reachable(start_pos, pp) then
			log.action("pick_random_location: %s", minetest.pos_to_string(pp))
			return pp
		end
	end
	log.action("pick_random_location: nil")
	return nil
end

--------------------------------------------------------------------

-- default physics function called from on_step()
-- copied from mobkit
-- NOTE: working_villages' NPCs have 0 at the bottom of the model
function villager:physics()
	local vel = self.object:get_velocity()
	local vnew = vector.new(vel)

	-- dumb friction
	--if self.isonground and not self.isinliquid then
	--	vnew = vector.new(vel.x > 0.2 and vel.x*func.friction or 0,
	--	                  vel.y,
	--	                  vel.z > 0.2 and vel.z*func.friction or 0)
	--end

	-- bounciness
	if self.springiness and self.springiness > 0 then
		if colinfo and colinfo.collides then
			for _,c in ipairs(colinfo.collisions) do
				if c.old_velocity[c.axis] > 0.1 then
					vnew[c.axis] = vnew[c.axis] * self.springiness * -1
				end
			end
		end
	end
	self.object:set_velocity(vnew)

	-- buoyancy
	local surface = nil
	local surfnodename = nil
	-- FIXME: figure out what this is really doing
	local spos = self:get_stand_pos() -- func.get_stand_pos()
	spos.y = spos.y+0.01
	-- get surface height
	local snodepos = func.get_node_pos(spos)
	local surfnode = func.nodeatpos(spos)
	while surfnode and surfnode.drawtype == 'liquid' do
		surfnodename = surfnode.name
		surface = snodepos.y + 0.5
		if surface > spos.y + self.height then
			break
		end
		snodepos.y = snodepos.y + 1
		surfnode = func.nodeatpos(snodepos)
	end
	self.isinliquid = surfnodename
	if surface then -- standing in liquid
		local submergence = math.min(surface - spos.y, self.height) / self.height
		local buoyacc = func.gravity * (self.buoyancy - submergence)
		func.set_acceleration(self.object,
			vector.new(-vel.x * self.water_drag,
			           buoyacc - vel.y * math.abs(vel.y) * 0.4,
			           -vel.z * self.water_drag))
	else
		local npos = func.get_node_pos(spos)
		-- not in liquid
		if pathfinder.is_node_climbable(npos) then
			--go down slowly
			--ctrl:set_acceleration{x = 0, y = -0.1, z = 0}
			self.object:set_acceleration{x = 0, y = 0, z = 0}
		else
			-- Mobs can stand on climbable nodes, but the engine doesn't collide, so
			-- they fall. Stop that.
			if pathfinder.is_node_climbable(vector.new(npos.x, npos.y-1, npos.z)) then
				self.object:set_acceleration{x = 0, y = 0, z = 0}
			else
				-- fall. If standing on a walkable node, the engine will stop the fall.
				self.object:set_acceleration{x = 0, y=func.gravity*10, z = 0}
			end
		end
	end

	--[[ special handling for sitting and laying
	When sitting or laying down, the node on which we lay is recorded as well
	as the rotation (param2). We also track our position when seated.
	If any of that changes, we stand up.
	]]
	if self._anim == "sit" or self._anim == "lay" then
		local si = self._sit_info
		local stop_sit
		if si and si.pos and si.npos and si.name and si.param2 then
			local node = minetest.get_node(si.npos)
			if node.name ~= si.name or si.param2 ~= node.param2 then
				stop_sit = "node"
			end
		else
			stop_sit = "data"
		end
		if stop_sit then
			log.warning("%s: sit terminate %s", self.inventory_name, stop_sit)
			self:animate("stand")
		end

	elseif self._sit_info then
		log.warning("%s: sit stuff: cleared sit_info", self.inventory_name)
		--self.object:set_properties({collide_with_objects=true})
		self._sit_info = nil
	end
end

-- FIXME: using mobkit 'oxygen' instead of minetest 'breath'
function villager:get_breath()
	return self.oxygen
end

-- FIXME: using mobkit 'oxygen' and 'lung_capacity' instead of minetest 'breath' and 'breath_max'.
function villager:set_breath(value)
	self.oxygen = math.min(value, self.lung_capacity)
end

--[[
Other player-only object methods that may need to be implemented.

* `get_look_dir()`: get camera direction as a unit vector
* `get_look_vertical()`: pitch in radians
    * Angle ranges between -pi/2 and pi/2, which are straight up and down
      respectively.
* `get_look_horizontal()`: yaw in radians
    * Angle is counter-clockwise from the +z direction.
* `set_look_vertical(radians)`: sets look pitch
    * radians: Angle from looking forward, where positive is downwards.
* `set_look_horizontal(radians)`: sets look yaw
    * radians: Angle from the +z direction, where positive is counter-clockwise.
* `get_meta()`: Returns a PlayerMetaRef.
]]

--[[
Update health and breath.
]]
function villager:vitals()
	-- vitals: fall damage
	local vel = self.object:get_velocity()
	local velocity_delta = abs(self.lastvelocity.y - vel.y)
	if velocity_delta > func.safe_velocity then
		self.hp = self.hp - floor(self.max_hp * min(1, velocity_delta / func.terminal_velocity))
	end

	-- vitals: oxygen
	if self.lung_capacity then
		local colbox = self.object:get_properties().collisionbox
		local headnode = func.nodeatpos(vector.offset(self.object:get_pos(), 0, colbox[5], 0)) -- node at hitbox top
		if headnode and headnode.drawtype == 'liquid' then
			self.oxygen = self.oxygen - self.dtime
		else
			self.oxygen = self.lung_capacity
		end

		if self.oxygen <= 0 then
			self.hp = 0
		end -- drown
	end
end

function villager:get_stand_pos()
	if self.stand_pos ~= nil then
		return self.stand_pos
	end
	self.stand_pos = working_villages.nav:round_position(self.object:get_pos())
	return self.stand_pos
end

--------------------------------------------------------------------

-- Generic memory functions. (key=val)
-- Stuff in memory is serialized, never try to remember objectrefs.
function villager:remember(key, val)
	self.memory[key]=val
	return val
end

function villager:forget(key)
	self.memory[key] = nil
end

function villager:recall(key)
	return self.memory[key]
end

--[[ Remember a rough position, rounded to 8x8x8 node increment.
8 was chosen because it is smaller than the search area (10) for villagers.
Uses minetest.get_gametime() as the time.
The stored layout is: memory[key][pos_hash] = time
]]
function villager:remember_area(key, pos)
	-- round to 8 node increments to reduce the size of the memory
	local rpos = vector.multiply(vector.round(vector.divide(pos, 8)), 8)
	local hash = minetest.hash_node_position(rpos)

	local data = self:recall(key) or {}
	data[hash] = minetest.get_gametime()
	self:remember(key, data)
end

-- forget a single position. used if no longer accessible.
function villager:forget_area_pos(key, pos)
	-- round to 8 node increments to reduce the size of the memory
	local rpos = vector.multiply(vector.round(vector.divide(pos, 8)), 8)
	local hash = minetest.hash_node_position(rpos)

	local data = self:recall(key) or {}
	if data[hash] ~= nil then
		data[hash] = nil
		self:remember(key, data)
	end
end

-- forgets any position older than max_dtime. Use forget() to drop everything.
function villager:forget_area(key, max_dtime)
	local data = self:recall(key)
	if data ~= nil then
		local tref = minetest.get_gametime()
		local new_data = {}
		local changed = false
		for k, v in pairs(data) do
			local dt = tref - v
			if dt <= max_dtime then
				new_data[k] = v -- keeping, no change
			else
				changed = true -- dropping the entry
			end
		end
		if changed then
			self:remember(key, new_data)
		end
	end
end

-- Converts the data for key into a sorted list of { pos={x,y,z}, time=gametime },
-- oldest entry first.
function villager:recall_area(key)
	local res = {}
	for k, v in pairs(self:recall(key) or {}) do
		local rpos = minetest.get_position_from_hash(k)
		table.insert(res, { pos=rpos, time=v })
	end
	table.sort(res, function (a, b) return a.time < b.time end)
	return res
end

--------------------------------------------------------------------

-- default is to call the scheduler every few seconds.
function villager:logic_default()
	if func.timer(self, 3) then
		working_villages.tasks.schedule_check(self)
	end
end

-- on_step is a callback function that is called every step.
-- @dtime is the amount of time that passed since the last call.
function villager:on_step(dtime, colinfo)
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
		local xxx = {}
		for _, ci in ipairs(colinfo.collisions) do
			if ci.type == "node" then
				if logit then
					table.insert(xxx, string.format("%s-%s", minetest.pos_to_string(ci.node_pos), tostring(ci.axis)))
					--log.action("collide %s axis %s", minetest.pos_to_string(ci.node_pos), tostring(ci.axis))
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
		if logit then
			log.action("collide jump=%s %s", tostring(need_jump), table.concat(xxx, ","))
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
		vel.y = 22.5
		--log.action(" jump vel %s on_ground=%s", minetest.pos_to_string(vel), tostring(self.isonground))
		self.object:set_velocity(vel)
	end

	if not self.pause then
		-- pickup surrounding item.
		self:pickup_items()

		if self.view_range then
			self:sensefunc()
		end
		self:logic_default()
		self:task_execute()
	end

	self.lastvelocity = self.object:get_velocity()
	self.time_total = self.time_total + self.dtime
end

--------------------------------------------------------------------

-- copied from mobkit
-- FIXME: do a full scan if the position changed enough?
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

-- on_activate is a callback function that is called when the object is created or recreated.
function villager:on_activate(staticdata)
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

	-- parse the staticdata, and compose the inventory.
	if staticdata == "" then
		-- this is a new villager
		self.manufacturing_number = working_villages.next_manufacturing_number(self.product_name)
		self:create_inventory()
	else
		-- if static data is not empty string, this object has beed already created.
		local data = minetest.deserialize(staticdata)
		self.manufacturing_number = data.manufacturing_number
		self.nametag = data.nametag
		self.owner_name = data.owner_name
		self.pause = data.pause
		self.job_data = data.job_data
		self.state_info = data.state_info
		self.pos_data = data.pos_data
		self.memory = data.memory

		local inventory = self:create_inventory()
		for list_name, list in pairs(data["inventory"]) do
			inventory:set_list(list_name, list)
		end
		fix_pos_data(self)
	end

	-- make sure certain fields are tables
	for _, tnam in ipairs({"memory", "job_data", "pos_data", "armor_groups"}) do
		if type(self[tnam]) ~= "table" then
			self[tnam] = {}
		end
	end

	-- We have to handle damage/breath to do it right (death animation, etc)
	self.armor_groups.immortal = 1
	self.object:set_armor_groups(self.armor_groups)

	if self.job_data.schedule_state == nil then
		self.job_data.schedule_state = {}
	end
	if self.job_data.schedule_done == nil then
		self.job_data.schedule_done = {}
	end

	-- create the wield holder thingy (right handed)
	self.hand = minetest.add_entity(self.object:get_pos(), "working_villages:wield_entity")
	self.hand:set_attach(self.object, "Arm_Right", {x=0, y=5.5, z=3}, {x=-90, y=225, z=90}, true)

	--hp
	self.max_hp = self.max_hp or 10
	self.hp = self.hp or self.max_hp
	self.time_total = 0
	self.water_drag = self.water_drag or 1

	self.buoyancy = self.buoyancy or 0
	self.oxygen = self.oxygen or self.lung_capacity
	self.lastvelocity = {x=0,y=0,z=0}
	self.sensefunc = sensors()

	-- create task stuff (not saved)
	self.task_queue = {} -- queue of tasks to run
	self.task_data = {}  -- misc data for the task
	self.task = {}       -- active task name and priority

	self:set_displayed_action("active")

	self.object:set_nametag_attributes{
		text = self.nametag
	}

	-- have to set an animation for the wield_item to be linked right
	self:stand_still()
	self.object:set_acceleration{x = 0, y = func.gravity, z = 0}

	--legacy
	if type(self.pause) == "string" then
		self.pause = (self.pause == "resting")
	end

	-- register this as a NPC
	if working_villages.active_villagers[self.inventory_name] ~= nil then
		log.warning("on_activate: [%s] -- DUPLICATE", self.inventory_name)
		self.object:remove()
	else
		working_villages.active_villagers[self.inventory_name] = self
		log.warning("on_activate: [%s]", self.inventory_name)
	end
end

function villager:on_deactivate(removal)
	log.warning("deactivate %s removal=%s", self.inventory_name, tostring(removal))
	-- remove the hand thingy
	if self.hand then
		self.hand:remove()
	end
	working_villages.active_villagers[self.inventory_name] = nil
end

-- get_staticdata is a callback function that is called when the object is destroyed.
-- it is used to save any instance data that needs to be preserved
function villager:get_staticdata()
	local inventory = self:get_inventory()
	local data = {
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

	-- set inventory lists.
	for list_name, list in pairs(inventory:get_lists()) do
		data.inventory[list_name] = {}
		for i, item in ipairs(list) do
			data.inventory[list_name][i] = item:to_string()
		end
	end

	return minetest.serialize(data)
end

-- on_rightclick is a callback function that is called when a player right-click them.
function villager:on_rightclick(clicker)
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
function villager:on_punch(puncher, time_from_last_punch, tool_capabilities, dir, damage)
	--TODO: aggression (add player ratings table)
end

-- villager:new returns a new villager object.
function villager.new(def)
	local self = {
		-- these are the required minetest "Object properties"
		initial_properties = {
			hp_max                      = def.hp_max, -- valid, unused
			mesh                        = def.mesh,
			textures                    = def.textures,

			physical                    = true,
			collide_with_objects        = true,
			visual                      = "mesh",
			visual_size                 = {x = 1, y = 1},
			collisionbox                = {-0.25, 0, -0.25, 0.25, 1.7, 0.25},
			pointable                   = true,
			stepheight                  = 1.5,
			is_visible                  = true,
			makes_footstep_sound        = true,
			automatic_face_movement_dir = false,
			infotext                    = "",
			nametag                     = "hello",
			static_save                 = true,
			show_on_minimap             = true,
			damage_texture_modifier     = "^[brighten",
			glow = 10,
		},

		--[[ Animation information. Defaults shown:
		  { range={x=FIRST,y=LAST}, speed=15, loop=true, collisionbox=nil }
		If collisionbox is missing, then initial_properties.collisionbox is used.
		If collisionbox is a function, then that is called to produce the box.
		]]
		animation = {
			stand     = { range={ x=  0, y= 79, }, speed=15, loop=true },
			sit       = { range={ x= 81, y=160, }, speed=15, loop=true,
			              collisionbox={-0.3, 0.0, -0.3, 0.3, 1.2, 0.3} },
			lay       = { range={ x=162, y=166, }, speed=15, loop=true,
			              calc_lay_collision_box },
			walk      = { range={ x=168, y=187, }, speed=15, loop=true },
			mine      = { range={ x=189, y=198, }, speed=15, loop=true },
			walk_mine = { range={ x=200, y=219, }, speed=15, loop=true },
		},

		-- extra initial properties
		weight                      = def.weight, -- ?? what is this for ??
		max_hp                      = def.hp_max or 10,

		pause                       = false,
		disp_action                 = "inactive\nNo job",
		state                       = "job",
		state_info                  = "I am doing nothing particular.",
		job_thread                  = false,
		product_name                = def.product_name,
		manufacturing_number        = -1,
		owner_name                  = "",
		time_counters               = {},
		destination                 = vector.zero(),
		job_data                    = {},
		pos_data                    = {},
		new_job                     = "",

		view_range                  = 10, -- can see objects in this range
		lung_capacity               = 30, -- seconds

		-- callback methods
		on_activate                 = villager.on_activate,
		on_deactivate               = villager.on_deactivate,
		on_step                     = villager.on_step,
		on_rightclick               = villager.on_rightclick,
		on_punch                    = villager.on_punch,
		get_staticdata              = villager.get_staticdata,

		-- storage methods?? NOT USED? What for?
		get_stored_table            = working_villages.get_stored_villager_table,
		set_stored_table            = working_villages.set_stored_villager_table,
		clear_cached_table          = working_villages.clear_cached_villager_table,

		-- home methods
		get_home                    = working_villages.get_home,
		has_home                    = working_villages.is_valid_home,
		set_home                    = working_villages.set_home,
		remove_home                 = working_villages.remove_home,
	}
	return setmetatable(self, {__index = villager})
end

return villager
