"""Pure guard/manifest tests: these do not connect to PostgreSQL or Docker."""
import copy
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    'database_recovery', pathlib.Path(__file__).with_name('database_recovery.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class RecoveryGuardTests(unittest.TestCase):
    def setUp(self):
        self.env = {'JANA_TEST_DATABASE':'disposable','PGHOST':'127.0.0.1',
                    'PGPORT':'5432','PGDATABASE':'jana_test','PGUSER':'postgres'}
        self.manifest = {
            'tables': {'public.orders': {'rows':1,'sha256':'a'}},
            'metadata': {'function_grants': {'rows':1,'sha256':'b'}},
            'sequences': {'public.example_seq': {'last_value':1,'is_called':True}},
        }

    def test_exact_disposable_target_is_accepted(self):
        module.require_disposable(self.env)

    def test_missing_or_changed_target_is_refused(self):
        for key in self.env:
            for replacement in (None, '', 'production'):
                with self.subTest(key=key,replacement=replacement):
                    env = dict(self.env)
                    if replacement is None:
                        del env[key]
                    else:
                        env[key] = replacement
                    with self.assertRaises(ValueError):
                        module.require_disposable(env)

    def test_connection_overrides_are_refused(self):
        for key in ('PGHOSTADDR','PGSERVICE','PGSERVICEFILE','PGOPTIONS'):
            with self.subTest(key=key):
                with self.assertRaises(ValueError):
                    module.require_disposable(dict(self.env,**{key:'alternate'}))

    def test_same_manifest_is_accepted(self):
        module.compare_snapshots(self.manifest,copy.deepcopy(self.manifest))

    def test_same_count_but_changed_contents_fails(self):
        changed = copy.deepcopy(self.manifest)
        changed['tables']['public.orders']['sha256'] = 'changed'
        with self.assertRaisesRegex(AssertionError,'tables:public.orders'):
            module.compare_snapshots(self.manifest,changed)

    def test_missing_and_extra_objects_fail(self):
        for section in self.manifest:
            with self.subTest(section=section):
                changed = copy.deepcopy(self.manifest)
                changed[section] = {}
                with self.assertRaises(AssertionError):
                    module.compare_snapshots(self.manifest,changed)
                with self.assertRaises(AssertionError):
                    module.compare_snapshots(changed,self.manifest)

    def test_permission_or_sequence_drift_fails(self):
        for section in ('metadata','sequences'):
            with self.subTest(section=section):
                changed = copy.deepcopy(self.manifest)
                changed[section][next(iter(changed[section]))] = {'changed':True}
                with self.assertRaises(AssertionError):
                    module.compare_snapshots(self.manifest,changed)

    def test_fingerprints_are_order_stable_and_content_sensitive(self):
        self.assertEqual(module.digest({'a':1,'b':2}),module.digest({'b':2,'a':1}))
        self.assertNotEqual(module.digest({'a':1}),module.digest({'a':2}))


    def test_recorded_varchar_array_constraint_roundtrips(self):
        pairs = [{"name":"orders.delivery_state","restored":"CHECK (((delivery_state)::text = ANY (ARRAY[('unassigned'::character varying)::text, ('assigned'::character varying)::text, ('out_for_delivery'::character varying)::text, ('delivered'::character varying)::text, ('failed'::character varying)::text, ('cancelled'::character varying)::text])))","source":"CHECK (((delivery_state)::text = ANY ((ARRAY['unassigned'::character varying, 'assigned'::character varying, 'out_for_delivery'::character varying, 'delivered'::character varying, 'failed'::character varying, 'cancelled'::character varying])::text[])))"},{"name":"order_costs.direct_cost_kind","restored":"CHECK (((kind)::text = ANY (ARRAY[('delivery'::character varying)::text, ('packaging'::character varying)::text, ('other'::character varying)::text])))","source":"CHECK (((kind)::text = ANY ((ARRAY['delivery'::character varying, 'packaging'::character varying, 'other'::character varying])::text[])))"},{"name":"orders.fulfillment_state","restored":"CHECK (((fulfillment_state)::text = ANY (ARRAY[('queued'::character varying)::text, ('picking'::character varying)::text, ('awaiting_customer'::character varying)::text, ('ready'::character varying)::text, ('cancelled'::character varying)::text])))","source":"CHECK (((fulfillment_state)::text = ANY ((ARRAY['queued'::character varying, 'picking'::character varying, 'awaiting_customer'::character varying, 'ready'::character varying, 'cancelled'::character varying])::text[])))"},{"name":"recurring_plans.jana_recurring_state","restored":"CHECK (((state)::text = ANY (ARRAY[('active'::character varying)::text, ('paused'::character varying)::text, ('cancelled'::character varying)::text])))","source":"CHECK (((state)::text = ANY ((ARRAY['active'::character varying, 'paused'::character varying, 'cancelled'::character varying])::text[])))"},{"name":"inventory_lots.lot_inspection_state","restored":"CHECK (((inspection_state)::text = ANY (ARRAY[('pending'::character varying)::text, ('accepted'::character varying)::text, ('rejected'::character varying)::text])))","source":"CHECK (((inspection_state)::text = ANY ((ARRAY['pending'::character varying, 'accepted'::character varying, 'rejected'::character varying])::text[])))"},{"name":"substitutions.no_implicit_consent","restored":"CHECK (((default_action)::text = ANY (ARRAY[('remove_entire_line'::character varying)::text, ('hold_for_resolution'::character varying)::text])))","source":"CHECK (((default_action)::text = ANY ((ARRAY['remove_entire_line'::character varying, 'hold_for_resolution'::character varying])::text[])))"},{"name":"offerings.offering_kind","restored":"CHECK (((kind)::text = ANY (ARRAY[('individual'::character varying)::text, ('basket'::character varying)::text, ('sized'::character varying)::text, ('usage'::character varying)::text, ('bulk'::character varying)::text, ('gift'::character varying)::text])))","source":"CHECK (((kind)::text = ANY ((ARRAY['individual'::character varying, 'basket'::character varying, 'sized'::character varying, 'usage'::character varying, 'bulk'::character varying, 'gift'::character varying])::text[])))"},{"name":"orders.order_status","restored":"CHECK (((status)::text = ANY (ARRAY[('active'::character varying)::text, ('completed'::character varying)::text, ('cancelled'::character varying)::text])))","source":"CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'completed'::character varying, 'cancelled'::character varying])::text[])))"},{"name":"orders.payment_state","restored":"CHECK (((payment_state)::text = ANY (ARRAY[('awaiting_collection'::character varying)::text, ('collected'::character varying)::text, ('partially_refunded'::character varying)::text, ('refunded'::character varying)::text, ('cancelled'::character varying)::text])))","source":"CHECK (((payment_state)::text = ANY ((ARRAY['awaiting_collection'::character varying, 'collected'::character varying, 'partially_refunded'::character varying, 'refunded'::character varying, 'cancelled'::character varying])::text[])))"},{"name":"product_versions.product_versions_kind_check","restored":"CHECK (((kind)::text = ANY (ARRAY[('individual'::character varying)::text, ('basket'::character varying)::text, ('sized'::character varying)::text, ('usage'::character varying)::text, ('bulk'::character varying)::text, ('gift'::character varying)::text])))","source":"CHECK (((kind)::text = ANY ((ARRAY['individual'::character varying, 'basket'::character varying, 'sized'::character varying, 'usage'::character varying, 'bulk'::character varying, 'gift'::character varying])::text[])))"},{"name":"quotes.quote_state","restored":"CHECK (((state)::text = ANY (ARRAY[('active'::character varying)::text, ('converted'::character varying)::text, ('expired'::character varying)::text, ('cancelled'::character varying)::text])))","source":"CHECK (((state)::text = ANY ((ARRAY['active'::character varying, 'converted'::character varying, 'expired'::character varying, 'cancelled'::character varying])::text[])))"},{"name":"refunds.refund_state","restored":"CHECK (((state)::text = ANY (ARRAY[('requested'::character varying)::text, ('processing'::character varying)::text, ('completed'::character varying)::text, ('failed'::character varying)::text, ('rejected'::character varying)::text])))","source":"CHECK (((state)::text = ANY ((ARRAY['requested'::character varying, 'processing'::character varying, 'completed'::character varying, 'failed'::character varying, 'rejected'::character varying])::text[])))"},{"name":"stock_items.stock_base_unit","restored":"CHECK (((base_unit)::text = ANY (ARRAY[('gram'::character varying)::text, ('piece'::character varying)::text])))","source":"CHECK (((base_unit)::text = ANY ((ARRAY['gram'::character varying, 'piece'::character varying])::text[])))"},{"name":"tickets.ticket_priority","restored":"CHECK (((priority)::text = ANY (ARRAY[('low'::character varying)::text, ('normal'::character varying)::text, ('high'::character varying)::text, ('urgent'::character varying)::text])))","source":"CHECK (((priority)::text = ANY ((ARRAY['low'::character varying, 'normal'::character varying, 'high'::character varying, 'urgent'::character varying])::text[])))"},{"name":"tickets.ticket_state","restored":"CHECK (((state)::text = ANY (ARRAY[('open'::character varying)::text, ('pending_customer'::character varying)::text, ('closed'::character varying)::text])))","source":"CHECK (((state)::text = ANY ((ARRAY['open'::character varying, 'pending_customer'::character varying, 'closed'::character varying])::text[])))"},{"name":"users.valid_role","restored":"CHECK (((role)::text = ANY (ARRAY[('customer'::character varying)::text, ('admin'::character varying)::text, ('picker'::character varying)::text, ('courier'::character varying)::text, ('inventory'::character varying)::text, ('finance'::character varying)::text, ('support'::character varying)::text])))","source":"CHECK (((role)::text = ANY ((ARRAY['customer'::character varying, 'admin'::character varying, 'picker'::character varying, 'courier'::character varying, 'inventory'::character varying, 'finance'::character varying, 'support'::character varying])::text[])))"}]
        for pair in pairs:
            with self.subTest(name=pair['name']):
                self.assertEqual(module.canonical_constraint(pair['source']),
                                 module.canonical_constraint(pair['restored']))

    def test_normalization_is_idempotent_and_preserves_changed_values(self):
        original = "CHECK (state = ANY ((ARRAY['active'::character varying, 'paused'::character varying])::text[]))"
        canonical = module.canonical_constraint(original)
        self.assertEqual(canonical,module.canonical_constraint(canonical))
        self.assertNotEqual(canonical,module.canonical_constraint(original.replace("'paused'","'cancelled'")))

    def test_other_array_casts_are_not_normalized(self):
        for expression in (
            "CHECK (state = ANY ((ARRAY['active'::character varying(2)])::text[]))",
            "CHECK (state = ANY ((ARRAY[some_function()])::text[]))",
            "CHECK (state = ANY ((ARRAY[1, 2])::integer[]))",
        ):
            self.assertEqual(expression,module.canonical_constraint(expression))

    def test_escaped_literals_are_preserved(self):
        original = "CHECK (state = ANY ((ARRAY['owner''s'::character varying])::text[]))"
        expected = "CHECK (state = ANY (ARRAY[('owner''s'::character varying)::text]))"
        self.assertEqual(expected,module.canonical_constraint(original))


if __name__ == '__main__':
    unittest.main()
