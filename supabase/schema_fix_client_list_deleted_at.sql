-- Hotfix: `list_practice_clients` + `get_client_by_id` were both returning
-- soft-deleted clients (deleted_at IS NOT NULL) after Wave 8's reshape of
-- their return-table signatures for `client_exercise_defaults`. Symptom:
-- delete a client on mobile → pull-to-refresh → SQLite cache re-hydrates
-- the deleted row → it reappears in the UI.
--
-- Fix: add `AND c.deleted_at IS NULL` to both WHERE clauses. Signatures
-- unchanged; CREATE OR REPLACE FUNCTION is safe.

CREATE OR REPLACE FUNCTION public.list_practice_clients(p_practice_id uuid)
 RETURNS TABLE(id uuid, name text, video_consent jsonb, client_exercise_defaults jsonb, last_plan_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'list_practice_clients requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  IF p_practice_id IS NULL THEN
    RAISE EXCEPTION 'list_practice_clients: p_practice_id is required'
      USING ERRCODE = '22023';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM practice_members pm
     WHERE pm.practice_id = p_practice_id AND pm.trainer_id = v_caller
  ) AND NOT public.user_is_practice_owner(p_practice_id) THEN
    RAISE EXCEPTION 'list_practice_clients: caller % is not a member of practice %',
      v_caller, p_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT c.id,
         c.name,
         c.video_consent,
         COALESCE(c.client_exercise_defaults, '{}'::jsonb) AS client_exercise_defaults,
         (SELECT MAX(COALESCE(p.sent_at, p.created_at))
            FROM plans p
           WHERE p.client_id = c.id) AS last_plan_at
    FROM clients c
   WHERE c.practice_id = p_practice_id
     AND c.deleted_at IS NULL
   ORDER BY last_plan_at DESC NULLS LAST, c.name ASC;
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_client_by_id(p_client_id uuid)
 RETURNS TABLE(id uuid, name text, video_consent jsonb, client_exercise_defaults jsonb)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_caller uuid := auth.uid();
  v_practice_id uuid;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'get_client_by_id requires an authenticated caller'
      USING ERRCODE = '28000';
  END IF;

  SELECT c.practice_id INTO v_practice_id
    FROM public.clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL
   LIMIT 1;

  IF v_practice_id IS NULL THEN
    RETURN;
  END IF;

  IF NOT (v_practice_id = ANY (public.user_practice_ids())) THEN
    RAISE EXCEPTION 'get_client_by_id: caller % is not a member of practice %',
      v_caller, v_practice_id
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  SELECT c.id,
         c.name,
         c.video_consent,
         COALESCE(c.client_exercise_defaults, '{}'::jsonb) AS client_exercise_defaults
    FROM public.clients c
   WHERE c.id = p_client_id
     AND c.deleted_at IS NULL;
END;
$function$;
