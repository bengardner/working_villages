--[[
Wayzone Path

Ties everything together to get a path.

Functions:
	wayzone_path.start(start_pos, target_pos, args) -> wayzone_path
		Start a path with the specified parameters.
		@args may contain (shown with defaults)
			height=2, jump_height=1, fall_height=2, can_climb=true, can_swim=false

	wayzone_path:next_goal(cur_pos) -> vector|nil
		Grab the next position in the path.
		Returns:
			vector = the next goal position
			nil, text = failed with a reason
			nil, nil = path finished, no failure
]]

local wayzone = working_villages.require("wayzone")
local wayzone_chunk = working_villages.require("wayzone_chunk")
local wayzone_store = working_villages.require("wayzone_store")

local pathfinder = working_villages.require("pathfinder")
local fail = working_villages.require("failures")

-------------------------------------------------------------------------------

local wayzone_path = {}

-------------------------------------------------------------------------------

-- Start a new path
function wayzone_path.start(start_pos, target_pos, args)
	assert(start_pos ~= nil)
	assert(target_pos ~= nil)

	local self = {}

	minetest.log("action", string.format(" wayzone_path.start "))

	self.ss = wayzone_store.get(args)
	-- other fields that show up later:
	-- self.path = nil
	-- self.path_idx = nil
	-- self.wzpath = nil
	-- self.wzpath_idx = nil
	-- self.wzpath_fail = nil

	-- We really like the :inside() test
	if target_pos.inside == nil then
		target_pos = pathfinder.make_dest(target_pos)
	end
	self.target_pos = target_pos

	return setmetatable(self, { __index = wayzone_path })
end

-- grab the next position
function wayzone_path:next_goal(cur_pos)
	-- Did we reach the goal?
	if self.target_pos:inside(cur_pos) then
		minetest.log("action", string.format("next_goal: inside end_pos %s", minetest.pos_to_string(cur_pos)))
		return nil
	end

	-- return the next pos on the path, if there are any positions left
	if self.path ~= nil then
		self.path_idx = (self.path_idx or 0) + 1
		if self.path_idx <= #self.path then
			local pp = self.path[self.path_idx]
			minetest.log("action",
				string.format("next_goal: path idx %d %s", self.path_idx, minetest.pos_to_string(pp)))
			return pp
		end
	end
	self.path = nil
	self.path_idx = 0

	-- grab info about the start and end wayzones
	local si = self.ss:get_pos_info(cur_pos)
	local di = self.ss:get_pos_info(self.target_pos)
	if si.wz == nil or di.wz == nil then
		-- Oof. Someone must have placed a block over the target position
		-- FIXME: if target_pos describes an area, we need to pick a different position in that area.
		return nil, fail.no_path
	end

	-- find where the current position lies in the wayzone path
	-- clear the wayzone sequence if we diverged from the path
	if self.wzpath ~= nil and self.wzkeys ~= nil then
		if self.wzkeys[si.wz.key] == nil then
			minetest.log("warning",
				string.format("next_goal: did not find current %s %s in path! Recomputing.",
					si.wz.key, minetest.pos_to_string(cur_pos)))
			self.wzpath = nil
		end
	end

	-- recompute the wayzone sequence
	if self.wzpath == nil then
		if self.wzpath_fail then
			minetest.log("action", string.format("wzpath_rebuild(%s) already failed", minetest.pos_to_string(cur_pos)))
			return nil, fail.no_path
		end
		-- rebuild the path
		minetest.log("action", string.format("calling wzpath_rebuild(%s)", minetest.pos_to_string(cur_pos)))
		self.wzpath_idx = 0

		local time_start = minetest.get_us_time()

		self.wzpath = self.ss:find_path(cur_pos, self.target_pos)
		if self.wzpath == nil then
			minetest.log("action", string.format("rebuild at %s fail", minetest.pos_to_string(cur_pos)))
			self.wzpath_fail = true
			return nil, fail.no_path
		end

		local time_end = minetest.get_us_time()
		local time_diff = time_end - time_start

		minetest.log("action", string.format(" wzpath has %d in %d ms", #self.wzpath, time_diff/1000))

		local wzkeys = {} -- key=wz.key, val=index in wzpath
		for idx, wz in ipairs(self.wzpath) do
			wzkeys[wz.key] = idx

			-- log the wayzone path
			local cpos, cidx = wayzone.key_decode_pos(wz.key)
			minetest.log("action", string.format(" wzpath[%d] = %s  %s:%d", idx, wz.key, minetest.pos_to_string(cpos), cidx))
		end
		--wayzones.show_particles_wzpath(self.wzpath, cur_pos, self.end_pos)

		self.wzkeys = wzkeys
	end
	local wzpath_idx = self.wzkeys[si.wz.key]
	if wzpath_idx == nil then
		minetest.log("warning", string.format("wzpath_idx=%s key=%s", tostring(wzpath_idx), si.wz.key))
		wzpath_idx = 1
	end

	--[[
	There is always at least 1 wayzone at self.wzpath[wzpath_idx] at this point.
	The 'target_pos' for pathfinder.find_path() is always the same.
	We allow the current and next wayzone (if present) for the search space.
	If there isn't a "next", then the dest is the original target_pos.
	Otherwise, the "target" has inside() set to end when we hit the next wayzone.
	In other words, the only places we can move are into the next wayzone OR
	the final position in the same wayzone.
	]]

	local next_wz = self.wzpath[wzpath_idx + 1]
	local target_area
	if next_wz ~= nil then
		-- moving to the next wayzone
		target_area = next_wz:get_dest(self.target_pos)
	else
		-- both cur_pos and target_pos are in the same wayzone
		target_area = self.target_pos
	end

	-- bound the search area to the one or two wayzones
	wayzone.outside_wz(target_area, { si.wz, next_wz })
	for _, wz in ipairs(target_area.wz_ok) do
		minetest.log("action", string.format(" find_path wz_ok: %s", wz.key))
	end

	-- find the path
	self.path = pathfinder.find_path(cur_pos, target_area, nil, {want_nil=true})
	if self.path == nil then
		return nil, fail.no_path
	end
	if #self.path > 0 then
		minetest.log("action", string.format("find_path %s -> %s len %d",
			minetest.pos_to_string(cur_pos),
			minetest.pos_to_string(self.target_pos), #self.path))
		self.path_idx = 1
		local pp = self.path[1]
		minetest.log("action",
			string.format("next_goal:x path idx %d %s", self.path_idx, minetest.pos_to_string(pp)))
		return pp
	end
	minetest.log("action", string.format("next_goal: empty path"))
	return nil, fail.no_path
end

return wayzone_path
