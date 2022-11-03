--[[
Misc utility functions that do not belong anywhere else.
]]
local wayzone = working_villages.require("wayzone")

local wayzone_utils = {}

-- Some unique colors for the particles
local wz_colors = {
	{ 255,   0,   0 },
	{   0, 255,   0 },
	{   0,   0, 255 },
	{ 255, 255,   0 },
	{ 255,   0, 255 },
	{   0, 255, 255 },
	{   0,   0,   0 },
	{ 255, 255, 255 },
	{ 128, 128, 128 },
	{ 255, 128,   0 },
	{ 128, 255,   0 },
	{ 255,   0, 128 },
	{ 128,   0, 255 },
	{   0, 255, 128 },
	{   0, 128, 255 },
}

--[[ Put a particle at @pos using args.
Args should contain "texture" OR "name" and "color"
args={texture=text, name=filename, color={r,g,b}, size=4, time=10}
]]
local function put_particle(pos, args)
	local vt = args.texture
	if vt == nil then
		local cc = args.color or {255,255,255}
		local fn = args.name or "wayzone_node.png"
		vt = string.format("%s^[multiply:#%02x%02x%02x", fn, cc[1], cc[2], cc[3])
	end
	minetest.add_particle({
		pos = pos,
		expirationtime = args.time or 10,
		playername = "singleplayer",
		glow = minetest.LIGHT_MAX,
		texture = vt,
		size = args.size or 4,
	})
end
wayzone_utils.put_particle = put_particle

-- show particles for one wayzone
function wayzone_utils.show_particles_wz(wz)
	local vn = "wayzone_node.png"
	local xn = "wayzone_exit.png"
	local xc = "wayzone_center.png"
	local cc = wz_colors[(wz.index % #wz_colors)+1]
	local vt = string.format("%s^[multiply:#%02x%02x%02x", vn, cc[1], cc[2], cc[3])
	local xt = string.format("%s^[multiply:#%02x%02x%02x", xn, cc[1]/2, cc[2]/2, cc[3]/2)
	local xcc = string.format("%s^[multiply:#%02x%02x%02x", xc, cc[1], cc[2], cc[3])
	local cpos = wz:get_center_pos()
	local dy = -0.25 + (wz.index / 8)

	put_particle(vector.new(cpos.x, cpos.y+dy, cpos.z), {texture=xcc})

	for pp in wz:iter_visited() do
		put_particle(vector.new(pp.x, pp.y+dy, pp.z), {texture=vt})
	end

	for pp in wz:iter_exited() do
		put_particle(vector.new(pp.x, pp.y+dy, pp.z), {texture=xt})
	end
end

-- show all the particles, @wzc is a wayzone_chunk or an array of wayzones
function wayzone_utils.show_particles(wzc)
	for _, wz in ipairs(wzc) do
		wayzone_utils.show_particles_wz(wz)
	end
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

-- show particles for a wayzone path, just the center nodes
function wayzone_utils.show_particles_wzpath(wzpath, start_pos, target_pos)
	local xc = "wayzone_center.png"
	local cur_tgt = start_pos

	for idx, wz_key in ipairs(wzpath) do
		local chash, idx = wayzone.key_decode(wz_key)
		local wzd = wayzones.get_chunk_data(chash)
		local wz = wzd[idx]
		local pos = wz:get_center_pos()

		local closest = closest_to_box(cur_tgt, wz.minp, wz.maxp)

		local cc = wz_colors[(idx % #wz_colors)+1]
		local xcc = string.format("%s^[multiply:#%02x%02x%02x", xc, cc[1], cc[2], cc[3])

		local clo_xcc = string.format("%s^[multiply:#%02x%02x%02x", xc, cc[1]/2, cc[2]/2, cc[3]/2)

		minetest.log("action", string.format("  center=%s target=%s closest=%s",
				minetest.pos_to_string(pos), minetest.pos_to_string(cur_tgt), minetest.pos_to_string(closest)))
		minetest.add_particle({
			pos = pos,
			expirationtime = 15,
			playername = "singleplayer",
			glow = minetest.LIGHT_MAX,
			texture = xcc,
			size = 4,
		})
		minetest.add_particle({
			pos = closest,
			expirationtime = 15,
			playername = "singleplayer",
			glow = minetest.LIGHT_MAX,
			texture = clo_xcc,
			size = 6,
		})
		cur_tgt = closest
	end
end

-- log the content of a table, recurse 1 level
function wayzone_utils.log_table(name, tab)
	minetest.log("info", string.format("%s content", name))
	for k, v in pairs(tab) do
		if type(v) == 'table' then
			for k2, v2 in pairs(v) do
				minetest.log("info", string.format("  | %s.%s = %s", k, k2, tostring(v2)))
			end
		else
			minetest.log("info", string.format("  | %s = %s", k, tostring(v)))
		end
	end
end


--[[
Estimate the cost to go from one chunk to another.
Since we can only go from one to the next on the 6-adjacent sides, and we
can't do a detailed cost check, and the chunks are 16x16x16, we use a cost
of 16 per chunk.
]]
local function wayzone_est_cost(s_cpos, d_cpos)
	local dx = math.abs(s_cpos.x - d_cpos.x)
	local dy = math.abs(s_cpos.y - d_cpos.y)
	local dz = math.abs(s_cpos.z - d_cpos.z)
	return dx + dy + dz
end

--[[ Check if two chunk positions are adjacent.
The total diff will be 0 (same chunk) or wayzone.chunk_size
]]
function wayzone_utils.chunks_are_adjacent(cpos1, cpos2)
	local dx = math.abs(cpos1.x - cpos2.x)
	local dy = math.abs(cpos1.y - cpos2.y)
	local dz = math.abs(cpos1.z - cpos2.z)
	--minetest.log("action", string.format("  dx=%d dy=%d dz=%d", dx, dy, dz))
	return (dx + dy + dz) <= wayzone.chunk_size
end

return wayzone_utils
