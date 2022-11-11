--[[
A tool to display information about a node.
]]
local wayzone_utils = working_villages.require("wayzone_utils")
local tree_scan = working_villages.require("tree_scan")
local tool_name = "working_villages:query_tool"
local log = working_villages.require("log")

local function log_object(obj)
	log.action(" + object.get_pos() -> %s",
		minetest.pos_to_string(obj:get_pos()))
	log.action(" + object.get_velocity() -> %s",
		minetest.pos_to_string(obj:get_velocity()))
	log.action(" + object.get_hp() -> %s",
		tostring(obj:get_hp()))
	log.action(" + object.get_inventory() -> %s",
		tostring(obj:get_inventory()))
	log.action(" + object.get_wield_list() -> %s",
		tostring(obj:get_wield_list()))
	log.action(" + object.get_wield_index() -> %s",
		tostring(obj:get_wield_index()))
	log.action(" + object.get_wielded_item() -> %s",
		tostring(obj:get_wielded_item()))
	log.action(" + object.get_armor_groups() -> %s",
		tostring(obj:get_armor_groups()))
	log.action(" + object.get_animation() -> %s",
		tostring(obj:get_animation()))
	log.action(" + object.is_player() -> %s",
		tostring(obj:is_player()))
	log.action(" + object.get_nametag_attributes() -> %s",
		tostring(obj:get_nametag_attributes()))
end

local interesting_groups = { "tree", "sapling" }

local function log_invref(inv)
	--log.action(" + inv:is_empty() -> %s",
	--	tostring(inv:is_empty()))
	--log.action(" + inv:get_size() -> %s",
	--	tostring(inv:get_size()))
	--log.action(" + inv:get_width() -> %s",
	--	tostring(inv:get_width()))
	wayzone_utils.log_table(" + inv:get_lists()", inv:get_lists())
	wayzone_utils.log_table(" + inv:get_location()", inv:get_location())
	local grp_cnt = {}
	for stack_name, stack in pairs(inv:get_lists()) do
		for idx, istack in ipairs(stack) do
			local nname = istack:get_name()
			log.action("  %s:%d name=%s count=%d", stack_name, idx, nname, istack:get_count())
			local ndef = minetest.registered_nodes[nname]
			if ndef ~= nil then
				wayzone_utils.log_table(" + node def", ndef)
				for _, gnam in ipairs(interesting_groups) do
					if minetest.get_item_group(nname, gnam) > 0 then
						grp_cnt[gnam] = (grp_cnt[gnam] or 0) + istack:get_count()
					end
				end
			end
		end
	end
	wayzone_utils.log_table("group counts", grp_cnt)
end

local function query_tool_do_stuff(user, pointed_thing, is_use)
	if (pointed_thing.type == "node") then
		local pos = minetest.get_pointed_thing_position(pointed_thing)
		local node = minetest.get_node(pos)
		local nodedef = minetest.registered_nodes[node.name]
		log.action("query_tool: node @ %s name='%s' param1=%s param2=%s",
			minetest.pos_to_string(pos), node.name, node.param1, node.param2)
		if not is_use then
			wayzone_utils.log_table("query_tool: node def", nodedef)
		end
		if minetest.get_item_group(node.name, "tree") > 0 then
			local ret, trunk_pos, leave_pos = tree_scan.check_tree(pos)
			if ret == true then
				log.action("query_tool: part of a tree @ %s with %d trunk and %d leaves nodes",
					minetest.pos_to_string(trunk_pos[1]), #trunk_pos, #leave_pos)
			end
		end

	elseif (pointed_thing.type == "object") then
		local ent = pointed_thing.ref:get_luaentity()
		log.action("query_tool: object @ %s [%s]",
			minetest.pos_to_string(ent.object:get_pos()),
			ent.itemstring or ent.product_name or "unknown")
		if not is_use then
			if ent.object ~= nil then
				log_object(ent.object)
			end
			if ent.get_inventory ~= nil then
				log_invref(ent:get_inventory())
			end
			wayzone_utils.log_table("query_tool: luaentity", ent)
		end
	else
		log.action("query_tool: type=%s", pointed_thing.type)
	end
end

minetest.register_tool(tool_name, {
	description = "Working Villagers Query Tool",
	inventory_image = "query_tool.png",
	range = 16,

	on_place = function(itemstack, placer, pointed_thing)
		query_tool_do_stuff(placer, pointed_thing, false)
		return itemstack
	end,

	on_use = function(itemstack, user, pointed_thing)
		query_tool_do_stuff(user, pointed_thing, true)
		return itemstack
	end,

	on_secondary_use = function(itemstack, user, pointed_thing)
		query_tool_do_stuff(user, pointed_thing, false)
		return itemstack
	end,
})
