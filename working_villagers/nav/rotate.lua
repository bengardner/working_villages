--[[
Box rotation code.
Only does the 90 degree increment rotations allowed in facedir.
]]
local rotate = {}

-- for unit testing
if not vector then
	vector = require("vector")
end
if not bit then
	bit = require("bit")
end

-- rotate in-place by dir around the X axis: 1=-90 2=180 3=90 0=0
local function vec_rotate_x(vec, dir)
	if dir == 1 then     -- -90 deg
		vec.y, vec.z = vec.z, -vec.y
	elseif dir == 2 then -- 180 deg
		vec.y, vec.z = -vec.y, -vec.z
	elseif dir == 3 then -- 90 deg
		vec.y, vec.z = -vec.z, vec.y
	end
end

-- rotate in-place by dir around the Y axis: 1=-90 2=180 3=90 0=0
local function vec_rotate_y(vec, dir)
	if dir == 1 then     -- -90 deg
		vec.x, vec.z = vec.z, -vec.x
	elseif dir == 2 then -- 180 deg
		vec.x, vec.z = -vec.x, -vec.z
	elseif dir == 3 then -- 90 deg
		vec.x, vec.z = -vec.z, vec.x
	end
end

-- rotate in-place by dir around the Z axis: 1=-90 2=180 3=90 0=0
local function vec_rotate_z(vec, dir)
	if dir == 1 then     -- -90 deg
		vec.x, vec.y = vec.y, -vec.x
	elseif dir == 2 then -- 180 deg
		vec.x, vec.y = -vec.x, -vec.y
	elseif dir == 3 then -- 90 deg
		vec.x, vec.y = -vec.y, vec.x
	end
end

-- rotate @vec based on facedir (param2).
-- bits 0:1 control the Y axis rotation
-- bits 2:4 point the Y axis along a different axis
function rotate.vec_facedir(vec, facedir)
	-- don't alter the caller's vector
	vec = vector.copy(vec)

	local axisdir = bit.band(bit.rshift(facedir, 2), 7)
	facedir = bit.band(facedir, 3)

	vec_rotate_y(vec, facedir)

	if axisdir == 0 then
		-- do nothing, usual case
	elseif axisdir == 1 then
		vec_rotate_x(vec, 3) -- Z+ (rotate on X axis, 90)
	elseif axisdir == 2 then
		vec_rotate_x(vec, 1) -- Z- (rotate on X axis, -90)
	elseif axisdir == 3 then
		vec_rotate_z(vec, 1) -- X+ (rotate on Z axis, 90)
	elseif axisdir == 4 then
		vec_rotate_z(vec, 3) -- X- (rotate on Z axis, -90)
	elseif axisdir == 5 then
		vec_rotate_z(vec, 2) -- Y- (rotate on Z axis, 180)
	end
	return vec
end

-- 144 char table with the char set to 0x50 (P) + index, with neg idx meaning neg value
-- J=-box[6], K=-box[5], L=-box[4], M=-box[3], N=-box[2], O=-box[1]
-- Q=box[1],  R=box[2],  S=box[3],  T=box[4],  U=box[5],  V=box[6]
local facedir_box_str = "QRSTUVSRLVUOLRJOUMJRQMUTQJRTMUSQRVTULSROVUJLRMOUQSKTVNSLKVONLJKOMNJQKMTNRLSUOVRJLUMORQJUTMRSQUVTKQSNTVKSLNVOKLJNOMKJQNMTLKSONVJKLMNOQKJTNMSKQVNT"

--[[
Rotate a box (node_box, selection_box, collision_box) and sort min/max
Uses a lookup table, which should be a bit faster than creating two vectors,
rotating them individually and the assembling the new box with min/max.
]]
local function rotate_box_facedir(box, facedir)
	assert(#box >= 6 and type(box[1]) == "number", "bad box")
	assert(type(facedir) == "number", "bad facedir")

	local ti = (bit.band(facedir, 0x1f) * 6) -- no +1 because start at 1 below
	-- entry 0 is a no-op
	if ti > 0 and ti < #facedir_box_str then
		local function lookup(idx)
			local si = string.byte(facedir_box_str, ti + idx) - 0x50
			if si < 0 then
				return -box[-si]
			else
				return box[si]
			end
		end
		return { lookup(1), lookup(2), lookup(3), lookup(4), lookup(5), lookup(6) }
	end
	return box
end

--[[
Rotate all the boxes in @box.
@box may be a single box or an array of boxes.
]]
function rotate.box_facedir(box, facedir)
	-- empty table returns nil
	if type(box) ~= "table" or #box == 0 then
		return nil
	end

	-- handle an array of boxes
	if type(box[1]) ~= "number" then
		local new_box = {}
		for _, ob in ipairs(box) do
			table.insert(new_box, rotate_box_facedir(ob, facedir))
		end
		return new_box
	end

	return rotate_box_facedir(box, facedir)
end

-- manually do the box rotation
-- need to profile to see if it is any slower/faster than the table
function rotate.box_facedir_notab(box, facedir)
	local rmin = rotate.vec_facedir(vector.new(box[1], box[2], box[3]), facedir)
	local rmax = rotate.vec_facedir(vector.new(box[4], box[5], box[6]), facedir)
	return {
		math.min(rmin.x, rmax.x),
		math.min(rmin.y, rmax.y),
		math.min(rmin.z, rmax.z),
		math.max(rmin.x, rmax.x),
		math.max(rmin.y, rmax.y),
		math.max(rmin.z, rmax.z),
		}
end

-- creates the string "facedir_box_str" by calculating the box rotate the hard way.
-- also verifies that the manual and table methods match.
local function print_box_rotate_table()
	local box = { 1, 2, 3, 4, 5, 6 }

	local function encode_idx(idx)
		return string.char(0x50 + idx)
	end
	local function encode_box(bbb)
		local zz = {}
		for _, c in ipairs(bbb) do
			table.insert(zz, encode_idx(c))
		end
		return table.concat(zz, '')
	end

	local alltab = {}
	local allrot = {}
	for facedir=0,23 do
		table.insert(alltab, encode_box(rotate.box_facedir(box, facedir)))
		table.insert(allrot, encode_box(rotate.box_facedir_notab(box, facedir)))
	end
	local new_tab = table.concat(alltab, '')
	local new_rot = table.concat(allrot, '')
	print(string.format('local facedir_box_str = "%s"', new_tab))
	if new_tab ~= facedir_box_str or new_tab ~= new_rot then
		print(" ** string changed **")
	end
end

--print_box_rotate_table()

return rotate
