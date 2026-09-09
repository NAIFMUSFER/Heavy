CREATE OR REPLACE FUNCTION public.jana_create_quote_idempotent(p_token text, p_idem_key text, p_slot_id text, p_address_id text, p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','extensions','pg_temp'
AS $function$
DECLARE
  u public.users;
  scope_key text;
  req_hash text;
  prior public.idempotency_records%rowtype;
  result jsonb;
  nowms bigint := (extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
  u=public.jana_auth_user(p_token);
  p_idem_key=trim(coalesce(p_idem_key,''));
  IF length(p_idem_key)<8 OR length(p_idem_key)>160 THEN RAISE EXCEPTION 'invalid_idempotency_key'; END IF;
  scope_key='quote:'||u.id||':'||p_idem_key;
  req_hash=encode(digest(jsonb_build_object('slot_id',p_slot_id,'address_id',p_address_id,'items',p_items)::text,'sha256'),'hex');
  PERFORM pg_advisory_xact_lock(hashtextextended(scope_key,0));
  SELECT * INTO prior FROM public.idempotency_records WHERE scope=scope_key;
  IF prior.scope IS NOT NULL THEN
    IF prior.request_hash<>req_hash THEN RAISE EXCEPTION 'idempotency_conflict'; END IF;
    RETURN prior.response::jsonb;
  END IF;
  result=public.jana_create_quote(p_token,p_slot_id,p_address_id,p_items);
  INSERT INTO public.idempotency_records(scope,user_id,key,request_hash,response,created_at)
  VALUES(scope_key,u.id,p_idem_key,req_hash,result::json,nowms);
  RETURN result;
END$function$;
REVOKE ALL ON FUNCTION public.jana_create_quote_idempotent(text,text,text,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_create_quote_idempotent(text,text,text,text,jsonb) TO service_role;