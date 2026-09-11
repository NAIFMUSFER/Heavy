const test=require('node:test'),assert=require('node:assert/strict');
process.env.JANA_EXPECTED_COMMIT='fixture-expected-commit';
const {waitForDeployment,smoke}=require('../scripts/smoke.cjs');

test('deployment polling waits for dependencies without submitting customer mutations',async()=>{
 const original=global.fetch,paths=[];let versionCalls=0,readyCalls=0,pauses=0;
 global.fetch=async(url,options)=>{const p=new URL(url).pathname;paths.push(p);assert.equal(options.method,undefined);if(p==='/version')return Response.json({commit:++versionCalls===1?'previous-commit':'fixture-expected-commit'});assert.equal(p,'/ready');return ++readyCalls===1?Response.json({ok:false},{status:503}):Response.json({ok:true})};
 try{await waitForDeployment({pause:async()=>{pauses++},attempts:4});assert.equal(pauses,2);assert.equal(readyCalls,2);assert.ok(paths.every(p=>['/version','/ready'].includes(p)))}finally{global.fetch=original}
});
test('readiness polling cannot accept an older healthy deployment',async()=>{
 const original=global.fetch;global.fetch=async()=>Response.json({commit:'older-commit',ok:true});
 try{await assert.rejects(waitForDeployment({pause:async()=>{},attempts:2}),/deployed commit/)}finally{global.fetch=original}
});

test('production smoke reports the number of requests it actually verifies',async t=>{
 const previousFetch=global.fetch,previousLog=console.log,seen=[],logs=[];
 t.after(()=>{global.fetch=previousFetch;console.log=previousLog});
 global.fetch=async url=>{
  const path=new URL(url).pathname;seen.push(path);
  if(path==='/version')return Response.json({commit:'fixture-expected-commit'});
  if(path==='/health')return Response.json({ok:true});
  if(path==='/ready')return Response.json({ok:true,dependencies:[]});
  if(path==='/api/catalog')return Response.json({items:[]});
  if(path==='/api/storefront')return Response.json({accepting_orders:false,message:'مغلق',published:null});
  if(path==='/api/ops/storefront'||path==='/api/auth/me')return Response.json({error:{code:'AUTH'}},{status:401});
  if(path==='/api/auth/login')return Response.json({error:{code:'INVALID_LOGIN'}},{status:401});
  if(['/server.js','/mobile/App.js','/supabase/functions/jana-api/index.ts'].includes(path))return new Response('missing',{status:404});
  return new Response('x'.repeat(200),{headers:{'content-security-policy':"default-src 'self'"}});
 };
 console.log=value=>logs.push(value);await smoke();
 const result=JSON.parse(logs.at(-1));assert.equal(result.ok,true);assert.equal(result.checks,seen.length);assert.equal(result.checks,30);
});
