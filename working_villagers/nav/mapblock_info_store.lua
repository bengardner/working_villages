--[[
A size-based store for map info sha1sum areas.

API
-------
store = mapblock_info_store.new_store(size)
Get or create the store with the give size (4,8, or 16).

hash = store:get_infohash(pos)
Get the hash string for the block that contains pos.

mapblock_info_store.dirty_pos(pos)
Mark all areas that contain @pos as dirty.

mapblock_info_store.dirty_mapblock(pos)
Mark all areas in the mapblock that contain @pos as dirty.
]]
local log = working_villages.require("log")
local mapblock_info = working_villages.require("nav/mapblock_info")

-------------------------------------------------------------------------------
local mapblock_info_store = {}

-- key=size, val=mapblock_entry
mapblock_info_store.entries = {}

-------------------------------------------------------------------------------

local function vec_floor16(pos)
	return vector.new(math.floor(pos.x/16)*16, math.floor(pos.y/16)*16, math.floor(pos.z/16)*16)
end

local function vec_floor8(pos)
	return vector.new(math.floor(pos.x/8)*8, math.floor(pos.y/8)*8, math.floor(pos.z/8)*8)
end

local function vec_floor4(pos)
	return vector.new(math.floor(pos.x/4)*4, math.floor(pos.y/4)*4, math.floor(pos.z/4)*4)
end

-------------------------------------------------------------------------------

-- Scan a range of positions and calculate the hash
local function mapblock_scan_info_minp_maxp(minp, maxp)
	local vals = {}
	for y=minp.y, maxp.y do
		for z=minp.z, maxp.z do
			for z=minp.z, maxp.z do
				local val = mapblock_info.get(minetest.get_node(vector.new(x, y, z)))
				table.insert(vals, string.char(val))
			end
		end
	end
	local data = table.concat(vals, "")
	return data, minetest.sha1(data)
end

-------------------------------------------------------------------------------

local function entry_refresh(ent)
	if ent.dirty then
		local data, shasum = mapblock_scan_info_minp_maxp(ent.minp, ent.maxp)
		ent.sha1sum = shasum
		ent.dirty = false
	end
end

-------------------------------------------------------------------------------
-- this is the entry "class"
local mapblock_entry = {}

-- check if a position is inside a minp/maxp
local function pos_in_minp_maxp(pos, minp, maxp)
	return not (pos.x < minp.x or pos.x > maxp.x or
				pos.y < minp.y or pos.y > maxp.y or
				pos.z < minp.z or pos.z > maxp.z)
end

-- private function: mark all entries containing pos as dirty
local function mapblock_entry_dirty_pos(self, pos)
	local cpos = vec_floor16(pos)
	local hash = minetest.hash_node_position(cpos)
	local xtab = self.data[hash]
	if xtab ~= nil then
		for _, ent in pairs(xtab) do
			if pos_in_minp_maxp(pos, ent.minp, ent.maxp) then
				ent.dirty = true
			end
		end
	end
end

-- private function: mark all areas that overlap a mapblock as dirty
local function mapblock_entry_dirty_mapblock(self, pos)
	local cpos = vec_floor16(pos)
	local hash = minetest.hash_node_position(cpos)
	local xtab = self.data[hash]
	if xtab ~= nil then
		for _, ent in pairs(xtab) do
			ent.dirty = true
		end
	end
end

-- public: get the hash for a position in the block
function mapblock_entry:get_infohash(pos)
	local epos = self.vec_floor(pos)
	local ehsh = minetest.hash_node_position(epos)
	local cpos = vec_floor16(pos)
	local chsh = minetest.hash_node_position(cpos)

	local xtab = self.data[chsh]
	if xtab == nil then
		xtab = {}
		self.data[chsh] = xtab
	end

	local ent = xtab[ehsh]
	if ent == nil then
		ent = {
			minp = epos,
			maxp = vector.offset(epos, self.size, self.size, self.size),
			hash = ehsh,
			dirty = true,
			sha1sum = "",
		}
		xtab[ehsh] = ent
	end

	entry_refresh(ent)
	return ent.sha1sum
end

-------------------------------------------------------------------------------

-- create a new size-storage, with 1 method: get_infohash()
function mapblock_info_store.new_store(size)
	local floor_fnc = {
		[4] = vec_floor4,
		[8] = vec_floor8,
		[16] = vec_floor16,
	}
	local ff = floor_fnc[size]
	assert(ff ~= nil, "invalid size")

	local store = mapblock_info_store.entries[size]
	if store == nil then
		store = setmetatable({ vec_floor=ff, size=size, data={} }, { _index = mapblock_entry })
		mapblock_info_store.entries[size] = store
	end
	return store
end

-- mark all the areas that contain pos as dirty
function mapblock_info_store.dirty_pos(pos)
	for _, xx in pairs(mapblock_info_store.entries) do
		mapblock_entry_dirty_pos(xx, pos)
	end
end

-- mark all areas that overlap a mapblock as dirty
function mapblock_info_store.dirty_mapblock(pos)
	for _, xx in pairs(mapblock_info_store.entries) do
		mapblock_entry_dirty_mapblock(xx, pos)
	end
end

return mapblock_info_store
