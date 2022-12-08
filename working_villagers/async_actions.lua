local fail = working_villages.require("failures")
local log = working_villages.require("log")
local func = working_villages.require("jobs/util")
local pathfinder = working_villages.require("nav/pathfinder")
local wayzone_path = working_villages.require("nav/wayzone_pathfinder")
local wayzone_utils = working_villages.require("nav/wayzone_utils")

--[[
This does the actual movement.
Gets a path and follows it.

returns:
 * true : check and maybe try again
 * false, reason : give up
]]
local function try_a_path(self, dest_pos, dest_radius, dest_height)
	-- NOTE: the *caller* must verify that dest_pos is valid.
	--  It is perfectly OK to set dest_pos to the position of a log and set
	--  radius to, say, 4. We shouldn't scan up the to the top of the tree!

	-- -- round the dest and find a walkable node at that X-Z.
	-- -- self.destination will be above a walkable surface.
	-- -- We may not be able to stand there, so it may be unreachable.
	-- self.destination = pathfinder.get_ground_level(vector.round(dest_pos))
	-- if self.destination == nil then
	-- 	-- unlikely that the entire column is filled, but whatever
	-- 	return false, fail.no_path
	-- end
	assert(dest_pos ~= nil)

	self.destination = vector.round(dest_pos)
	--wayzone_utils.put_marker(self.destination, "target")

	-- calculate the path with a radius
	local start_pos = vector.round(self.object:get_pos())
	--if dest_height ~= nil then
	--	self.path = pathfinder.find_path_cylinder(start_pos, self, self.destination, dest_radius, dest_height)
	--else
	--	self.path = pathfinder.find_path_sphere(start_pos, self, self.destination, dest_radius)
	--end

	--wayzone_utils.put_marker(start_pos, "start")

	local wzp = wayzone_path.start(start_pos, self.destination)
	self.cur_goal = nil

	self:set_timer("go_to:find_path",0)  -- interval to regen the path
	self:set_timer("go_to:change_dir",0) -- how often to turn

	--print("the first waypiont on his path:" .. minetest.pos_to_string(self.path[1]))
	--self:change_direction(self.path[1])
	--self:set_animation(working_villages.animation_frames.WALK)
	self:animate("walk")

	-- NOTE: If we will do a sharp turn (90 deg) when we hit the current
	-- waypoint, then we need to reach exactly the node center before the turn.
	-- That means updating the facing direction on every step.
	-- This does a 2D dot product of the vector pos->wp1 and wp1->wp2.
	-- If over 60 deg, then use exact positioning.
	local function need_exact_pos()
		return false
		--if #self.path < 2 then return false end
		--local pos = self.object:get_pos()
		--local wp1 = self.path[1]
		--local wp2 = self.path[2]
		--local v1 = vector.normalize(vector.subtract(pos, wp1))
		--local v2 = vector.normalize(vector.subtract(wp1, wp2))
		--local dp = v1.x * v2.x + v1.z * v2.z
		--return dp <= 0.5 -- 60+ deg
	end
	local exact_step = need_exact_pos()

	while true do
		--self:set_animation(working_villages.animation_frames.WALK)
		self:animate("walk")
		if self.cur_goal == nil then
			self.cur_goal = wzp:next_goal(self.stand_pos)
			if self.cur_goal == nil then
				break
			end
			self:set_timer("go_to:find_path",0)
			self:change_direction(self.cur_goal)
			wayzone_utils.put_marker(self.cur_goal, "node")
		end
		self:count_timer("go_to:find_path")
		self:count_timer("go_to:change_dir")

		-- If we have haven't reached the next waypoint for a while, then we
		-- are likely stuck and need to recalculate the path.
		if self:timer_exceeded("go_to:find_path",200) then
			-- We are stuck, so give up. This function will be called again.
			break
			-- -- someone may have placed a node on top of our destination, so recalculate ground level
			-- self.destination = pathfinder.get_ground_level(self.destination)
			-- if self.destination == nil then
			-- 	-- unlikely that the entire column is filled, but whatever
			-- 	return false, fail.no_path
			-- end
			--
			-- -- don't endlessly recalculate if we are really stuck
			-- self:count_timer("go_to:give_up")
			-- if self:timer_exceeded("go_to:give_up", 3) then
			-- 	print("villager can't find path to "..minetest.pos_to_string(val_pos))
			-- 	return false, fail.no_path
			-- end
			--
			-- -- calculate the path again
			-- start_pos = vector.round(self.object:get_pos())
			-- self.path = pathfinder.find_path_sphere(start_pos, self, self.destination, radius)
			-- exact_step = need_exact_pos()
		end

		--if exact_step or self:timer_exceeded("go_to:change_dir",30) then
		--	self:change_direction(self.cur_goal)
		--else
		--
		--end

		local function close_enough(v1, v2)
			local d = vector.distance(v1, v2)
			return d < 2
		end
		local function is_same_vec(v1, v2)
			local r1 = vector.round(v1)
			return r1.x == v2.x and r1.y == v2.y and r1.z == v2.z
		end

		-- follow path
		--if self:is_near({x=self.path[1].x,y=self.object:get_pos().y,z=self.path[1].z}, 1) then
		--if self:is_near(self.path[1], 1) then
		if is_same_vec(self.object:get_pos(), self.cur_goal) then
			--log.action("jumping to %s", minetest.pos_to_string(self.path[1]))
			--self.object:set_pos(self.path[1])
			--table.remove(self.path, 1)
			--exact_step = need_exact_pos()
			self.cur_goal = nil

			--if #self.path == 0 then -- end of path
			--	-- keep walking another step for good measure
			--	coroutine.yield()
			--	break
			--end

			--self:set_timer("go_to:find_path",0)
			--self:change_direction(self.path[1])
		else
			self:change_direction(self.cur_goal)
		end
		-- if vilager is stopped by obstacles, the villager must jump or open the door.
		self:handle_obstacles(true)
		-- end step
		coroutine.yield()
	end

	-- the path has been completed, so we need to stop and stand.
	-- the path may not have placed us at the destination, so the caller will
	-- check and retry.
	self.path = nil
	self:stand_still()
	return true
end

--[[
This is the MOB movement function.
It will try really hard to move to @pos.
If it can't get within @radius+1 of dest_pos, then this will fail.
]]
function working_villages.villager:go_to(dest_pos, dest_radius, dest_height)
	if dest_height ~= nil and dest_height < 1 then
		dest_height = 1
	end
	if dest_radius == nil or dest_radius < 1 then
		dest_radius = 1
	end

	-- find a real position nearby the target
	local target_pos = working_villages.nav:find_standable_near(dest_pos, 3, self.object:get_pos())
	--local target_pos = pathfinder.get_neighbor_ground_level(dest_pos)
	if target_pos == nil then
		log.warning("go_to: not valid ground for %s", minetest.pos_to_string(dest_pos))
		return false, fail.no_path
	end
	log.action("go_to: %s => ground %s",
		minetest.pos_to_string(dest_pos), minetest.pos_to_string(target_pos))

	-- dest_radius must be at least 1
	local function close_enough()
		local d = vector.distance(self.object:get_pos(), dest_pos)
		return d <= dest_radius + 1
	end

	self:set_timer("go_to:give_up",0)    -- counter to give up if unable to reach dest
	while not close_enough() do
		try_a_path(self, target_pos, dest_radius, dest_height)
		coroutine.yield()
		-- see if we should try again
		self:count_timer("go_to:give_up")    -- counter to give up if unable to reach dest
		if self:timer_exceeded("go_to:give_up", 3) then
			return false, fail.no_path
		end
	end
	return true
end

function working_villages.villager:collect_nearest_item_by_condition(cond, searching_range)
	local item = self:get_nearest_item_by_condition(cond, searching_range)
	if item == nil then
		return false
	end
	local pos = item:get_pos()
	--print("collecting item at:".. minetest.pos_to_string(pos))
	local inv=self:get_inventory()
	if inv:room_for_item("main", ItemStack(item:get_luaentity().itemstring)) then
		self:go_to(pos)
		self:pickup_item(item)
	end
end

function working_villages.villager:collect_item(item)
	local item_pos = item:get_pos()
	local item_ent = item:get_luaentity()
	if item_pos == nil or item_ent == nil then
		-- lie and say we collected it, as it no longer exists
		return true
	end

	local rpos = vector.round(item_pos)
	if not working_villages.failed_pos_test(rpos) then
		local stand_pos = working_villages.nav:find_standable_near(rpos, {x=1, y=2, z=1})
		if stand_pos == nil then
			log.action("no stand_pos around %s", minetest.pos_to_string(rpos))
			working_villages.failed_pos_record(rpos)
		else
			local inv = self:get_inventory()

			if inv:room_for_item("main", ItemStack(item:get_luaentity().itemstring)) then
				log.action("Collecting %s @ %s stand=%s",
					item_ent.itemstring,
					minetest.pos_to_string(item_pos),
					minetest.pos_to_string(stand_pos))
				local ret, msg = self:go_to(stand_pos)
				if ret ~= true then
					log.action(" -- go_to fail %s", msg)
				else
					self:pickup_item(item)
				end
			end
		end
	end
	return true
end

function working_villages.villager:collect_nearby_items_by_condition(cond, searching_range)
	local items = self:get_items_by_condition(cond, searching_range)
	if #items == 0 then
		return false
	end
	log.action("collect_nearby_items_by_condition: found %d items", #items)
	while #items > 0 do
		local my_pos = self.object:get_pos()
		if #items > 1 then
			-- collect the closest item first
			table.sort(items, function(a, b)
				-- items may have been destroyed...
				if a == nil or a:get_pos() == nil or b == nil or b:get_pos() == nil then
					return false
				end
				return vector.distance(my_pos, a:get_pos()) > vector.distance(my_pos, b:get_pos())
			end)
		end
		log.action("  +++ %d items left", #items)
		for i, x in ipairs(items) do
			local xp = x:get_pos()
			if xp ~= nil then
				log.action("  +++ [%d] %s %d", i,
					minetest.pos_to_string(x:get_pos()),
					vector.distance(my_pos, x:get_pos()))
			end
		end
		local item = items[#items]
		table.remove(items)
		self:collect_item(item)
	end
	return true
end

-- delay the async action by @step_count steps
function working_villages.villager:delay_steps(step_count)
	for _=0, step_count do
		coroutine.yield()
	end
end

function working_villages.villager:delay_seconds(seconds)
	local end_clock = os.clock() + seconds
	while os.clock() < end_clock do
		coroutine.yield()
	end
end

local drop_range = {x = 2, y = 10, z = 2}

function working_villages.villager:dig(pos,collect_drops,do_dist_check)
	self:stand_still()

	if func.is_protected(self, pos) then
		return false, fail.protected
	end

	-- verify distance
	local dist = vector.subtract(pos, self.object:get_pos())
	if do_dist_check ~= false and vector.length(dist) > 5 then
		return false, fail.too_far
	end

	-- wield the best tool for the dig
	local changed, wield = self:wield_best_for_dig(minetest.get_node(pos).name)
	if changed then
		--self.object:stand_still() -- FIXME: need something to update the animation?
		self:delay_seconds(1)
	end

	-- start the 'mine' animation, facing the node
	--self:set_animation(working_villages.animation_frames.MINE)
	self:animate("mine")
	self:set_yaw_by_direction(dist)

	local destnode = minetest.get_node(pos)
	local def_node = minetest.registered_items[destnode.name];

	local dig_time = wield.time or 2
	local dig_sound
	local dug_sound
	if def_node.sounds then
		dig_sound = def_node.sounds.dig
		dug_sound = def_node.sounds.dug
	end

	-- play the digging sound during the animation
	if dig_sound then
		-- FIXME: how long are the sounds?
		local sound_sec = 0.6
		while dig_time > 0 do
			minetest.sound_play(dig_sound, {object=self.object, max_hear_distance = 10}, true)
			self:delay_seconds(sound_sec)
			dig_time = dig_time - sound_sec
		end
	else
		-- no dig sound, so just delay for the dig time
		self:delay_seconds(dig_time)
	end

	-- Perform the default dig action, which transfers the drops to the inventory
	local on_dig = def_node.on_dig or minetest.node_dig
	if not on_dig(pos, destnode, self) then
		return false, fail.dig_fail
	end

	if dug_sound then
		minetest.sound_play(dug_sound, {object=self.object, max_hear_distance = 10}, true)
	end

	-- stop the mine animation
	self:stand_still()
	return true
end

function working_villages.villager:place(item, pos)
	if type(pos) ~= "table" then
		error("no target position given")
	end
	if func.is_protected(self,pos) then
		return false, fail.protected
	end
	local dist = vector.subtract(pos, self.object:get_pos())
	if vector.length(dist) > 5 then
		return false, fail.too_far
	end
	local destnode = minetest.get_node(pos)
	if not minetest.registered_nodes[destnode.name].buildable_to then
		return false, fail.blocked
	end
	local find_item = function(name)
		if type(item)=="string" then
			return name == working_villages.buildings.get_registered_nodename(item)
		elseif type(item)=="table" then
			return name == working_villages.buildings.get_registered_nodename(item.name)
		elseif type(item)=="function" then
			return item(name)
		else
			log.error("got %s instead of an item",item)
			error("no item to place given")
		end
	end
	local wield_stack = self:get_wielded_item()
	--move item to wield
	if not (find_item(wield_stack:get_name()) or self:move_main_to_wield(find_item)) then
		return false, fail.not_in_inventory
	end
	--set animation
	if self.object:get_velocity().x==0 and self.object:get_velocity().z==0 then
		--self:set_animation(working_villages.animation_frames.MINE)
		self:animate("mine")
	else
		--self:set_animation(working_villages.animation_frames.WALK_MINE)
		self:animate("walk_mine")
	end
	--turn to target
	self:set_yaw_by_direction(dist)
	self:delay_seconds(1)
	--wait 15 steps
	--for _=0,15 do coroutine.yield() end
	--get wielded item
	local stack = self:get_wielded_item()
	--create pointed_thing facing upward
	--TODO: support given pointed thing via function parameter
	local pointed_thing = {
		type = "node",
		above = pos,
		under = vector.add(pos, {x = 0, y = -1, z = 0}),
	}
	--TODO: try making a placer
	local itemname = stack:get_name()
	--place item
	if type(item)=="table" then
		minetest.set_node(pointed_thing.above, item)
		--minetest.place_node(pos, item) --loses param2
		stack:take_item(1)
	else
		local before_node = minetest.get_node(pos)
		local before_count = stack:get_count()
		local itemdef = stack:get_definition()
		if itemdef.on_place then
			stack = itemdef.on_place(stack, self, pointed_thing)
		elseif itemdef.type=="node" then
			stack = minetest.item_place_node(stack, self, pointed_thing)
		end
		local after_node = minetest.get_node(pos)
		-- if the node didn't change, then the callback failed
		if before_node.name == after_node.name then
			return false, fail.protected
		end
		-- if in creative mode, the callback may not reduce the stack
		if before_count == stack:get_count() then
			stack:take_item(1)
		end
	end
	--take item
	self:set_wielded_item(stack)
	coroutine.yield()
	--handle sounds
	local sounds = minetest.registered_nodes[itemname]
	if sounds then
		if sounds.sounds then
			local sound = sounds.sounds.place
			if sound then
				minetest.sound_play(sound,{object=self.object, max_hear_distance = 10})
			end
		end
	end
	--reset animation
	if self.object:get_velocity().x==0 and self.object:get_velocity().z==0 then
		--self:set_animation(working_villages.animation_frames.STAND)
		self:animate("stand")
	else
		--self:set_animation(working_villages.animation_frames.WALK)
		self:animate("walk")
	end

	return true
end

function working_villages.villager:manipulate_chest(chest_pos, take_func, put_func, data)
	if func.is_chest(chest_pos) then
		-- try to put items
		local vil_inv = self:get_inventory();

		-- from villager to chest
		if put_func then
			local size = vil_inv:get_size("main");
			for index = 1,size do
				local stack = vil_inv:get_stack("main", index);
				if (not stack:is_empty()) and (put_func(self, stack, data)) then
					local chest_meta = minetest.get_meta(chest_pos);
					local chest_inv = chest_meta:get_inventory();
					local leftover = chest_inv:add_item("main", stack);
					vil_inv:set_stack("main", index, leftover);
					for _=0,10 do coroutine.yield() end --wait 10 steps
				end
			end
		end
		-- from chest to villager
		if take_func then
			local chest_meta = minetest.get_meta(chest_pos);
			local chest_inv = chest_meta:get_inventory();
			local size = chest_inv:get_size("main");
			for index = 1,size do
				chest_meta = minetest.get_meta(chest_pos);
				chest_inv = chest_meta:get_inventory();
				local stack = chest_inv:get_stack("main", index);
				if (not stack:is_empty()) and (take_func(self, stack, data)) then
					local leftover = vil_inv:add_item("main", stack);
					chest_inv:set_stack("main", index, leftover);
					for _=0,10 do coroutine.yield() end --wait 10 steps
				end
			end
		end
	else
		log.error("Villager %s does not find chest on position %s.", self.inventory_name, minetest.pos_to_string(chest_pos))
	end
end

function working_villages.villager.wait_until_dawn()
	local daytime = minetest.get_timeofday()
	while (daytime < 0.2 or daytime > 0.805) do
		coroutine.yield()
		daytime = minetest.get_timeofday()
	end
end

function working_villages.villager:sleep()
	log.action("villager %s is laying down",self.inventory_name)
	self.object:set_velocity{x = 0, y = 0, z = 0}
	local bed_pos = vector.new(self.pos_data.bed_pos)
	local bed_top = func.find_adjacent_pos(bed_pos,
		function(p) return string.find(minetest.get_node(p).name,"_top") end)
	local bed_bottom = func.find_adjacent_pos(bed_pos,
		function(p) return string.find(minetest.get_node(p).name,"_bottom") end)
	if bed_top and bed_bottom then
		self:set_yaw_by_direction(vector.subtract(bed_bottom, bed_top))
		bed_pos = vector.divide(vector.add(bed_top,bed_bottom),2)
	else
		log.info("villager %s found no bed", self.inventory_name)
	end
	--self:set_animation(working_villages.animation_frames.LAY)
	self:animate("lay")
	self.object:setpos(bed_pos)
	self:set_state_info("Zzzzzzz...")
	self:set_displayed_action("sleeping")

	-- FIXME: this should be based on the schedule
	self.wait_until_dawn()

	local pos=self.object:get_pos()
	self.object:setpos({x=pos.x,y=pos.y+0.5,z=pos.z})
	log.action("villager %s gets up", self.inventory_name)
	--self:set_animation(working_villages.animation_frames.STAND)
	self:animate("stand")
	self:set_state_info("I'm starting into the new day.")
	self:set_displayed_action("active")
end

function working_villages.villager:goto_bed()
	if self.pos_data.home_pos==nil then
		log.action("villager %s is waiting until dawn", self.inventory_name)
		self:set_state_info("I'm waiting for dawn to come.")
		self:set_displayed_action("waiting until dawn")
		self:sit_down()
		self.wait_until_dawn()
		--self:set_animation(working_villages.animation_frames.STAND)
		self:animate("stand")
		self:set_state_info("I'm starting into the new day.")
		self:set_displayed_action("active")
	else
		log.action("villager %s is going home", self.inventory_name)
		self:set_state_info("I'm going home, it's late.")
		self:set_displayed_action("going home")
		self:go_to(self.pos_data.home_pos)
		if (self.pos_data.bed_pos==nil) then
			log.warning("villager %s couldn't find his bed",self.inventory_name)
			--TODO: go home anyway
			self:set_state_info("I am going to rest soon.\nI would love to have a bed in my home though.")
			self:set_displayed_action("waiting for dusk")
			local tod = minetest.get_timeofday()
			while (tod > 0.2 and tod < 0.805) do
				coroutine.yield()
				tod = minetest.get_timeofday()
			end
			self:set_state_info("I'm waiting for dawn to come.")
			self:set_displayed_action("waiting until dawn")
			self:sit_down()
			self.wait_until_dawn()
		else
			log.info("villager %s bed is at: %s", self.inventory_name, minetest.pos_to_string(self.pos_data.bed_pos))
			self:set_state_info("I'm going to bed, it's late.")
			self:set_displayed_action("going to bed")
			self:go_to(self.pos_data.bed_pos)
			self:set_state_info("I am going to sleep soon.")
			self:set_displayed_action("waiting for dusk")
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

function working_villages.villager:handle_night()
	local tod = minetest.get_timeofday()
	if	tod < 0.2 or tod > 0.76 then
		if (self.job_data.in_work == true) then
			self.job_data.in_work = false;
		end
		self:goto_bed()
		self.job_data.manipulated_chest = false;
	end
end

function working_villages.villager:goto_job()
	log.action("villager %s is going to the last job location", self.inventory_name)
	if self.pos_data.job_pos==nil then
		log.warning("villager %s couldn't find his job position",self.inventory_name)
		self.job_data.in_work = true;
	else
		log.action("villager %s going to job position %s", self.inventory_name, minetest.pos_to_string(self.pos_data.job_pos))
		self:set_state_info("I am going to my job position.")
		self:set_displayed_action("going to job")
		self:go_to(self.pos_data.job_pos)
		self.job_data.in_work = true;
	end
	self:set_state_info("I'm working.")
	self:set_displayed_action("active")
	return true
end

function working_villages.villager:handle_chest(take_func, put_func, data)
	if (not self.job_data.manipulated_chest) then
		local chest_pos = self.pos_data.chest_pos
		if (chest_pos~=nil) then
			log.action("villager %s is handling chest at %s", self.inventory_name, minetest.pos_to_string(chest_pos))
			self:set_state_info("I am taking and puting items from/to my chest.")
			self:set_displayed_action("active")
			local chest = minetest.get_node(chest_pos);
			local dir = minetest.facedir_to_dir(chest.param2);
			local destination = vector.subtract(chest_pos, dir);
			self:go_to(destination)
			self:manipulate_chest(chest_pos, take_func, put_func, data);
		end
		self.job_data.manipulated_chest = true;
	end
end

function working_villages.villager:handle_job_pos()
	if (not self.job_data.in_work) then
		self:goto_job()
	end
end

