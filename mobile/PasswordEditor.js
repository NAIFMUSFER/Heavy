import React,{useRef,useState} from 'react';
import {Text} from 'react-native';
import {passwordProblem} from './order.mjs';

export default function PasswordEditor({onSave,ui}){
 const {Input,Btn,s}=ui;
 const [current,setCurrent]=useState(''),[next,setNext]=useState(''),[confirmation,setConfirmation]=useState(''),[error,setError]=useState(''),[busy,setBusy]=useState(false);
 const locked=useRef(false);
 async function save(){
  if(locked.current)return;const problem=passwordProblem(current,next,confirmation);setError(problem);if(problem)return;
  locked.current=true;setBusy(true);
  try{await onSave(current,next);setCurrent('');setNext('');setConfirmation('')}
  catch(e){setError(e.code==='NETWORK_UNKNOWN'?'انقطع الاتصال ولم نتأكد من النتيجة. إذا انتهت جلستك فسجّل الدخول بالكلمة الجديدة.':e.message)}
  finally{locked.current=false;setBusy(false)}
 }
 return <><Text>بعد الحفظ تنتهي جلسات حسابك على جميع الأجهزة، ويلزم الدخول بكلمة المرور الجديدة.</Text>
  <Input label="كلمة المرور الحالية" secureTextEntry autoCapitalize="none" autoCorrect={false} textContentType="password" editable={!busy} value={current} onChangeText={setCurrent}/>
  <Input label="كلمة المرور الجديدة" secureTextEntry autoCapitalize="none" autoCorrect={false} textContentType="newPassword" editable={!busy} value={next} onChangeText={setNext}/>
  <Input label="تأكيد كلمة المرور الجديدة" secureTextEntry autoCapitalize="none" autoCorrect={false} textContentType="newPassword" editable={!busy} value={confirmation} onChangeText={setConfirmation}/>
  <Text style={s.muted}>12 حرفًا على الأقل وبحد أقصى 72 بايت.</Text>{!!error&&<Text accessibilityRole="alert" style={{color:'#a53737'}}>{error}</Text>}
  <Btn title={busy?'جارٍ الحفظ…':'حفظ كلمة المرور وإنهاء الجلسات'} disabled={busy} onPress={save}/>
 </>;
}
