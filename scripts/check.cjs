const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),{execFileSync}=require('node:child_process');
const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'jana-check-'));
try {
 for(const f of ['server.js','tests/e2e/journey.mjs','tests/e2e/harness.mjs','server/notification-worker.mjs','server/providers/notification-repository.mjs','scripts/notification-worker.mjs'])execFileSync(process.execPath,['--check',f],{stdio:'inherit'});
 for(const [prefix,count] of [['shop',5],['ops',4],['common',1],['zone-map',1],['address',1],['order',1],['checkout',1],['local-cart',1],['input',1]]){
  const files=['common','zone-map','address','order','checkout','local-cart','input'].includes(prefix)?['assets/'+prefix+'.js']:Array.from({length:count},(_,i)=>`assets/${prefix}.part${String(i+1).padStart(2,'0')}.js`);
  const target=path.join(tmp,prefix+'.mjs');fs.writeFileSync(target,files.map(f=>fs.readFileSync(f,'utf8')).join(''));
  execFileSync(process.execPath,['--check',target],{stdio:'inherit'});
 }
 for(const f of ['index.html','admin.html','picker.html','courier.html','manifest.webmanifest','sw.js'])if(!fs.statSync(f).isFile())throw Error('Missing public file '+f);
 console.log('Gateway and browser bundles checked');
}finally{fs.rmSync(tmp,{recursive:true,force:true})}
