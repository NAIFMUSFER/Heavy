import React,{useEffect,useState} from 'react';
import {Alert,AppState,Text,View} from 'react-native';
import StorePolicies from './StorePolicies.js';
import {quoteState,quoteRemaining} from './checkout.mjs';

export default function CheckoutReview({checkout,state,call,onConfirmed,onReleased,onSignIn,ui}){
 const {Card,Btn,s,money,when}=ui,[readyPolicy,setReadyPolicy]=useState(null),[,tick]=useState(0);
 const q=state.quote,status=quoteState(q,checkout.elapsed()),seconds=quoteRemaining(q,checkout.elapsed());
 const run=async fn=>{try{await fn()}catch{/* The shared checkout state retains the actionable error. */}};
 useEffect(()=>{setReadyPolicy(null)},[q?.id]);
 useEffect(()=>{
  const timer=setInterval(()=>tick(n=>n+1),1000);
  const subscription=AppState.addEventListener('change',value=>{if(value==='active')run(()=>checkout.refresh())});
  return()=>{clearInterval(timer);subscription.remove()};
 },[checkout]);
 if(!state.pending)return <Text>لا توجد مراجعة طلب معلّقة.</Text>;
 return <View>
  {state.error!==''&&<Card><Text accessibilityRole="alert">{state.error}</Text></Card>}
  {state.errorCode==='AUTH_REQUIRED'&&<Btn title="تسجيل الدخول لاستكمال المراجعة" onPress={onSignIn}/>}
  {state.pending.attempted&&status!=='ordered'&&<Card><Text>سبق الضغط على التأكيد. تحقّق من حالة هذا الحجز لمعرفة النتيجة قبل بدء طلب آخر.</Text></Card>}
  {status==='ordered'?<Card><Text style={s.productTitle}>يوجد طلب مسجّل: {q.order.number}</Text><Text>الحالة: {q.order.status==='cancelled'?'ملغى':'مسجّل في طلباتي'}</Text><Btn title="متابعة الطلب المسجل" disabled={state.busy} onPress={()=>run(onConfirmed)}/></Card>:<>
   {q&&<Card>{(q.lines||[]).map(x=><View key={x.offering_id||x.line_id} style={s.between}><View style={{flex:1}}><Text>{x.name} × {x.qty}</Text>{x.weight_policy&&<Text style={s.muted}>الوزن المسموح {x.weight_policy.min_base}–{x.weight_policy.max_base} جرام. النقص يخفض السعر والزيادة المسموحة مجانًا.</Text>}</View><Text>{money(x.line_total_halalas)}</Text></View>)}{q.discount_halalas>0&&<Text>خصم {q.coupon?.code}: −{money(q.discount_halalas)}</Text>}<Text>التوصيل {money(q.delivery_fee_halalas)}</Text><Text style={s.price}>الإجمالي {money(q.total_halalas)}</Text></Card>}
   <Text>{status==='active'?`متبقي لحجز السعر والمخزون ${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,'0')}`:status==='expired'?'انتهت مهلة حجز السعر. تحقّق من النتيجة أو ألغِ الحجز للعودة للسلة.':status==='cancelled'?'أُلغي حجز هذا العرض.':'حدّث حالة الحجز للمتابعة.'}</Text>
   {status==='active'&&q?.store_profile?.id&&<StorePolicies key={q.id} call={call} version={q.store_profile.id} onReady={setReadyPolicy} ui={{Card,Btn,s,when}}/>}
   <Text>الدفع عند الاستلام. تأكيد الطلب يعني الموافقة على شروط البيع المعروضة.</Text>
   <Btn title="تأكيد الطلب والموافقة على شروط البيع" disabled={state.busy||status!=='active'||!q?.store_profile?.id||readyPolicy!==q.store_profile.id} onPress={()=>run(async()=>{const order=await checkout.confirm(readyPolicy);if(order)await onConfirmed()})}/>
  </>}
  <Btn title={state.pending.attempted?'التحقق من نتيجة الطلب':'تحديث حالة الحجز'} kind="outline" disabled={state.busy} onPress={()=>run(()=>checkout.refresh())}/>
  {status!=='ordered'&&<Btn title="إلغاء الحجز والعودة للسلة" kind="outline" disabled={state.busy} onPress={()=>Alert.alert('إلغاء حجز عرض السعر','نحرر الحجز إذا لم يتحول إلى طلب. إن كان الطلب قد تأكد فسنظهره دون إلغائه.',[{text:'الاحتفاظ بالحجز',style:'cancel'},{text:'إلغاء الحجز',onPress:()=>run(async()=>{await checkout.cancel();if(!checkout.snapshot.pending)onReleased()})}])}/>}
 </View>;
}
