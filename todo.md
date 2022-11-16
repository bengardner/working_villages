# To Do

This is a list of things that I want to do.

## Janky movement

I tried porting parts of mobkit and the movement is really jumpy when trying to navigate. Not sure why.
Possibly a bad gravity value or jump value.

## Auto-create a village

If a villager doesn't have a home or village then create shelter.

 - chop down trees to get logs
 - convert to planks and sticks
 - make a wood axe
 - make a wood pickaxe
 - pick a spot for a hut, designate as village center
 - dig out to make land level
 - build hut
 - make a bed

## Pickup stuff -- better check for finding place we can stand.

Use new working_village.nav:find_standable_near() for pickup verification.
No point in trying to 

## Pathfinder

## AI glitch

-- can't add planter, etc, tasks unless we find a spot or tree.
-- causes glitches in the random walk otherwise.
-- maybe stop for a while?
   -- MOB has saplings, but there is no spot nearby to plant -- check every 30 seconds?

## Current position

Saw the MOB get stuck on a corner between 4 nodes.

There were 3 present and the on missing was 2-deep.

The collision box for the MOB is colliding with a neighbor node. We have to assume that we are standing on the ground.


### Cost Adjustments

 - cost increase for each side-cell that doesn't have a ground pos (calculate on leaving)
    - Intended to stop the villager from walking next to dangerous drops
 - water cost adjustments
   - 3x cost for walking through 1-deep water (walk=10/14 in_water=30/42)
   - 20x cost for swimming through 2-deep water (swim=200/280)
   - should we allow swimming down?
     - +100 cost for every y below water (swim @ y=2 below=200+200=400)
   - allow a path to go along the water surface
 - calculate the real cost between connected waypoint centers
   - this accounts for the water cost
   - allows the waypoint_zone layer to navigate over a bridge instead of through water.

### Wayzone Selection

 - Add a knob that disallows going through water wayzones (no_swim)
     - Would prevent going from non-water to water.
 - Caller would have to first try with no water and then with water


### Add radius to destination again

If the destination node is not valid (in a tree), we need to find a nearby node that works.

Destination is a box.

Find the minp and maxp for the radius. Iterate over the chunks in that area to find wayzones that might overlap.

```
function get_overlapping_wayzones(pos, radius)
    local ss = wayzone_store.get()
    local minp = vector.new(pos.x - radius, pos.y - radius, pos.z - radius)
    local maxp = vector.new(pos.x + radius, pos.y + radius, pos.z + radius)
    local wz_set = {}
    for cx = minp.x,maxp.x,chunk_size do
        for cy = minp.y,maxp.y,chunk_size do
            for cz = minp.z,maxp.z,chunk_size do
                local cpos = vector.new(cx, cy, cz)
                local wzc = ss:chunk_get_by_pos(cpos)
                for idx, wz in ipairs(wzc) do
                    if wz:overlaps(minp,maxp) then
                        wz_set[wz.key] = wz
                    end
                end
            end
        end
    end
    return wzset
end
```

Then spiral outwards, looking for the first position that is in one of the listed wayzones.
Use that as the destination instead of the desired destination.
Keep the radius, so that we may end up in another nearby node.


### Rename the whole thing NavigationManager

wayzone_store => navigation_manager

nm = navigation_manager.new(args)


### Improve Tree Cutter Tree Selection

Use new "query_check_tree()" (rename it) to find a tree to cut down.

Store it in the woodcutter data.  When we go to select a node, grab the base position.
We go there.
Then randomly cut the last node from either the leaves or trunk list.
Repeat until empty.


### Chunk Scan -- to quickly see if anything changed

Uses the same logic as the stand-pos scan in process_chunk()?

1 nibble per node, 8x8x8/2=256 bytes, 16x16x16/2=2048 bytes

  b0=walkable
  b2=water         (in node)
  b3=climbable     (in node)
  b4=door          (in node)

Later, after it is all working...




## Working_Village AI revamp

Semi-copy mobkit

 - brain function decides what it should be doing. Runs on every tick. Usually throttled to 1 Hz check.
 - brain function sets a task, with a priority. May register tasks by name.
 - on_step() loop goes like this (identical to mobkit)
     - self:physics()
     - self:sensefunc()
     - self.logic()
     - execute_queues(self)

The logic() function is supposed to add the appropriate tasks to the queue.
I'm thinking it would add it by name so that we can easily add/remove a task.

For example, it adds "goto_bed" if it is nighttime and removes it during the day.
The goto_bed() task will yield until 

Unlike mobkit, there is no low queue.
A task is added to a sorted list.
If a function is running and has a lower priority than the head of the queue, then it is canceled.
The highest priority task is executed.
If the function returns true, then it is removed from the queue.
Otherwise, it is left on the queue and will be re-ran on the next step.
The function should yield() to wait for the next step.

```lua
function execute_queues(self)
    if self.job_thread ~= nil then
        if coroutine.status(self.job_thread) == "dead" then
            -- if exit status was 'true', then remove
            self.job_thread = nil
        end
    end
    if self.job_thread == nil then
    	if #self.hqueue > 0 then
    		local func = self.hqueue[1].func
    		if func(self) then
    			table.remove(self.hqueue,1)
    			self.lqueue = {}
    		end
    	end
    

-- adds a task at the given priority, which will be started with args passed to the function
function task_add(self, name, priority, args)

-- removes a task from the queue. stops it if it is the current active thread
function task_del(self, name)

-- clear all tasks
function task_cleaf(self)

For example, if a MOB is attacked, it would add the attacker to the list and call task_add() with a function that handles getting attacked.
The options are, for example, to flee, regroup, cower, take it, or attack.

It's OK if the task has already been added. It won't be restarted. The function should handle the update to the attacker list.

The brain function would add or remove the "goto_bed" task.

The brain function may unconditionally add gather_saplings(), plant_saplings(), chop_trees(), and chest_dropoff() if there is highest priority is below a certain value.
Each would expire as there is nothing to do.

For example, the gather_saplings() would be done if none were found or the MOB is carring more than 9 saplings.

plant_saplings() would be done if it doesn't have any saplings or it couldn't find a spot to plant one.

chop_trees() would be done if carring more than 32 logs or if no trees were found.

chest_dropoff() would be done if it doesn't have an assigned chest or there isn't enough inventory to bother dropping or the chest is full.
It might also construct a chest if needed.
```

-- Nav issue:
find sapling on top of a tree. Obviously no path to it.
need to blacklist it if there is no path.

Change find pickup to check if the object position is in the wayzone.



## Food 

Looks like nodes can be registered with a group named food_xxx


A craftitem can be registered with a "food_xx" label.
So far:
food_berry
food_bread
food_meat
food_milk
food_wheat
food_carrot
food_sugar
food_egg
food_rice


Need to determine how much hunger each removes.


