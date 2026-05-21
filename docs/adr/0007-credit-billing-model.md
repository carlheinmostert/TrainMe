# Credit billing model (vs subscription, vs JIT client-pays)

The billing unit is the plan URL — one credit per plan ≤75 min estimated duration, two credits per plan >75 min. The 75-minute threshold is anti-abuse; almost every real plan costs 1 credit.

## Considered Options

We considered a subscription per practitioner (too high friction for SA bios) and just-in-time client-pays-on-open (would damage adherence, which is the platform's core value prop). Both rejected.
