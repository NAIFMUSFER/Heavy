import React,{useEffect,useState} from 'react';
import {Text,View} from 'react-native';
export default function StorePolicies({call,version,onReady,ui}){
 const {Card,Btn,s,when}=ui;const [data,setData]=useState(null),[error,setError]=useState(''),[attempt,setAttempt]=useState(0);
 useEffect(()=>{let current=true;setData(null);setError('');call('/api/storefront'+(version?'?version='+encodeURIComponent(version):'')).then(r=>{if(!current)return;if(version&&r.published?.id!==version)throw Error('تعذر مطابقة إصدار شروط البيع');setData(r);onReady?.(r.published?.id||null)}).catch(e=>{if(current)setError(e.message)});return()=>{current=false}},[version,attempt]);
 if(error)return <Card><Text accessibilityRole="alert">{error}</Text><Btn title="إعادة تحميل السياسات" onPress={()=>setAttempt(n=>n+1)}/></Card>;
 if(!data)return <Text>جارٍ تحميل بيانات المتجر والسياسات…</Text>;
 if(!data.published)return <Card><Text>{data.message||'لم تُنشر بيانات المتجر بعد.'}</Text></Card>;
 const {profile:p,version:v,published_at}=data.published;
 return <View><Card><Text style={s.productTitle}>{p.display_name}</Text><Text selectable>{p.legal_name}</Text><Text selectable>رقم السجل أو وثيقة المنشأة: {p.registration_number}</Text><Text selectable>{p.business_address}</Text><Text selectable>الهاتف: {p.phone}</Text><Text selectable>البريد: {p.email}</Text><Text>ساعات الدعم: {p.support_hours}</Text><Text>{p.tax_status==='registered'?'رقم التسجيل الضريبي: '+p.tax_number:'المنشأة غير مسجلة في ضريبة القيمة المضافة بحسب إفادة المالك.'}</Text><Text style={s.muted}>إصدار {v} · {when(published_at)}</Text></Card>{[['terms','شروط البيع'],['privacy','سياسة الخصوصية'],['delivery','التوصيل والبدائل'],['returns','الإلغاء والاسترداد']].map(([k,label])=><Card key={k}><Text style={s.productTitle}>{label}</Text><Text selectable>{p[k]}</Text></Card>)}</View>;
}
