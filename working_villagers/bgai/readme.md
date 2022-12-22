Key Concepts
------------

# Check Function

A check function decides which tasks should be active.

A check function runs as often as every on_step() call. This might be called 10 times per second.

It should add tasks. It can set some AI-related data.
It generally should not alter the MOB object state (animation, velocity, position, inventory).

For example, the "pick up stuff" check function would periodically (3 seconds?) check the cached object scan info for something that it wants.
It would queue the "pick up stuff" task if something is found, storing the position(s) and names of the wanted items in the MOB data.

Likewise, the woodcutter check function would scan the surroundings for a tree (if not in town) every 5 seconds or so and queue the chop_tree task if found.
The tree is removed from the AI data store when processed. The check function could add more trees while the MOB is chopping down a tree.


# Tasks

A task is a script that runs in a coroutine. It does stuff. It generally calls lower-level tasks.

It should call coroutine.yield() or self:delay_*() the allow other code to run. Unless it runs through in one step.

It can be tricky because local data may become invalid when a yield occurs.

For example, a pick_up_stuff task may look like:
```
function task_pick_up_stuff(self)
    while true do
        local hash, names = next(self._bgai.pickups)
        local pos = minetest.get_position_from_hash(hash)

        self:goto(pos)
        for name, _ in pairs(names) do
            if self:item_wanted(name) then
                self:pickup(name)
                self:delay_seconds(2)
            end
        end
        self._bgai.pickups[hash] = nil
    end
    return true
end

```

## Example Task Names

  - farmer_plant_seeds
  - farmer_harvest_and_plant
  - farmer_till
  - woodcutter_plant_saplings
  - woodcutter_cut_down_trees
  - gather_items
  - goto_bed
  - goto
  - take_a_seat
  - wait_sit
  - work_break
  - meal
  - idle_rest
  - idle_wander
  - visit_job_sites
  - follow_player
  - follow_object
  - flee_player
  - flee_object
  - congregate
  - go_home
  - go_tavern
  - visit_chest
  - go_shopping  
  - ??

# Async Functions (low-level tasks)

These are really basic functions that do specific things. They may only be called from a task and may yield.

They return two values: `success` and `message`. `success` is either `true` or `false`. `message` is only provided when `success` is `false`.

  - delay_steps(count) : yield count times
  - delay_seconds(sec) : yield until deadline, using os.clock() as the time (NOTE: not sure how accurate this is)
  - go_to(pos, [radius], [allow_swim])
    - use pathfinder to go to a position or area
    - this will open doors/gates as needed and close them behind
  - dig_node(position, [tool])
    - go_to a position
    - checks protected status, distance
    - picks the best tool if tool is not set, ""=hand
    - dig the node, play dig/dug sounds
  - place_node(position, item)
    - go_to a position and place the node
    - checks protected status, distance, buildable_to
    - moves item to wield inventory
    - calls on_place(), minetest.set_node() or minetest.item_place_node(), depending
    - verifies by reading back the node
    - plays sound
  - use_node(position, tool)
    - go_to a position and use the tool on the node (scythe for harvest?)
  - collect_item(item)
    - go_to(pos), pickup_item(item)
  - collect_nearest_item_by_condition(cond, range)
    - collect the closest matching items
    - go_to(pos), pickup_item(item)
  - collect_nearby_items_by_condition(cond, range)
    - collect all matching items, closest first (picks closest on each pass, as this calls go_to())

# Sync Functions

These may be called from a task or from the check function. They cannot yield.

## ObjectRef Compatibility

The following are implemented in the base MOB class for player ObjectRef compatibility. This allows passing the `lua_entity` where an `ObjectRef` is expected.

In many cases, the functions simply calls the matching ObjectRef method. `self.object` is the ObjectRef.

  - get_player_name() -> ""
  - is_player() -> `false`
  - get_inventory() -> `InvRef`
  - get_wield_list() -> "wield_item"
  - get_wield_index() -> 1
  - get_wielded_item() -> `ItemStack`
  - set_wielded_item(itemstack)
  - get_breath() -> `number`
  - set_breath(value)
  - get_look_dir() -> `vector`
  - get_look_vertical() -> radians
  - get_look_horizontal() -> radians
  - set_look_vertical(radians)
  - set_look_horizontal(radians)
  - set_yaw(yaw)
  - get_yaw()
  - get_rotation()
  - set_rotation(rot)
  - get_pos() -> `vector`
  - set_pos(pos)
  - get_velocity() -> `vector`
  - set_velocity(vec)
  - add_velocity(vec)
  - get_luaentity() -> `self`


NOTE: The "look" direction is meant to rotate the head to look at a position. It will also rotate the whole MOB if it exceeds the rotation limits for the head.
In other words, setting the `look` may also set the `yaw`.

NOTE: I plan to try caching the velocity and setting it at the end of on_step(). It might be smoother if the velocity isn't set multiple times.

The MOB uses a detached inventory.

## Movement

  - stand_still() : stop movement and do "stand" animation
  - sit_down([position]) : sit down at the current position or at a specific position (range check?)
  - lay_down([position]) : lay down at the current position or at a specific position (range check?)
  - jump() : sets verticle velocity to jump up 1 node

## World Interaction

  - pickup_item(object)
    - remove item from world, add to main inventory, drop leftovers (range check?)
  - pickup_items()
    - pickup all itemstacks within range

### Object Scans

These should use the cached list of nearby objects instead of doing a new scan.

The distance args should probably be ignored.

  - get_nearest_enemy(distance)
  - get_nearest_item_by_condition(cond, distance)
  - get_nearest_player(distance)
  - get_items_by_condition(cond, distance) : ItemStacks only
  - get_nearby_objects_by_condition(cond) : any ObjectRef

### Chest

  - chest_open(pos)
    - checks range, permissions, etc
    - add self as a chest opener, potentially doing the chest open animation (no idea if a NPC can cause the chest to "open")
    - caller then manipulates the chest
    - returns the chest inventory ?
  - chest_get(pos)
    - grab the chest inventory (minetest.get_
  - chest_add(pos, itemstack)
    - remove from main, add to chest inv, return overflow
  - chest_remove(pos, itemstack)
    - remove from chest inv, add to main, return overflow
  - chest_close(pos)
    - remove self as a chest opener, close chest if the owner list is empty

## Inventory Functions

  - wield_item(item)
    - move the item by name to the wield inventory (checks wield first)
  - wield_by_cond(func)
    - move the first matching itemstack to the wield inventory (checks wield first)
  - wield_best_for_dig(node_name)
    - examines the node and inventory to pick the best item to wield

  - count_inventory_groups(groups)
    - get a count of the matching inventory items by group name
    - use to see if the MOB has "too many" trees, etc
  - count_inventory_items(items)
    - get a count of the matching inventory items by item name
    - used to, say, find which seeds we have so that we can plant them

  - get_job_name()
  - get_job()
  - set_job()

  - add_item_to_main(itemstack) : add to main return leftovers
  - replace_item_from_main(remove_stack, add_stack) ??
  - move_main_to_wield(cond) : swap the first matching itemstack with wield
  - move_wield_to_main(cond) : move wield stack to main, set wield to "" (hand)
  - has_item_in_main(cond) : returns true if cond() returns true on any itemstack in main

## Memory

  - remember(key, val)
  - forget(key)
  - recall(key)

  - remember_area(key, pos)
  - forget_area_pos(key, pos)
  - forget_areas(key, max_dtime)
  - recall_area(key)

# Generic Tasks

These can be extended to any object, assuming the following standard functions:

  - self:get_inventory()
  - self:get_wield_list()
  - self:get_wield_index()
  - self:get_wielded_item()
  - self:set_wielded_item(itemstack)
  - self:get_pos()
  - "main" inventory

## self:pickup_item(self, item)

Removes an itemstack from the world and puts it in the "main" inventory.

Calls:

  - self:get_inventory()

## self:drop_item(self, itemstack)

Calls:

  - self:get_inventory()
  - self:get_pos()

# Schedule

The schedule is a table used by a check function to schedule certain tasks at certain times.

This causes NPC to do things like go to bed or go to work.


# Events

An event, such as on_punch(), should set MOB state and/or add a task.
A check function may check that MOB state to determine if it should do an action.

"Events" that are derived from nearby objects or nodes should be handled in a check function.


# Sensors Cache

Mobkit periodically scans the surroundings of a MOB.

The cached data can be used by the check function to determine if the MOB should run away, attack, pick up something, etc.

A partial scan (half radius) scan is done every step. A full is done every 3 seconds.

FIXME: make the scan full all the time and lazy. Don't scan until a function is called that searches for nearby objects.


# BOT Functions

## goto(pos, range)
Navigate to the position, stop when within range.

Fails if there is no path to pos or unable to walk there. (something blocking the path?)


## dig(pos)
Pick the best tool for the job and dig the node.

Fails if there is a permission issue, or unable to dig the node due to tooling or not close enough to dig.


## place(item, pos)
Wield item and place the node.

Fails if there is a permission issue (is_protected), we don't have the item in the inventory, the position is too far away, or we can't place a node there (buildable_to).


## stand_still()

Stop moving and do the stand animation.

## sit_down(pos)

Sit at position, which must be a valid 'sit' location and must be within range.

## lay_down(pos)

Lay down at position, which must be a valid 'lay' location and must be within range.


# Common Tasks

These tasks are common, meaning that they should apply to all humanoid MOBs.

Short list (details below)
  - "go_to_sleep"
  - "go_home"
  - "sit_down", args: position of chair/bench/bed/table
    - w/o arg, will find a suitable spot and sit
    - bed will pick appropriate seat location
    - table will look for a chair adjacent to the table
  - 

## "dig_node", args: position

Navigates to and digs the node at the position.

May involve building a ladder if the node is out of reach.

## "place_node", args: item, position



## "cut_down_tree", args: position

Navigates to and chops down all the 'tree' nodes connected to the position.

May involve building a ladder to reach high spots on the tree.

## "go_to_sleep"

  - if MOB has a bed AND it is within range, then goto the bed, lay down in it and stay there until we've slept 6-8 hours or the task is removed
  - if MOB does not have a bed, but does have a house, then go to somewhere in the house. sit down.
  - if the MOB is also homeless, then find a place to sit down and sit until morning

## "visit_jobsite"

  - go to a job site
  - wait a bit
  - go to the next job site
  - repeat
  - after visiting all job sites, work is done for the day

This is intended as a lower-priority task.  For example, the farmer would patrol farming sites and the check function would find crops to harvest, fields to till, etc.

This might be the main task for a guard that is patrolling.

## "visit_chest_start"

  - if the MOB doesn't have the tools needed for the job
      - visit the chest that belongs to the MOB. take items.
      - visit community chest. take items. (pay coins for this)

## "visit_chest_deposit"

  - if the MOB has too much inventory
      - visit the chest that belongs to the MOB. deposit excess items.
      - visit community chest. deposit excess items. (receive coins for this)

## "visit_check_done"

  - at the end of the work day if the MOB has excess inventory
      - visit the chest that belongs to the MOB. deposit excess items.
      - visit community chest. deposit excess items. (receive coins for this)

## "get_item"

This is the crazy task that I haven't thought through.

It a MOB needs an item, it will:

   - check owned chests for the item
   - check community chests for the item (purchase, if coin is available)
   - execute a dependency graph to try to craft the item
       - may cause other needs

Uses the minetest craft recipies to determine what is needed.

Basics that are acquirable through MOB actions:

  - branches (for an axe) -- break leaves
  - wood (chop down trees) -- need an axe (not really -- oddly breakable by hand)
  - cobblestone(to get stone) -- dig -- need pick
  - food (hunger)
      - harvest berries
      - harvest edible crops
      - craft crops to make food
  - water (thirst)
      - go to the town well, drink
      - go to a water source, drink
      - get cup or bucket
          - get water at source
      - dig a well

  - shelter
     - build a hut from a schematic
  - gather sticks, etc

Example:

  - MOB doesn't have a chest
  - try to buy from market
  - try to buy from the community chest (free)
  - acquire wood
      - check inventory
      - check chest(s)
      - check community chest (buy wood)
      - chop down tree (needs axe)

      -