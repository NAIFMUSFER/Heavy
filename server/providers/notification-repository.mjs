import {ProviderError} from './notifications.mjs';
// Explicit dedicated environment names; never pick up unrelated project credentials.
export class NotificationRepository{
 #key;#fetch;
 constructor({env={},fetchImpl=fetch}={}){
  if(env.JANA_SUPABASE_URL!=='https://jjdsajiwoqanefmnikls.supabase.co'||!env.JANA_SUPABASE_SERVICE_ROLE_KEY)throw new ProviderError('NOTIFICATION_DATABASE_CONFIGURATION_REQUIRED');
  this.#key=env.JANA_SUPABASE_SERVICE_ROLE_KEY;this.#fetch=fetchImpl;
 }
 async #rpc(name,body){
  let r;try{r=await this.#fetch('https://jjdsajiwoqanefmnikls.supabase.co/rest/v1/rpc/'+name,{method:'POST',redirect:'error',signal:AbortSignal.timeout(10000),headers:{apikey:this.#key,authorization:'Bearer '+this.#key,'content-type':'application/json'},body:JSON.stringify(body)})}catch{throw new ProviderError('NOTIFICATION_DATABASE_UNAVAILABLE')}
  if(!r.ok)throw new ProviderError('NOTIFICATION_DATABASE_REJECTED');
  try{return await r.json()}catch{throw new ProviderError('NOTIFICATION_DATABASE_RESPONSE_INVALID')}
 }
 insertOnce({eventId,userId,title,body}){return this.#rpc('jana_notification_insert_once',{p_event_id:eventId,p_user_id:userId,p_title:title,p_body:body})}
 claim(channel,provider,scope){return this.#rpc('jana_notification_claim',{p_channel:channel,p_provider:provider,p_provider_scope:scope})}
 finish(job,result){return this.#rpc('jana_notification_finish',{p_job_id:job.id,p_lease_id:job.lease_id,p_result:result})}
}
