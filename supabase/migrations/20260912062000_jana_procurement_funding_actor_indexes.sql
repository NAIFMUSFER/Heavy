-- Cover the phase-8 funding/settlement foreign keys used for audit and evidence lookup.
CREATE INDEX jana_procurement_funding_actor
 ON public.procurement_purchase_funding(actor_id,created_at,id);
CREATE INDEX jana_procurement_settlement_actor
 ON public.procurement_settlement_entries(actor_id,created_at,id);
CREATE INDEX jana_procurement_settlement_purchase
 ON public.procurement_settlement_entries(purchase_record_id,created_at,id);
