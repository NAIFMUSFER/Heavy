"""Rehearse fixture-only recovery; never accepts a production source or destination."""
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile
import time

SOURCE = 'jana-test-postgres'
TARGET = 'jana-recovery-postgres'
ROLE_SQL = """CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS;
CREATE ROLE authenticator NOLOGIN;"""


def require_disposable(env):
    expected = {'JANA_TEST_DATABASE': 'disposable', 'PGHOST': '127.0.0.1',
                'PGPORT': '5432', 'PGDATABASE': 'jana_test', 'PGUSER': 'postgres'}
    if any(env.get(k) != v for k, v in expected.items()):
        raise ValueError('Recovery rehearsal requires the fixed disposable loopback database')
    if any(env.get(k) for k in ('PGHOSTADDR', 'PGSERVICE', 'PGSERVICEFILE', 'PGOPTIONS')):
        raise ValueError('Recovery rehearsal refuses alternate PostgreSQL routing/options')


def command(args, **kwargs):
    try:
        return subprocess.run(args, check=True, timeout=180, **kwargs)
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr or ''
        if isinstance(detail, bytes):
            detail = detail.decode('utf-8',errors='replace')
        # Only the first diagnostic line; never print SQL, row data or parameters.
        first = detail.splitlines()[0] if detail else 'see command diagnostics'
        raise RuntimeError('Fixture recovery command failed: ' + first) from None


def sql(container, statement):
    if container not in (SOURCE, TARGET):
        raise ValueError('Unknown disposable container')
    result = command(['docker', 'exec', '-i', container, 'psql', '-X', '-qAt',
                      '-U', 'postgres', '-d', 'jana_test', '-v', 'ON_ERROR_STOP=1'],
                     input='SET search_path=public,extensions;\n' + statement,
                     text=True, capture_output=True)
    return result.stdout.strip()


def value(container, statement):
    return json.loads(sql(container, statement))


def identifier(name):
    return '"' + name.replace('"', '""') + '"'


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                    separators=(',', ':')).encode()).hexdigest()


def records(container, query):
    return value(container, "SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY "
                 "to_jsonb(q)::text COLLATE \"C\"),'[]'::jsonb) FROM (" + query + ") q;")


METADATA = {
    'tables': """SELECT n.nspname AS schema,c.relname,c.relkind,c.relrowsecurity,
        c.relforcerowsecurity,c.relowner::regrole::text AS owner
        FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S')""",
    'columns': """SELECT c.relname,a.attname,a.attnum,
        format_type(a.atttypid,a.atttypmod) AS type,a.attnotnull,a.attidentity,
        a.attgenerated,pg_get_expr(d.adbin,d.adrelid) AS expression
        FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
        LEFT JOIN pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum
        WHERE c.relnamespace='public'::regnamespace AND c.relkind IN ('r','p','v','m')
        AND a.attnum>0 AND NOT a.attisdropped""",
    'constraints': """SELECT c.relname,k.conname,k.contype,k.convalidated,
        pg_get_constraintdef(k.oid) AS definition
        FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid
        WHERE c.relnamespace='public'::regnamespace""",
    'indexes': """SELECT tablename,indexname,indexdef FROM pg_indexes WHERE schemaname='public'""",
    'triggers': """SELECT c.relname,t.tgname,t.tgenabled,pg_get_triggerdef(t.oid) AS definition
        FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
        WHERE c.relnamespace='public'::regnamespace AND NOT t.tgisinternal""",
    'policies': """SELECT schemaname,tablename,policyname,permissive,roles,cmd,qual,with_check
        FROM pg_policies WHERE schemaname='public'""",
    'functions': """SELECT p.oid::regprocedure::text AS signature,
        p.proowner::regrole::text AS owner,pg_get_functiondef(p.oid) AS definition
        FROM pg_proc p WHERE p.pronamespace='public'::regnamespace
        AND p.proname LIKE 'jana_%'""",
    'function_grants': """SELECT p.oid::regprocedure::text AS signature,
        CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS grantee,
        a.grantor::regrole::text AS grantor,a.privilege_type,a.is_grantable
        FROM pg_proc p CROSS JOIN LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        WHERE p.pronamespace='public'::regnamespace AND p.proname LIKE 'jana_%'""",
    'table_grants': """SELECT c.relname,
        CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS grantee,
        a.grantor::regrole::text AS grantor,a.privilege_type,a.is_grantable
        FROM pg_class c CROSS JOIN LATERAL aclexplode(coalesce(c.relacl,
        acldefault(CASE WHEN c.relkind='S' THEN 'S'::\"char\" ELSE 'r'::\"char\" END,c.relowner))) a
        WHERE c.relnamespace='public'::regnamespace AND c.relkind IN ('r','p','v','m','S')""",
    'schema_grants': """SELECT n.nspname,
        CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS grantee,
        a.grantor::regrole::text AS grantor,a.privilege_type,a.is_grantable
        FROM pg_namespace n CROSS JOIN LATERAL aclexplode(coalesce(n.nspacl,
        acldefault('n',n.nspowner))) a WHERE n.nspname IN ('public','extensions')""",
    'default_grants': """SELECT d.defaclrole::regrole::text AS owner,
        coalesce(n.nspname,'GLOBAL') AS schema,d.defaclobjtype,
        CASE WHEN a.grantee=0 THEN 'PUBLIC' ELSE a.grantee::regrole::text END AS grantee,
        a.grantor::regrole::text AS grantor,a.privilege_type,a.is_grantable
        FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid=d.defaclnamespace
        CROSS JOIN LATERAL aclexplode(d.defaclacl) a""",
    'role_memberships': """SELECT r.rolname AS role,m.rolname AS member,a.admin_option
        FROM pg_auth_members a JOIN pg_roles r ON r.oid=a.roleid
        JOIN pg_roles m ON m.oid=a.member
        WHERE r.rolname IN ('anon','authenticated','service_role','authenticator')
        OR m.rolname IN ('anon','authenticated','service_role','authenticator')""",
    'roles': """SELECT rolname,rolsuper,rolinherit,rolcreaterole,rolcreatedb,rolcanlogin,
        rolreplication,rolbypassrls FROM pg_roles
        WHERE rolname IN ('anon','authenticated','service_role','authenticator')""",
    'extensions': """SELECT e.extname,e.extversion,n.nspname FROM pg_extension e
        JOIN pg_namespace n ON n.oid=e.extnamespace""",
    'schedules': """SELECT jobid,schedule,command,nodename,nodeport,database,username,active,jobname
        FROM cron.job""",
}


def snapshot(container):
    tables = records(container, """SELECT n.nspname,c.relname FROM pg_class c
        JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='public' AND c.relkind IN ('r','p')""")
    result = {'tables': {}, 'metadata': {}, 'sequences': {}}
    for table in tables:
        name = table['nspname'] + '.' + table['relname']
        relation = identifier(table['nspname']) + '.' + identifier(table['relname'])
        result['tables'][name] = value(container, """SELECT jsonb_build_object(
            'rows',count(*),'sha256',encode(extensions.digest(coalesce(
            string_agg(to_jsonb(r)::text,E'\\n' ORDER BY to_jsonb(r)::text COLLATE "C"),''),
            'sha256'),'hex')) FROM """ + relation + " r;")
    for category, query in METADATA.items():
        rows = records(container, query)
        result['metadata'][category] = {'rows': len(rows), 'sha256': digest(rows)}
    sequences = records(container, """SELECT n.nspname,c.relname FROM pg_class c
        JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='public' AND c.relkind='S'""")
    for sequence in sequences:
        name = sequence['nspname'] + '.' + sequence['relname']
        relation = identifier(sequence['nspname']) + '.' + identifier(sequence['relname'])
        result['sequences'][name] = value(container,
            'SELECT to_jsonb(s) FROM (SELECT last_value,is_called FROM ' + relation + ') s;')
    return result


def compare_snapshots(before, after):
    differences = []
    for section in ('tables', 'metadata', 'sequences'):
        a, b = before.get(section, {}), after.get(section, {})
        for name in sorted(set(a) | set(b)):
            if a.get(name) != b.get(name):
                differences.append(section + ':' + name)
    if differences:
        # Report names only, never dumped rows, password hashes or session tokens.
        raise AssertionError('Recovery mismatch: ' + ', '.join(differences))


def main():
    require_disposable(os.environ)
    from database_support import fixture, quote, rpc, literal
    checks = []
    def passed(name):
        checks.append(name)
        print('PASS ' + name, flush=True)
    def source(statement):
        return value(SOURCE, statement)
    def target(statement):
        return value(TARGET, statement)

    # Freeze only this new disposable source. Preserve cron.job active definitions.
    sql(SOURCE, "ALTER SYSTEM SET cron.launch_active_jobs='off';")
    sql(SOURCE, 'SELECT pg_reload_conf();')
    for _ in range(30):
        if sql(SOURCE, 'SHOW cron.launch_active_jobs;') == 'off':
            break
        time.sleep(0.2)
    assert sql(SOURCE, 'SHOW cron.launch_active_jobs;') == 'off'
    # No test worker should already be running in this dedicated job.
    assert source("SELECT count(*) FROM pg_stat_activity WHERE application_name='pg_cron' "
                  "AND backend_type='client backend' AND state='active';") == 0
    passed('source is disposable and scheduled execution is paused without deleting jobs')

    f = fixture(stock=10000, capacity=20)
    sql(SOURCE, "UPDATE public.sessions SET expires_at=(extract(epoch from now())*1000)::bigint+1800000 "
        "WHERE user_id IN (" + ','.join(literal(f['p']+suffix) for suffix in ('u','a','c')) + ');')
    q = source(quote(f, 'recovery-quote'))
    confirmed = source(rpc('jana_critical_write', f['t'], 'recovery-confirm',
                           'order.confirm', {'quote_id': q['id']}))
    oid = confirmed['id']
    source(rpc('jana_ops_transition', f['atok'], oid, 'start', ''))
    source(rpc('jana_finalize_picking', f['atok'], oid))
    source(rpc('jana_ops_transition', f['ct'], oid, 'dispatch', ''))
    source(rpc('jana_critical_write', f['ct'], 'recovery-deliver', 'order.deliver',
               {'order_id': oid, 'code': confirmed['delivery_code']}))
    source(rpc('jana_critical_write', f['ct'], 'recovery-collect', 'cod.collect',
               {'order_id': oid, 'amount_halalas': confirmed['total_halalas']}))
    source(rpc('jana_critical_write', f['atok'], 'recovery-settle', 'cod.settle',
               {'order_id': oid, 'amount_halalas': 700, 'reference': 'fixture-deposit'}))
    source(rpc('jana_critical_write', f['atok'], 'recovery-refund', 'refund.create',
               {'order_id': oid, 'amount_halalas': 100, 'reason': 'Recovery fixture',
                'reference': 'fixture-refund', 'payment_source': 'courier'}))
    assert source('SELECT jana_deep_health();')['ok'] is True
    before = snapshot(SOURCE)
    for table in ('orders','stock_balances','inventory_lots','cash_entries',
                  'inventory_cost_entries','refunds','sessions'):
        assert before['tables']['public.' + table]['rows'] > 0, table
    assert before['metadata']['schedules']['rows'] > 0
    passed('nonempty delivered order stock cost cash refund and session fixtures')

    started = time.monotonic()
    image = command(['docker','inspect','--format','{{.Image}}',SOURCE],
                    text=True,capture_output=True).stdout.strip()
    if not image.startswith('sha256:'):
        raise AssertionError('Expected the exact already-built disposable image')
    created = False
    try:
        command(['docker','run','--detach','--name',TARGET,'--network','none',
                 '--env','POSTGRES_USER=postgres','--env','POSTGRES_DB=jana_test',
                 '--env','POSTGRES_PASSWORD=disposable-ci-only',image,
                 '-c','shared_preload_libraries=pg_cron','-c','cron.database_name=jana_test',
                 '-c','cron.launch_active_jobs=off'],capture_output=True)
        created = True
        for _ in range(60):
            probe = subprocess.run(['docker','exec',TARGET,'pg_isready','-h','127.0.0.1',
                                    '-U','postgres','-d','jana_test'],
                                   capture_output=True,timeout=5)
            if probe.returncode == 0:
                break
            time.sleep(1)
        else:
            raise AssertionError('Isolated recovery database did not start')
        mode = command(['docker','inspect','--format','{{.HostConfig.NetworkMode}}',TARGET],
                       text=True,capture_output=True).stdout.strip()
        assert mode == 'none'
        assert sql(TARGET,'SHOW cron.launch_active_jobs;') == 'off'
        # Roles are cluster-level preconditions, not contents of pg_dump.
        sql(TARGET, ROLE_SQL)
        passed('fresh same-image recovery container has no network or scheduled execution')

        with tempfile.TemporaryDirectory(prefix='jana-fixture-recovery-') as directory:
            archive = pathlib.Path(directory) / 'fixture.dump'
            dump_started = time.monotonic()
            with archive.open('wb') as output:
                command(['docker','exec',SOURCE,'pg_dump','-U','postgres','-d','jana_test',
                         '--format=custom'],stdout=output)
            dump_seconds = time.monotonic() - dump_started
            archive_sha = hashlib.sha256(archive.read_bytes()).hexdigest()
            archive_bytes = archive.stat().st_size
            assert archive_bytes > 0
            restore_started = time.monotonic()
            with archive.open('rb') as source_file:
                command(['docker','exec','-i',TARGET,'pg_restore','-U','postgres',
                         '--dbname=jana_test','--single-transaction','--exit-on-error'],
                        stdin=source_file,capture_output=True)
            restore_seconds = time.monotonic() - restore_started
        passed('full custom-format schema and data archive restored atomically; archive removed')

        after = snapshot(TARGET)
        if before['metadata']['constraints'] != after['metadata']['constraints']:
            original = records(SOURCE, METADATA['constraints'])
            restored = records(TARGET, METADATA['constraints'])
            changed = {'source_only':[r for r in original if r not in restored],
                       'restored_only':[r for r in restored if r not in original]}
            # Structural constraint definitions only; no table contents or credentials.
            print('Constraint metadata differences: ' + json.dumps(changed),flush=True)
        compare_snapshots(before, after)
        passed('every public table row count and content fingerprint matches')
        passed('RLS policies object ownership RPC definitions and effective grants match')
        passed('constraints indexes triggers sequence state extensions and schedules match')
        assert target('SELECT jana_deep_health();')['ok'] is True
        passed('restored stock slot duplicate-order and cash invariants are healthy')
        detail_before = source(rpc('jana_order_detail',f['t'],oid))
        detail_after = target(rpc('jana_order_detail',f['t'],oid))
        assert detail_before == detail_after
        passed('restored custom session reads the identical frozen order and money history')
        retried = target(rpc('jana_critical_write',f['t'],'recovery-confirm',
                             'order.confirm',{'quote_id':q['id']}))
        assert retried == confirmed
        replayed = snapshot(TARGET)
        for table in ('orders','stock_balances','inventory_lots','cash_entries',
                      'inventory_cost_entries','refunds'):
            assert replayed['tables']['public.'+table] == after['tables']['public.'+table]
        passed('persisted order retry remains idempotent after recovery')
        next_quote = target(quote(f,'recovery-after-restore'))
        assert next_quote['id'] != q['id']
        assert target('SELECT jana_deep_health();')['ok'] is True
        passed('restored service can reserve a new quote without violating invariants')

        report = {
            'ok': True, 'scope': 'disposable-fixtures-only',
            'commit': os.environ.get('GITHUB_SHA','local'),
            'checked_at': time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
            'checks': checks, 'public_tables': len(before['tables']),
            'nonempty_public_tables': sum(t['rows']>0 for t in before['tables'].values()),
            'tables': before['tables'], 'metadata': before['metadata'],
            'sequences_checked': len(before['sequences']),
            'archive_sha256': archive_sha, 'archive_bytes': archive_bytes,
            'dump_seconds': round(dump_seconds,3),
            'restore_seconds': round(restore_seconds,3),
            'rehearsal_seconds': round(time.monotonic()-started,3),
            'production_restore_verified': False,
            'production_rpo_rto_verified': False,
            'limits': ['fixture scale; not production capacity',
                       'cluster roles preprovisioned; no role passwords backed up',
                       'no Supabase Storage objects or provider configuration',
                       'no production backup retrieval or point-in-time recovery',
                       'cron execution kept off; job definitions compared',
                       'no archive or row data uploaded as artifacts'],
        }
        output = pathlib.Path('evidence/local/recovery/rehearsal.json')
        output.parent.mkdir(parents=True,exist_ok=True)
        output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps({k:v for k,v in report.items() if k not in ('tables','metadata')}),
              flush=True)
    finally:
        if created:
            command(['docker','rm','-f','-v',TARGET],capture_output=True)


if __name__ == '__main__':
    main()
