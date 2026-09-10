import React,{useMemo,useState} from 'react';
import {FlatList,Text,View} from 'react-native';
import {loadCatalog} from './catalog.mjs';
import {mergeSavedCart} from './saved-cart.mjs';

export default function BasketBuilder({catalog,cart,call,onAdd,ui}){
 const {Card,Btn,Input,s,money}=ui;
 const [selected,setSelected]=useState({}),[query,setQuery]=useState(''),[category,setCategory]=useState('all'),[pending,setPending]=useState(false),[error,setError]=useState('');
 const choices=useMemo(()=>catalog.filter(p=>p.kind!=='basket'&&(p.components||[]).length===1),[catalog]);
 const rows=choices.filter(p=>(category==='all'||p.category===category)&&p.name.includes(query.trim()));
 const items=Object.entries(selected).filter(([,quantity])=>quantity>0).map(([offering_family_id,quantity])=>({offering_family_id,quantity}));
 const total=items.reduce((n,x)=>n+(choices.find(p=>p.family_id===x.offering_family_id)?.price_halalas||0)*x.quantity,0);
 function change(p,delta){const quantity=(selected[p.family_id]||0)+delta;if(quantity<0||quantity>Math.min(20,p.available_units))return;if(quantity&&!selected[p.family_id]&&items.length>=40){setError('الحد الأقصى 40 صنفًا');return}setSelected(old=>({...old,[p.family_id]:quantity}));}
 async function add(){if(pending||!items.length)return;setPending(true);setError('');try{const fresh=await loadCatalog(call),next=mergeSavedCart(cart,items,fresh);onAdd(next,fresh)}catch(e){setError(e.message||'تعذر إضافة الاختيارات')}finally{setPending(false)}}
 return <FlatList contentContainerStyle={s.list} data={rows} keyExtractor={p=>p.id} ListHeaderComponent={<View><Text style={s.pageTitle}>كوّن سلتك</Text><Text>اختر الأصناف والأحجام. كل كمية تمثل عدد العبوات أو الأوزان المعروضة. تُراجع الأسعار والتوفر قبل تأكيد الطلب.</Text><Input label="ابحث عن صنف" value={query} onChangeText={setQuery}/><View style={s.row}>{[['all','الكل'],['fruit','فواكه'],['vegetables','خضار']].map(([k,n])=><Btn key={k} title={n} kind={category===k?'primary':'outline'} onPress={()=>setCategory(k)}/>)}</View>{error!==''&&<Card><Text accessibilityRole="alert">{error}</Text></Card>}</View>} ListEmptyComponent={<Card><Text>لا توجد أصناف متاحة لهذا الاختيار.</Text></Card>} renderItem={({item:p})=><Card><Text style={s.productTitle}>{p.name} · {p.size_label}</Text><Text>{money(p.price_halalas)} · المتوفر {p.available_units}</Text><View style={s.row}><Btn title="−" kind="outline" disabled={pending||!selected[p.family_id]} onPress={()=>change(p,-1)}/><Text>{selected[p.family_id]||0}</Text><Btn title="+" disabled={pending||(selected[p.family_id]||0)>=Math.min(20,p.available_units)} onPress={()=>change(p,1)}/></View></Card>} ListFooterComponent={<Card><Text style={s.pageTitle}>اختياراتك</Text>{items.map(x=>{const p=choices.find(p=>p.family_id===x.offering_family_id);return <Text key={x.offering_family_id}>{p.name} · {p.size_label} × {x.quantity} — {money(p.price_halalas*x.quantity)}</Text>})}<Text style={s.price}>الإجمالي المبدئي {money(total)}</Text><Text>يضاف التوصيل عند مراجعة الموعد، ولا يُحجز المخزون قبل عرض السعر.</Text><Btn title="إضافة الاختيارات إلى السلة" disabled={pending||!items.length} onPress={add}/></Card>}/>;
}
