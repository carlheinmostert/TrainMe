# Practice as the multi-tenancy boundary

The Practice is the tenant — every practitioner-owned row carries a `practice_id`, and RLS is scoped via the SECURITY DEFINER helpers `user_practice_ids()` and `user_is_practice_owner()`. A practitioner can belong to many practices; the publish-screen picker is where they choose which one pays.

## Considered Options

We considered keeping the user as the tenancy boundary (single-owner) and rejected it — every real practice we've onboarded has more than one practitioner, and the multi-tenant shape needed to exist on day one rather than as a later migration.
