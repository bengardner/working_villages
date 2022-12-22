--[[
Generator that iterates over a line using something like Bresenham's algo.
]]
local line_gen = {}

local function co_line2d(x0, y0, x1, y1)
	local dx = math.abs(x1 - x0)
	local sx
	if x0 < x1 then
		sx = 1
	else
		sx = -1
	end

	local dy = -math.abs(y1 - y0)
	local sy
	if y0 < y1 then
		sy = 1
	else
		sy = -1
	end
	local err = dx + dy

	while true do
		coroutine.yield(x0, y0)
		if x0 == x1 and y0 == y1 then
			break
		end
		local e2 = 2 * err
		if e2 >= dy then
			if x0 == x1 then
				break
			end
			err = err + dy
			x0 = x0 + sx
		end
		if e2 <= dx then
			if y0 == y1 then
				break
			end
			err = err + dx
			y0 = y0 + sy
		end
	end
end

function line_gen.iter_line2d(x0, y0, x1, y1)
	return coroutine.wrap(function ()
		co_line2d(x0, y0, x1, y1)
	end)
end

return line_gen
