import React,{useEffect,useRef,useState} from 'react';
import {Linking,Platform,Switch,Text,View} from 'react-native';
import * as Location from 'expo-location';
import {addressPayload,googleMapsLink,googleMapsSearch,locationPoint,parseMapLocation} from './address.mjs';
import {currentDeliveryLocation} from './location.mjs';

export default function AddressEditor({address,user,onSave,call,ui}) {
  const {Input,Btn,Card,s}=ui;
  const [draft,setDraft]=useState(()=>({label:'المنزل',recipient_name:user?.name||'',recipient_phone:user?.phone||'',is_default:false,...address}));
  const [mapInput,setMapInput]=useState(''),[busy,setBusy]=useState(false),[error,setError]=useState(''),[status,setStatus]=useState(''),[manual,setManual]=useState(false);
  const revision=useRef(0),active=useRef(true),locked=useRef(false);
  useEffect(()=>{active.current=true;return()=>{active.current=false;revision.current++;};},[]);
  const v=k=>String(draft[k]??'');
  let mapLink='';try{mapLink=googleMapsLink(draft.latitude,draft.longitude);}catch{}
  function update(key,value){if(['latitude','longitude'].includes(key)){revision.current++;setStatus('');}setError('');setDraft(old=>({...old,[key]:value}));}
  async function run(fn){if(locked.current)return;locked.current=true;setBusy(true);setError('');try{await fn();}catch(e){if(active.current){setError(e.message||'تعذر تحديد الموقع');if(['latitude','longitude'].includes(e.field))setManual(true);}}finally{locked.current=false;if(active.current)setBusy(false);}}
  async function usePoint(load){const version=++revision.current;const {point,message}=await load();if(!active.current||version!==revision.current)return;const p=locationPoint(point.latitude,point.longitude);setDraft(old=>({...old,latitude:String(p.latitude),longitude:String(p.longitude)}));setStatus(message);}
  function openMap(url){return run(()=>Linking.openURL(url));}
  return <View style={{gap:12}}>
    <Card><Text style={s.productTitle}>موقع التوصيل</Text>
      <Btn title={busy?'جارٍ التنفيذ…':'استخدم موقعي الحالي'} disabled={busy} onPress={()=>run(()=>usePoint(async()=>{const coords=await currentDeliveryLocation({platform:Platform.OS,location:Location});return {point:coords,message:`تم تحديد موقعك${Number.isFinite(coords.accuracy)?` بدقة تقريبية ${Math.ceil(coords.accuracy)} متر`:''}. راجع الدبوس عند مدخل التوصيل.`};}))}/>
      <Btn title="ابحث في Google Maps" kind="outline" disabled={busy} onPress={()=>openMap(googleMapsSearch(draft))}/>
      <Text>اضغط مطولًا على موقع التوصيل في الخرائط، ثم انسخ رابط الدبوس أو إحداثياته والصقها هنا.</Text>
      <Input label="رابط Google Maps أو الإحداثيات" value={mapInput} maxLength={4096} autoCapitalize="none" autoCorrect={false} placeholder="16.5, 42.5" onChangeText={value=>{revision.current++;setMapInput(value);setError('');}}/>
      <Btn title="استخدم هذا الموقع" kind="outline" disabled={busy} onPress={()=>run(()=>usePoint(async()=>({point:parseMapLocation(mapInput)||await call('/api/maps/resolve',{method:'POST',body:{url:mapInput}}),message:'تم استيراد الموقع. راجع الدبوس ووصف المدخل قبل الحفظ.'})))}/>
      <Text accessibilityLiveRegion="polite">{status||(mapLink?`الموقع المحدد: ${v('latitude')}, ${v('longitude')}`:'لم يُحدد موقع صالح بعد.')}</Text>
      {!!mapLink&&<Btn title="راجع الدبوس في Google Maps" kind="outline" disabled={busy} onPress={()=>openMap(mapLink)}/>}
      <Btn title={manual?'إخفاء الإحداثيات':'إدخال الإحداثيات يدويًا'} kind="outline" onPress={()=>setManual(!manual)}/>
      {manual&&<><Input label="خط العرض" keyboardType="numbers-and-punctuation" value={v('latitude')} onChangeText={x=>update('latitude',x)}/><Input label="خط الطول" keyboardType="numbers-and-punctuation" value={v('longitude')} onChangeText={x=>update('longitude',x)}/></>}
    </Card>
    <Input label="اسم العنوان" value={v('label')} maxLength={40} onChangeText={x=>update('label',x)}/>
    <Input label="اسم المستلم" value={v('recipient_name')} maxLength={80} onChangeText={x=>update('recipient_name',x)}/>
    <Input label="رقم الجوال" keyboardType="phone-pad" value={v('recipient_phone')} maxLength={30} onChangeText={x=>update('recipient_phone',x)}/>
    {[['city','المدينة'],['district','الحي'],['street','الشارع'],['building','المبنى'],['floor','الدور'],['apartment','الشقة']].map(([k,label])=><Input key={k} label={label} value={v(k)} maxLength={100} onChangeText={x=>update(k,x)}/>)}
    <Input label="وصف العنوان" value={v('details')} maxLength={500} multiline placeholder="رقم المبنى والمدخل وأقرب علامة واضحة" onChangeText={x=>update('details',x)}/>
    <Input label="ملاحظات التوصيل" value={v('notes')} maxLength={500} multiline onChangeText={x=>update('notes',x)}/>
    <View style={s.between}><Text>اجعله العنوان الافتراضي</Text><Switch accessibilityLabel="اجعله العنوان الافتراضي" value={draft.is_default===true} onValueChange={x=>update('is_default',x)} disabled={busy}/></View>
    {!!error&&<Text accessibilityRole="alert" style={{color:'#a63e39'}}>{error}</Text>}
    <Text style={s.muted}>راجع الدبوس ووصف المدخل. يُفحص نطاق التوصيل الفعلي عند اختيار العنوان للطلب.</Text>
    <Btn title={busy?'جارٍ التنفيذ…':'حفظ العنوان'} disabled={busy} onPress={()=>run(()=>onSave(addressPayload(draft)))}/>
  </View>;
}
