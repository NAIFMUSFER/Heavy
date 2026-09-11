-- Cover the actor foreign key used by audit and user-retention checks.
CREATE INDEX jana_stock_bin_assigned_by ON public.stock_item_bins(assigned_by);
