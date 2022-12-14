# Path Finding Basics

Path finding is the search for a series of states that transition between a START state and TARGET state.

Each state must have a list of other states that can be reached from the current state.

The result of a path search is either the series of states (the transition between each can usually be inferred) or failure if there is no solution.

For a 2D block-based map, we reduce the problem to a series of cells/nodes that we can occupy or not.
The "state" is the location of the MOB in the map.

We can move north, south, east, or west. If we can't move to and occupy the cell in a direction, then that is not a valid transition.

These valid movements are called "neighbors". There is a cost associated with moving to each neighbor.

The costs involved are denoted as follows:

  * gCost is the total cost to reach the current state from the START state
  * hCost is the estimated cost to reach the TARGET state from the current state
  * fCost is the total estimated cost of the path (gCost + hCost)

The simplest algorithm is as follows:

  * We have a collection of states (positions) with some data associated with each position.
    * The collection is accessible via a get() method to get the data for a position.
    * The collection is accessible via a get_first() method that removes the first "active" position.
    * The data item contains a few items
        * the cost to reach this position (gCost)
        * the parent position (where we came from: position, direction, transition, etc)
        * whether the position is active or not
  * The loop goes as follows:
     1. Grab the first active position, removing it from the active list, but not the key/val store.
     2. If the position is the target position, then roll-up the path and return it
     3. Find all the valid neighbors and the associated cost, creating new position data for each.
     4. For each neighbor, do the following:
        * If the position is NOT already in the store or the new data has a lower cost, then add/replace the item as an active position
   * The rollup loop goes as follows:
       * The current node is the one that hit the end position
           * Loop while current.parent ~= nil
           * Append the current.pos to the list
           * current = current.parent
        * The list is reversed, so reverse the list to get a forward-list


Pseudo code:
```lau
function find_path(start_pos, end_pos)
    local walkers = position_store.new()
    walkers:add({pos=start_pos, cost=0}) -- add puts it in the hash and the sorted list
    while true do
        local cur = walkers:pop_next() -- removes and returns the first item from the sorted list
        if cur == nil then break end

        if cur.pos == target_pos then
            local rev_path = {}
            while cur ~= nil do
                table.insert(rev_path, cur.pos)
                cur = walkers:get(cur.parent)
            end
            local path = {}
            for i=#walkers,1,-1 do
                table.insert(path, rev_path[i])
            end
            return path
        end

        for idx, neighbors in pairs(get_neighbors(cur.pos)) do
            local old_data = walkers:get(cur.pos)
            if old_data == nil or old_data.cost > neighbor.cost then
                walkers:add(neighbor)
            end
        end
    end
    -- target_pos not reachable
    return nil
end
```

## Path Finding - Cost Estimate

Estimating the cost of the path is important in finding a good path quickly.

The estimate should be the lowest possible cost. Put another way, it should be less than or equal to any possible path.
It should never over-estimate the path cost.

Using hCost=0 is valid, but degrades to the Dijkstra's algorithm.

For example, if the lowest movement cost on the map is 10, then the estimate should use 10 per move.

On the grid example, the movements are uniform and predicable.

The grid estimated cost is typically calculated as follows (no diagonals, x=east/west, z=north/south, min_cost=10):
```
    return (abs(cur.x - tgt.x) + abs(cur.z - tgt.z)) * 10
```

The estimate with diagonals is typically calculated as follows:
```
    local dx = math.abs(cur.x - tgt.x)
    local dz = math.abs(cur.z - tgt.z)

    if dx > dz then
        return 14 * dz + 10 * (dx - dz)
    else
        return 14 * dx + 10 * (dz - dx)
    end
```
The `14` is sqrt(2), which is the distance traveled on the diagonal.

However, depending on the platform and language, it may be more efficient to calculate hCost as a vector distance:
```
    return vector.distance(cur, tgt) * 10
```

If the map has complex features, like a transportation portal, this estimate won't work right.

## Path Finding - A*

The A* algorithm adds an estimated cost (hCost) to reach the target to each node.

The pop_next() function grabs the walker with the lowest fCost (hCost + gCost). If the fCosts are the same, then the lowest gCost breaks the tie.

This greatly reduces the number of nodes visited in the simple cases, but will often fail to find the optimal path if movement costs are not uniform.

For example, the path may run parallel to a road with cost 50 on terrain with cost 100. Shifting over two squares to the road would result in a much lower total cost, but the A* algo won't find it.

## Path Finding Limits

If there is no solution and the problem space is unbounded, the path finding algorithm will consume a lot of memory and CPU time.
That isn't good for a game that is expected to run 10 cycles per second.

Safeguards must be added to limit the search space.

### Distance Limit
Limit the distance between START and TARGET. Refuse to calculate the path if too far.

Instead, blindly walk towards TARGET until START is within range.

### Incremental Distance Limit

If CPU time is a concern, but memory is not, then the active walkers in the open set can be paused when the distance from the current position exceeds a certain value.

Alternatively, when the 'best' active walker is out of range, the MOB can move toward the best active walker. When the MOD changes position, the search can resume until the active walker is out of range again.

This may cause the MOB to alternate between two ends of an obstical.

### Limit Search Space
Put a box around the START and TARGET nodes. Don't allow walking outside those bounds.

This has the problem that there may be a valid path, but it travels outside of the bounds.

### Limit the number of active walkers
Worst case, the number of active walkers is approximately the circumference of a circle. (2 * PI * R)

Limit the number of active walkers to, say, 100.

## Path Finding Flood Fill - Uniform Cost

If the movement cost is uniform, we can evaluate all walkers in the list at each step.

The accumulated cost for all walkers will be the same.
The first one to hit the target will be the best path.

This ends up visiting at most PI * R ^ 2 nodes, where R is the number of steps.

It is extremely easy to implement, as we don't need to track costs.

## Path Finding Flood Fill - Variable Cost

If the movement cost is not uniform, we can modify the A* algorithm in the following ways:

  - Don't stop when the first path hits the target, but track the lowest cost solution (gCost)
  - Discard active walkers where the total est cost (fCost) is greater than or equal to the lowest cost solution

This is effectively the flood-fill algorithm, but with built-in bounds. It would properly solve the parallel road problem.

It will visit more nodes than the A* algorithm, but not by too much.

## Path Finding with Portals

A portal is a node that has an unusual movement to another node that is not a neighbor.

For example, the node (0,0,0) could have a portal that tranports the MOB to (100,0,0) in one move.

If the START is something like (0,0,5) and TARGET is something like (100,0,5), then we would want to take the portal.

The A* algo may not find the portal. It might move 100 times, directly from START to TARGET.

Both Flood Fill algos should find it. The simple flood fill would do better than the Variable Cost flood fill.

The Variable Cost would trace all the way to the target and then thicken the path until it hits the portal. Then it would be done. (~1000 visited nodes)

The simple Flood Fill would hit the portal much earlier. (~11 steps or ~380 visited nodes)


# Minetest Adaption

The Minetest world is divided into nodes.  All positions are at the center of the node.

The MOB has properties that affect pathfinding:

  * Height = the number of nodes (vertical) that the MOB occupies.
  * Width = the width of the MOB (not used) 
  * Jump Height = the number of verticle nodes that the MOB can jump.
  * Fear Height = the number of verticle nodes that the MOB will willingly go down in one step.
  * Hurt Height = the number of verticle nodes that the MOB can fall without damage. (not used)

For all examples in this document, we assume the following settings:

  * Height = 2
  * Width = 1 (not used)
  * Jump Height = 1
  * Fear Height = 2
  * Hurt Height = 5 (not used)

## Terminology

A node is "clear" if it will not collide with the MOB. Minetest uses the term "walkable" to indicate that the node is collidable.

However, there are certain nodes that are "walkable" that should be considered clear.

  * Doors
  * Gates

A node is "standable" (meaning that a MOB can stand on it) if:

  * the node is collidable
  * the node is NOT a door
  * the node is NOT in group leaves (if the MOB cannot walk on leaves -- weight check?)
  * the node is climbable AND the MOB can climb


A node is "swimmable" (meaing that a MOB can swim through it) if:

  * the MOB can swim AND
  * the node is liquid (water) AND
  * the node above OR below is liquid


## Stand Position

The first and most basic check that must be done is to determine if a MOB can be at a position.

A MOB can be at a position if:

  * There are @Height clear nodes at and above the position AND
      * There is a "standable" node below the position OR
      * The current node is swimmable

## Find Ground Level

One of the more basic operations is to find the ground.

If the current node is not clear, then we move up a node until we hit a clear node. The dy is limited by the jump_height.

Otherwise we test the node below for 'standable' and the current node for 'swimmable'. Move down a node until we hit a standable/swimmable node. The dy is limited by the fear_height.

Once the ground level is found, we scan upwards to see if we can stand at the position.

# Waypoints (basic idea)

Waypoints are used to pre-calculate path finding and reduce the search area. It enables finding large and complex paths with little CPU time.

When two waypoints are linked, it tells the planner that a path between the two points exists. We don't need to know the exact path at the time, only that they can reach each other.

Waypoints are (typically) linked such that only nearby waypoints are linked together and links do not cross.

For example, in a town, waypoints would be placed on door nodes and along roads, especially at intersections. They would also be placed in each rooms and hallway in a building.

When there are no good places for a waypoint (outdoors), they would be evenly spaced.

Waypoints are connected to each other via links that contain a cost for going from one waypoint to another. The cost is precalculated by doing an A* search or is estimated.

## Waypoint Usage

When calculating a path, we'd find the waypoints near the start and end positions. This would be limited by a radius of, say, 16 nodes. We calulate the cost (estimate) for going from the position to each nearby waypoint.

We then do a A* path along the waypoint network for each starting waypoint to each target waypoint and use the pre-computed cost to evaluate which path is best.
Once that is determined, we have a list of waypoints that we need to visit. We can then iterate over the waypoints, creating an A* path from the current position to the next waypoint.

## Waypoint Problems

The itermediate paths go directly to the next waypoint. This causes the path to be a bit strange and suboptimal.

## Waypoint Improvement (Areas or Zones)

Instead of a single position for a waypoint, we need an area or zone associated with the waypoint. Perhaps a radius or some simple geometry (box).  The pathfinder can terminate early when it hits any point in the zone.
This allows for a more natural path -- the MOB will head towards the waypoint and then start heading towards the next waypoint when it gets close.

We could eliminate the start and target search by making every standable node covered by one (or more) waypoints.

We could jump straight to the waypoint network evaluation. Each zone feeds into another zone.

This causes another problem related to cost estimation of traveling between wayzones.

Going from one zone to another may cost as little as 1 move. The upper bounds can be quite large, assuming complex obstacles.

We might be able to get a better cost esimate using a traversal cost. For example, if the wayzone links are A -> B -> C, we know that the cost of both A->B and B->C may be as little as 1 move. However, we can estimate the average cost to go from A -> C. That complicates things, as we won't know the cost of A->B until we choose B->C. But we also might choose B->D.

Another option is to find the closest point in the linked wayzone and estimate the cost to that point. That would give an "accurate" gCost estimate. However, it would be difficult to determine which 


# Wayzones (Waypoint Zones)

Wayzones are my attempt at dealing with the complexity of pathfinding on unstable terrain.

The world is broken into chunks of a certain size.

Within each chunk all "standable" nodes are examined. A wayzone consists of every node inside the chunk that is reachable from every other node in the zone. Since jump_height and fall_height are not the same, that means that certain moves are one-way. A wayzone does not cross one-way transitions, nor does it transition from a water node to a non-water node or a door node to a non-door node.

Non-reversible moves, moves that change water state, moves that change door state, and moves that leave the chunk are 'exit moves'.
The destination position is the "exit node".

A series of wayzones are tied to the height, jump_height and fear_height settings. For now, I chose to use fixed values of height=2, jump_height=1, and fear_height=2. Different settings would require a different set of wayzones.

## Transitions

  - water to non-water (water gets its own wayzone)
  - door to non-door (doors get their own wayzone)
  - top_of_fence to not-top_of_fence (make it easy to not allow climbing a fence
  - climb to non-climb

Climbing note:

I want a non-climbing MOB to be able to walk across a node containing a ladder if the ground underneath is solid.

I want a "climbing" wayzone to be separate from normal terrain.

A "climbing" node is any node that does not have solid ground underneath AND the node has climbable=true.

In this side view, I want the ground to be walkable by all MOBs. The 'climbable' wayzone starts at y+1, above ground.
(X=solid, H=ladder, 1=WZ1, 2=WZ2)
```
    HXXX      2XXX
    HXXX      2XXX
....HXXX  11111XXX
XXXXXXXX  XXXXXXXX
```
If there is only 1 ladder, then we won't create a new wayzone, as all MOBs should be able to jump.

```
               111
    HXXX  11111XXX
XXXXXXXX  XXXXXXXX
```

I want the wayzone planner to be able to exclude certain terrain.

  - MOB doesn't swim, so water is forbidden
  - Check whether able to open a door while planning a route
  - Can or can't hop over a fence
  - Can or can't climb



## Chunk Size

As of now, an 8x8x8 chunk size seems most promising. The other option is 16x16x16.

The size determines both the time required to process a chunk and the maximum number of nodes that could be vistied during the A* steps.

The number of nodes visited is essentially the area of a circle (ignoring vertical movement).

## Finding Wayzones

Every standable node inside the chunk is found. They are processed one at a time.
If the node is not already part of another wayzone, then a flood fill is performed and a new wayzone is created.

### Standable Scan

See above for what constitute a "stand position".

With a height of 2, a standable node occupies 3 vertical nodes. At the bottom and top of the chunk, the standable node
depends on nodes in a different chunk. For example, standing at Y=0 requires a standable node at y=-1.
Likewise, standing at y=15 requires 2 clear nodes in the chunk above (y=16, y=17).

Pseudo code for processing a chunk:
```lua
    local nodes_to_scan = {}
    for x=0,chunk_size-1 do
        for z=0,chunk_size-1 do
            local clear_cnt = 0
            local water_cnt = 0
            local last_pos
            local last_hash
            for y=chunk_size,-1,-1 do
                local pos = vector.new(cpos.x+x, cpos.y+y, cpos.z+z)
                local hash = minetest.hash_node_position(pos)
                local node = minetest.get_node(pos)
                -- standable node after @height clear nodes, use last_pos
                if (is_node_standable(node) and clear_cnt >= height) then
                    nodes_to_scan[last_hash] = last_pos
                end
                if is_node_clear(pos) then
                    clear_cnt = clear_cnt + 1
                    -- water nodes are clear
                    if is_node_water(node) then
                        water_cnt = water_cnt + 1
                        if water_cnt >= height then
                            nodes_to_scan[hash] = pos
                        end
                    else
                        water_cnt = 0
                    end
                else
                    clear_cnt = 0
                    water_cnt = 0
                end
                last_pos = pos
                last_hash = hash
            end
        end
    end

    local wzd = wayzone_store:new_chunk(chunk_pos)
    for hash, pos in pairs(nodes_to_scan) do
        if wzd:get_wayzone_for_pos(pos) ~= nil then
            local visited, exited = wayzone_flood_fill(pos)
            local wz = wzd:wayzone_new()
            for hh, _ in pairs(visited) do
                wz:add_visited(hh)
            end
            for hh, _ in pairs(exited) do
                wz:add_exited(hh)
            end
            -- this compresses the wayzone data
            wz:finish()
        end
    end
    -- this replaces the chunk data in the store, updating the generation
    wayzone_store:add_chunk(wzd)
```


### Flood Fill

A modified "flood-fill" pathfinder is used to find all accessible nodes. We don't need to
support diagonal moves and we don't track cost.

This type of pathfinder expands all neighbors in all directions. It has 3 tables:

  * active - active walkers, used to expand neighbors
  * visited - vistited nodes
  * exited - nodes that dropped more than jump_height, changed water/door state, or are not in the chunk

Pseudo code for the flood fill:
```lua
    local in_water = is_node_water(start_pos)
    local in_door = is_node_door(start_pos)
    local max_y = math.min(jump_height, fall_height)
    local active = pos_store.new()
    local visited = pos_store.new()
    local exited = pos_store.new()
    active:add(start_pos)
    while not active:empty() do
        cur = active:pop_head()
        visted:add(cur.pos)
        for _, nn in pairs(wayzone_get_neighbors(cur.pos, height, jump_height, fall_height)) do
            if not (active:present(nn.pos) or visited:present(nn.pos)) then
                local dy = math.abs(cur.pos.y - nn.pos.y)
                if dy > max_y or not chunk:inside(nn.pos) or in_water ~= nn.in_water or in_door ~= nn.in_door then
                    exited:add(nn.pos)
                else
                    exited:del(nn.pos)
                    active:add(nn.pos)
                end
            end
        end
    end
    return visited, exited
```

This finds the neighbors using roughly the same 'find_neighbors' function used for the A* pathfinder. No cost sorting is needed.
The walkers are processed until the are all gone. We don't need to test diagonals for the flood fill.

## Handling Updates

We need an indication that an important node in the chunk has changed so that we can mark the wayzone info as stale/dirty.

Minetest provides two hooks that seem to work:
```
    minetest.register_on_placenode(wayzones_on_placenode)
    minetest.register_on_dignode(wayzones_on_dignode)
```

The callback functions check if the node change is "significant". If so, it marks the chunk as dirty.

A change is significant if the node was collidable, water, or climbable.

Examples of important nodes:

  * dirt, wood, etc
  * ladder
  * water

Examples of not-important changes (non-walkable):

  * crops
  * flowers, etc
  * doors (TBD, walkable, but some NPCs can open)

If the node was water, we need to check to see if it will spread / fade out to see if any further changes are expected.
Since that is a bit complicated, we can simply set the node to automatically go dirty again in, say, 30 seconds. Any water effects should be settled by then.

When the wayzone data for a chunk is update:

  * the "generation" field is incremented by 1
  * all memory of "other" chunk generation is cleared
  * all links are removed
  * "valid_deadline" is preserved if it has not expired
  * "gen_time" is updated

If a node near the border is altered, then the adjacent chunk also must be marked dirty.


## Navigation

Once we have a bunch of wayzones, we need to hook them together. Adjacent chunks are checked for wayzones that exit into the wayzones of the other chunk.
Links between wayzones are one-way, but they are recorded in both wayzones to allow reverse navigation of the mesh.

## Link Information

We need the following information to form a link between 2 wayzones.

  * The "from" chunk ID and generation.
  * The "to" chunk ID and generation.
  * The "from" wayzone ID
  * The "to" wayzone ID

A wayzone ID is the chunk ID + the index in the wayzone array. A wayzone structure contains the chunk hash and index.

A link is valid only to a particular generation. If the generation changes, all links to or from the chunk are invalidated.

Wayzone links are only used to find other wayzones.

Based on all that, it makes sense to put the wayzone links inside the wayzone structure.

When a chunk is reprocessed, all old wayzones are discarded and the generation is incremented.


### Creating Links

Pseudo code for updating the links from one chunk to another:
```lua
local function wayzones_update_links(wzd_from, wzd_to)
    -- only process if the gen changed (the gen table is cleared when we reprocess the chunk)
    if wzd_from:other_gen_mismatch(wzd_to) then
        -- remove all links wzd_from -> wzd_to, as we will re-add them
        wzd_from:del_chunk_links_to(wzd_to)
        wzd_to:del_chunk_links_from(wzd_from)
        for wz_idx, wz in ipairs(wzd_from) do
            -- test all exit positions on the appropriate side and create links
            for exit_pos in wz:iter_exit(aidx) do
                local wz_to = wzd_to:get_wayzone_for_pos(exit_pos)
                if wz_to ~= nil then
                    wz:add_link_to(wz_to)
                    wz_to:add_link_from(wz)
                end
            end
        end
        -- record that we have updated the links for the current generation
        wzd_from:other_gen_update(awzd)
    end
end
```

Pseudo code to update the links for one chunk.
This is done right before checking for links when building a path.
```lua
local function wayzones_update_chunk_links(wzd)
    -- adjacent_chunk_vec is an array of vectors that maps to adjacent chunk positions
    for aidx, avec in ipairs(adjacent_chunk_vec) do
        wayzones_update_links(wzd, wayzone_store:get_chunk(vector.add(wzd.pos, avec)))
    end
end
```

## Navigating Links

When finding a path between a start and target position, we need to collect a list of all wayzones that we have to go through.

The first step is to find the wayzone for the start pos and target pos. If either position doesn't land in a wayzone
then the path fails. Return nil.

If the start and target are in the same wayzone, then return a list containing only that wayzone.

If the start and target wayzones are directly connected (adjacent chunks), the return a list containing only those two wayzones.

If the start and target wayzones are not directly connected, then we need to use the A* algo to navigate wayzones, from start to target.

Once we have a list of wayzones, we can use that information to do an incremental find_path.

We always go toward the final destination. If we are going to the last wayzone, we use the target area from the target position.

Since we are only moving from one wayzone to the next, the allowed search space is the current and next wayzone. The path will not stray from those two.
If not heading towards the final wayzone, the 'target area' is the next wayzone.

We use pathfinder.find_path() to navigate towards the first wayzone in the list. When we reach the wayzone, we discard it and navigate towards the center of the next wayzone, etc, until we run out of wayzones. We then use find_path() to go the target, which should now be in an adjacent wayzone.

Assuming we determined a wayzone path with 4 wayzones as follows in wzpath:

  * wzpath[1] = start wayzone
  * wzpath[2] = wayzone2
  * wzpath[3] = wayzone3
  * wzpath[4] = target wayzone

We would call find_path() as follows:

  * find_path(target_pos, target_area=wzpath[2], allowed_wz={wzpath[1], wzpath[2]})
  * find_path(target_pos, target_area=wzpath[3], allowed_wz={wzpath[2], wzpath[3]})
  * find_path(target_pos, target_area=target_pos, allowed_wz={wzpath[3], wzpath[4]})

If any find_path() fails to reach the target, then we can rebuild the wayzone list and try again. If building the wayzone list fails, then we quit.

When we run out of path entries, we do the next item in wzpath.

To make it a bit more robust, we look up the index in wzpath based on the wayzone for the current position.
If the current wayzone is not in the list (unexpected fall, knockback, etc), then we rebuild the wayzone list.


## Failed Path Workaround

A simple impossible path is trying to go to the top of two stacked dirt nodes when the jump height is 1.

The big problem with the A* algorithm is that if the target is not reachable, we will waste a lot of time and memory looking for a path that doesn't exist. The minetest search space is effectively infinite, so the search could go for a very long time. And since most "AI" is stupid, it will look for the same path again after a few seconds.

There are a few typical work-arounds for this:

  * abort if there are "too many" active walkers
  * restrict the search path to a certain area
  * do a reverse path search in parallel with the forward search

In a straight-line path, there will be on average 2 walkers per step (on either side). So, "too many" should be based on distance between the start and target.

If the path is impossible, we tend to see the search area expand as a circle, with visited nodes equal to the area of the circle and the active walkers equal to the circumference.
By tracing backwards, we can immediately see that there is no possible way to get up to the target and abort the path before we start.

By tracing backwards, we can effectively cut the radius in half and catch unreachable targets very quickly. It also reduces the visited nodes by 1/2 for the same distance.
Node-based navigation is tricky to do reverse navigation, so it typically isn't used. Linked wayzones are easy, so that is what I did.

## Possible Optimization

The A* algorithm re-scans nodes for stand position, clearance, etc. We might be able to re-use the information in the wayzone "visited" map to speed things up a bit.

However, we may need to store the possible movements from each node, which would make the 'visited' bitmap 8x as large. If we use CS=8, then that is 512 bytes per chunk instead of 64.
I'd use bit flags. Perhaps something like:

  * b0=can be in this node
  * b1=can move +X
  * b2=can move -X
  * b3=can move +Y
  * b4=can move -Y
  * b5=can move +Z
  * b6=can move -Z
  * b7=in water

We'd still have to search a bit for the ground level, but that would consist of a few byte checks.
And diagonals would be more tricky. A diagonal (say, +X,+Z) would be allowed only if both +X and +Z are allowed AND those can both move into the diag node.

Another option is to store the number of clear nodes above the position and then use that to figure out movements.

Perhaps something like:

  * b0:2=clear height at this node 1-7 (0=no standing)
  * b3=in water
  * b4=can climb

Although, if I'm going to spend the extra 448 bytes per chunk, then I may as well eliminate as much processing as possible.


## Problems and Possible Improvements

### Unable to Detect bulk updates

Bulk updates via, say, WorldEdit do not provide notification.

If I add a bridge using WorldEdit, the MOBs won't see it.

We might require a timeout for cached chunk information to ensure that "bad" data won't stick around forever.

If we have an unexpected failure moving between two wayzones, we can dirty the chunks involved to update the links.


### Sub-optimal Cost Estimates

The cost to move from one wayzone to a connected wayzone is at minimum 1, average chunk_size and at most, who knows?

The lack of an accurate cost for traversing the path results in sub-optimal wayzone selection.

We can get a more accurate estimate if three wayzones are involved by calculating a path from A through B to C.

There are a few ways to address this:
  * Do a standard cost estimate between wayzone center nodes
  * Actually calculate a path between wayzone center nodes
  * Record and update an average traversal cost from wayzone to wayzone, excluding the first and last in the wzpath list

### Wayzone Navigation Idea

Leaving or entering a building.

If the start wayzone has one exit, then follow that exit until it has mulitple exits. The first step into the wayzone that has multiple exits creates a waypoint.

With the waypoint, the path is broken into two sections: START -> Waypoint -> TARGET

Do the same for the target wayzone if it has one exit.

Using something like Bresenham's line algo, walk straight toward to target. Add wayzones to the active list as they are encountered.

If a wayzone is a "dead end", meaning it has no exit that hasn't been visited, then pick a different wayzone and try again.

---

## Pathfinding optimization idea.

This is for quick movement between close locations.
It follows a straight line and does not expand all neighbors.

 1. Select, but do not remove the best walker from the list (cur)
 2. Find the neighbor that would be next in Bresenham's line algo.
 3. If we can go to that neighbor (only check horizontal) AND the ground class is the same (solid, liquid), then add that neighbor as a walker
 4. If not, then remove the best walker from the list and do the usual A* neighbor search. Discard Bresenham's state.
 5. Repeat.

This only works if movement cost is uniform. IE, no penalty for going through water or bonus for a road. Probably won't work for climbables.


## Failings of A*

Assume you have a start and end position by the side of the road.
The side of the road has a cost 5, the road has cost 1.

Because anything other walker will have a worse cost than going straight to the target, we will never find the road.

```
5555555555555555
1111111111111111
5555555555555555
5s555555555555t5
5555555555555555

straight: 13 x 5 = 65
road: 2*(5*1.4 + 3*1.4) + 9*1 = ~32

```

Solution:

 1. Evaluate all walkers instead of only picking the "best" walker.

    That greatly increases the number of nodes that must be visited, but it will always produce the best path.
    With CS=8, this isn't too bad (up to 8 * 8=64 nodes), but because of small size, the wayzone search isn't likely to find the road.  
    Unless, of source, wayzone traveral costs were more accurate.
    With CS=16, we would be more likely to find the road, but would need to visit 4x as many nodes (up to 16 * 16=256 nodes).
    

 2. Evaluate 10% or 50% of the walkers (in sorted order) on each pass

    More complicated, but won't waste as much CPU.  Will usually find the best path.

 3. Mark fast paths with some sort of waypoint so that the path can gravitate towards that.


Or, we could just not care. The paths will be good enough.



---

## Packing visited wayzone data

This should be left for when it is all working...

But I can't help myself.

Use an octree to represent the visited nodes.

Assuming CS=16
byte 1: represents whether each of the eight 4x4x4 sections have any nodes.
For each bit that is 1, there is a byte for the 2x2x2 subsections.
For each of the 2x2x2 subsections, there is a byte that the 8 nodes.
[1] [8] * [1 + 8] = 

Top
  + 8x8x8 (*8) 1 byte each
    +- 4x4x4 (*8) 1 byte each
      + 2x2x2 1 byte each
Worse-case size is 585 for CS=16 or 73 for CS=8.

Second pass:

byte 1 = default for each of the 8 sections (0=default absent, 1=default present)
byte 2 = bit flag for the 8 nodes indicating that a subdivision is present
byte 3:4 = 2 bytes for the first subsection
byte 5:6 = 2 bytes for the second subsection
byte 7:8 = 2 bytes for the second subsection
 9.10
 11.12
 13.14.
 15.16
 17"18 = 2 bytes for the last subsection
Data starts for the subsections
 - same 2 bytes for each subnode

[TAG]  - 8x8x8 sections
0-8 [TAG] for 4x4x4 sections
0-8 [DATA] for 2x2x2 sections

sub-tags = 0 to 8 in length



8x2x4

0,0,0 => 0
7,1,3 => 




# TODO

## Avoid walking next to ridges
+/- 1 has a penalty of 5
-2 has a penalty of 10
unwalkable has a penalty of 20

NOTE: This just doesn't seem to work right.

## Disallow changing Y on a diagonal

Diagonals only allowed on flat.
Not sure I got this right. Seems to still use diagonals.

## Enhance the villager scepter

left click to select/pause/resume villager

left click on a node to tell selected villager to walk there. (to test pathfinding)

Working.

## Drop 'exit nodes'.

Change a wayzone to ONLY contain minp, size, center, and visited bitmap.

A link test between two adjacent wayzones is done by *calculating* one neighbor from the edge node toward the neighbor.

For example if the neighbor is on -X, then test all node in all wayzones where x=0, going toward -X.
For example if the neighbor is on +X, then test all node in all wayzones where x=15, going toward +X.
etc.
For a neighbor at -X,-Y, test all nodes where x=0,y=0.


## Use an invisible object to notice load/discard events on chunks

Put an invisible object in the center of each chunk that has been processed and has any wayzones.
Store data the node:
  - [n] = {minp={x,y,z},size={x,y,z},center={x,y,z},flags=1, visited="packed bit string"}
      - pack as 5-bytes + bitarray
          - nibble.1 = minp.x
          - nibble.2 = minp.y
          - nibble.3 = minp.z
          - nibble.4 = size.x
          - nibble.5 = size.y
          - nibble.6 = size.z
          - nibble.7 = cpos.z
          - nibble.8 = cpos.y
          - nibble.9 = cpos.z
          - nibble.10 = flags (b0=water, b1=door, b2=climb?)

Reload when the object is resurrected.

Not sure if this is worth it, but it would keep CPU time low.


## Silly Idea #28 : Use Lines for Outdoor Movement

Use a modified Bresenham's line algo to walk directly toward the target using the wayzones.

The path is a series of line segments.

```
S -> D

S**?
  ?**D
```
There are 3 possible moves: N/S or E/W or diagonal. If diagonal both the diagonal and either the N/S or E/W node must be clear.

If an obstacle is hit, then trace left and right until an outer corner is hit. Insert that position as a waypoint between the current segment.
```
S -> P -> D
```
Then restart S->P.


Not sure if it is usable, seeing as how the villager has to walk.
Perhaps using bresenhams line algo?

1. Go straight creating (but not resolving) walkers. Maybe set a flag for which direction we went.

Movement is N/S/E/W only? If we hit an obstacle, then the walker is fully expanded. 
Do the straight line again.

while true do
    walker = store:get_head()
    best_neighbor = 



## Enhance wayzone-to-wayzone cost estimation

Remember the 'ref_pos' in the wayzone and calculate the cost to the next wayzone based on that.

The ref_pos for the first wayzone is the start_pos.
The ref_pos for the last wayzone is the target_pos.
The ref_pos for the second wayzone is the closest accessible node in the wayzone, which would be the closest exit pos to the current ref_pos.
That doesn't seem too cheap to calculate.




### BROKEN

Don't do a diaganol unless BOTH corners are passible.
```
1   -- must go 1-2-3
23

12
34 -- can go 1-4 directly
```
