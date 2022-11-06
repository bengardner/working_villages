--[[
This collection is specifically for the pathfinder.
It is a combination of a sorted linked list and a key-value pair (hash/table).
The key must be unique.

The sorted list is for the "active" positions.
The key/val table is for the "visited" positions.
Any entry added to the collection goes on the sorted list and is remove via
pop_head().

The item stored in the collection must be a table.
The insert() function modifies the item by adding the following fields:
 - sl_key : set with the result of the key_encode(item) function
 - sl_pnext : points to the next entry in the list
 - sl_active : indicates that the item is on the active list

Two functions must be supplied:
 - key_encode(item): takes an item and returns the unique key used for the key
   in table. The key must be a number or a string.
 - item_before(item1, item2): return true if item1 should be before item2
   Note that this is a less-than-or-equal check, as newly added items should
   go before existing items if they have the same cost value.

Fields:
 - data = the table containing all items
 - count = the number of "active" items in the sorted list
 - total = the total number of all items in the collection
 - sl_pnext = the first item in the list, which contains a field of the same
     name that points to the next item, etc. The last item has sl_pnext=nil.
--]]

local sorted_hash = {}

--[[
Remove and return the first item from the sorted list.
This does not remove it from the collection.
]]
function sorted_hash:pop_head()
	local item = self.sl_pnext
	if item ~= nil then
		self.sl_pnext = item.sl_pnext -- point head to next
		-- remove 'sl_pnext' and 'sl_active', but do NOT remove 'sl_key'
		item.sl_pnext = nil
		item.sl_active = nil
		self.count = self.count - 1 -- decrement list count, but not total
		return item
	end
	return nil
end

--[[
Do a sorted add of an item to the 'active' list, remove any item with the same
key first. Sets item.sl_key, item.sl_active, and item.sl_pnext.
]]
function sorted_hash:insert(item)
	item.sl_key = self.key_encode(item)
	item.sl_active = true
	-- must make sure there isn't already an entry with the key
	-- this also removes it from the linked list
	self:del(item.sl_key)
	-- add it by key
	self.data[item.sl_key] = item
	self.total = self.total + 1
	self.count = self.count + 1
	-- find a spot for it
	local head = self
	while true do
		-- if there is no head.sl_pnext, then set it to item (end of the list)
		local ref = head.sl_pnext
		if ref == nil then
			head.sl_pnext = item
			item.sl_pnext = nil -- to be safe
			return
		end
		-- if item is better than ref, then insert before ref
		if self.item_before(item, ref) then
			-- insert item before ref
			item.sl_pnext = ref
			head.sl_pnext = item
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
		self.total = self.total - 1
		-- if sl_active is true, then it is on the sorted list
		if item.sl_active == true then
			local head = self
			while head.sl_next ~= nil do
				if head.sl_next.sl_key == item.sl_key then
					head.sl_next = item.sl_next
					self.count = self.count - 1
					item.sl_active = nil
					item.sl_next = nil
					return true
				end
				head = head.sl_next
			end
		end
	end
	return false
end

--[[
Create a new collection.
@key_encode is a function that creates a key for the item.
@item_before is a function that compares two items, returning truw if the first
  item should be added before the second.
]]
function sorted_hash.new(key_encode, item_before)
	return setmetatable({ count=0, total=0, data={}, key_encode=key_encode, item_before=item_before }, {__index = sorted_hash})
end

return sorted_hash
