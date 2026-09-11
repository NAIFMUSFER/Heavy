-- Cover the immutable supplier credit actor foreign key without changing ledger rows.
CREATE INDEX jana_supplier_credits_actor_idx ON public.supplier_credit_notes(actor_id);
