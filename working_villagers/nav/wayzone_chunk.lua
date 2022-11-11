--[[
This is an array of wayzones with some special sauce.
There is one per chunk.
The size of the chunk is in wayzone.

Fields:
	pos (vector)
		Position of the minimum corner

	hash (number)
		Hash over pos used as an ID

	generation (number)
		Incremented each time the chunk is processed.

	gen_clock (number)
		os.clock() when the chunk was last processed.

	use_clock (number)
		os.clock() when the chunk was last used in a path.
		This changes after creation.

	use_count (number)
		Count of uses in a path.
		This changes after creation.

	adjacent (table) - internal
		Table with key=chunk.hash and val=chunk.generation.
		Used to track the generation of the chunk when we last updated links.
		This changes after creation.

	expire_clock (number, usually nil) - internal
		os.clock() + delta when the chunk will be dirty again.

Functions:
	wayzone_chunk.new(cpos) -> wayzone_chunk
		Create a new, empty wayzone chunk.

	wayzone_chunk:new_wayzone() -> wayzone
		Create a new, empty wayzone.

	wayzone_chunk:get_wayzone_for_pos(pos) -> wayzone
		Return the wayzone that owns the position or nil if there is no match.

	wayzone_chunk:gen_is_current(other) -> bool
		Check if the recorded generation for the other wayzone_chunk matches what
		we recorded previously.

	wayzone_chunk:gen_update(other)
		Update the recorded generation for the other wayzone_chunk.

	wayzone_chunk:mark_used()
		Update use_count and use_clock.

	wayzone_chunk:mark_dirty(future_sec)
		Mark as dirty now or @future_sec in the future.

	wayzone_chunk:is_dirty()
		Check if the chunk needs to be regenerated.
]]
local log = working_villages.require("log")
local wayzone = working_villages.require("nav/wayzone")

local wayzone_chunk = {}

function wayzone_chunk.new(pos, old_chunk)
	local self = {}
	self.pos = wayzone.normalize_pos(pos)
	self.hash = minetest.hash_node_position(self.pos)
	if old_chunk ~= nil then
		self.generation = old_chunk.generation + 1
		-- keep expire_clock if it hasn't expired (water spread)
		if old_chunk.expire_clock ~= nil and old_chunk.expire_clock > os.clock() then
			self.expire_clock = old_chunk.expire_clock
		end
		self.use_clock = old_chunk.use_clock
		self.use_count = old_chunk.use_count
	else
		self.generation = 1
		self.use_count = 0
	end
	self.gen_clock = os.clock()
	self.adjacent = {}
	return setmetatable(self, { __index = wayzone_chunk })
end

function wayzone_chunk:new_wayzone()
	local wz = wayzone.new(self.pos, #self+1)
	table.insert(self, wz)
	return wz
end

function wayzone_chunk:get_wayzone_for_pos(pos)
	for idx, wz in ipairs(self) do
		if wz:inside(pos) then
			return wz
		end
	end
	return nil
end

function wayzone_chunk:get_wayzone_by_key(key)
	local chash, cidx = wayzone.key_decode(key)
	if cidx <= #self then
		return self[cidx]
	end
	return nil
end

function wayzone_chunk:gen_is_current(other)
	return self.adjacent[other.hash] == other.generation
end

function wayzone_chunk:gen_update(other)
	self.adjacent[other.hash] = other.generation
end

function wayzone_chunk:mark_used()
	self.use_count = self.use_count + 1
	self.use_clock = os.clock()
end

function wayzone_chunk:mark_dirty(future_sec)
	future_sec = future_sec or 0
	if future_sec <= 0 then
		self.expire_clock = 0
	else
		self.expire_clock = math.min(os.clock() + future_sec, self.expire_clock)
	end
	--minetest.log("warning", string.format("mark_dirty %x %s", self.hash, minetest.pos_to_string(self.pos), future_sec))
end

function wayzone_chunk:is_dirty()
	return self.expire_clock ~= nil and os.clock() > self.expire_clock
end

return wayzone_chunk
