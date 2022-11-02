# Wayzones (Waypoint Zones)

Wayzones are my attempt at dealing with the complexity of pathfinding on unstable terrain.

The world is broken into chunks of a certain size (8x8x8).

Within each chunk all "standable" nodes are examined. A wayzone consists of every node inside the chunk that is reachable from every other node in the zone. Since jump_height and fall_height are not the same, that means that certain moves are one-way. A wayzone does not cross one-way transitions, nor does it transition from a water node to a non-water node.

Non-reversible moves, moves that change water state, and moves that leave the chunk are 'exit moves'. The destination position is
the "exit node".

A series of wayzones are tied to the height, jump_height and fear_height settings. For now, I chose to use fixed values of height=2, jump_height=1, and fear_height=2. Different settings would require a different set of wayzones.

## Finding Wayzones

Every standable node inside the chunk is found. They are processed one at a time.
If the node is not already part of another wayzone, then a flood fill is performed and a new wayzone is created.

### Standable Scan

A standable node is a node that:

  * is clear (not walkable)
  * and a standable (walkable or climbable) node below
  * and a clear node above it
  * or has water in all nodes that the MOB occupies (at the pos and y+1)

A standable node occupies 3 vertical nodes. At the bottom and top of the chunk, the standable node
depends on nodes in a different chunk. For example, standing at Y=0 requires a standable node at y=-1.
Likewise, standing at y=15 requires 2 clear nodes in the chunk above (y=16, y=17).

Pseudo code for processing a chunk:
```lua
    local nodes_to_scan = {}
    for x=0,7 do
        for z=0,7 do
            local clear_cnt = 0
            local water_cnt = 0
            local last_pos
            local last_hash
            for y=8,-1,-1 do
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
support diagonal moves.

This type of pathfinder expands all neighbors in all directions. It has 3 tables:

  * active - active walkers, used to expand neighbors
  * visited - vistited nodes
  * exited - nodes that dropped more than jump_height or are not in the chunk

Pseudo code for the flood fill:
```lua
    local in_water = is_node_water(start_pos)
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
                if dy > max_y or not chunk:inside(nn.pos) or in_water ~= nn.in_water then
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


## Navigation

Once we have a bunch of wayzones, we need to hook them together. Adjacent chunks are checked for wayzones that exit into the wayzones of the other chunk.
Links between wayzones are one-way, but they are recorded in both wayzones to allow reverse navigation of the mesh.

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

When finding a path between a start and target position, we need to collect a list of all intermediate wayzones that we have to go through.

The first step is to find the wayzone for the start pos and target pos. If either position doesn't land in a wayzone
then the path fails. Return nil.

If the start and target are in the same wayzone, then use pathfinder.find_path() to go to the target. Done.

If the start and target wayzones are directly connected (adjacent chunks), then use find_path() to go directly to the target.

If the start and target wayzones are not directly connected, then we need to use the A* algo navigate wayzones, from start to target.

We do not include the start or target wayzone in the wayzone list.

We use pathfinder.find_path() to navigate towards the first wayzone in the list. When we reach the wayzone, we discard it and navigate towards the center of the next wayzone, etc, until we run out of wayzones. We then use find_path() to go the target, which should now be in an adjacent wayzone.

Assuming we determined a wayzone path with 4 wayzones as follows:

  * [1] start wayzone
  * [2] wayzone2
  * [3] wayzone3
  * [4] target wayzone

We would call find_path() as follows:

  * find_path(wayzone2)
  * find_path(wayzone3)
  * find_path(target)

If any find_path() fails to reach the target, then we can rebuild the wayzone list and try again. If building the wayzone list fails, then we quit.

All find_path() calls are given the bounding boxes of the wayzones and limit the search area to those boxes.

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

## Problems and Possible Improvements

### Favoring diagonals when we shouldn't

The paths tend to go diagonal until either X or Z matches the dest and then go straight.

It would be nice to follow something like Breshem's line algo.


### Wandering Path
The path tends to wander a bit toward the center of the next wayzone, since that is where we are going.
This is due to the cost estimation function, which requires a single point.

A simple example of the problem is illustrated below. A B C mark the different positions in the wayzones (which cover the whole chunk).
"s" is the start and "t" is the target. "x" is the center point. "o" are points on the path.

```
AAAAAAAA BBBBBBBB
AAAAAAAA BBBBBBBB
AAAAAAAA BBBBBBBB
AAAxAAAA BBBBxBBB
AAAAAAAA BBBBBBBB
AAAAAAAo oBBBBBBB
AAAAoooA BoBBBBBB
AsooAAAA BBoBBBBB
         CCCoCCCC
         CooCCCCC
         tCCCCCCC
         CCCxCCCC
         CCCCCCCC
         CCCCCCCC
         CCCCCCCC
         CCCCCCCC
```

  * The first leg of the path goes directly towards B.x, moving further up than it should.
  * The second leg goes towards C.x, again moving furher right than it should.


One possible work-around is to calculate a bounding box around the wayzone and use that to calculate the closest point to the current position.
That can then be used as the "target" in the cost calculation.

That might end up with something like the following, as the center point would be ignored.
```
AAAAAAAA BBBBBBBB
AAAAAAAA BBBBBBBB
AAAAAAAA BBBBBBBB
AAAxAAAA BBBBxBBB
AAAAAAAA BBBBBBBB
AAAAAAAA BBBBBBBB
AAAAAAAA BBBBBBBB
Asoooooo oBBBBBBB
         oCCCCCCC
         oCCCCCCC
         tCCCCCCC
         CCCxCCCC
         CCCCCCCC
         CCCCCCCC
         CCCCCCCC
         CCCCCCCC
```

Another option is to calculate the estimated cost to the real target and not the intermediate wayzone.


### Sub-optimal Cost Estimates

The cost to move from one wayzone to a connected wayzone is at minimum 1, average 8 and at most, who knows?

The lack of an accurate cost for traversing the path results in sub-optimal wayzone selection.

We can get a more accurate estimate if three wayzones are involved by calculating a path from A through B to C.

There are a few ways to address this
Probably the best approach is to use the bounding box concept and get an estimate to the 








---
