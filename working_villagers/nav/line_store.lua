--[[
Creates a series of entities as a line.
]]
local log = working_villages.require("log")

local line_store = {}

local line_store_names = {}

local line_name = "working_villages:line_node"

local default_options = {
	spacing = 0.5,
	texture = "wayzone_node.png",
	visual_size = vector.new(0.5, 0.5, 0.5),
	color1 = { 255, 0, 255},
	color2 = { 0, 255, 255},
}

-- create a store for lines with the same properties
function line_store.new(name, def)
	local self = line_store_names[name]
	if self ~= nil then
		return self
	end
	def = def or {}
	self = {
		seq_no = 0,
		lines = {},
	}
	for k, v in pairs(default_options) do
		self[k] = def[k] or v
	end
	-- convert endpoint colors to vectors
	self.color1 = vector.new(self.color1[1], self.color1[2], self.color1[3])
	self.color2 = vector.new(self.color2[1], self.color2[2], self.color2[3])
	line_store_names[name] = self
	return setmetatable(self, { __index = line_store })
end

local function resolve_store(name_or_inst)
	if type(name_or_inst) == "string" then
		return line_store_names[name]
	end
	return name_or_inst
end

-- get a line store that has already been created
function line_store.get(name)
	return line_store_names[name]
end

-- clear all lines from a line store
function line_store.clear(name)
	local store = resolve_store(name)
	if store then
		store:clear()
	end
end

-- clear all line stores
function line_store.clear_all()
	for name, store in pairs(line_store_names) do
		store:clear()
	end
end

-- remove a line store, destroying all lines in it
function line_store.remove(name)
	local store = resolve_store(name)
	if store then
		store:clear()
		line_store_names[name] = nil
	end
end

-- remove all lines and line stores
function line_store.remove_all()
	local lsn = line_store_names
	line_store_names = {}
	for name, store in pairs(lsn) do
		store:clear()
	end
end

-------------------------------------------------------------------------------
local line_class = {}

-- private function to create a new node on the line
local function line_class_create_node(self, spos)
	local obj = minetest.add_entity(spos, line_name)
	local ent = obj:get_luaentity()

	ent.line = self -- needed?

	-- update the texture and visual_size
	local texture = self.store.texture
	local visual_size = self.store.visual_size
	local props = {}
	if texture ~= nil then
		props.textures = { texture }
	end
	if visual_size ~= nil then
		props.visual_size = visual_size
	end
	if next(props) then
		obj:set_properties(props)
	end
	return obj
end

-- private function to refresh the line nodes
local function line_class_refresh(self)
	local spacing = math.max(0.1, self.store.spacing or 0.5)
	local steps = math.max(2, math.floor(vector.distance(self.spos, self.epos) / spacing))

	local pos = self.spos
	local pos_delta = vector.divide(vector.subtract(self.epos, self.spos), steps-1)
	local color = self.color1 or self.store.color1
	local color2 = self.color2 or self.store.color2
	local color_delta = vector.divide(vector.subtract(color2, color), steps-1)

	-- create and position/color the objs
	for idx=1, steps do
		local obj = self.objs[idx]
		if obj == nil then
			obj = line_class_create_node(self, pos)
			table.insert(self.objs, obj)
		end
		obj:set_pos(pos)
		obj:set_texture_mod(string.format("^[multiply:#%02x%02x%02x", color[1], color[2], color[3]))

		pos = vector.add(pos, pos_delta)
		color = vector.add(color, color_delta)
	end

	-- remove any excess objs
	while #self.objs > steps do
		self.objs[#self.objs]:remove()
		table.remove(self.objs)
	end
end

-- update the line start and end position
function line_class:update_pos(spos, epos)
	if self.spos and self.epos and vector.equals(self.spos, spos) and vector.equals(self.epos, epos) then
		return
	end
	self.spos = spos
	self.epos = epos
	line_class_refresh(self)
end

-- update the line color gradient
function line_class:update_color(color1, color2)
	if self.color1 and self.color2 and vector.equals(self.color1, color1) and vector.equals(self.color2, color2) then
		return
	end
	self.color1 = color1
	self.color2 = color2
	line_class_refresh(self)
end

-- private function to remove all nodes in the line
local function line_class_clear(self)
	local objs = self.objs
	self.objs = {}
	self.spos = nil
	self.epos = nil

	for k, v in pairs(objs) do
		v:remove()
	end
end

-- remove all nodes in the line and disconnect from the store
function line_class:remove()
	line_class_clear(self)
	self.store.lines[self.store_idx] = nil
end

-------------------------------------------------------------------------------

function line_store:draw_line(spos, epos)
	self.seq_no = self.seq_no + 1
	local line = {
		store = self,
		store_idx = self.seq_no, -- so the line can remove itself from the store
		objs = {},
	}
	setmetatable(line, { __index = line_class })

	-- add the line to the store
	self.lines[line.store_idx] = line

	-- update the line, creating the entities
	line:update_pos(spos, epos)
	return line
end

-- remove all lines from the store
function line_store:clear()
	local lines = self.lines
	self.lines = {}
	for k, v in pairs(lines) do
		line_class_clear(v)
	end
end

-------------------------------------------------------------------------------

minetest.register_entity(line_name, {
	initial_properties = {
		physical = false,
		pointable = false,
		visual = "sprite",
		collisionbox = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}, -- needed? not physical
		visual_size = default_options.visual_size,
		textures = { default_options.texture },
		glow = 14,
		static_save = false,
	},
})

return line_store
