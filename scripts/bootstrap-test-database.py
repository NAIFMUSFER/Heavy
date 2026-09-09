"""Replay recovered JANA schema only into a disposable loopback database.
Never accepts production hosts or the Supabase project URL.
"""
import os,pathlib,subprocess,sys
if os.environ.get('JANA_TEST_DATABASE')!='disposable' or os.environ.get('PGHOST') not in ('127.0.0.1','localhost') or os.environ.get('PGDATABASE')!='jana_test':
 raise SystemExit('Refusing bootstrap outside an explicitly disposable loopback jana_test database')
def sql(source):subprocess.run(['psql','-X','-v','ON_ERROR_STOP=1'],input=source,text=True,check=True)
sql('''CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS; CREATE ROLE authenticator NOLOGIN;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
SET search_path=public,extensions;
''')
for p in sorted(pathlib.Path('tests/database-history').glob('*.sql'))+sorted(pathlib.Path('supabase/migrations').glob('*.sql')):
 print('Applying',p.name,flush=True)
 sql('SET search_path=public,extensions;\n'+p.read_text())
print('Recovered migrations replayed successfully')
