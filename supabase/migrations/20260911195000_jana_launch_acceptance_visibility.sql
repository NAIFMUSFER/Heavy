-- Surface the latest real opening attestation to administrators without
-- duplicating it or exposing merchant/private policy content publicly.
-- A published policy change must be made while intake is closed so that the
-- owner explicitly records a fresh opening review for the new policy version.

ALTER FUNCTION public.jana_admin_storefront(text)
 RENAME TO jana_admin_storefront_pre_acceptance;

CREATE FUNCTION public.jana_admin_storefront(p_token text) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
 r jsonb;
 review jsonb;
BEGIN
 r=public.jana_admin_storefront_pre_acceptance(p_token);

 SELECT jsonb_build_object(
   'recorded_at',a.created_at,
   'storefront_revision',a.detail::jsonb->'after_revision',
   'published_id',a.detail::jsonb->>'published_id',
   'reference',a.detail::jsonb->'payload'->>'reference',
   'reviewed',a.detail::jsonb->'payload'->'reviewed',
   'actor',jsonb_build_object('id',a.actor_id,'name',u.name)
 ) INTO review
 FROM public.audit_log a
 JOIN public.users u ON u.id=a.actor_id
 WHERE a.action='storefront_intake_set'
  AND a.detail::jsonb->'payload'->'accepting_orders'='true'::jsonb
  AND a.detail::jsonb->'payload'->'reviewed'='{"catalog":true,"inventory":true,"coverage":true,"tax":true,"operations":true}'::jsonb
  AND jsonb_typeof(a.detail::jsonb->'payload'->'reference')='string'
 ORDER BY CASE
   WHEN jsonb_typeof(a.detail::jsonb->'after_revision')='number'
    AND a.detail::jsonb->>'after_revision'~'^[0-9]{1,15}$'
   THEN (a.detail::jsonb->>'after_revision')::bigint ELSE -1
  END DESC,a.created_at DESC,a.id DESC
 LIMIT 1;

 RETURN r||jsonb_build_object(
  'last_opening_review',review,
  'opening_review_matches_published',review IS NOT NULL
   AND review->>'published_id'=r->>'published_id');
END$$;

ALTER FUNCTION public.jana_storefront_write(text,text,text,jsonb)
 RENAME TO jana_storefront_write_pre_acceptance;

CREATE FUNCTION public.jana_storefront_write(p_token text,p_idem_key text,p_operation text,p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE
 u public.users;
 intake_open boolean;
BEGIN
 u=public.jana_auth_user(p_token);
 IF u.role<>'admin' THEN RAISE EXCEPTION 'forbidden';END IF;

 IF p_operation='profile.publish' THEN
  SELECT accepting_orders INTO intake_open
  FROM public.storefront_state WHERE singleton FOR SHARE;
  IF intake_open THEN RAISE EXCEPTION 'storefront_close_before_publish';END IF;
 END IF;

 RETURN public.jana_storefront_write_pre_acceptance(p_token,p_idem_key,p_operation,p_payload);
END$$;

REVOKE ALL ON FUNCTION public.jana_admin_storefront_pre_acceptance(text),public.jana_storefront_write_pre_acceptance(text,text,text,jsonb)
 FROM PUBLIC,anon,authenticated,service_role;
REVOKE ALL ON FUNCTION public.jana_admin_storefront(text),public.jana_storefront_write(text,text,text,jsonb)
 FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_admin_storefront(text),public.jana_storefront_write(text,text,text,jsonb)
 TO service_role;
