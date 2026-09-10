"""Disposable CI fixtures only; never imports a production credential or account."""
import sys
sys.path.insert(0,'tests')
from database_support import *
f=fixture(stock=1,capacity=5)
password='Browser-fixture-only-password-12!'
run("UPDATE users SET password_hash=extensions.crypt("+literal(password)+",extensions.gen_salt('bf',12)) WHERE id IN ("+literal(f['p']+'a')+','+literal(f['p']+'c')+');')
accounts={'admin':f['p']+'a@example.invalid','courier':f['p']+'c@example.invalid'}
for role in ['inventory','picker','support','finance']:
 email=f['p']+role+'@example.invalid';staff=val(rpc('jana_create_staff',f['atok'],email,'Browser '+role,password,role));accounts[role]=email
run("ALTER ROLE authenticator LOGIN PASSWORD 'disposable-rest-only'; GRANT anon,authenticated,service_role TO authenticator; GRANT USAGE ON SCHEMA public TO service_role; GRANT SELECT ON settings,reviews,delivery_zones,refunds TO service_role;")
# The four SELECT grants reproduce the verified Supabase platform privileges
# used by the existing trusted Edge table reads. No client grants are added.
meta={'prefix':f['p'],'accounts':accounts,'stock_id':f['p']+'st','offering_id':f['p']+'off','slot_id':f['p']+'s'}
out=pathlib.Path('evidence/local/e2e-fixture.json');out.parent.mkdir(parents=True,exist_ok=True);out.write_text(json.dumps(meta))
print('Disposable browser fixture created; no production network or account used')
