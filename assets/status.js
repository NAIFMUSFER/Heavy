'use strict';
(()=>{
 const $=s=>document.querySelector(s),labels={'jana-api':'الطلبات والحسابات','jana-critical':'الحجز والتسعير','jana-ops-extra':'التشغيل والمخزون'};
 async function read(path){const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),10000);try{const response=await fetch(path,{cache:'no-store',credentials:'omit',headers:{accept:'application/json'},signal:controller.signal});let body={};try{body=await response.json()}catch{}return{ok:response.ok,body}}finally{clearTimeout(timer)}}
 async function refresh(){
  const button=$('[data-status-refresh]'),overall=$('[data-status-overall]');button.disabled=true;overall.dataset.statusOverall='checking';overall.textContent='جارٍ فحص الخدمات…';
  const [health,ready,version]=await Promise.allSettled([read('/health'),read('/ready'),read('/version')]);
  const gateway=health.status==='fulfilled'&&health.value.ok&&health.value.body.ok===true;
  const dependencies=ready.status==='fulfilled'&&Array.isArray(ready.value.body.dependencies)?ready.value.body.dependencies:[];
  const services=['jana-api','jana-critical','jana-ops-extra'].map(name=>{const item=dependencies.find(x=>x&&x.name===name);return{label:labels[name],ok:item?.ok===true}});
  const serviceReady=ready.status==='fulfilled'&&ready.value.ok&&ready.value.body.ok===true&&services.every(x=>x.ok);
  const release=version.status==='fulfilled'&&version.value.ok&&typeof version.value.body.commit==='string'?version.value.body.commit.slice(0,8):null;
  $('[data-status-gateway]').textContent=gateway?'متصلة':'غير متاحة الآن';
  $('[data-status-dependencies]').textContent=services.map(x=>`${x.label}: ${x.ok?'متصلة':'غير متاحة'}`).join(' — ');
  $('[data-status-version]').textContent=release?`الإصدار ${release}`:'تعذر قراءة الإصدار';
  const ok=gateway&&serviceReady&&Boolean(release);overall.dataset.statusOverall=ok?'ok':'attention';overall.textContent=ok?'الخدمات الأساسية متصلة الآن.':'إحدى الخدمات لا تستجيب الآن؛ أعد الفحص أو راجع فريق التشغيل.';
  $('[data-status-time]').textContent=`وقت الفحص: ${new Intl.DateTimeFormat('ar-SA',{dateStyle:'medium',timeStyle:'medium'}).format(new Date())}`;button.disabled=false;
 }
 document.addEventListener('DOMContentLoaded',()=>{$('[data-status-refresh]').addEventListener('click',refresh);refresh()});
})();
