--[[
Schedules...

A schedule consists of a series of day/time segments with an associated task
or check function.

The qualifiers for the schedule are:
 - the day of week
 - day of year (for holidays, parties)
 - the time of day - with start and stop times
 - maximum possible priority (optional, used to skip calling 'check' or adding the task)

A schedule line also has a concept of being "done". When a schedule is done, the
activity ends early. For example, "eat_lunch" would be done when lunch has been
eaten. The scheduler will not re-add "done" tasks.

A task is a function. Active tasks are stored in a sorted list, with the highest
priority tasks first. Only the highest priority task runs.
If the task exits with 'true', then the task is removed. Otherwise, it is
restarted on the next step. If a task is interrupted, it is terminated.
When it resumes, it will start as a new coroutine, starting from the beginning
of the function.
]]


function bgai.schedule_new(name)

end
