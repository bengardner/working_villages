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
No point in trying to pick up something that we can't reach.

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


### Looser wayzone limits

Already done, but when computing the A* path, allow any wayzone that is doubly-linked to a wayzone that we pass through.

This makes the path look pretty good. It also allows passing through a neighboring wayzone when the start and dest are in the same wayzone.


### Rename the whole thing NavigationManager

wayzone_store => navigation_manager

nm = navigation_manager.new(args)

Methods:

Wayzone:

Class Items:

  * chunk_size = 8
  * chunk_adjacent[] -- offsets to the 15 adjacent chunks, including self at 1
  * outsize_wz(target, allowed_wz) -- add "outside" method to check list of allowed_wz
  * normalize_pos(pos)
  * key_encode(chash, index)
  * key_encode_pos(cpos, index)
  * key_decode(key)
  * key_decode_pos(key)
  * new(cpos, index)

Instance Items:

  * pos_to_lpos(pos) -- convert a global position to a local position
  * lpos_to_pos(pos) -- convert a local position to a global position
  * insert_exit(pos) -- add a global exit position
  * insert(pos)      -- add a global position to the wayzone
  * finish()         -- indicate that we are done with insert()
  * inside_local(lpos) -- check if a local position is inside the wayzone
  * inside(pos)      -- check if a global position is inside the wayzone
  * exited_to(wz_other, max_count)
  * iter_exited(adjacent_cpos)
  * iter_visited()
  * get_center_pos()
  * get_closest(ref_pos)
  * get_dest(target_pos)
  * link_add_to(to_wz, xcnt)
  * link_add_from(from_wz, xcnt)
  * link_test_to(to_wz)
  * link_test_from(from_wz)
  * link_del(other_chash) -- not used

Wayzone_Chunk:

  * new(cpos)                -- create a new wayzone_chunk, which will need to be populated
  * new_wayzone()            -- create a new wayzone, which will need to be populated
  * get_wayzone_for_pos(pos) -- find a wayzone whose inside() returns true
  * get_wayzone_by_key(key)  -- get the wayzone by key (extracts the index and returns that)
  * gen_is_current(other)    -- check if we have the current gen for the other chunk
  * gen_update(other)        -- update our copy of the current gen for the other chunk
  * mark_used()  -- note that we used the chunk
  * mark_dirty() -- mark as dirty
  * is_dirty()   -- check if dirty and needs rebuild

Wayzone_Store:

  * chunk_get_pos(pos)
  * chunk_get_by_pos(pos, no_load)
  * chunk_get_by_hash(hash, no_load)
  * chunk_dirty(cpos)
  * wayzone_get_by_key(key)
  * get_wayzone_for_pos(pos) -- find a wayzone that contains the position
  * find_standable_near(target, radius, start_pos)
  * find_standable_y(pos, up_y, down_y)
  * is_reachable(start_pos, target_pos)
  * round_position(pos)  -- move to pathfinder?
  * refresh_links_around(wz)
  * refresh_links(wzc1, wzc2)
  * find_path(start_pos, target_pos)
  * get_pos_info(pos, where)

Wayzone_Pathfinder:

  * wayzone_path.start(start_pos, target_pos, args)
  * wayzone_path:next_goal(cur_pos)

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

Later, after it is all working... maybe.




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
The goto_bed() task will yield until morning.

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


# AI: General

After a bit of research, it seems the 'best' approach is to periodically call a "check" function, which queues tasks.

There isn't a 1:1 relationship between check and tasks. Or, rather, there is some overlap.

It looks like most of the AI script can be shared with some job-specific check tasks.

  * check_farmer()
      * add "harvest_and_replant" task if there is something harvestable around
      * add "plant" task if we have seed AND have somewhere to plant
      * add "create_farm" task if we found a water node with a soil node within 2 nodes
      * add "check_jobsite" task to travel between old jobsites
      * add "gather_items" tasks if there are nay items that we want in sight AND we have inventory space

  * check_woodcutter()
      * add "chop_tree" task if there are trees we can chop around AND we have inventory space for logs
      * add "plant_sapling" task if we have saplings AND we can find somewhere to plant a sapling
      * add "gather_items" task if there are any items that we want in sight AND we have inventory space
      * add "check_jobsite" task to travel between old jobsites (where we planted a sapling or chopped a tree)

  * check_plant_collector()
      * add "harvest_node" task if there is something to harvest
      * add "check_jobsite" task to travel between old jobsites (where we previously found stuff)

  * check_snow_clearer()
      * add "clear_snow" task if snow is found over a path, next to a house, etc (not just anywhere)
      * add "wander_village" task that wanders around the village roads

  * check_path_builder()
      * build paths between buildings? villages?

  * check_builder()
      * add "check_jobsite" task to travel between old jobsites
      * gather materials
      * craft materials
      * use a "scaffolding" node for each planned node
          * shapes? solid, stair, etc
          * can only place a matching node over the "scaffolding"

  * torcher??

  * follow_player ?? why? replace with "supporter" 
      * picks up stuff
      * carries a backpack (chest on back, extra inventory)
      * ranged attacks on enemies

  * guard
      * stationary or patrol or follow player
      * alerted when enemies attack
      * attacks enemies
      * alternate schedules available (night, day shift)


In all cases, there are common tasks like
 
  * go home, go to bed
  * go to town center
  * chat with other villager (exchange info)
  * eat when hungry
  * drink when thirsty
  * acquire food
  * offload excess inventory to a chest (village or personal)


Other stuff:

  * Add economy
    * Add coin value to everything?
    * Players can remove or add stuff to village chests in exchange for coins
    * villagers do the same
    * where do coins come from??


# AI: schedule

Add a series of time slots that set or clear a variable based on the activity that the NPC should be doing during that time period.

There may be several schedules, based on the shift (for guards).

Examples:

  * sleep from 10 PM to 7 AM
  * breakfast from 7 AM to 9 AM
  * lunch from 12 AM to 2 PM
  * dinner from 5 PM to 7 PM
  * coordinate from 7 AM to 8 AM
  * work from 8 AM to 5 PM
  * break from 10 AM to 10:30 AM
  * break from 3 PM to 4 PM
  * school from 9 AM to 4 PM
  * church from 9 AM to 10 AM
  * socialize from 6 AM to 10 PM
  * hometime from 9 PM to 10 PM

The schedules can overlap. For example, the "breakfast" task would be complete for the day once breakfast has been eaten.

Once breakfast is complete, other tasks could be active, such as socialize and work.

A "completion" flag is maintained for each row, named after the schedule name. When the schedule is complete, the flags is set.
```
    self.job_data.complete['sleep'] = minetest.get_timeofday()
```
If the schedule is NOT active, then the data is cleared.
```
    self.job_data.complete['sleep'] = nil  -- or set to false?
```

The `check` function is called from on_step() if the job_data indicates the schedule is NOT complete. The check function is passed whether the schedule is active.
It is called once more with active=false when out of schedule if it was called with active=true.
```
function check_sleep(self, name, active)

Example:
    check_sleep(self, "sleep", true)
```

Example row (using 24-hour clock instead of the 24-scaled to 1.0):
```
    { name, array_of_start_stop_times, done_variable, check_function }
    { "sleep", { {0, 6}, {22, 24} }, "sleep", check_sleep }
    { "breakfast", {8, 17}, "breakfast", check_breakfast }
    { "work", {8, 17}, "work", check_work }
```

Have an assigned job for the day. Or maybe until done. The "work" 

A table of entries is used to check various things.

Tasks consist of a pair of check/task functions. Or maybe the check function i

# AI: Farmer

## Done

  * Added berry bush support
  * Using efficient planting logic

## Broken

  * ?

## ToDo

### Farmer: Need to be next to node that we work on.

Find a node adjacent to the node that we want to work on. Use the wayzone. Check N/S/E/W then diags.

Or just move to that node with a radius of 2 (anywhere in the 9 nodes).





### Bonemeal/fertiliser

Collect and use

  * bonemeal:fertiliser
  * bonemeal:mulch
  * bonemeal:bonemeal

### Use Scythe to harvest, if available.


# AI: Woodcutter

Try to move under the tree node if it is above head level.







# broken

register task circular include loop.

 -- move register routines to one file
 -- ??