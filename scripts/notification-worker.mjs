import {setTimeout as pause} from 'node:timers/promises';
import {configuredWorker} from '../server/notification-worker.mjs';
const allowed=new Set(['NOTIFICATION_WORKER_DISABLED','EMAIL_DISABLED','EMAIL_CONFIGURATION_INVALID','NOTIFICATION_DATABASE_CONFIGURATION_REQUIRED','NOTIFICATION_DATABASE_UNAVAILABLE','NOTIFICATION_DATABASE_REJECTED','NOTIFICATION_DATABASE_RESPONSE_INVALID']);
let stopping=false;process.on('SIGTERM',()=>{stopping=true});process.on('SIGINT',()=>{stopping=true});
try{
 const run=configuredWorker();do{
  try{const result=await run();console.log(JSON.stringify({event:'jana_notification_worker',state:result.state}));if(result.state==='idle'&&!process.argv.includes('--once'))await pause(5000)}
  catch(e){console.error(JSON.stringify({event:'jana_notification_worker_error',code:allowed.has(e.code)?e.code:'WORKER_FAILED'}));if(process.argv.includes('--once'))throw e;await pause(5000)}
 }while(!stopping&&!process.argv.includes('--once'));
}catch(e){console.error(JSON.stringify({event:'jana_notification_worker_stopped',code:allowed.has(e.code)?e.code:'WORKER_FAILED'}));process.exitCode=1}
