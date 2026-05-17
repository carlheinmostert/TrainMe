# Three-tier deploy pipeline: feature → staging → main

Code lands on a feature branch, opens a PR against `staging`. Carl reviews and merges; the persistent staging environment runs against the staging Supabase branch + `staging.*` web domains. Promotion from `staging` to `main` is an explicit human action — it replaces the previous flow where every web merge to main hit production. Docs and specs skip the pipeline (see ADR 0013).
