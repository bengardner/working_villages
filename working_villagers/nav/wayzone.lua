--[[
This is the storage for wayzone data.

NOTE: CSZ=chunk_size, either 8 or 16 (still testing, likely stay with 8)

What we need:
 - a set of all (local) positions in the chunk that are part of the zone
   - the positiions will mainly be tested, so a test should be O(1).
   - should be able to hold all positions without penalty (water block)
 - a set of all exit positions, or links to another zone
   - the exit positions can be in 7 groups:
     - internal (between zones inside the chunk)
     - to each of the 6 adjacent chunks
   - the exit positions will only be iterated (no lookup)
   - worse case could have CSZ*CSZ exit nodes on each side with maybe
     an extra layer on bottom (can fall 2) (CSZ*CSZ*7 total)
     - exit nodes on the side are expected to be common. top/bottom/inside less so.
     - with CSZ=8, that is 64 exit nodes per side or up to 448 total (896 bytes)
     - with CSZ=8, we need 3x3 (9) bits to store the local position
     - with CSZ=16, that is 256 exit nodes per side or up to 1792 total (3584 bytes)
     - with CSZ=16, we need 3x4 (12) bits to store the local position
     - We could do tricks to reduce the memory usage (compress, special encoding)
       but that doesn't seem worth the effort right now.
       - a bit-packed array would save 43% (CSZ=8) or 25% (CSZ=16)
       - encoding (bitmap, CSZ=8) would require 8 bytes on each of the 7 outside
         slots (4 horizontal, 1 up, 2 down) for 56 bytes each
       - internal would need 64 bytes, so an array would be better
     - for now, we store the lpos using a u16 (2 bytes)
 - all positions (either group) are clear and *above* a standable node

The simplest approach (in Lua) would be to use a table for each of the above and
use the position hash as the key. The value doesn't matter.

There are 4096 (16x16x16) nodes in a chunk. Assuming a height of 2, it would
require 3 nodes to have a stand position. That would give a realistic worst-case
count of ~1365 (16/3*16*16) positions. The absolute worst case would be a chunk
of 4906 climbable or swimable nodes, all of which can be in the zone.
The worst possible number of zones is also ~1365, if the pattern were constructed
such that no position could reach another position in the chunk. However, at some
point, the chunk should be declared impassible.

Lua uses about 40 bytes per table and about 40 bytes per entry.
A typical chunk will have 1 zone with about 256 positions (16x16, ground level).
That is over 10 KB just for the zone members.

A better approach is to use 1 bit per node.
That requires 4096 bits or 512 bytes.
However, given that we can't be in a solid node and we require (typically) 2
clear nodes above the standing position, we can cut the vertical resolution by 2.
That leaves a 2048 (16x8x16) bit array of 256 bytes per zone.

Directly constructing a 256 byte string, one bit at a time would trash
the garbage collector, so we build it as an array and table.concat() when done.

If a similar approach is taken with exit nodes, we could get away with a 16 byte
bitmap (16*8/8) on each side and a 32-byte bitmap (16x16/8) on top/bottom.
For exit nodes, a 2x2x2 cell should suffice.


Corner cases (assume 16x16x16, from 0,0,0 to 15,15,15):
 - We can stand on the bottom of the chunk, with the node that we are standing on
   in the chunk below. That makes the zone depend on the chunk below.
 - The exit node from the bottom layer may drop down to y-2 due to the fear height
 - We can stand on the top, with 1 empty space in the chunk above.
 - Exit nodes, of course, depend on the the neighbor chunks

This "class" hides the implementation of the data storage.

** Building a Wayzone
wz = wayzone.new(chunk_pos)
Create a new wayzone.

wz:insert(pos)
Add a position to the zone.
If pos is outside the chunk, this does nothing.

wz:insert_exit(pos)
Add a position as an exit node.
The position may be inside the chunk (internal) or a x+/-1, z+/-1, y+/-1/-2.

wz:finish()
Indicate that we are done adding visited/exit positions.
This compacts the data storage.
You cannot call insert() or insert_exit() after calling finish().

** Testing Wayzone Content
wz:inside(pos)
wz:inside_local(lpos)
Test if a position (global or local) is inside the zone.

wz:exited_to(wz_other)
Test if the current zone has an exit that maps to the other zone.
This iterates over the appropriate exit nodes and calls wz_other:inside(pos)

** Iteration
wz:iter_exited(adjacent_cpos)
wz:iter_visited()
Create an iterator over the set.

** Links
wz:link_add_to(to_wz, gCost)
wz:link_add_from(from_wz, gCost)
Add a one-way link to or from another wayzone.
gCost is the cost of that link. The default is the pathfinder estimate between
the two center positions, with a multiplier if either is a water wayzone.
NOTE: You can add a link to ANY other wayzone, not just adjacent ones.

wz:link_test_to(to_wz)
wz:link_test_from(from_wz)
Test if there is a link to (or from) the other wayzone.

wz:link_del(other_chash)
Remove all links to wayzones in the other chunk.
This is used when the chunk is reprocessed.

** Misc
wz:get_center_pos()
Return the position of the center-most visited node.

wz:get_dest(from_cpos)
Creates and "end_pos" area for find_path(). This uses the center pos as the
coordinates and the wayzone as the area.
If from_cpos is set, then a min/max box around the two chunks is used to limit
the path exploration area.
NOTE: if the chunks are not adjacent, this can include a rather large area.
REVISIT: use a list of chunk positions to allow for multihop paths.


Todo:
 - rescan a chunk when a path fails
   - cant find wayzone for a location
 - have the 'visited' nodes include all air above the ground? (no?)

Problems:
 - the regular A* path algo ends up with some weird patterns, as it has to
   go towards a destination, but the destination is really an area, so it tends
   to veer towards the center.
   - I may need to use the far side of the other chunk as the dest?
   - Or maybe use a flood-fill? may need a smaller grid size for that

 - scanning a 16x16x16 area takes a while.

 - consider using 8x8x8 area (512 bits, 64 bytes)
   - more exit nodes? more dependant on neighboring chunks?
   - use a 2nd layer? (64x64x64) ?

ToDo:
 - handle path failure
   - may need to reprocess some chunks and links
 - Add link chains
]]
local S = default.get_translator
local log = working_villages.require("log")

local wayzone = {}

--local chunk_size = 16 -- can be 8 or 16 for testing. 8 is looking better.
local chunk_size = 8 -- can be 8 or 16 for testing. 8 is looking better.
local chunk_bytes = (chunk_size * chunk_size * chunk_size / 8)

-- this should be read-only
wayzone.chunk_size = chunk_size

-- convert a mask back to the bit -- we don't have ilog2()
local mask_to_bit = {
	[0x01] = 0,
	[0x02] = 1,
	[0x04] = 2,
	[0x08] = 3,
	[0x10] = 4,
	[0x20] = 5,
	[0x40] = 6,
	[0x80] = 7,
}

-- change a local position to a hash for the exit nodes
-- The hash is either 12 bits for chunk_size=16 and 9 bits for chunk_size=8.
-- NOTE: y is in the lsb so that we can reduce y precision with a rshift as a
-- future enhancement.

-- lpos to hash functions for 8-node chunk size
local function lpos_to_hash_8(lpos)
	return bit.lshift(lpos.x, 6) + bit.lshift(lpos.z, 3) + lpos.y
end
local function hash_to_lpos_8(hash)
	return vector.new(bit.band(bit.rshift(hash, 6), 0x07),
	                  bit.band(hash, 0x07),
	                  bit.band(bit.rshift(hash, 3), 0x07))
end

-- lpos to hash functions for 16-node chunk size
local function lpos_to_hash_16(lpos)
	return bit.lshift(lpos.x, 8) + bit.lshift(lpos.z, 4) + lpos.y
end
local function hash_to_lpos_16(hash)
	return vector.new(bit.band(bit.rshift(hash, 8), 0x0f),
	                  bit.band(hash, 0x0f),
	                  bit.band(bit.rshift(hash, 4), 0x0f))
end

-- pick the right hash based on the chunk size
local lpos_to_hash
local hash_to_lpos
if chunk_size == 8 then
	lpos_to_hash = lpos_to_hash_8
	hash_to_lpos = hash_to_lpos_8
else
	lpos_to_hash = lpos_to_hash_16
	hash_to_lpos = hash_to_lpos_16
end

--[[
Convert a bit index into a bit array into a byte index and mask.
Reverses bytemask_to_bitidx()
NOTE: bit_idx is 0-based, byte_idx is 1-based.
]]
local function bitidx_to_bytemask(bit_idx)
	local byte_idx = 1 + bit.rshift(bit_idx, 3)
	local mask = bit.lshift(1, bit.band(bit_idx, 7))
	return byte_idx, mask
end

--[[
Convert a byte index (1-based) and a mask to a bit index (0-based).
Reverses bitidx_to_bytemask()
NOTE: bit_idx is 0-based, byte_idx is 1-based.
]]
local function bytemask_to_bitidx(byte_idx, mask)
	return bit.lshift(byte_idx - 1, 3) + (mask_to_bit[mask] or 0)
end

--[[
Convert a local position to a byte index and mask.
Reverses bytemask_to_lpos()
@lpos is the local position, adjused to 0-chunk_size.
@return byte_index, byte_mask

NOTE: byte_index is 1-based
]]
local function lpos_to_bytemask(lpos)
	local phash = lpos_to_hash(lpos)
	return bitidx_to_bytemask(phash)
end

--[[
Go from a byte index and mask to the lpos.
Reverses lpos_to_bytemask()
]]
local function bytemask_to_lpos(bidx, mask)
	return hash_to_lpos(bytemask_to_bitidx(bidx, mask))
end

local function in_range(val)
	return val >= 0 and val < chunk_size
end

--[[
15 "adjacent" chunks (includes self as [1])
Note that we have to include the node above and below the side nodes to allow
for jumping up or dropping down while moving outside the chunk.
This is roughly ordered from most likely to least likely to save a bit of memory.
]]
wayzone.chunk_adjacent = {
	[1]  = vector.new(0, 0, 0),                      -- self/same chunk
	[2]  = vector.new(-chunk_size, 0, 0),            -- -X
	[3]  = vector.new(chunk_size, 0, 0),             -- +X
	[4]  = vector.new(0, 0, -chunk_size),            -- -Z
	[5]  = vector.new(0, 0, chunk_size),             -- +Z
	[6]  = vector.new(0, -chunk_size, 0),            -- -Y
	[7]  = vector.new(0, chunk_size, 0),             -- +Y
	[8]  = vector.new(-chunk_size, -chunk_size, 0),  -- -X, -Y
	[9]  = vector.new(-chunk_size, chunk_size,  0),  -- -X, +Y
	[10] = vector.new(chunk_size, -chunk_size, 0),   -- +X, -Y
	[11] = vector.new(chunk_size, chunk_size,  0),   -- +X, +Y
	[12] = vector.new(0, -chunk_size, -chunk_size),  -- -Z, -Y
	[13] = vector.new(0, chunk_size, -chunk_size),   -- -Z, +Y
	[14] = vector.new(0, -chunk_size, chunk_size),   -- +Z, -Y
	[15] = vector.new(0, chunk_size, chunk_size),    -- +Z, +Y
}

--[[
Lookup table for finding the index for the lpos.
The comparison of each axis (-1,0,1) is turned in a 3-bit field.
Note: 3 is a 2-bit "-1"
b0:1 = 0x03=-X, 0x00=inside, 0x01=+X
b2:3 = 0x0c=-Z, 0x00=inside, 0x04=+Z
b4:5 = 0x30=-Y, 0x00=inside, 0x10=+Y
]]
local chunk_adjacent_lookup = {
	[0x00] = 1,
	[0x30] = 6,
	[0x10] = 7,
	[0x03] = 2,
	[0x33] = 8,
	[0x13] = 9,
	[0x01] = 3,
	[0x31] = 10,
	[0x11] = 11,
	[0x0c] = 4,
	[0x3c] = 12,
	[0x1c] = 13,
	[0x04] = 5,
	[0x34] = 14,
	[0x14] = 15,
}

-- find the index (into chunk_adjacent) for the "outside" exit set
-- returns the index into chunk_adjacent, lpos in the adjacent chunk
local function exit_index(self, lpos)
	local key = 0

	if lpos.x < 0 then
		key = key + 0x03
	elseif lpos.x >= chunk_size then
		key = key + 0x01
	end

	if lpos.z < 0 then
		key = key + 0x0c
	elseif lpos.z >= chunk_size then
		key = key + 0x04
	end

	if lpos.y < 0 then
		key = key + 0x30
	elseif lpos.y >= chunk_size then
		key = key + 0x10
	end

	local index = chunk_adjacent_lookup[key]
	if index ~= nil then
		local avec = wayzone.chunk_adjacent[index]
		if avec ~= nil then
			return index, vector.new(lpos.x - avec.x, lpos.y - avec.y, lpos.z - avec.z)
		end
	end
	return nil
end

-- convert a global position to a local position by subtracting off self.cpos
function wayzone:pos_to_lpos(pos)
	return vector.subtract(vector.floor(pos), self.cpos)
end

-- convert a global position to a local position by adding self.cpos
function wayzone:lpos_to_pos(lpos)
	return vector.new(self.cpos.x + lpos.x, self.cpos.y + lpos.y, self.cpos.z + lpos.z)
end

-- Insert an exit position in the correct table.
function wayzone:insert_exit(pos)
	local lpos = self:pos_to_lpos(pos)
	local x_idx, x_lpos = exit_index(self, lpos)
	if x_idx == nil then
		log.warning("no exit idx lpos=%s pos=%s", minetest.pos_to_string(lpos), minetest.pos_to_string(pos))
		return
	end
	-- We need to put it in the correct exited table to reduce iteration time.
	-- This also indicates that the chunk to that side is important and we can
	-- link to it.
	local xmap = self.exited[x_idx]
	if xmap == nil then
		xmap = {}
		self.exited[x_idx] = xmap
	end
	-- store the lpos for the adjacent chunk
	xmap[lpos_to_hash(x_lpos)] = true
end

-- add a visited node
function wayzone:insert(pos)
	assert(type(self.visited) == "table")

	-- the position has to be inside the chunk
	local lpos = self:pos_to_lpos(pos)
	assert(in_range(lpos.x) and in_range(lpos.y) and in_range(lpos.z))

	-- update minp/maxp
	if self.minp == nil then
		self.minp = vector.new(pos)
		self.maxp = vector.new(pos)
	else
		for _, fld in ipairs({'x', 'y', 'z'}) do
			if self.minp[fld] > pos[fld] then
				self.minp[fld] = pos[fld]
			end
			if self.maxp[fld] < pos[fld] then
				self.maxp[fld] = pos[fld]
			end
		end
	end

	local bidx, bmask = lpos_to_bytemask(lpos)
	self.visited[bidx] = bit.bor(self.visited[bidx] or 0, bmask)
	return true
end

-- Calculate the center pos. this is called once via finish()
local function wayzone_calc_center(self)
	-- add up the coordinates to find the center
	local count = 0
	local sx = 0
	local sy = 0
	local sz = 0
	for pos in self:iter_visited() do
		count = count + 1
		sx = sx + pos.x
		sy = sy + pos.y
		sz = sz + pos.z
	end
	local vave = vector.new(sx/count, sy/count, sz/count)
	local best = nil
	local best_dist = 0
	for pos in self:iter_visited() do
		-- REVISIT: use distance squared to save a sqrt()?
		local dist = vector.distance(pos, vave)
		if best == nil or dist < best_dist then
			best = pos
			best_dist = dist
		end
	end
	self.center_pos = best
	self.visited_count = count
end

--function wayzone:minpack_pos_to_bitidx(self, pos)
--	local rel_pos = vector.new(pos.x - self.minp.x, pos.y - self.minp.y, pos.z - self.minp.z)
--	local bit_idx = rel_pos.y + rel_pos.x *
--end
--
---- rebase all coordinates to minp and re-build the visited array.
--function wayzone:minpackvisited(self)
--	self.visited_x_stride = 1 + self.maxp.x - self.minp.x
--	self.visited_z_stride = (1 + self.maxp.z - self.minp.z) * self.visited_x_stride
--	self.visited_dy = 1 + self.maxp.y - self.minp.y
--	local total_bits = self.visited_dx * self.visited_dy * self.visited_dz
--	local total_bytes = (self.visited_dx * self.visited_dy * self.visited_dz + 7) / 8
--	for pos in self:iter_visited() do
--		local bit_idx = vector.new(pos.x - self.minp.x, pos.y - self.minp.y, pos.z - self.minp.z)
--	end
--end

--[[
Flatten the 'visited' bitarray to a string, which uses at most chunk_bytes.
If CS=8, chunk_bytes is 64 bytes (8x8x8/8).
If CS=16, chunk_bytes is 512 bytes (16x16X16/8).

We could save some memory by using the bounding box and have the bitarray relative
to that. If a wayzone had one node, it would take 1 byte for the visited bitarray.
Wayzones that were flat (dy=1) would use even less.
]]
function wayzone:finish(in_water, in_door)
	-- pack the visited table into a fixed-length string.
	assert(type(self.visited) == "table")
	--self:minpackvisited()
	local tmp = {}
	for idx=1,chunk_bytes do
		table.insert(tmp, string.char(self.visited[idx] or 0))
	end
	self.visited = table.concat(tmp, '')
	self.in_water = in_water or false
	self.in_door = in_door or false

	-- pack the exited info into a variable-length string
	-- REVISIT: use a bitmap for X,Z,+Y sides (8 bytes or u64)
	local packed_exited = {}
	for k, v in pairs(self.exited) do
		--log.action("   idx=%d", k)
		assert(type(v) == "table")
		local xxx = {}
		for hash, _ in pairs(v) do
			--log.action("   exit %s", hash)
			-- pack 16-bit hash MSB-first in a string
			table.insert(xxx, string.char(bit.rshift(hash, 8), bit.band(hash, 0xff)))
		end
		packed_exited[k] = table.concat(xxx, '')
		--log.action("packed %d=>%d", k, #packed_exited[k])
	end
	self.exited = packed_exited

	-- update the center position
	wayzone_calc_center(self)
end

--[[
Check if a local position is in the visited positions inside the chunk.
This can be called before and after finish(), so both storage methods need to
be checked.
]]
function wayzone:inside_local(lpos)
	-- TODO: remove assert when it all works
	assert(in_range(lpos.x) and in_range(lpos.y) and in_range(lpos.z))

	-- get the byte index and bit mask
	local bidx, bmask = lpos_to_bytemask(lpos)
	-- pull the value from the right spot
	local val
	if type(self.visited) == "table" then
		val = self.visited[bidx] or 0
	else
		val = string.byte(self.visited, bidx)
	end
	assert(val ~= nil)

	return bit.band(val, bmask) > 0
end

local function pos_inside_min_max(pos, minp, maxp)
	return not (pos.x < minp.x or pos.y < minp.y or pos.z < minp.z or
	            pos.x > maxp.x or pos.y > maxp.y or pos.z > maxp.z)
end

--[[
Check if a position is inside the chunk.
]]
function wayzone:inside(pos)
	-- check the bounding box for the wayzone
	if self.minp == nil or not pos_inside_min_max(pos, self.minp, self.maxp) then
		return false
	end

	-- check the visited array/string
	return self:inside_local(self:pos_to_lpos(pos))
end

--[[
Counts the number of exit nodes that are in the other wayzone.
Stops counting at max_count, default 1.
]]
function wayzone:exited_to(wz_other, max_count)
	max_count = max_count or 1
	local count = 0
	local pcnt = 0
	for pos in self:iter_exited(wz_other.cpos) do
		pcnt = pcnt + 1
		if wz_other:inside(pos) then
			count = count + 1
			--log.action(" %s-%d connects to %s-%d",
			--	minetest.pos_to_string(self.cpos), self.index,
			--	minetest.pos_to_string(wz_other.cpos), wz_other.index)
			if count >= max_count then
				break
			end
		end
	end
	--if count == 0 and pcnt > 0 then
	--	log.action("exited_to: no hit for %s -> %s  pcnt=%d", self.key, wz_other.key, pcnt)
	--end

	return count
end

--[[
Iterate over the "exited" stores
If @adjacent_cpos is nil, the it iterates over all of them.
If @adjacent_cpos is set to a neighboring chunk, then it only iterates over those.
]]
function wayzone:iter_exited(adjacent_cpos)
	-- Create a local list of populated indexes
	local exited_indexes = {}
	if adjacent_cpos == nil then
		for x_idx, text in pairs(self.exited) do
			table.insert(exited_indexes, x_idx)
		end
	else
		local x_idx = exit_index(self, vector.subtract(adjacent_cpos, self.cpos))
		-- check for invalid "adjacent" chunk
		if x_idx ~= nil then
			table.insert(exited_indexes, x_idx)
		end
	end

	local exit_idx = 1	-- index into exited_indexes[]
	local text_idx = 1  -- index into the string at self.exited[exited_indexes[exit_idx]]
	return function()
		while true do
			if exit_idx > #exited_indexes then
				return nil
			end
			local x_idx = exited_indexes[exit_idx]
			local text = self.exited[x_idx]

			if text ~= nil and text_idx < #text then
				local hash = bit.lshift(string.byte(text, text_idx), 8) + string.byte(text, text_idx+1)
				local lpos = hash_to_lpos(hash)
				local pos = vector.add(self.cpos, lpos)
				local avec = wayzone.chunk_adjacent[x_idx]
				if avec ~= nil then
					pos = vector.add(pos, avec)
				end
				text_idx = text_idx + 2
				return pos
			end
			exit_idx = exit_idx + 1
			text_idx = 1
		end
	end
end

-- iterate over the visited nodes, returning the global position of each
function wayzone:iter_visited()
	-- This needs to work before and after finish()
	local fcn
	if type(self.visited) == 'table' then
		fcn = function(bidx)
			-- this is a sparse array
			return self.visited[bidx] or 0
		end
	else
		fcn = function(bidx)
			-- this is a string
			return string.byte(self.visited, bidx)
		end
	end
	local byte_idx = 1
	local bit_mask = 1
	return function ()
		while true do
			if byte_idx > chunk_bytes then
				return nil
			end
			if bit_mask < 256 then
				local val = fcn(byte_idx)
				if val == 0 then -- skip 8 bits at a time
					byte_idx = byte_idx + 1
					bit_mask = 1
				else
					local cur_mask = bit_mask
					bit_mask = bit_mask * 2
					if bit.band(val, cur_mask) > 0 then
						return vector.add(self.cpos, bytemask_to_lpos(byte_idx, cur_mask))
					end
				end
			else
				byte_idx = byte_idx + 1
				bit_mask = 1
			end
		end
	end
end

-- Return a new vector containing the center of the wayzone.
function wayzone:get_center_pos()
	assert(self.center_pos ~= nil)
	return vector.new(self.center_pos)
end

-- find the closest location in minp, maxp to pos
local function closest_to_box(pos, minp, maxp)
	local function bound_val(val, vmin, vmax)
		if val < vmin then return vmin end
		if val > vmax then return vmax end
		return val
	end
	return vector.new(
		bound_val(pos.x, minp.x, maxp.x),
		bound_val(pos.y, minp.y, maxp.y),
		bound_val(pos.z, minp.z, maxp.z))
end

-- get the closest position in the wayzone to pos
function wayzone:get_closest(ref_pos)
	local rpos = vector.round(ref_pos)

	-- try the easy check first -- pos is in the wayzone
	if self:inside(rpos) then
		return rpos
	end

	-- be stupid until I have time to do this right
	local best = {}
	for pos in self:iter_visited() do
		local dist = vector.distance(pos, ref_pos)
		if best.dist == nil or dist < best.dist then
			best.dist = dist
			best.pos = pos
		end
	end
	return best.pos
end

-- Get the first and last itersection with wayzone in the X-Z plane
-- ignores Y pos
--function wayzone:get_closest_hit_xz(start_pos, target_pos)
--	local maxp = vector.new(self.cpos.x + chunk_size, self.cpos.y + chunk_size, self.cpos.z + chunk_size)
--	local dv = vector.subtract(start_pos, target_pos)
--	local d_ts = vector.subtract(target_pos, start_pos)
--	local max_len = vector.distance(start_pos, target_pos)
--
--	-- be stupid until I have time to do this right
--	local close = {}
--	local best_end = {}
--	local d_max = {}
--	local d_min = {}
--	for pos in self:iter_visited() do
--		local p_d = math.abs((d_ts.x * (start_pos.z - pos.z)) - ((start_pos.x - pos.x) * d_ts.z))
--		local s_dist = vector.distance(pos, start_pos)
--		local t_dist = vector.distance(pos, target_pos)
--		local dt = (s_dist + t_dist) - max_len
--		if d_min.dist == nil or (dt <= 1 and dist < s_best.dist then
--			best.dist = dist
--			best.pos = pos
--		end
--	end
--	return best.pos
--end

--[[
Create the "end_pos" for this wayzone.
@allowed_chash is optional.
  It can be a chunk hash (number) or an array of chunk hashes.
  If present, this will create an "outside" function that discards
  walkers that stray outside any of the chunks.
@target_pos is optional.
  It must be a table with x,y,z. If missing the center position
]]
function wayzone:get_dest(target_pos)
	local target_area
	if target_pos ~= nil then
		target_area = vector.new(target_pos)
	else
	--if cur_pos ~= nil then
	--	target_area = closest_to_box(cur_pos, self.minp, self.maxp)
	--else
		target_area = self:get_center_pos()
	end

	target_area.inside = function(fself, pos, hash)
		-- call wayzone:inside(), not target_area:inside()
		return self:inside(pos)
	end
	return target_area
end

-- Adds an 'outside' function that allows only the chunks associated with the
-- hashes listed in allowed_chash.
-- target_area must be a table.
function wayzone.outside_chash(target_area, allowed_chash)
	assert(type(target_area) == "table")

	if target_area.chash_ok == nil then
		target_area.chash_ok = {} -- table of allowed chunks (by hash)
	end
	if allowed_chash ~= nil then
		if type(allowed_chash) == "table" then
			for _, hh in ipairs(allowed_chash) do
				target_area.chash_ok[hh] = true
			end
		elseif type(allowed_chash) == "number" then
			target_area.chash_ok[allowed_chash] = true
		end
	end
	if target_area.outside == nil then
		target_area.outside = function(self, pos, hash)
			local chash = minetest.hash_node_position(wayzone.normalize_pos(pos))
			return self.chash_ok[chash] ~= true
		end
	end
end

-- Adds an 'outside' function that allows positions only in the wayzones.
-- target_area must be a table.
function wayzone.outside_wz(target_area, allowed_wz)
	assert(type(target_area) == "table")

	if target_area.wz_ok == nil then
		target_area.wz_ok = {} -- table of allowed wayzones
		target_area.outside = function(self, pos, hash)
			-- check to see if pos is inside any of the wayzones
			for _, wz in ipairs(self.wz_ok) do
				if wz:inside(pos) then
					return false
				end
			end
			-- not in a wayzone, so the position is outside
			return true
		end
	end

	-- add the wayzones to the list
	if allowed_wz ~= nil and type(allowed_wz) == "table" then
		for _, wz in pairs(allowed_wz) do
			if wz ~= nil then
				table.insert(target_area.wz_ok, wz)
			end
		end
	end
end

-- record that we have a link to self to @to_wz
function wayzone:link_add_to(to_wz, xcnt)
	self.link_to[to_wz.key] = { chash=to_wz.chash, index=to_wz.index, key=to_wz.key, xcnt=xcnt }
end

-- record that we have a link from @from_wz to self
function wayzone:link_add_from(from_wz, xcnt)
	self.link_from[from_wz.key] = { chash=from_wz.chash, index=from_wz.index, key=from_wz.key, xcnt=xcnt }
end

-- check if we have a link to the wayzone
function wayzone:link_test_to(to_wz)
	log.action("link_test: %s => %s", self.key, to_wz.key)
	return self.link_to[to_wz.key] ~= nil
end

-- check if we have a link to the wayzone
function wayzone:link_test_from(from_wz)
	log.action("link_test: %s <= %s", self.key, from_wz.key)
	return self.link_from[to_wz.key] ~= nil
end

local function wayzone_link_filter(link_tab, chash)
	-- do a scan to see if we need to change anything
	local found = false
	for _, ni in pairs(link_tab) do
		--log.action("wayzone_link_filter: check %s %x vs %x", ni.key, ni.chash, chash)
		if ni.chash == chash then
			found = true
			--log.action("wayzone_link_filter: found %x", chash)
			break
		end
	end
	if found then
		-- build a list of all we are keeping and replace self.link_out
		local link_new = {}
		for _, ni in pairs(link_tab) do
			if ni.chash ~= chash then
				--log.action("wayzone_link_filter: keep %s", ni.key)
				link_new[ni.key] = ni
			end
		end
		return link_new
	end
	return link_tab
end

-- delete all links to wayzones in the chunk described by other_chash
function wayzone:link_del(other_chash)
	--log.action("wayzone:link_del self=%s other=%x", self.key, other_chash)
	self.link_to = wayzone_link_filter(self.link_to, other_chash)
	self.link_from = wayzone_link_filter(self.link_from, other_chash)
end

--[[
Get the chunk position for an arbitrary position (clear lowest 4 bits of x,y,z)
This creates a new table.
]]
function wayzone.normalize_pos(pos)
	return vector.new(math.floor(pos.x/chunk_size)*chunk_size,
	                  math.floor(pos.y/chunk_size)*chunk_size,
	                  math.floor(pos.z/chunk_size)*chunk_size)
end

-- Encode the chash/index pair into a globally unique table key
-- I'd like to use a uint64, but that doesn't work in Lua. (precision issue)
-- So, we do hex right now, as that is really useful for debug logs.
-- We could use pack/unpack if not using it in logs.
function wayzone.key_encode(chash, index)
	-- return string.pack('=I6B', chash, index)
	return string.format("%012x:%d", chash, index)
end

-- Encode the cpos/index pair into a globally unique table key
function wayzone.key_encode_pos(cpos, index)
	return wayzone.key_encode(minetest.hash_node_position(cpos), index)
end

-- Decode the chash/index pair from the key
function wayzone.key_decode(key)
	-- return string.unpack('=I6B', key)
	return tonumber(string.sub(key, 1, 12), 16), tonumber(string.sub(key, 14), 10)
end

-- Decode the cpos/index pair from the key
function wayzone.key_decode_pos(key)
	local hash, index = wayzone.key_decode(key)
	return minetest.get_position_from_hash(hash), index
end

-- create a new, empty wayzone
function wayzone.new(cpos, index)
	local wz = {}
	wz.index = index                                -- index in owning chunk
	wz.cpos = wayzone.normalize_pos(cpos)           -- global coords of owning chunk
	wz.chash = minetest.hash_node_position(wz.cpos) -- hash (ID) of owning chunk
	-- wz.center_pos = visited node position closest to the center (global coords)
	-- wz.minp = minimum of all visited node positions (global coords)
	-- wz.maxp = maximum of all visited node positions (global coords)
	-- globally unique key for this wayzone
	wz.key = wayzone.key_encode(wz.chash, wz.index) -- unique key for this wayzone
	wz.visited = {} -- visited locations (table of hashes or bitmap string)
	wz.exited = {} -- inside=7,1..6=outside, val=table of hashes or array/string
	-- wz.visited_count = number of visited entries after finish
	-- the neighbor entries are only the chash, index, and key fields from the wayzone
	wz.link_to = {}   -- links to other wayzones, key=other_wz.key
	wz.link_from = {} -- links from other wayzones, key=other_wz.key
	return setmetatable(wz, { __index = wayzone })
end

-------------------------------------------------------------------------------

--[[
Expand the cube in any direction so that ALL new coverage is in the self.visited
store but not in the visited map.
Update @mm and @visited.
@return true=expanded in a direction (-x,+x,-y,+y,-z,+z), false=cannot expand
]]
local function expand_cube(self, mm, visited)
	-- check to see if all nodes in minp/maxp are in self.visited, but not in @visited
	local function all_good(minp, maxp)
		for x = minp.x, maxp.x do
			for z = minp.z, maxp.z do
				for y = minp.y, maxp.y do
					local tpos = vector.new(x, y, z)
					local thsh = minetest.hash_node_position(tpos)
					-- cannot have already visited and must be inside the wayzone
					if visited[thsh] == true or not self:inside(tpos) then
						return false
					end
				end
			end
		end
		return true
	end

	-- try -x
	local minp = vector.new(mm.minp.x - 1, mm.minp.y, mm.minp.z)
	local maxp = vector.new(mm.minp.x - 1, mm.maxp.y, mm.maxp.z)
	if all_good(minp, maxp) then
		mm.minp.x = mm.minp.x - 1
		log.action("# expanded -x")
		return true
	end

	-- try +x
	minp.x = mm.maxp.x + 1
	maxp.x = minp.x
	if all_good(minp, maxp) then
		mm.maxp.x = mm.maxp.x + 1
		log.action("# expanded +x")
		return true
	end

	-- try -z
	minp = vector.new(mm.minp.x, mm.minp.y, mm.minp.z - 1)
	maxp = vector.new(mm.maxp.x, mm.maxp.y, mm.minp.z - 1)
	if all_good(minp, maxp) then
		mm.minp.z = mm.minp.z - 1
		log.action("# expanded -z")
		return true
	end

	-- try +z
	minp.z = mm.maxp.z + 1
	maxp.z = minp.z
	if all_good(minp, maxp) then
		mm.maxp.z = mm.maxp.z + 1
		log.action("# expanded +z")
		return true
	end

	-- try -y
	minp = vector.new(mm.minp.x, mm.minp.y - 1, mm.minp.z)
	maxp = vector.new(mm.maxp.x, mm.minp.y - 1, mm.maxp.z)
	if all_good(minp, maxp) then
		mm.minp.y = mm.minp.y - 1
		log.action("# expanded -y")
		return true
	end

	-- try +y
	minp.y = mm.maxp.y + 1
	maxp.y = minp.y
	if all_good(minp, maxp) then
		mm.maxp.y = mm.maxp.y + 1
		log.action("# expanded +y")
		return true
	end

	return false
end

-- split the wayzone into boxes (not useful right now)
function wayzone:split()
	log.action("wayzone:split %s", self.key)
	local new_wz = {}
	local visited = {} -- key=pos hash, val=true/false

	for pos in self:iter_visited() do
		local hash = minetest.hash_node_position(pos)
		if visited[hash] ~= true then
			visited[hash] = true

			local mm = { minp = vector.copy(pos), maxp = vector.copy(pos) }
			while expand_cube(self, mm, visited) do
			end
			for x = mm.minp.x, mm.maxp.x do
				for y = mm.minp.y, mm.maxp.y do
					for z = mm.minp.z, mm.maxp.z do
						local vpos = vector.new(x,y,z)
						local vhsh = minetest.hash_node_position(vpos)
						visited[vhsh] = true
					end
				end
			end
			log.action("wayzone:split %s - %s", minetest.pos_to_string(mm.minp), minetest.pos_to_string(mm.maxp))
		end
	end
end

return wayzone
