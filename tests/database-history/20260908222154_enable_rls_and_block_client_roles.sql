DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'coupons','delivery_zones','offerings','provider_events','rate_windows','settings','stock_items','suppliers','users','worker_runs','addresses','audit_log','delivery_slots','idempotency_records','inventory_lots','sessions','stock_balances','count_requests','quotes','recurring_plans','stock_movements','orders','notifications','order_costs','order_events','refunds','reviews','substitutions','tickets','favorites','shopping_lists','slot_templates'
  ]
  LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON TABLE public.%I FROM anon, authenticated', t);
  END LOOP;
END $$;