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


if __name__ == '__main__':
    unittest.main()
