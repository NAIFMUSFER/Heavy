import React,{useRef,useState} from 'react';
import {Alert,Linking,Text,View} from 'react-native';
import {orderFacts,orderLinks,trackingView} from './order.mjs';

export default function OrderDetails({order,call,onRefresh,onSupport,children,ui}){
 const {Card,Btn,s,money,when,statusLabel}=ui;
 const [busy,setBusy]=useState(false),[tracking,setTracking]=useState(null),[code,setCode]=useState(null);
 const locked=useRef(false),facts=orderFacts(order),address=facts.address,slot=facts.slot,links=orderLinks(address);
 async function run(fn){if(locked.current)return;locked.current=true;setBusy(true);try{await fn()}catch(e){Alert.alert('تعذر التنفيذ',e.message)}finally{locked.current=false;setBusy(false)}}
 const track=trackingView(tracking?{...tracking,delivery_state:order.delivery_state}:null);
 return <>
  <Card><Text style={s.productTitle}>{order.number}</Text><Text>{statusLabel(order.status)} · {statusLabel(order.fulfillment_state)} · {statusLabel(order.delivery_state)}</Text><Text>{statusLabel(order.payment_state)}</Text><Text>{when(order.created_at)}</Text></Card>
  <Card><Text style={s.productTitle}>تفاصيل التوصيل</Text><Text>{[address.city,address.district,address.street,address.details].filter(Boolean).join('، ')||'تفاصيل العنوان غير مسجلة'}</Text>
   {(address.building||address.floor||address.apartment)&&<Text>{[address.building&&'مبنى '+address.building,address.floor&&'طابق '+address.floor,address.apartment&&'وحدة '+address.apartment].filter(Boolean).join(' · ')}</Text>}
   <Text>{address.recipient_name} · {address.recipient_phone}</Text>{!!address.notes&&<Text>{address.notes}</Text>}
   <Text>{slot.starts_at&&slot.ends_at?`الموعد المحجوز: ${when(slot.starts_at)} — ${when(slot.ends_at)}`:'موعد التوصيل غير مسجل'}</Text>
   {!!links.map&&<Btn title="موقع التوصيل على Google Maps" kind="outline" disabled={busy} onPress={()=>run(()=>Linking.openURL(links.map))}/>}
  </Card>
  <Card><Text style={s.productTitle}>أصناف الطلب والمبالغ</Text>{facts.lines.map((line,i)=><View key={line.line_id||String(i)} style={s.between}><View style={{flex:1}}><Text>{line.name} × {line.qty}</Text>{line.actual_base_qty!=null&&<Text style={s.muted}>الكمية المجهزة: {line.actual_base_qty} {line.components?.[0]?.base_unit==='piece'?'قطعة':'جرام'}</Text>}</View><Text>{money(line.line_total_halalas)}</Text></View>)}
   {Number.isSafeInteger(order.snapshot?.delivery_fee_halalas)&&<Text>رسوم التوصيل: {money(order.snapshot.delivery_fee_halalas)}</Text>}{order.snapshot?.discount_halalas>0&&<Text>الخصم: −{money(order.snapshot.discount_halalas)}</Text>}
   <Text style={s.price}>إجمالي الطلب: {money(facts.total)}</Text><Text>المبلغ المحصّل: {money(facts.collected)}</Text><Text>المبلغ المُعاد لك: {money(facts.refunded)}</Text><Text>المتبقي للتحصيل: {money(facts.due)}</Text>
  </Card>
  <Card><Text style={s.productTitle}>تحديثات الطلب</Text>{order.timeline_has_earlier&&<Text style={s.muted}>أحدث 100 تحديث مسجل لهذا الطلب.</Text>}{facts.timeline.length?facts.timeline.map(event=><View key={event.id} style={{borderRightWidth:3,borderColor:'#1b563d',paddingRight:10,gap:4}}><Text>{event.title}</Text><Text style={s.muted}>{when(event.created_at)}</Text></View>):<Text>لا توجد تحديثات مؤرخة متاحة.</Text>}</Card>
  <Card><Text style={s.productTitle}>موقع المندوب</Text><Text>{tracking?track.message:'اضغط التحديث لمعرفة آخر موقع مسجل.'}</Text>{track.updatedAt&&<Text>وقت التسجيل: {when(track.updatedAt)}</Text>}{track.accuracy!=null&&<Text>دقة الموقع التقريبية: {track.accuracy} متر</Text>}{!!track.map&&<Btn title="فتح آخر موقع مسجل" kind="outline" disabled={busy} onPress={()=>run(()=>Linking.openURL(track.map))}/>}
   <Btn title="تحديث موقع المندوب" kind="outline" disabled={busy} onPress={()=>run(async()=>setTracking(await call('/api/orders/'+order.id+'/tracking')))}/>
  </Card>
  {children}
  {!!code&&facts.canRenewCode&&<Card><Text style={s.productTitle}>رمز التسليم الجديد: {code.delivery_code}</Text><Text>لا تشاركه إلا عند استلام الطلب. الرمز السابق لم يعد صالحًا.</Text><Text>ينتهي: {when(code.expires_at)}</Text></Card>}
  {facts.canRenewCode&&<Btn title="تجديد رمز التسليم" kind="outline" disabled={busy} onPress={()=>Alert.alert('تجديد رمز التسليم','سيُلغى الرمز السابق. احتفظ بالرمز الجديد حتى الاستلام.',[{text:'رجوع',style:'cancel'},{text:'تجديد',onPress:()=>run(async()=>setCode(await call('/api/orders/'+order.id+'/delivery-code',{method:'POST'})))}])}/>}
  {facts.canCancel&&<Btn title="إلغاء قبل التجهيز" kind="outline" disabled={busy} onPress={()=>Alert.alert('إلغاء الطلب','إلغاء هذا الطلب قبل بدء تجهيزه؟',[{text:'رجوع',style:'cancel'},{text:'إلغاء الطلب',style:'destructive',onPress:()=>run(async()=>{await call('/api/orders/'+order.id+'/cancel',{method:'POST'});await onRefresh();})}])}/>}
  <Btn title="تحديث الطلب" kind="outline" disabled={busy} onPress={()=>run(onRefresh)}/><Btn title="الدعم" kind="outline" disabled={busy} onPress={onSupport}/>
 </>;
}
