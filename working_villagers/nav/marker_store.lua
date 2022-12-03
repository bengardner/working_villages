--[[
A marker store.
]]
local log = working_villages.require("log")

local marker_store = {}

local marker_name = "working_villages:marker"

marker_store.named = {}

function marker_store.get(name)
	return marker_store.named[name]
end

function marker_store.new(name, def)

	local self = {
		active = {},
	}
	for k, v in pairs(def) do
		self[k] = v
	end
	marker_store.named[name] = self
	return setmetatable(self, { __index = marker_store })
end

function marker_store.clear_all(name)
	for _, info in pairs(marker_store.named) do
		info:clear()
	end
end

-------------------------------------------------------------------------------

local marker = {}
function marker.new(def)
	return setmetatable(def or {}, { __index = marker })
end

function marker:refresh()
	local pstr = minetest.pos_to_string(self.marker_pos)
	local spos = string.format("%s %s", self._marker_text, pstr)
	self.marker_name = pstr
	self.object:set_nametag_attributes({text=spos})
	self.object:set_properties{infotext = spos}
end

-------------------------------------------------------------------------------

minetest.register_entity(marker_name, marker.new({
	initial_properties = {
		physical = false,
		--visual = "upright_sprite",
		visual = "sprite",
		pointable = false,
		collisionbox = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
		--visual_size = {x = 1, y = 1, z = 1},
		textures = {"wayzone_node.png", "wayzone_node.png", "wayzone_node.png", "wayzone_node.png", "wayzone_node.png", "wayzone_node.png"},
		glow = 14,
		nametag = "marker",
		--nametag_color = {},
		--nametag_bgcolor = {},
		infotext = "marker",
		static_save = false,
		damage_texture_modifier = "^[brighten",
		show_on_minimap = true,
	},
	on_activate = function(self, staticdata, dtime_s)
		self.marker_pos = vector.round(self.object:get_pos())
		self.marker_hash = minetest.hash_node_position(self.marker_pos)
		self._marker_text = ""
		--log.action("marker add %s", minetest.pos_to_string(self.marker_pos))
		self:refresh()
	end,
	on_deactivate = function(self, removal)
		--log.action("marker del %s", minetest.pos_to_string(self.marker_pos))
		self.marker_store.active[self.marker_hash] = nil
	end,
}))

function marker_store:add(pos, text, color, texture)
	local marker_pos = vector.round(pos)
	local marker_hash = minetest.hash_node_position(marker_pos)
	local ent = self.active[marker_hash]
	if ent ~= nil then
		ent._marker_text = ent._marker_text .. '\n' .. text
		ent:refresh()
		return
	end
	local obj = minetest.add_entity(pos, marker_name)
	ent = obj:get_luaentity()
	ent.marker_store = self
	self.active[marker_hash] = ent

	local props = {}
	if texture ~= nil then
		props.textures = { texture, texture }
	elseif self.texture ~= nil then
		props.textures = { self.texture, self.texture }
	end
	if self.visual_size ~= nil then
		props.visual_size = self.visual_size
	end
	obj:set_properties(props)
	if color ~= nil then
		obj:set_texture_mod(string.format("^[multiply:#%02x%02x%02x", color[1], color[2], color[3]))
	end

	if self.yoffs ~= nil then
		obj:set_pos(vector.add(obj:get_pos(), {x=0, y=self.yoffs, z=0}))
	end

	--log.action("marker_store:add %s @ %s", minetest.pos_to_string(pos), minetest.pos_to_string(obj:get_pos()))

	ent._marker_text = text
	ent:refresh()
	return ent
end

function marker_store:del(marker)
	marker.object:remove()
end

function marker_store:clear()
	for _, m in pairs(self.active) do
		m.object:remove()
	end
end

return marker_store
