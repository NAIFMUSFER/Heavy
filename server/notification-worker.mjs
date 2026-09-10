import {createHash} from 'node:crypto';
import {ResendEmailProvider,ProviderError} from './providers/notifications.mjs';
import {NotificationRepository} from './providers/notification-repository.mjs';
const allowedErrors=new Set(['PROVIDER_UNAVAILABLE','PROVIDER_REJECTED','INVALID_PROVIDER_RESPONSE','EMAIL_DISABLED','EMAIL_CONFIGURATION_INVALID','INVALID_NOTIFICATION','EMAIL_DOMAIN_NOT_VERIFIED','DELIVERY_RECONCILIATION_REQUIRED']);
export function resendScope(env){return createHash('sha256').update(JSON.stringify([env.JANA_RESEND_DOMAIN_ID,env.JANA_EMAIL_DOMAIN,env.JANA_EMAIL_FROM])).digest('hex')}
export async function deliverNext({repository,provider,scope,now=Date.now}){
 const job=await repository.claim('email','resend',scope);if(!job)return {state:'idle'};
 let result;
 try{
  if(job.channel!=='email'||job.provider!=='resend'||job.provider_scope!==scope||now()>=job.retry_until)throw new ProviderError('DELIVERY_RECONCILIATION_REQUIRED');
  const sent=await provider.send({to:job.recipient,subject:job.title,text:job.body,idempotencyKey:job.idempotency_key,createdAt:job.created_at});
  if(sent?.status!=='submitted'||sent?.channel!=='email'||typeof sent?.id!=='string'||!sent.id)throw new ProviderError('INVALID_PROVIDER_RESPONSE',{outcome:'unknown'});
  result={outcome:'submitted',retryable:false,provider_id:sent.id};
 }catch(e){
  // An unexpected exception may occur after submission; never infer failure to send.
  const known=e instanceof ProviderError&&allowedErrors.has(e.code);
  result={outcome:known&&e.outcome==='not_submitted'?'not_submitted':'unknown',retryable:known&&e.retryable===true,error_code:known?e.code:'UNEXPECTED_PROVIDER_FAILURE'};
 }
 // If acknowledgement fails, preserve the lease. A later claim uses the same
 // provider key within the durable retry window, or requires reconciliation.
 return repository.finish(job,result);
}
export function configuredWorker({env=process.env,fetchImpl=fetch,now=Date.now}={}){
 if(env.JANA_NOTIFICATION_WORKER_ENABLED!=='true')throw new ProviderError('NOTIFICATION_WORKER_DISABLED');
 if(env.JANA_EMAIL_ENABLED!=='true')throw new ProviderError('EMAIL_DISABLED');
 const repository=new NotificationRepository({env,fetchImpl});const provider=new ResendEmailProvider({env,fetchImpl,now});
 return ()=>deliverNext({repository,provider,scope:resendScope(env),now});
}
