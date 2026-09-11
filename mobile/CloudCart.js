import React,{useEffect,useState} from 'react';
import {Alert,ScrollView,Text} from 'react-native';
import {loadCatalog} from './catalog.mjs';
import {mergeSavedCart} from './saved-cart.mjs';

const confirm=message=>new Promise(resolve=>Alert.alert('مراجعة السلة',message,[{text:'إلغاء',style:'cancel',onPress:()=>resolve(false)},{text:'تأكيد',onPress:()=>resolve(true)}],{cancelable:true,onDismiss:()=>resolve(false)}));
export default function CloudCart({call,cart,catalog,onRestore,ui}){
 const {Card,Btn,s,money,when}=ui;
 const [saved,setSaved]=useState(null),[pending,setPending]=useState(false),[error,setError]=useState('');
 async function load(){setSaved(await call('/api/cart'))}
 async function run(fn){if(pending)return;setPending(true);setError('');try{await fn()}catch(e){setError(e.message||'تعذر تحديث السلة المحفوظة')}finally{setPending(false)}}
 useEffect(()=>{run(load)},[]);
 async function save(clear=false){
  if((clear||saved.items.length)&&!await confirm(clear?'مسح النسخة المحفوظة في الحساب؟ ستبقى سلة هذا الجهاز.':'استبدال النسخة المحفوظة باختيارات هذا الجهاز؟'))return;
  await call('/api/cart',{method:'PUT',body:{revision:saved.revision,items:clear?[]:cart.map(x=>({offering_family_id:x.family_id||catalog.find(p=>p.id===x.offering_id)?.family_id,quantity:x.quantity}))}});
  await load();Alert.alert('السلة','حُفظ التعديل في حسابك');
 }
 async function restore(){
  if(cart.length&&!await confirm('استبدال سلة هذا الجهاز بالنسخة المحفوظة والأسعار الحالية؟'))return;
  const fresh=await loadCatalog(call),next=mergeSavedCart([],saved.items,fresh);await onRestore(next,fresh);
 }
 const unavailable=saved?.items.some(x=>!x.available);
 return <ScrollView contentContainerStyle={s.list}><Text style={s.pageTitle}>السلة المحفوظة في حسابي</Text><Text>احفظ نسخة من اختياراتك واستعدها على جهاز آخر. الحفظ لا يحجز الأصناف، وتُراجع الأسعار والتوفر عند الطلب.</Text>{error!==''&&<Card><Text accessibilityRole="alert">{error}</Text></Card>}<Btn title="تحديث النسخة المحفوظة" kind="outline" disabled={pending} onPress={()=>run(load)}/>{saved&&<><Text>آخر حفظ: {saved.updated_at?when(saved.updated_at):'لم تحفظ سلة بعد'}</Text>{saved.items.map(x=><Card key={x.offering_family_id}><Text>{x.name} · {x.size_label} × {x.quantity}</Text><Text>{money(x.price_halalas)} · {x.available?'متاح حاليًا':'غير متاح حاليًا'}</Text></Card>)}{!saved.items.length&&<Card><Text>لا توجد أصناف محفوظة.</Text></Card>}<Btn title="حفظ سلة هذا الجهاز في حسابي" disabled={pending||!cart.length} onPress={()=>run(()=>save())}/><Btn title="استعادة النسخة المحفوظة لهذا الجهاز" kind="outline" disabled={pending||!saved.items.length||unavailable} onPress={()=>run(restore)}/><Btn title="مسح النسخة المحفوظة" kind="outline" disabled={pending||!saved.items.length} onPress={()=>run(()=>save(true))}/>{unavailable&&<Text>توجد أصناف غير متاحة. تبقى محفوظة حتى تتوفر أو تحفظ اختيارًا جديدًا.</Text>}</>}</ScrollView>;
}
