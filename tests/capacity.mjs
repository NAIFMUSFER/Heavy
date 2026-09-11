import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {performance} from 'node:perf_hooks';
import {startHarness} from './e2e/harness.mjs';

assert.equal(process.env.JANA_TEST_DATABASE,'disposable');
assert.equal(process.env.PGHOST,'127.0.0.1');
assert.equal(process.env.PGDATABASE,'jana_test');

const harness=await startHarness();
const samples=[];
const total=Number(process.env.JANA_CAPACITY_REQUESTS||320);
const concurrency=Number(process.env.JANA_CAPACITY_CONCURRENCY||32);
const p95Limit=Number(process.env.JANA_CAPACITY_P95_MS||3000);
const throughputFloor=Number(process.env.JANA_CAPACITY_MIN_RPS||15);
const percentile=(values,fraction)=>values[Math.min(values.length-1,Math.ceil(values.length*fraction)-1)];

async function catalogSample(){
 const started=performance.now();
 const response=await harness.fetchLocal('/api/catalog?limit=20&offset=0');
 const elapsed=performance.now()-started;
 let body;try{body=await response.json()}catch{body=null}
 samples.push({status:response.status,duration_ms:elapsed});
 assert.equal(response.status,200,JSON.stringify(body));
 assert.ok(Array.isArray(body?.items));
}

try{
 const ready=await harness.fetchLocal('/ready');
 assert.equal(ready.status,200,await ready.text());
 for(let index=0;index<5;index++)await catalogSample();
 samples.length=0;
 const started=performance.now(),workers=Array.from({length:concurrency},async(_,worker)=>{
  for(let index=worker;index<total;index+=concurrency)await catalogSample();
 });
 await Promise.all(workers);
 const durationMs=performance.now()-started;
 const durations=samples.map(sample=>sample.duration_ms).sort((a,b)=>a-b);
 const p50=percentile(durations,0.50),p95=percentile(durations,0.95),p99=percentile(durations,0.99);
 const requestsPerSecond=total/(durationMs/1000);
 assert.equal(samples.length,total);
 assert.ok(p95<=p95Limit,`catalog p95 ${p95.toFixed(1)}ms exceeds ${p95Limit}ms`);
 assert.ok(requestsPerSecond>=throughputFloor,`catalog throughput ${requestsPerSecond.toFixed(1)} req/s is below ${throughputFloor}`);

 harness.setEdgeDelay(400);
 const burst=await Promise.all(Array.from({length:125},async()=>{
  const response=await harness.fetchLocal('/api/catalog?limit=1&offset=0');
  const body=await response.json();
  return{status:response.status,code:body?.error?.code||null};
 }));
 harness.setEdgeDelay(0);
 const admitted=burst.filter(result=>result.status===200).length;
 const shed=burst.filter(result=>result.status===503&&result.code==='BUSY').length;
 assert.ok(admitted>0,'burst admitted no catalog requests');
 assert.ok(shed>0,'burst did not exercise the gateway admission limit');
 assert.equal(admitted+shed,burst.length,'burst returned an unexpected status');
 const recovery=await harness.fetchLocal('/api/catalog?limit=1&offset=0');
 assert.equal(recovery.status,200,'gateway did not recover after shedding the burst');

 const evidence={
  status:'passed',scope:'disposable gateway, canonical Edge handlers and PostgreSQL/PostGIS fixture',
  commit:process.env.GITHUB_SHA||'local',created_at:new Date().toISOString(),
  read_load:{requests:total,concurrency,duration_ms:Number(durationMs.toFixed(1)),requests_per_second:Number(requestsPerSecond.toFixed(1)),p50_ms:Number(p50.toFixed(1)),p95_ms:Number(p95.toFixed(1)),p99_ms:Number(p99.toFixed(1)),limits:{p95_ms:p95Limit,min_requests_per_second:throughputFloor}},
  overload:{requests:burst.length,admitted,shed_busy:shed,recovered:true},
  limitations:['fixture-only; not production capacity acceptance','single GitHub-hosted runner; no network latency to managed Supabase','read-only catalog traffic; no production data or writes']
 };
 await fs.mkdir('evidence/local/capacity',{recursive:true});
 await fs.writeFile('evidence/local/capacity/rehearsal.json',JSON.stringify(evidence,null,2)+'\n');
 console.log(JSON.stringify(evidence));
}finally{
 harness.setEdgeDelay(0);
 await harness.close();
}
