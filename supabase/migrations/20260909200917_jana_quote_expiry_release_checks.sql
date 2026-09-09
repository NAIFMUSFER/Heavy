-- Releasing an expired quote must fail visibly if a ledger allocation is inconsistent.
CREATE OR REPLACE FUNCTION public.jana_expire_quotes()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,extensions,pg_temp AS $$
DECLARE q record; allocation jsonb; n integer:=0;
 nowms bigint:=(extract(epoch from clock_timestamp())*1000)::bigint;
BEGIN
 -- Serialize sweep workers; customer operations still use row-level locks.
 IF NOT pg_try_advisory_xact_lock(hashtextextended('jana:quote-expiry-sweep',0)) THEN RETURN 0; END IF;
 FOR q IN SELECT id,slot_id,snapshot FROM public.quotes
  WHERE state='active' AND expires_at<=nowms ORDER BY expires_at,id LIMIT 200 FOR UPDATE SKIP LOCKED
 LOOP
  PERFORM 1 FROM public.delivery_slots WHERE id=q.slot_id FOR UPDATE;
  PERFORM 1 FROM public.stock_balances WHERE stock_id IN
   (SELECT value->>'stock_id' FROM jsonb_array_elements(q.snapshot::jsonb->'allocations')) ORDER BY stock_id FOR UPDATE;
  FOR allocation IN SELECT value FROM jsonb_array_elements(q.snapshot::jsonb->'allocations') ORDER BY value->>'lot_id'
  LOOP
   UPDATE public.inventory_lots SET reserved_base=reserved_base-(allocation->>'base_qty')::bigint
    WHERE id=allocation->>'lot_id' AND reserved_base>=(allocation->>'base_qty')::bigint;
   IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
   UPDATE public.stock_balances SET reserved_base=reserved_base-(allocation->>'base_qty')::bigint
    WHERE stock_id=allocation->>'stock_id' AND reserved_base>=(allocation->>'base_qty')::bigint;
   IF NOT FOUND THEN RAISE EXCEPTION 'inventory_allocation_invalid'; END IF;
   INSERT INTO public.stock_movements(id,stock_id,lot_id,on_hand_delta,reserved_delta,reason,reference,actor_id,created_at)
    VALUES('mov-'||replace(gen_random_uuid()::text,'-',''),allocation->>'stock_id',allocation->>'lot_id',0,-(allocation->>'base_qty')::bigint,'quote_expired',q.id,NULL,nowms);
  END LOOP;
  UPDATE public.delivery_slots SET booked=booked-1 WHERE id=q.slot_id AND booked>0;
  IF NOT FOUND THEN RAISE EXCEPTION 'slot_allocation_invalid'; END IF;
  UPDATE public.quotes SET state='expired' WHERE id=q.id;
  n=n+1;
 END LOOP;
 RETURN n;
END$$;
REVOKE ALL ON FUNCTION public.jana_expire_quotes() FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.jana_expire_quotes() TO service_role;
