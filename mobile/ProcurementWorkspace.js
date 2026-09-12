import React,{useEffect,useRef,useState} from 'react';
import {Alert,FlatList,Pressable,ScrollView,Text,View} from 'react-native';
import {appendProcurementPage,canSeeProcurementFinance,PROCUREMENT_STATES,procurementPageUrl,procurementQuantity,procurementStateLabel} from './procurement.mjs';

export default function ProcurementWorkspace({call,role,ui}){
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

 if(detail)return <ProcurementDetail data={detail} role={role} close={close} ui={ui}/>;
 const finance=canSeeProcurementFinance(role);
 return <FlatList contentContainerStyle={s.list} data={items} keyExtractor={item=>item.id} refreshing={busy&&!next} onRefresh={refresh}
  ListHeaderComponent={<View style={{gap:10}}><Text style={s.pageTitle}>مهام شراء الطلبات</Text><Text style={s.muted}>جمع مباشر من الموردين والمحلات بلا مخزن. هذه المساحة للمتابعة فقط ولا تسجل شراءً أو تسوية.</Text>{error!==''&&<Card><Text accessibilityRole="alert">{error}</Text><Btn title="إعادة المحاولة" disabled={busy} onPress={refresh}/></Card>}<ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={s.row}>{PROCUREMENT_STATES.map(([key,label])=><Btn key={key||'all'} title={label} kind={filter===key?'primary':'outline'} disabled={busy&&filter!==key} onPress={()=>setFilter(key)}/>)}</ScrollView></View>}
  ListEmptyComponent={!busy?<Card><Text>لا توجد مهام شراء ضمن هذا المرشح.</Text></Card>:null}
  renderItem={({item})=><Pressable accessibilityRole="button" accessibilityLabel={'فتح مهمة '+(item.order_number||item.id)} disabled={detailBusy} onPress={()=>open(item.id)}><Card><View style={s.between}><Text style={s.productTitle}>{item.order_number||'طلب بلا رقم'}</Text><Text>{procurementStateLabel(item.state)}</Text></View><Text>موظف الشراء: {item.assigned_name||'غير مسند'}</Text><Text>الأصناف {Number(item.requested_line_count)||0} · زيارات الشراء {Number(item.purchase_count)||0}</Text><Text>التكلفة الفعلية: {money(Number(item.actual_cost_total_halalas))}</Text>{finance&&<Text>مستحق الموظف: {money(Number(item.employee_reimbursement_outstanding_halalas))} · مستحق المورد: {money(Number(item.supplier_payable_outstanding_halalas))}</Text>}<Text style={s.muted}>آخر تحديث {when(item.updated_at||item.created_at)}</Text></Card></Pressable>}
  ListFooterComponent={next?<Btn title="عرض مهام أقدم" kind="outline" disabled={busy} onPress={loadMore}/>:null}/>;
}

function ProcurementDetail({data,role,close,ui}){
 const {Card,Btn,s,money,when}=ui,job=data.job||{},finance=canSeeProcurementFinance(role)&&data.financial_detail_included===true;
 const fundingName=value=>({company_paid:'دفع الشركة',employee_paid:'دفع الموظف',supplier_credit:'آجل المورد'})[value]||value;
 return <ScrollView contentContainerStyle={s.list}><View style={s.between}><Text style={s.pageTitle}>{job.order_number||'مهمة شراء'}</Text><Btn title="رجوع" kind="outline" onPress={close}/></View><Card><Text style={s.productTitle}>{procurementStateLabel(job.state)}</Text><Text>موظف الشراء: {job.assigned_name||'غير مسند'} · المراجعة {Number(job.revision)||0}</Text><Text style={s.muted}>آخر تحديث {when(job.updated_at||job.created_at)}</Text></Card>
  <Text style={s.productTitle}>الأصناف والكميات</Text>{(data.lines||[]).map(line=><Card key={line.line_id}><Text style={s.productTitle}>{line.name||'صنف'}</Text><Text>المطلوب {procurementQuantity(line.qty)} · جُمع {procurementQuantity(line.collected_qty)} · المتبقي {procurementQuantity(line.remaining_qty)}</Text></Card>)}{!(data.lines||[]).length&&<Card><Text>لا توجد أصناف مسجلة.</Text></Card>}
  <Card><Text>إجمالي العميل الحالي: {money(Number(data.customer_terms?.total_halalas))}</Text><Text style={s.muted}>بيانات اتصال العميل غير معروضة، وسعره لا يُعاد احتسابه من تكلفة المورد.</Text></Card>
  <Text style={s.productTitle}>زيارات الموردين</Text>{(data.purchases||[]).map(purchase=><Card key={purchase.id}><Text style={s.productTitle}>{purchase.supplier?.name||'مورد غير مسمى'} · {money(Number(purchase.total_actual_cost_halalas))}</Text><Text>{[purchase.pickup_site?.name,purchase.pickup_site?.city,purchase.pickup_site?.address_line].filter(Boolean).join(' — ')||'موقع الاستلام محفوظ'}</Text><Text>مرجع المستند: {purchase.document_reference||'غير مسجل'} · {when(purchase.created_at)}</Text>{(purchase.lines||[]).map((line,index)=><Text key={line.line_id||String(index)}>{procurementQuantity(line.collected_qty)} من {procurementQuantity(line.requested_qty)} · {money(Number(line.actual_cost_halalas))}{line.quality_note?' · '+line.quality_note:''}</Text>)}</Card>)}{!(data.purchases||[]).length&&<Card><Text>لم تُسجل زيارة شراء.</Text></Card>}
  <Text style={s.productTitle}>تمويل المشتريات</Text>{(data.funding||[]).map(entry=><Card key={entry.id}><Text>{fundingName(entry.funding_source)} · {money(Number(entry.principal_halalas))}</Text><Text>المتبقي للتسوية: {money(Number(entry.outstanding_halalas))}</Text></Card>)}{!(data.funding||[]).length&&<Card><Text>لم يُسجل مصدر تمويل.</Text></Card>}
  {finance?<><Text style={s.productTitle}>دفعات التسوية</Text>{(data.settlements||[]).map(entry=><Card key={entry.id}><Text>{money(Number(entry.amount_halalas))} · {entry.payment_reference||'بلا مرجع'}</Text><Text>{when(entry.created_at)}{entry.note?' · '+entry.note:''}</Text></Card>)}{!(data.settlements||[]).length&&<Card><Text>لا توجد دفعات تسوية.</Text></Card>}</>:<Card><Text>تفاصيل دفع التسويات محجوبة عن موظف الشراء، وتظهر للمالية والإدارة فقط.</Text></Card>}
  {data.shortage&&<Card><Text style={s.productTitle}>النقص: {data.shortage.state}</Text><Text>التخفيض المقترح: {money(Number(data.shortage.proposed_reduction_halalas))}</Text><Text>{data.shortage.reason||''}</Text></Card>}
  {data.handover&&<Card><Text style={s.productTitle}>عهدة التوصيل</Text><Text>{data.handover.accepted_at?'قبل المندوب العهدة':'بانتظار قبول المندوب'}</Text></Card>}
  <Text style={s.muted}>متابعة ومطابقة فقط؛ لا تنفذ هذه الشاشة شراءً أو دفعًا أو تعديلًا في الطلب.</Text></ScrollView>;
}
