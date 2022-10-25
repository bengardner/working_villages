--[[
This is the storage for wayzone data.

What we need:
 - a set of all positions in the chunk that are part of the zone
 - the member positiions will only be tested
 - a set of all exit positions, or links to another zone
 - the exit positions can be in 7 groups:
   - internal (between zones inside the chunk)
   - to each of the 6 adjacent chunks
 - the exit positions will only be iterated (no lookup)
 - all position are clear and *above* a standable node

The simplest approach would be to use a table for each of the above and use
the position hash as the key. The value doesn't matter.

There are 4096 (16x16x16) nodes in a chunk. Assuming a height of 2, it would
require 3 nodes to have a stand position. That would give a realistic worst-case
count of ~1365 (16/3*16*16) positions. The absolute worst case would be a chunk
of 4906 climbable nodes, all of which can be in the zone.
The worst possible number of zones is also ~1365, if the pattern were constructed
such that no position could reach another position in the chunk

Lua uses about 40 bytes per table and about 40 bytes per entry.
A typical chunk will have 1 zone with about 256 positions.
That is over 10 KB just for the zone members.

A better approach is to use 1 bit per node.
That requires 4096 bits or 512 bytes.
However, given that we can't be in a solid node and we require (typically) 2
clear nodes above the standing position, we can cut the vertical resolution by 2.
That leaves a 2048 (16x8x16) bit array of 256 bytes per zone.

However, directly constructing a 256 byte string, one bit at a time would trash
the garbage collector, so we build it as an array and table.concat() when done.

Corner cases (assume 16x16x16, from 0,0,0 to 15,15,15):
 - We can stand on the bottom of the chunk, with the node that we are standing on
   in the chunk below. That makes the zone depend on the chunk below.
 - We can stand on the top

16 _ this is part of chunk y+1
15 : s <- can stand here, this row and above are clear
14 : XXX
...
 2
 1
 0 _ s <- can stand here, depends on the chunk below
-1 : XXXXX

This "class" hides the implementation.

wz = wayzone.new(chunk_pos)
Create a new wayzone.

wz:insert(pos)
Add a position to the zone.
If pos is outside the chunk, this does nothing.

wz:insert_exit(pos)
Add a position as an exit node.
The position may be inside the chunk (internal) or a x+/-1, z+/-1, y+/-1.

wz:finish()
Indicate that we are done adding positions.
This compacts the data storage.
Cannot call insert() after calling finish().

wz:inside(pos)
Test if a position is inside the zone.

wz:exited_to(wz_other)
Test if the current zone has an exit that maps to the other zone.


Todo:
 - put a box around the path when going from one wayzone to the next.
   the box includes the involved chunks.
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
]]
local S = default.get_translator

local wayzone = {}

-- convert a mask back to the bit -- there has to be a better way
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

-- change a local position to a hash (12 bits, 0-15) (for the exit nodes)
-- y is in the lsb so that we can reduce y precision with a rshift.
local function lpos_to_hash(lpos)
	return bit.lshift(lpos.x, 8) + bit.lshift(lpos.z, 4) + lpos.y
end

-- change a hash to a local position (for the exit nodes)
local function hash_to_lpos(hash)
	return { x=bit.band(bit.rshift(hash, 8), 15),
	         y=bit.band(hash, 15),
	         z=bit.band(bit.rshift(hash, 4), 15) }
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
@lpos is the local position, adjused to 0-15.
@return byte_index, byte_mask

NOTE: byte_index is 1-based
]]
local function lpos_to_bytemask(lpos)
	-- REVISIT: We could rshift to reduce y resolution, but do full res for now
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
	return val >= 0 and val <= 15
end

-- Seven "adjacent" chunks (includes self)
wayzone.chunk_adjacent = {
	[1] = { x=-16, y=  0, z=  0 },
	[2] = { x= 16, y=  0, z=  0 },
	[3] = { x=  0, y=-16, z=  0 },
	[4] = { x=  0, y= 16, z=  0 },
	[5] = { x=  0, y=  0, z=-16 },
	[6] = { x=  0, y=  0, z= 16 },
	[7] = { x=  0, y=  0, z=  0 },
}

-- find the index for the "outside" exit set
-- 1=-1, 2=+x, 3=-y, 4=+y, 5=-z, 6=+z, 7=inside
local function exit_index(self, lpos)
	--minetest.log("action", string.format("wayzone: exit %s %s",
	--	minetest.pos_to_string(lpos),
	--	minetest.pos_to_string(vector.add(lpos, self.cpos))))
	if in_range(lpos.x) then
		if in_range(lpos.y) then
			-- x,y in range
			if in_range(lpos.z) then
				-- x,y,z in range
				return 7, lpos -- inside
			elseif lpos.z < 0 then
				return 5, {x=lpos.x, y=lpos.y, z=lpos.z+16} -- at -z
			else
				return 6, {x=lpos.x, y=lpos.y, z=lpos.z-16} -- at +z
			end
		elseif in_range(lpos.z) then
			-- x,z in range
			if lpos.y < 0 then
				return 3, {x=lpos.x, y=lpos.y+16, z=lpos.z}  -- at -y
			else
				return 4, {x=lpos.x, y=lpos.y-16, z=lpos.z} -- at +y
			end
		end
	elseif in_range(lpos.y) and in_range(lpos.z) then
		-- y,z in range, x not
		if lpos.x < 0 then
			return 1, {x=lpos.x+16, y=lpos.y, z=lpos.z} -- at -x
		else
			return 2, {x=lpos.x-16, y=lpos.y, z=lpos.z} -- at +x
		end
	end
	return nil -- corner?
end

function wayzone:pos_to_local(pos)
	return vector.subtract(vector.floor(pos), self.cpos)
end

-- Insert an exit position in the correct table.
function wayzone:insert_exit(pos)
	local lpos = self:pos_to_local(pos)
	local x_idx, x_lpos = exit_index(self, lpos)
	if x_idx == nil then return end
	-- we need to put it in the correct exited table to reduce iteration time
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
	local lpos = self:pos_to_local(pos)
	if lpos.x < 0 or lpos.y < 0 or lpos.z < 0 or lpos.x > 15 or lpos.y > 15 or lpos.z > 15 then
		minetest.log("warning", "wayzone: Called insert on ".. minetest.pos_to_string(lpos))
		return false
	end

	local bidx, bmask = lpos_to_bytemask(lpos)
	self.visited[bidx] = bit.bor(self.visited[bidx] or 0, bmask)
	return true
end

-- Flatten the byte array into a string
-- The array takes at least 10 KB. The string uses < 550.
function wayzone:finish()
	-- pack the visited table into a fixed-length string.
	assert(type(self.visited) == "table")
	local tmp = {}
	for idx=1,512 do
		table.insert(tmp, string.char(self.visited[idx] or 0))
	end
	self.visited = table.concat(tmp, '')

	-- pack the exited info into a variable-length string
	local packed_exited = {}
	for k, v in pairs(self.exited) do
		assert(type(v) == "table")
		local xxx = {}
		for hash, _ in pairs(v) do
			-- pack MSB-first in a string
			table.insert(xxx, string.char(bit.rshift(hash, 8), bit.band(hash, 0xff)))
		end
		packed_exited[k] = table.concat(xxx, '')
	end
	self.exited = packed_exited
end

--[[
Check if a local position is in the visited positions inside the chunk.
x,y,z should all be in range 0-15.
]]
function wayzone:inside_local(lpos)
	-- TODO: remove assert when it all works
	assert(in_range(lpos.x) and in_range(lpos.y) and in_range(lpos.z))
	-- get the byte index and bit mask
	local bidx, bmask = lpos_to_bytemask(lpos)
	local val
	-- pull the value from the right spot
	if type(self.visited) == "table" then
		val = self.visited[bidx] or 0
	else
		val = string.byte(self.visited, bidx)
	end

	return bit.band(val, bmask) > 0
end

--[[
Check if a position is inside the chunk.
This can be called before and after finish(), so both storage methods need to
be checked.
]]
function wayzone:inside(pos)
	-- convert to local coordinates
	local lpos = self:pos_to_local(pos)
	-- do the box check
	if lpos.x < 0 or lpos.y < 0 or lpos.z < 0 or lpos.x > 15 or lpos.y > 15 or lpos.z > 15 then
		return false
	end
	-- check the visited array/string
	return self:inside_local(lpos)
end

--[[
Check to see if this zone exits into @wz_other by checking the appropriate
exit positions against the zone content.
]]
function wayzone:exited_to(wz_other)
	for pos in self:iter_exited(wz_other.cpos) do
		if wz_other:inside(pos) then
			--minetest.log("action", string.format(" %s-%d connects to %s-%d",
			--	minetest.pos_to_string(self.cpos), self.index,
			--	minetest.pos_to_string(wz_other.cpos), wz_other.index))
			return true
		end
	end
	return false
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

-- iterate over the visited nodesm returning the global position of each
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
			if byte_idx > 512 then
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

--[[
Find a position at the center of the visited zone.
]]
function wayzone:get_center_pos()
	if self.center_pos == nil then
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
		local vave = { x=sx/count, y=sy/count, z=sz/count }
		local best = nil
		local best_dist = 0
		for pos in self:iter_visited() do
			local dist = vector.distance(pos, vave)
			if best == nil or dist < best_dist then
				best = pos
				best_dist = dist
			end
		end
		self.center_pos = best
	end
	return vector.new(self.center_pos)
end

--[[
Create the "end_pos" for this wayzone.
@cur_pos is optional. If present, create an "outside" function that discards
  walkers that stray outside the box created by the two wayzones.
]]
function wayzone:get_dest(from_cpos)
	local end_pos = self:get_center_pos()
	end_pos.inside = function(fself, pos, hash)
		return self:inside(pos)
	end
	if from_cpos ~= nil then
		local minp = {
			x=math.min(from_cpos.x, self.cpos.x),
			y=math.min(from_cpos.y, self.cpos.y),
			z=math.min(from_cpos.z, self.cpos.z)
		}
		local maxp = {
			x=math.max(from_cpos.x+15, self.cpos.x+15),
			y=math.max(from_cpos.y+15, self.cpos.y+15),
			z=math.max(from_cpos.z+15, self.cpos.z+15)
		}
		end_pos.outside = function(fself, pos, hash)
			return (pos.x < minp.x or pos.y < minp.y or pos.z < minp.z or
			        pos.x > maxp.x or pos.y > maxp.y or pos.z > maxp.z)
		end
	end
	return end_pos
end

-- local function that does the work
local function wayzone_link_add(self, to_chash, to_index, to_key)
	local ni = { chash=to_chash, index=to_index, key=to_key or wayzone.key_encode(to_hash, to_index) }

	-- Add the entry if we don't already have it
	if self.neighbors[ni.key] == nil then
		self.neighbors[ni.key] = ni
	end
end

function wayzone:link_add_hash_idx(to_chash, to_idx)
	wayzone_link_add(self, to_chash, to_idx, nil)
end

function wayzone:link_add(to_wz)
	wayzone_link_add(self, to_wz.chash, to_wz.index, to_wz.key)
end

-- check if we have a link to the wayzone
function wayzone:link_test(to_wz)
	minetest.log("action", string.format("link_test: %s => %s", self.key, to_wz.key))
	for k, v in pairs(self.neighbors) do
		minetest.log("action", string.format("link_test:    %s", k))
	end
	return self.neighbors[to_wz.key] ~= nil
end

-- delete all links to wayzones in the chunk described by to_chash
function wayzone:link_del(to_chash)
	-- do a scan to see if we need to change anything
	local found = false
	for ni_key, ni in ipairs(self.neighbors) do
		if ni.chash == to_chash then
			found = true
			break
		end
	end
	if found then
		-- build a list of all we are keeping and replace self.neighbors
		local neighbors = {}
		for _, ni in ipairs(self.neighbors) do
			if ni.chash ~= to_chash then
				neighbors[ni.key] = ni
			end
		end
		self.neighbors = neighbors
	end
end

--[[
Get the chunk position for an arbitrary position (clear lowest 4 bits of x,y,z)
This creates a new table.
]]
function wayzone.normalize_pos(pos)
	return { x=math.floor(pos.x/16)*16, y=math.floor(pos.y/16)*16, z=math.floor(pos.z/16)*16 }
end

-- Encode the chash/index pair into a globally unique table key
function wayzone.key_encode(chash, index)
	return string.format("%012x:%d", chash, index)
end

-- Encode the cpos/index pair into a globally unique table key
function wayzone.key_encode_pos(cpos, index)
	return wayzone.key_encode(minetest.hash_node_position(cpos), index)
end

-- Decode the chash/index pair from the key
function wayzone.key_decode(key)
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
	wz.index = index
	wz.cpos = wayzone.normalize_pos(cpos)
	wz.chash = minetest.hash_node_position(wz.cpos)
	-- globally unique key for this wayzone
	wz.key = wayzone.key_encode(wz.chash, wz.index)
	wz.visited = {} -- sparse array of 512 bytes
	wz.exited = {} -- inside=7,1..6=outside
	-- the neighbor entries are only the chash, index, and key fields from the wayzone
	wz.neighbors = {} -- key=to_wz.key val={ chash=to_wz.chash, index=to_wz.index, key=to_wz.key }
	return setmetatable(wz, { __index = wayzone })
end

return wayzone
