# No modal confirmations; undo + soft-delete instead (R-01)

Destructive actions fire immediately with an undo SnackBar plus a 7-day soft-delete recycle bin. We never show "Are you sure?".

## Consequences

We pay for soft-delete plumbing on every deletable entity in exchange for never breaking the trainer's flow with a modal. Every new deletable entity must ship with a `deleted_at` column, a recycle-bin surface, and an undo SnackBar — this is non-negotiable.
