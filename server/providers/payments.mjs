import {ProviderError} from './notifications.mjs';
export class PaymentProvider{
 status(){return {state:'CONFIGURATION_REQUIRED',methods:[]}}
 async prepare(){throw new ProviderError('PAYMENT_CONFIGURATION_REQUIRED')}
 async capture(){throw new ProviderError('PAYMENT_CONFIGURATION_REQUIRED')}
 async refund(){throw new ProviderError('PAYMENT_CONFIGURATION_REQUIRED')}
 async verifyWebhook(){throw new ProviderError('PAYMENT_CONFIGURATION_REQUIRED')}
}
export class CodPaymentProvider extends PaymentProvider{
 status(){return {state:'AVAILABLE',methods:['cod']}}
 async prepare({orderId,amountHalalas,currency='SAR'}){
  if(typeof orderId!=='string'||!orderId||currency!=='SAR'||!Number.isSafeInteger(amountHalalas)||amountHalalas<0)throw new ProviderError('INVALID_PAYMENT_TERMS');
  return {method:'cod',orderId,amountHalalas,currency,status:'awaiting_collection'};
 }
 async capture(){throw new ProviderError('USE_TRANSACTIONAL_COD_COLLECTION')}
 async refund(){throw new ProviderError('USE_AUDITED_COD_REFUND')}
 async verifyWebhook(){throw new ProviderError('COD_HAS_NO_PAYMENT_WEBHOOK')}
}
export function paymentProvider(method){if(method==='cod')return new CodPaymentProvider();return new PaymentProvider()}
