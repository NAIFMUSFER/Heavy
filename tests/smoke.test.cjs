const test=require('node:test'),assert=require('node:assert/strict');
process.env.JANA_EXPECTED_COMMIT='fixture-expected-commit';
const {waitForDeployment}=require('../scripts/smoke.cjs');
test('deployment polling waits for dependencies without submitting customer mutations',async()=>{
 const original=global.fetch,paths=[];let versionCalls=0,readyCalls=0,pauses=0;
 global.fetch=async(url,options)=>{const p=new URL(url).pathname;paths.push(p);assert.equal(options.method,undefined);if(p==='/version')return Response.json({commit:++versionCalls===1?'previous-commit':'fixture-expected-commit'});assert.equal(p,'/ready');return ++readyCalls===1?Response.json({ok:false},{status:503}):Response.json({ok:true})};
 try{await waitForDeployment({pause:async()=>{pauses++},attempts:4});assert.equal(pauses,2);assert.equal(readyCalls,2);assert.ok(paths.every(p=>['/version','/ready'].includes(p)))}finally{global.fetch=original}
});
test('readiness polling cannot accept an older healthy deployment',async()=>{
 const original=global.fetch;global.fetch=async()=>Response.json({commit:'older-commit',ok:true});
 try{await assert.rejects(waitForDeployment({pause:async()=>{},attempts:2}),/deployed commit/)}finally{global.fetch=original}
});
