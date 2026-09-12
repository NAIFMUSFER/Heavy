-- Cover the actor foreign key on the append-only adjustment evidence table.
-- IF NOT EXISTS keeps clean rebuilds compatible with the aligned prior migration.
CREATE INDEX IF NOT EXISTS jana_retail_adjustment_actor
ON public.procurement_retail_adjustments(actor_id,created_at DESC,id DESC);
