const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),{execFileSync}=require('node:child_process');
const tmp=fs.mkdtempSync(path.join(os.tmpdir(),'jana-check-'));
try {
 execFileSync(process.execPath,['--check','server.js'],{stdio:'inherit'});
 for(const [prefix,count] of [['shop',5],['ops',4],['common',1]]){
  const files=prefix==='common'?['assets/common.js']:Array.from({length:count},(_,i)=>`assets/${prefix}.part${String(i+1).padStart(2,'0')}.js`);
  const target=path.join(tmp,prefix+'.mjs');fs.writeFileSync(target,files.map(f=>fs.readFileSync(f,'utf8')).join(''));
  execFileSync(process.execPath,['--check',target],{stdio:'inherit'});
 }
 for(const f of ['index.html','admin.html','picker.html','courier.html','manifest.webmanifest','sw.js'])if(!fs.statSync(f).isFile())throw Error('Missing public file '+f);
 console.log('Gateway and browser bundles checked');
}finally{fs.rmSync(tmp,{recursive:true,force:true})}
