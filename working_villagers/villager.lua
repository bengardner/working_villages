--TODO: split this into single modules

local log = working_villages.require("log")
local cmnp = modutil.require("check_prefix","venus")
local pathfinder = working_villages.require("pathfinder")

---------------------------------------------------------------------

-- villager represents a table that contains common methods
-- for villager object.
-- this table must be contains by a metatable.__index of villager self tables.
-- minetest.register_entity set initial properties as a metatable.__index, so
-- this table's methods must be put there.
local villager = {}

-- villager.get_inventory returns a inventory of a villager.
function villager:get_inventory()
  return minetest.get_inventory {
    type = "detached",
    name = self.inventory_name,
  }
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
        if cond(found_item) then
          local item_position = object:get_pos()
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
			if found_item ~= nil and cond(found_item) then
				table.insert(items, object)
			end
		end
	end
	return items
end

-- villager.get_front returns a position in front of the villager.
function villager:get_front()
  local direction = self:get_look_direction()
  if math.abs(direction.x) >= 0.5 then
    if direction.x > 0 then	direction.x = 1	else direction.x = -1 end
  else
    direction.x = 0
  end

  if math.abs(direction.z) >= 0.5 then
    if direction.z > 0 then	direction.z = 1	else direction.z = -1 end
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
    if direction.x > 0 then	direction.x = -1
    else direction.x = 1 end
  else
    direction.x = 0
  end

  if math.abs(direction.z) >= 0.5 then
    if direction.z > 0 then	direction.z = -1
    else direction.z = 1 end
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

-- villager.set_animation sets the villager's animation.
-- this method is wrapper for self.object:set_animation.
function villager:set_animation(frame)
  self.object:set_animation(frame, 15, 0)
  if frame == working_villages.animation_frames.LAY then
    local dir = self:get_look_direction()
    local dirx = math.abs(dir.x)*0.5
    local dirz = math.abs(dir.z)*0.5
    self.object:set_properties({collisionbox={-0.5-dirx, 0, -0.5-dirz, 0.5+dirx, 0.5, 0.5+dirz}})
  else
    self.object:set_properties({collisionbox={-0.25, 0, -0.25, 0.25, 1.75, 0.25}})
  end
end

-- villager.set_yaw_by_direction sets the villager's yaw
-- by a direction vector.
function villager:set_yaw_by_direction(direction)
  self.object:set_yaw(math.atan2(direction.z, direction.x) - math.pi / 2)
end

-- villager.get_wield_item_stack returns the villager's wield item's stack.
function villager:get_wield_item_stack()
  local inv = self:get_inventory()
  return inv:get_stack("wield_item", 1)
end

-- villager.set_wield_item_stack sets villager's wield item stack.
function villager:set_wield_item_stack(stack)
  local inv = self:get_inventory()
  inv:set_stack("wield_item", 1, stack)
end

-- villager.add_item_to_main add item to main slot.
-- and returns leftover.
function villager:add_item_to_main(stack)
  local inv = self:get_inventory()
  return inv:add_item("main", stack)
end

function villager:replace_item_from_main(rstack,astack)
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

-- villager.is_named reports the villager is still named.
function villager:is_named()
  return self.nametag ~= ""
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

-- villager.change_direction change direction to destination and velocity vector.
function villager:change_direction(destination)
	local position = self.object:get_pos()
	local direction = vector.subtract(destination, position)

	--[[
	minetest.log("action", "change_dir "
				 ..minetest.pos_to_string(position)
				 .." to "..minetest.pos_to_string(destination)
				 .." dir="..minetest.pos_to_string(direction))
	]]

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
			minetest.log("action", "climbing up from "..minetest.pos_to_string(position).." to "..minetest.pos_to_string(destination).." dy="..tostring(direction.y))
			do_climb(node, 1)
			return
		end
	elseif direction.y < 0 then
		local node = minetest.get_node({x=position.x, y=position.y-1, z=position.z})
		if pathfinder.is_node_climbable(node) then
			minetest.log("action", "climbing down from "..minetest.pos_to_string(position).." to "..minetest.pos_to_string(destination).." dy="..tostring(direction.y))
			do_climb(node, -1)
			return
		end
	end

	direction.y = 0
	local velocity = vector.multiply(vector.normalize(direction), 1.5)
	--minetest.log("action", "velocity "..tostring(velocity))

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
  self:set_animation(working_villages.animation_frames.WALK)
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
  self.object:set_properties{infotext = infotext}
end

-- villager.is_near checks if the villager is within the radius of a position
function villager:is_near(pos, distance)
  local p = self.object:get_pos()
  p.y = p.y + 0.5
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
  if below_node.name == "air" then return false end
  local jump_force = math.sqrt(self.initial_properties.weight) * 1.5
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
        for _,box in pairs(nBox) do --TODO: check rotation of the nodebox
          local nHeight = (box[5] - box[2]) + front_pos.y
          if nHeight > self.object:get_pos().y + .5 then
            self:jump()
          end
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
function villager:pickup_item()
  local pos = self.object:get_pos()
  local radius = 1.0
  local all_objects = minetest.get_objects_inside_radius(pos, radius)

  for _, obj in ipairs(all_objects) do
    if not obj:is_player() and obj:get_luaentity() and obj:get_luaentity().itemstring then
      local itemstring = obj:get_luaentity().itemstring
      local stack = ItemStack(itemstring)
      if stack and stack:to_table() then
        local name = stack:to_table().name

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

-- villager.is_active check if the villager is paused.
-- deprecated check self.pause instesad
function villager:is_active()
  print("self:is_active is deprecated: check self.pause directly it's a boolean value")
  --return self.pause == "active"
  return self.pause
end

--villager.set_paused set the villager to paused state
--deprecated use set_pause
function villager:set_paused(reason)
  print("self:set_paused() is deprecated use self:set_pause() and self:set_displayed_action() instead")
  --[[
  self.pause = "resting"
  self.object:set_velocity{x = 0, y = 0, z = 0}
  self:set_animation(working_villages.animation_frames.STAND)
  ]]
  self:set_pause(true)
  self:set_displayed_action(reason or "resting")
end

-- compatibility with like player object
function villager:get_player_name()
  return self.object:get_player_name()
end

function villager:is_player()
  return false
end

function villager:get_wield_index()
  return 1
end

--deprecated
function villager:set_state(id)
  if id == "idle" then
    print("the idle state is deprecated")
  elseif id == "goto_dest" then
    print("use self:go_to(pos) instead of self:set_state(\"goto\")")
    self:go_to(self.destination)
  elseif id == "job" then
    print("the job state is not nessecary anymore")
  elseif id == "dig_target" then
    print("use self:dig(pos,collect_drops) instead of self:set_state(\"dig_target\")")
    self:dig(self.target,true)
  elseif id == "place_wield" then
    print("use self:place(itemname,pos) instead of self:set_state(\"place_wield\")")
    local wield_stack = self:get_wield_item_stack()
    self:place(wield_stack:get_name(),self.target)
  end
end

--------------------------------------------------------------------

function villager:set_pause(state)
  assert(type(state) == "boolean","pause state must be a boolean")
  self.pause = state
  if state then
    self.object:set_velocity{x = 0, y = 0, z = 0}
    --perhaps check what animation we are in
    self:set_animation(working_villages.animation_frames.STAND)
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
		minetest.log("warning", string.format("villager:task_add: unknown task %s", name))
		return false
	end

	local new_info = { name=name, func=info.func, priority=priority or info.priority }
	self.task_queue[name] = new_info
	minetest.log("action", string.format("%s: added task %s priority %d", self.product_name, new_info.name, new_info.priority))
	return true
end

-- Remove a task by name, @reason is for logging
function villager:task_del(name, reason)
	local info = self.task_queue[name]
	if info ~= nil
		minetest.log("action", string.format("%s: removed task %s priority %d %s",
				self.product_name, info.name, info.priority, reason))
		self.task_queue[name] = nil
	end
end

-- get the best task
function villager:task_best()
	local best_info
	for _, info in pairs(self.task_queue) do
		if best_info == nil or info.priority > best_info.priority then
			best_info = info
		end
	end
	if best_info == nil then
		best_info = working_villages.registered_tasks["idle"]
	end
	return best_info
end

-- this executes the best task as a coroutine
function villager:task_execute(self, dtime)
	local best = self:task_best()
	-- Does the coroutine exist?
	if self.task.thread ~= nil then
		-- Clean up dead task or cancel no-longer-best task
		if coroutine.status(self.task.thread) == "dead" then
			-- Remove the task from the queue if it returned true
			if self.task.ret == true then
				self:task_del(self.task.name, "complete")
			end
			self.task = {}
			best = self:task_best()
		elseif best == nil or best.name ~= self.task.name then
			coroutine.close(self.task.thread)
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
				minetest.log("warning", string.format("task %s failed: %s", self.task.name, tostring(ret[2])))
				-- remove it from the queue
				self:task_del(self.task.name, "failed")
			end
		end
	end
end

--------------------------------------------------------------------

-- villager:new returns a new villager object.
function villager:new(o)
	return setmetatable(o or {}, {__index = self})
end

return villager
