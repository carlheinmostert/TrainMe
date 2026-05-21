# 14-day structural-edit grace window after first client open

The first publish of a plan URL consumes a credit. Non-structural edits (reps, sets, hold, notes, filter params) are free forever. Structural edits (add/delete/reorder exercises) are free indefinitely while the client has not opened the link; once the client opens it, the practitioner has 14 days of free structural editing, after which the plan locks and a 1-credit unlock (via `unlock_plan_for_edit`) buys the next republish. The 14-day grace matches typical practitioner/client follow-up cadence.
