# Single-tier referral with 5% lifetime rebate + 1-credit goodwill floor

Every referee purchase pays the referrer 5% of credits bought, forever. On the referrer's FIRST rebate from each referee, if raw 5% rounds to less than 1 credit it's clamped up to 1 — that's the goodwill floor. A `BEFORE INSERT` trigger enforces single-tier: A → B → C pays A nothing from C. POPIA-respecting: referee names default to "Practice N"; referees opt in to be named via `referee_named_consent`.
