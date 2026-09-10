// Server-only provider contracts. They are not included in public gateway assets.
export class ProviderError extends Error{
 constructor(code,{retryable=false,outcome='not_submitted'}={}){super(code);this.name='ProviderError';this.code=code;this.retryable=retryable;this.outcome=outcome}
}
export class NotificationProvider{
 constructor(channel){this.channel=channel}
 status(){return {channel:this.channel,state:'CONFIGURATION_REQUIRED'}}
 async send(){throw new ProviderError('PROVIDER_CONFIGURATION_REQUIRED')}
}
export class InAppProvider extends NotificationProvider{
 constructor(repository){super('in_app');if(typeof repository?.insertOnce!=='function')throw new ProviderError('IN_APP_REPOSITORY_REQUIRED');this.repository=repository}
 status(){return {channel:this.channel,state:'AVAILABLE'}}
 async send(message){
  if(!message?.eventId||!message?.userId||typeof message.title!=='string'||typeof message.body!=='string')throw new ProviderError('INVALID_NOTIFICATION');
  // insertOnce is a trusted transactional repository operation; it must persist
  // a unique eventId/userId result and reject a changed body for the same event.
  const record=await this.repository.insertOnce({eventId:message.eventId,userId:message.userId,title:message.title,body:message.body});
  if(!record?.id)throw new ProviderError('INVALID_PROVIDER_RESPONSE');
  return {channel:this.channel,status:'stored',id:record.id};
 }
}
export class SmsProvider extends NotificationProvider{constructor(){super('sms')}}
export class WhatsAppProvider extends NotificationProvider{constructor(){super('whatsapp')}}
export class PushProvider extends NotificationProvider{constructor(){super('push')}}
const email=value=>typeof value==='string'&&value.length<=254&&/^[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(value);
const domain=value=>typeof value==='string'&&value.length<=253&&/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(value);
export class ResendEmailProvider extends NotificationProvider{
 #key;#domain;#domainId;#from;#enabled;#fetch;#now;
 constructor({env={},fetchImpl=fetch,now=Date.now}={}){
  super('email');this.#enabled=env.JANA_EMAIL_ENABLED==='true';this.#key=env.JANA_RESEND_API_KEY;this.#domain=env.JANA_EMAIL_DOMAIN;this.#domainId=env.JANA_RESEND_DOMAIN_ID;this.#from=env.JANA_EMAIL_FROM;this.#fetch=fetchImpl;this.#now=now;
  if(this.#enabled&&(!this.#key||!domain(this.#domain)||!email(this.#from)||this.#from.split('@')[1]!==this.#domain||!/^[0-9a-f-]{36}$/i.test(this.#domainId||'')))throw new ProviderError('EMAIL_CONFIGURATION_INVALID');
 }
 status(){return {channel:this.channel,state:this.#enabled?'DOMAIN_VERIFICATION_REQUIRED':'DISABLED'}}
 async #request(path,{method='GET',body,key}={}){
  let response;
  try{response=await this.#fetch('https://api.resend.com'+path,{method,redirect:'error',signal:AbortSignal.timeout(8000),headers:{authorization:'Bearer '+this.#key,...(body?{'content-type':'application/json'}:{}),...(key?{'Idempotency-Key':key}:{})},...(body?{body:JSON.stringify(body)}:{})})}
  catch{throw new ProviderError('PROVIDER_UNAVAILABLE',{retryable:true,outcome:method==='POST'?'unknown':'not_submitted'})}
  if(!response.ok)throw new ProviderError('PROVIDER_REJECTED',{retryable:response.status===429||response.status>=500,outcome:method==='POST'&&response.status>=500?'unknown':'not_submitted'});
  try{return await response.json()}catch{throw new ProviderError('INVALID_PROVIDER_RESPONSE',{outcome:method==='POST'?'unknown':'not_submitted'})}
 }
 async send(message){
  if(!this.#enabled)throw new ProviderError('EMAIL_DISABLED');
  if(!message||!email(message.to)||typeof message.subject!=='string'||message.subject.length<1||message.subject.length>150||/[\r\n]/.test(message.subject)||typeof message.text!=='string'||message.text.length<1||message.text.length>10000||!/^[A-Za-z0-9:_-]{8,128}$/.test(message.idempotencyKey||''))throw new ProviderError('INVALID_NOTIFICATION');
  // Resend retains retry keys for 24 hours. Old uncertain jobs require manual
  // reconciliation; never blindly re-send them outside that window.
  const age=this.#now()-message.createdAt;
  if(!Number.isSafeInteger(message.createdAt)||age<0||age>=23*3600000)throw new ProviderError('DELIVERY_RECONCILIATION_REQUIRED');
  const verified=await this.#request('/domains/'+encodeURIComponent(this.#domainId));
  if(verified.id!==this.#domainId||verified.name!==this.#domain||verified.status!=='verified'||verified.capabilities?.sending!=='enabled')throw new ProviderError('EMAIL_DOMAIN_NOT_VERIFIED');
  const result=await this.#request('/emails',{method:'POST',key:message.idempotencyKey,body:{from:'JANA <'+this.#from+'>',to:[message.to],subject:message.subject,text:message.text}});
  if(typeof result.id!=='string'||!result.id)throw new ProviderError('INVALID_PROVIDER_RESPONSE',{outcome:'unknown'});
  return {channel:this.channel,status:'submitted',id:result.id}; // Not proof of recipient delivery.
 }
}
export function notificationProviders({env,repository,fetchImpl,now}={}){
 return {inApp:new InAppProvider(repository),email:new ResendEmailProvider({env,fetchImpl,now}),sms:new SmsProvider(),whatsapp:new WhatsAppProvider(),push:new PushProvider()};
}
