--[[
A tool to display information about a node.
]]
local wayzone_utils = working_villages.require("nav/wayzone_utils")
local tree_scan = working_villages.require("tree_scan")
local tool_name = "working_villages:query_tool"
local log = working_villages.require("log")
local func = working_villages.require("jobs/util")

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

local function log_player_pos(player)
	local ppos = player:get_pos()
	local spos = func.adjust_stand_pos(ppos)

	wayzone_utils.put_marker(spos, "node")
	log.warning("player %s adjusted %s", minetest.pos_to_string(ppos), minetest.pos_to_string(spos))
end

local function get_node_drops(node_name)
	local nodedef = minetest.registered_nodes[node_name]
	if nodedef and nodedef.drops then
	end
end

--[[
Discover the drops that a node can drop.
Note that "minetest.get_node_drops(node, toolname)" returns the actual drops
for a particular node+tool combo and won't necessarily return all listed drops.
We do this by recursively scanning the "nodedef.drop" table for string values.
The values are in the "serialized" ItemStack representation "<ident> [<amount>...]".
We split the <ident> off the string at the first whitespace.
]]
local function my_get_drops(node_name)
	local out_tab = {}
	local function get_items_from_table(val)
		if type(val) == "string" then
			local idx = string.find(val, " ")
			if idx then
				val = string.sub(val, 1, idx-1)
			end
			out_tab[val] = true
		elseif type(val) == "table" then
			for k, v in pairs(val) do
				get_items_from_table(v)
			end
		end
	end

	local nodedef = minetest.registered_nodes[node_name]
	if nodedef and nodedef.drop then
		get_items_from_table(nodedef.drop)
	end
	-- convert the table keys to a list
	local out_list = {}
	for k, _ in pairs(out_tab) do
		table.insert(out_list, k)
	end
	return out_list
end

local did_tool_log = false

local function do_tool_log()
	local axes = {}
	for name, def in pairs(minetest.registered_tools) do
		if def.tool_capabilities and
			def.tool_capabilities.groupcaps and
			def.tool_capabilities.groupcaps.choppy
		then
			log.action("name: %s %s", name, dump(def))

			axes[name] = def
		end
	end
	for name, def in pairs(axes) do
		log.action("axe: %s", name)
		log.action("craft: %s", dump(minetest.get_all_craft_recipes(name)))
	end

	--for name, def in pairs(minetest.registered_craftitems) do
	--	log.action("CraftItem: %s %s", name, dump(def))
	--end

	--log.action("Minetest: %s", dump(minetest.get_all_craft_recipes()))
end

function is_bed(name)
	return minetest.get_item_group(name, "bed") > 0
end

function is_stair(name)
	return minetest.get_item_group(name, "stair") > 0
end

function is_chair(name)
	return string.find(name, "chair_") or string.find(name, "_chair")
end

function is_bench(name)
	return string.find(name, "bench_") or string.find(name, "_bench")
end

--[[
Determine the sit position and orientation.
Checks the node at pos and below to see if either is sittable.
Chairs:
 - if of type "fixed", then just sit in the node
 - if type "mesh", then pos = middle of the chair node (y+0.5)

bench:
 - so far all are good, use the face dir

bed:
 - use the face dir and pos (works, faces off bottom of bed.
 - if the bottom of the bed is blocked, then try +-90 deg

@return sit_pos, face_dir
]]
function get_sit_pos(pos)

end

local function do_sit_log()
	local ii = {}
	for name, def in pairs(minetest.registered_nodes) do
		if minetest.get_item_group(name, "bed") > 0 then
			table.insert(ii, { "bed", name })
		elseif minetest.get_item_group(name, "stair") > 0 then
			if string.find(name, "_inner_") == nil and string.find(name, "_outer_") == nil then
				table.insert(ii, { "stair", name })
			end
		elseif string.find(name, "chair_") or string.find(name, "_chair") then
			table.insert(ii, { "chair", name })
		elseif string.find(name, "bench_") or string.find(name, "_bench") then
			table.insert(ii, { "bench", name })
		elseif string.find(name, "slab") then
			table.insert(ii, { "slab", name })
		elseif string.find(name, "furniture") then
			table.insert(ii, { "furniture", name })
		end
	end
	table.sort(ii, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
	for _, v in ipairs(ii) do
		log.action("[%s] %s", v[1], v[2])
	end
end

local function log_center_top(def)
	local pos = func.find_seat_center(def)
	if pos then
		log.warning("top_center %s", minetest.pos_to_string(pos))
	end
end

local function query_tool_do_stuff(user, pointed_thing, is_use)
	if not did_tool_log then
		--do_tool_log()
		do_sit_log()
		did_tool_log = true
	end
	--log_player_pos(user)

	if (pointed_thing.type == "node") then
		local pos = minetest.get_pointed_thing_position(pointed_thing)
		local node = minetest.get_node(pos)
		local nodedef = minetest.registered_nodes[node.name]

		log.action("query_tool: node @ %s name='%s' param1=%s param2=%s light=%s",
			minetest.pos_to_string(pos), node.name, node.param1, node.param2, minetest.get_node_light(pos))
		if nodedef.paramtype2 == "facedir" then
			local dir = minetest.facedir_to_dir(node.param2)
			log.action(" ++ facedir %s rot=%d", minetest.pos_to_string(dir), bit.band(node.param2, 0x1f))
			local mpos = vector.subtract(pos, dir) -- subtract to get in front of item
			wayzone_utils.put_marker(mpos, "node")
		end
		if not is_use then
			wayzone_utils.log_table("query_tool: node def", nodedef)
			log.action("node def: %s", dump(nodedef))
			log_center_top(nodedef)
			log.action("drop: %s", dump(func.get_possible_drops(node.name)))
			local md = minetest.get_meta(pos)
			if md then
				local mt = md:to_table()
				if next(mt.fields) then
					log.action("meta.fields: %s", dump(mt.fields))
				end
				if next(mt.inventory) then
					log.action("meta.inventory: %s", dump(mt.inventory))
				end
			end
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
			ent.inventory_name or ent.itemstring or ent.product_name or "unknown")
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
