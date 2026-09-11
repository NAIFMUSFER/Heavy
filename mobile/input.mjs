import {latinDigits} from './address.mjs';
const numeric=value=>typeof value==='string'||typeof value==='number'?latinDigits(value).replace(/٫/g,'.'):'';
export function moneyValue(value){
 const text=numeric(value);
 if(!/^\d+(\.\d{1,2})?$/.test(text))throw Error('أدخل مبلغًا صحيحًا بحد أقصى منزلتين عشريتين، مثل ١٢٫٥٠');
 const [whole,fraction='']=text.split('.');
 const amount=Number(whole+fraction.padEnd(2,'0'));
 if(!Number.isSafeInteger(amount))throw Error('المبلغ أكبر من المسموح');
 return amount;
}
export function integerValue(value,{min=0,max=Number.MAX_SAFE_INTEGER,label='الكمية'}={}){
 const text=numeric(value),number=Number(text);
 if(!/^\d+$/.test(text)||!Number.isSafeInteger(number)||number<min||number>max)throw Error(`راجع ${label}: أدخل عددًا صحيحًا من ${min} إلى ${max}`);
 return number;
}
export function saudiDateValue(value){
 const text=typeof value==='string'?latinDigits(value):'';
 if(!/^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}$/.test(text))throw Error('أدخل الموعد بصيغة 2026-10-15 09:00 بتوقيت السعودية');
 const local=text.replace(' ','T'),stamp=Date.parse(local+':00+03:00');
 if(!Number.isSafeInteger(stamp)||new Date(stamp+10800000).toISOString().slice(0,16)!==local)throw Error('تاريخ الموعد غير صحيح');
 return stamp;
}
