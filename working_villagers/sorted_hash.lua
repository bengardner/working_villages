--[[
A sorted hash is a combo of a linked list and a key-value pair.
The key must be unique.

This modifies the item by adding (and then removing) sl_pnext and sl_key

Three functions must be supplied:
 - key_encode(item): takes an item and returns the unique key
 - key_decode(key): takes a key from key_encode() and returns the component parts
 - item_compare(item1, item2): return true if item1 should be before item2
--]]

local sorted_hash = {}

-- Remove and return the first sorted item.
function sorted_hash:pop_head()
	local item = self.sl_pnext
	if item ~= nil then
		self.data[item.sl_key] = nil  -- clear from table
		self.sl_pnext = item.sl_pnext -- point head to next
		item.sl_pnext = nil           -- remove link, but do NOT remove the key
		self.count = self.count - 1   -- decrement count
		return item
	end
	return nil
end

-- Do a sorted add of an item, remove any item with the same key first
-- Sets item.sl_key
function sorted_hash:insert(item)
	item.sl_key = self.key_encode(item)
	-- must make sure there isn't already an entry with the key
	-- this also removes it from the linked list
	self:del(item.sl_key)
	-- add it by key
	self.data[item.sl_key] = item
	-- find a spot for it
	local head = self
	while true do
		-- if there is no head.sl_pnext, then set it to item (end of the list)
		local ref = head.sl_pnext
		if ref == nil then
			head.sl_pnext = item
			item.sl_pnext = nil -- to be safe
			self.count = self.count + 1
			return
		end
		-- if item is better than ref, then insert before ref
		if self.item_compare(item, ref) then
			-- insert item before ref
			item.sl_pnext = ref
			head.sl_pnext = item
			self.count = self.count + 1
			return
		end
		-- use ref as the new head (iterate down the list)
		head = ref
	end
end

-- gets an entry by key
function sorted_hash:get(key)
	return self.data[key]
end

-- remove an entry by key
function sorted_hash:del(key)
	local item = self.data[key]
	if item ~= nil then
		self.data[key] = nil
		local head = self
		while head.sl_next ~= nil do
			if head.sl_next._key == item._key then
				head.sl_next = item.sl_next
				self.count = self.count - 1
				return true
			end
			head = head.sl_next
		end
	end
	return false
end

function sorted_hash.new(key_encode, item_compare)
	return setmetatable({ count=0, data={}, key_encode=key_encode, item_compare=item_compare }, {__index = sorted_hash})
end

return sorted_hash
