I started using the maidroid api, but by now it's a lot different.
for specific documentation look for the comments in the (api.lua)

## jobs

To register a new job use:
```lua

working_villages.register_job("[itemstring for the job item]", {
	description      = "[description for the job item]",
	inventory_image  = "[texture for the job item]",
	jobfunc = "[coroutine that is continued every step]",
})
```

examples: see testing jobs

## villagers

To register a new villager use:
```lua

working_villages.register_villager([entity name for the villager], {
	hp_max     = [maximum hp],
	weight     = [falling acceleration of the villager],
	mesh       = [3D mesh of the villager],
	textures   = [texture of the villager],
	egg_image  = [texture of the spawnegg],
})
```

examples: [register.lua](register.lua)

##async actions

* actions that are run for more than one step
* called with `villager:action()`
* return true for sucess
* return false, fail for failure, the failures are listed in [failures.lua](failures.lua)

`go_to(pos, radius, height)`
Looks for a path to pos and goes there. Stops when within the radius from pos.
If a radius is given and height is nil, then the volume is a sphere.
If height is given, the volume is a cylinder.

`dig(pos)`
Digs the node at the position.
Protections are checked.
The position must be within a distance of 5.

`place(item,pos)`
Places the given item at the position.
Protections are checked.
The position must be within a distance of 5.

`goto_bed()`
Rests for the night.
If the MOB has a bed, it will navigate to the bed and sit on it.
Otherwise, it will sit down and rest.
