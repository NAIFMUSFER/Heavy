import React,{useEffect,useRef,useState} from 'react';
import {Alert,FlatList,Pressable,ScrollView,Text,TextInput,View} from 'react-native';
import {
 appendProcurementPage,canSeeProcurementFinance,procurementAdjustmentFacts,
 procurementAssignmentFacts,procurementPageUrl,procurementPurchaseFacts,
 procurementPurchasePayload,PROCUREMENT_STATES,procurementQuantity,procurementStateLabel
} from './procurement.mjs';

export default function ProcurementWorkspace({call,role,user,ui}){
 const {Card,Btn,s,money,when}=ui;
 const [filter,setFilter]=useState(''),[items,setItems]=useState([]),[next,setNext]=useState(null),[busy,setBusy]=useState(false),[error,setError]=useState(''),[detail,setDetail]=useState(null),[detailBusy,setDetailBusy]=useState(false);
 const listGeneration=useRef(0),detailGeneration=useRef(0);

 useEffect(()=>{
  const generation=++listGeneration.current;detailGeneration.current++;setItems([]);setNext(null);setDetail(null);setBusy(true);setError('');
  call(procurementPageUrl({state:filter})).then(data=>{if(generation!==listGeneration.current)return;setItems(data.items||[]);setNext(data.next||null)}).catch(e=>{if(generation===listGeneration.current)setError(e.message||'تعذر تحميل مهام الشراء')}).finally(()=>{if(generation===listGeneration.current)setBusy(false)});
  return()=>{listGeneration.current++;detailGeneration.current++};
 },[call,filter]);

 async function loadMore(){
  if(busy||!next)return;const generation=++listGeneration.current;setBusy(true);setError('');
  try{const data=await call(procurementPageUrl({state:filter,cursor:next}));if(generation!==listGeneration.current)return;setItems(rows=>appendProcurementPage(rows,data.items||[]));setNext(data.next||null)}
  catch(e){if(generation===listGeneration.current)setError(e.message||'تعذر تحميل مهام أقدم')}
  finally{if(generation===listGeneration.current)setBusy(false)}
 }
 async function refresh(){
  const generation=++listGeneration.current;setBusy(true);setError('');
  try{const data=await call(procurementPageUrl({state:filter}));if(generation!==listGeneration.current)return;setItems(data.items||[]);setNext(data.next||null)}
  catch(e){if(generation===listGeneration.current)setError(e.message||'تعذر تحديث المهام')}
  finally{if(generation===listGeneration.current)setBusy(false)}
 }
 async function open(id){
  const generation=++detailGeneration.current;setDetailBusy(true);
  try{const data=await call('/api/ops/procurement/'+encodeURIComponent(id));if(generation===detailGeneration.current)setDetail(data)}
  catch(e){if(generation===detailGeneration.current)Alert.alert('تعذر فتح المهمة',e.message)}
  finally{if(generation===detailGeneration.current)setDetailBusy(false)}
 }
 function close(){detailGeneration.current++;setDetail(null);setDetailBusy(false)}
 async function applied(id){await Promise.all([open(id),refresh()])}

 if(detail)return <ProcurementDetail data={detail} role={role} user={user} close={close} call={call} applied={applied} ui={ui}/>;
 const finance=canSeeProcurementFinance(role),capability=role==='picker'?'يمكنك تسجيل كل زيارة فعلية للمهمات المسندة إليك.':role==='admin'?'يمكنك تكليف موظف الشراء، والتسجيل إذا كانت المهمة مسندة إليك.':'هذه مساحة متابعة؛ التسجيل محصور بموظف الشراء المسند.';
 return <FlatList contentContainerStyle={s.list} data={items} keyExtractor={item=>item.id} refreshing={busy&&!next} onRefresh={refresh}
  ListHeaderComponent={<View style={{gap:10}}><Text style={s.pageTitle}>مهام شراء الطلبات</Text><Text style={s.muted}>جمع مباشر من الموردين والمحلات بلا مخزن. {capability} سعر العميل لا يُعاد احتسابه من تكلفة المورد، والتسوية إجراء مستقل.</Text>{error!==''&&<Card><Text accessibilityRole="alert">{error}</Text><Btn title="إعادة المحاولة" disabled={busy} onPress={refresh}/></Card>}<ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={s.row}>{PROCUREMENT_STATES.map(([key,label])=><Btn key={key||'all'} title={label} kind={filter===key?'primary':'outline'} disabled={busy&&filter!==key} onPress={()=>setFilter(key)}/>)}</ScrollView></View>}
  ListEmptyComponent={!busy?<Card><Text>لا توجد مهام شراء ضمن هذا المرشح.</Text></Card>:null}
  renderItem={({item})=><Pressable accessibilityRole="button" accessibilityLabel={'فتح مهمة '+(item.order_number||item.id)} disabled={detailBusy} onPress={()=>open(item.id)}><Card><View style={s.between}><Text style={s.productTitle}>{item.order_number||'طلب بلا رقم'}</Text><Text>{procurementStateLabel(item.state)}</Text></View><Text>موظف الشراء: {item.assigned_name||'غير مسند'}</Text><Text>الأصناف {Number(item.requested_line_count)||0} · زيارات الشراء {Number(item.purchase_count)||0}</Text><Text>التكلفة الفعلية: {money(Number(item.actual_cost_total_halalas))}</Text>{finance&&<Text>مستحق الموظف: {money(Number(item.employee_reimbursement_outstanding_halalas))} · مستحق المورد: {money(Number(item.supplier_payable_outstanding_halalas))}</Text>}<Text style={s.muted}>آخر تحديث {when(item.updated_at||item.created_at)}</Text></Card></Pressable>}
  ListFooterComponent={next?<Btn title="عرض مهام أقدم" kind="outline" disabled={busy} onPress={loadMore}/>:null}/>;
}

function ProcurementDetail({data,role,user,close,call,applied,ui}){
 const {Card,Btn,s,money,when}=ui,job=data.job||{},finance=canSeeProcurementFinance(role)&&data.financial_detail_included===true,adjustment=procurementAdjustmentFacts(data,role),assignment=procurementAssignmentFacts(data,role),purchase=procurementPurchaseFacts(data,user);
 const [reason,setReason]=useState(''),[adjusting,setAdjusting]=useState(false);
 const [staff,setStaff]=useState([]),[staffBusy,setStaffBusy]=useState(false),[staffError,setStaffError]=useState(''),[employeeId,setEmployeeId]=useState(''),[assignmentReason,setAssignmentReason]=useState(''),[assigning,setAssigning]=useState(false);
 const [sites,setSites]=useState([]),[sitesBusy,setSitesBusy]=useState(false),[sitesError,setSitesError]=useState(''),[siteId,setSiteId]=useState(''),[reference,setReference]=useState(''),[visitNote,setVisitNote]=useState(''),[drafts,setDrafts]=useState({}),[recording,setRecording]=useState(false);
 const staffGeneration=useRef(0),sitesGeneration=useRef(0);
 const fundingName=value=>({company_paid:'دفع الشركة',employee_paid:'دفع الموظف',supplier_credit:'آجل المورد'})[value]||value;

 useEffect(()=>{
  if(!assignment)return;const generation=++staffGeneration.current;setStaffBusy(true);setStaffError('');
  call('/api/ops/staff').then(result=>{if(generation!==staffGeneration.current)return;const choices=(result.items||[]).filter(row=>row.active&&['admin','picker'].includes(row.role)&&row.id!==assignment.assignedTo);setStaff(choices);setEmployeeId(choices[0]?.id||'')}).catch(e=>{if(generation===staffGeneration.current)setStaffError(e.message||'تعذر تحميل الموظفين')}).finally(()=>{if(generation===staffGeneration.current)setStaffBusy(false)});
  return()=>{staffGeneration.current++};
 },[call,assignment?.jobId,assignment?.revision]);

 useEffect(()=>{
  if(!purchase)return;const generation=++sitesGeneration.current;setSitesBusy(true);setSitesError('');
  (async()=>{const rows=[];let after=null;for(let page=0;page<10;page++){const result=await call('/api/ops/pickup-sites?limit=100'+(after?'&after_id='+encodeURIComponent(after):''));rows.push(...(result.items||[]));after=result.next||null;if(!after)return rows.filter(site=>site.active&&site.supplier_active)}throw Error('دليل الموردين أكبر من حد شاشة الجوال')})()
   .then(rows=>{if(generation!==sitesGeneration.current)return;setSites(rows);setSiteId(rows[0]?.id||'')}).catch(e=>{if(generation===sitesGeneration.current)setSitesError(e.message||'تعذر تحميل نقاط الاستلام')}).finally(()=>{if(generation===sitesGeneration.current)setSitesBusy(false)});
  return()=>{sitesGeneration.current++};
 },[call,purchase?.jobId,purchase?.revision]);

 function applyAdjustment(){
  const note=reason.trim();if(!adjustment||note.length<3||note.length>1000){Alert.alert('راجع سبب التطبيق','أدخل سببًا واضحًا من 3 إلى 1000 حرف.');return}
  Alert.alert('تطبيق التخفيض الموافق عليه',`الإجمالي: ${money(adjustment.before)} ← ${money(adjustment.after)}\nالتخفيض: ${money(adjustment.reduction)}\nلن تُضاف رسوم ولن يتغير السعر الأصلي.`,[{text:'رجوع',style:'cancel'},{text:'تطبيق التخفيض',style:'destructive',onPress:async()=>{setAdjusting(true);try{await call('/api/ops/procurement/'+encodeURIComponent(adjustment.jobId)+'/shortage-adjustment',{method:'POST',body:{request_id:adjustment.requestId,expected_revision:adjustment.revision,reason:note}});setReason('');await applied(adjustment.jobId);Alert.alert('تم التطبيق','أصبحت المهمة جاهزة لتسليم العهدة.')}catch(e){Alert.alert('تعذر تطبيق التخفيض',e.message)}finally{setAdjusting(false)}}}]);
 }
 function assign(){
  const employee=staff.find(row=>row.id===employeeId),note=assignmentReason.trim();if(!assignment||!employee||note.length<3||note.length>1000){Alert.alert('راجع التكليف','اختر موظفًا نشطًا وأدخل سببًا واضحًا.');return}
  Alert.alert('تأكيد التكليف',`تكليف ${employee.name} بجمع احتياجات هذا الطلب من الموردين؟`,[{text:'رجوع',style:'cancel'},{text:'حفظ التكليف',onPress:async()=>{setAssigning(true);try{await call('/api/ops/procurement/'+encodeURIComponent(assignment.jobId)+'/assignment',{method:'POST',body:{employee_id:employee.id,expected_revision:assignment.revision,reason:note}});setAssignmentReason('');await applied(assignment.jobId);Alert.alert('تم التكليف','حُفظ الموظف والسبب في سجل المهمة.')}catch(e){Alert.alert('تعذر التكليف',e.message)}finally{setAssigning(false)}}}]);
 }
 function setLine(lineId,key,value){setDrafts(current=>({...current,[lineId]:{...(current[lineId]||{}),[key]:value}}))}
 function recordPurchase(){
  let prepared;try{prepared=procurementPurchasePayload({facts:purchase,site:sites.find(row=>row.id===siteId),documentReference:reference,note:visitNote,drafts})}catch(e){Alert.alert('راجع سجل الشراء',e.message);return}
  Alert.alert('حفظ زيارة الشراء',`عدد الأصناف: ${prepared.body.lines.length}\nالتكلفة الفعلية: ${money(prepared.total)}\nلن يتغير سعر العميل أو المخزون، وليست هذه تسوية دفع.`,[{text:'رجوع',style:'cancel'},{text:'حفظ السجل',onPress:async()=>{setRecording(true);try{await call('/api/ops/procurement/'+encodeURIComponent(purchase.jobId)+'/purchases',{method:'POST',body:prepared.body});setReference('');setVisitNote('');setDrafts({});await applied(purchase.jobId);Alert.alert('تم الحفظ','سُجلت الكميات والتكلفة الفعلية ومستند الزيارة.')}catch(e){Alert.alert('تعذر حفظ الشراء',e.message)}finally{setRecording(false)}}}]);
 }

 return <ScrollView contentContainerStyle={s.list} keyboardShouldPersistTaps="handled"><View style={s.between}><Text style={s.pageTitle}>{job.order_number||'مهمة شراء'}</Text><Btn title="رجوع" kind="outline" onPress={close}/></View><Card><Text style={s.productTitle}>{procurementStateLabel(job.state)}</Text><Text>موظف الشراء: {job.assigned_name||'غير مسند'} · المراجعة {Number(job.revision)||0}</Text><Text style={s.muted}>آخر تحديث {when(job.updated_at||job.created_at)}</Text></Card>
  {assignment&&<Card><Text style={s.productTitle}>تكليف موظف الشراء</Text>{staffError!==''&&<Text accessibilityRole="alert">{staffError}</Text>}{staff.map(row=><Btn key={row.id} title={(employeeId===row.id?'✓ ':'')+row.name+' — '+(row.role==='picker'?'موظف شراء':'مدير')} kind={employeeId===row.id?'primary':'outline'} disabled={staffBusy||assigning} onPress={()=>setEmployeeId(row.id)}/>)}{!staffBusy&&!staff.length&&staffError===''&&<Text>لا يوجد موظف آخر نشط يمكن إعادة الإسناد إليه.</Text>}<TextInput accessibilityLabel="سبب التكليف" value={assignmentReason} onChangeText={setAssignmentReason} multiline maxLength={1000} editable={!assigning} placeholder="سبب التكليف أو إعادة الإسناد" placeholderTextColor="#89928d" textAlign="right" style={s.input}/><Text style={s.muted}>التكليف لا ينشئ مخزونًا ولا يغير سعر العميل أو يسجل دفعًا.</Text><Btn title="مراجعة التكليف وحفظه" disabled={staffBusy||assigning||!employeeId||assignmentReason.trim().length<3} onPress={assign}/></Card>}
  {purchase&&<Card><Text style={s.productTitle}>تسجيل زيارة شراء</Text>{sitesError!==''&&<Text accessibilityRole="alert">{sitesError}</Text>}<ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={s.row}>{sites.map(site=><Btn key={site.id} title={(siteId===site.id?'✓ ':'')+[site.supplier_name,site.name,site.city].filter(Boolean).join(' — ')} kind={siteId===site.id?'primary':'outline'} disabled={sitesBusy||recording} onPress={()=>setSiteId(site.id)}/>)}</ScrollView>{!sitesBusy&&!sites.length&&sitesError===''&&<Text>لا توجد نقطة استلام نشطة. راجع دليل الموردين دون إنشاء مخزن أو رصيد وهمي.</Text>}<TextInput accessibilityLabel="مرجع الفاتورة أو الإيصال" value={reference} onChangeText={setReference} maxLength={180} editable={!recording} placeholder="مرجع الفاتورة أو الإيصال" placeholderTextColor="#89928d" textAlign="right" style={s.input}/><TextInput accessibilityLabel="ملاحظة الزيارة" value={visitNote} onChangeText={setVisitNote} multiline maxLength={1000} editable={!recording} placeholder="ملاحظة الزيارة" placeholderTextColor="#89928d" textAlign="right" style={s.input}/>{purchase.lines.map(line=><View key={line.line_id} style={{gap:8}}><Text style={s.productTitle}>{line.name||'صنف'} · المتبقي {procurementQuantity(line.remaining_qty)}</Text><TextInput accessibilityLabel={'الكمية المجمعة '+(line.name||'')} value={drafts[line.line_id]?.quantity||''} onChangeText={value=>setLine(line.line_id,'quantity',value)} keyboardType="decimal-pad" editable={!recording} placeholder="الكمية المجمعة في هذه الزيارة" placeholderTextColor="#89928d" textAlign="right" style={s.input}/><TextInput accessibilityLabel={'التكلفة الفعلية '+(line.name||'')} value={drafts[line.line_id]?.cost||''} onChangeText={value=>setLine(line.line_id,'cost',value)} keyboardType="decimal-pad" editable={!recording} placeholder="تكلفتها الفعلية لدى المورد بالريال" placeholderTextColor="#89928d" textAlign="right" style={s.input}/><TextInput accessibilityLabel={'ملاحظة الجودة '+(line.name||'')} value={drafts[line.line_id]?.quality||''} onChangeText={value=>setLine(line.line_id,'quality',value)} maxLength={1000} editable={!recording} placeholder="ملاحظة الجودة والقبول" placeholderTextColor="#89928d" textAlign="right" style={s.input}/></View>)}<Text style={s.muted}>أدخل فقط ما استلمته فعليًا. التكلفة ليست سعر العميل، والحفظ لا ينشئ مخزونًا أو تسوية.</Text><Btn title="مراجعة سجل الشراء وحفظه" disabled={sitesBusy||recording||!siteId} onPress={recordPurchase}/></Card>}
  <Text style={s.productTitle}>الأصناف والكميات</Text>{(data.lines||[]).map(line=><Card key={line.line_id}><Text style={s.productTitle}>{line.name||'صنف'}</Text><Text>المطلوب {procurementQuantity(line.qty)} · جُمع {procurementQuantity(line.collected_qty)} · المتبقي {procurementQuantity(line.remaining_qty)}</Text></Card>)}{!(data.lines||[]).length&&<Card><Text>لا توجد أصناف مسجلة.</Text></Card>}
  <Card><Text>إجمالي العميل الحالي: {money(Number(data.customer_terms?.total_halalas))}</Text><Text style={s.muted}>بيانات اتصال العميل غير معروضة، وسعره لا يُعاد احتسابه من تكلفة المورد.</Text></Card>
  <Text style={s.productTitle}>زيارات الموردين</Text>{(data.purchases||[]).map(record=><Card key={record.id}><Text style={s.productTitle}>{record.supplier?.name||'مورد غير مسمى'} · {money(Number(record.total_actual_cost_halalas))}</Text><Text>{[record.pickup_site?.name,record.pickup_site?.city,record.pickup_site?.address_line].filter(Boolean).join(' — ')||'موقع الاستلام محفوظ'}</Text><Text>مرجع المستند: {record.document_reference||'غير مسجل'} · {when(record.created_at)}</Text>{(record.lines||[]).map((line,index)=><Text key={line.line_id||String(index)}>{procurementQuantity(line.collected_qty)} من {procurementQuantity(line.requested_qty)} · {money(Number(line.actual_cost_halalas))}{line.quality_note?' · '+line.quality_note:''}</Text>)}</Card>)}{!(data.purchases||[]).length&&<Card><Text>لم تُسجل زيارة شراء.</Text></Card>}
  <Text style={s.productTitle}>تمويل المشتريات</Text>{(data.funding||[]).map(entry=><Card key={entry.id}><Text>{fundingName(entry.funding_source)} · {money(Number(entry.principal_halalas))}</Text><Text>المتبقي للتسوية: {money(Number(entry.outstanding_halalas))}</Text></Card>)}{!(data.funding||[]).length&&<Card><Text>لم يُسجل مصدر تمويل.</Text></Card>}
  {finance?<><Text style={s.productTitle}>دفعات التسوية</Text>{(data.settlements||[]).map(entry=><Card key={entry.id}><Text>{money(Number(entry.amount_halalas))} · {entry.payment_reference||'بلا مرجع'}</Text><Text>{when(entry.created_at)}{entry.note?' · '+entry.note:''}</Text></Card>)}{!(data.settlements||[]).length&&<Card><Text>لا توجد دفعات تسوية.</Text></Card>}</>:<Card><Text>تفاصيل دفع التسويات محجوبة عن موظف الشراء، وتظهر للمالية والإدارة فقط.</Text></Card>}
  {data.shortage&&<Card><Text style={s.productTitle}>النقص: {data.shortage.state}</Text><Text>التخفيض المقترح: {money(Number(data.shortage.proposed_reduction_halalas))}</Text><Text>{data.shortage.reason||''}</Text></Card>}
  {adjustment&&<Card><Text style={s.productTitle}>تطبيق التخفيض الموافق عليه</Text><Text>الإجمالي الحالي: {money(adjustment.before)}</Text><Text>التخفيض المعتمد: − {money(adjustment.reduction)}</Text><Text>الإجمالي بعد التطبيق: {money(adjustment.after)}</Text><TextInput accessibilityLabel="سبب تطبيق التخفيض" value={reason} onChangeText={setReason} multiline maxLength={1000} editable={!adjusting} placeholder="سبب التطبيق في سجل التدقيق" placeholderTextColor="#89928d" textAlign="right" style={s.input}/><Text style={s.muted}>يحفظ السعر الأصلي ولا يضيف رسومًا أو يسجل دفعًا أو مخزونًا.</Text><Btn title="مراجعة التخفيض وتطبيقه" disabled={adjusting||reason.trim().length<3} onPress={applyAdjustment}/></Card>}
  {data.handover&&<Card><Text style={s.productTitle}>عهدة التوصيل</Text><Text>{data.handover.accepted_at?'قبل المندوب العهدة':'بانتظار قبول المندوب'}</Text></Card>}
  <Text style={s.muted}>التسجيل متاح فقط للموظف المسند؛ الدفع والتسوية وتسليم العهدة إجراءات مستقلة.</Text></ScrollView>;
}
