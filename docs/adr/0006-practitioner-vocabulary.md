# Practitioner vocabulary; trainer is a retired role noun (R-06)

UI copy uses "practitioner". "Trainer", "bio", "physio", "coach", and "fitness trainer" are retired role nouns. The database keeps `trainer_id` for schema stability — renaming would cascade through every RLS policy and SECURITY DEFINER helper. New columns adopt `practitioner_id` or `user_id`. Client-facing copy uses `{TrainerName}` with "your practitioner" as the fallback.
