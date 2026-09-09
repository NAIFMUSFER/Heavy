// JANA live admin extensions: profitability dashboard + canonical product component editor.
dashboard=async function(){
  const [orders,reports]=await Promise.all([loadOrders(),get('/api/ops/reports')]);state.reports=reports;
  const margin=(Number(reports.gross_margin_bps||0)/100).toFixed(1)+'%';
  const daily=(reports.daily||[]).map(x=>`<tr><td>${esc(x.report_day)}</td><td>${Number(x.order_count||0)}</td><td>${money(Number(x.sales_halalas||0))}</td></tr>`).join('');
  const low=(reports.low_stock||[]).map(x=>`<tr><td>${esc(x.name)}</td><td>${Number(x.available_base||0)}</td></tr>`).join('');
  const exp=(reports.expiring_7d||[]).map(x=>`<tr><td>${esc(x.name)}</td><td>${Number(x.on_hand_base||0)}</td><td>${date(x.expires_at,false)}</td></tr>`).join('');
  const top=(reports.top_items||[]).map(x=>`<tr><td>${esc(x.item_name||x.name||'')}</td><td>${Number(x.qty||0)}</td></tr>`).join('');
  shell(`<div class="stat-grid">
    <div class="stat-card"><span>مبيعات مكتملة 7 أيام</span><strong class="stat-value">${money(Number(reports.sales_7d_halalas||0))}</strong></div>
    <div class="stat-card"><span>الربح الإجمالي التقديري</span><strong class="stat-value">${money(Number(reports.gross_profit_7d_halalas||0))}</strong></div>
    <div class="stat-card"><span>هامش الربح</span><strong class="stat-value">${margin}</strong></div>
    <div class="stat-card"><span>متوسط الطلب المكتمل</span><strong class="stat-value">${money(Number(reports.avg_completed_order_halalas||0))}</strong></div>
    <div class="stat-card"><span>قيمة المخزون الحالية</span><strong class="stat-value">${money(Number(reports.inventory_value_halalas||0))}</strong></div>
    <div class="stat-card"><span>نقد لدى المندوبين</span><strong class="stat-value">${money(Number(reports.cash_unsettled_halalas||0))}</strong></div>
  </div>
  <div class="ops-section"><div class="panel"><h2>المبيعات اليومية — آخر 7 أيام</h2><div class="table-wrap"><table class="data-table"><thead><tr><th>اليوم</th><th>الطلبات</th><th>المبيعات المكتملة</th></tr></thead><tbody>${daily||'<tr><td colspan="3">لا توجد بيانات مكتملة بعد.</td></tr>'}</tbody></table></div></div></div>
  <div class="ops-section"><div class="panel"><h2>أكثر المنتجات طلبًا</h2><div class="table-wrap"><table class="data-table"><thead><tr><th>المنتج</th><th>الكمية</th></tr></thead><tbody>${top||'<tr><td colspan="2">لا توجد بيانات.</td></tr>'}</tbody></table></div></div></div>
  <div class="ops-section"><div class="panel"><h2>أقل المخزون المتاح</h2><div class="table-wrap"><table class="data-table"><thead><tr><th>الصنف</th><th>المتاح</th></tr></thead><tbody>${low||'<tr><td colspan="2">لا توجد بيانات.</td></tr>'}</tbody></table></div></div></div>
  <div class="ops-section"><div class="panel"><h2>دفعات تنتهي خلال 7 أيام</h2><div class="table-wrap"><table class="data-table"><thead><tr><th>الصنف</th><th>الكمية</th><th>الانتهاء</th></tr></thead><tbody>${exp||'<tr><td colspan="3">لا توجد دفعات قريبة الانتهاء.</td></tr>'}</tbody></table></div></div></div>
  <p class="notice">الربح الإجمالي = المبيعات المكتملة ناقص التكاليف المسجلة والاستردادات المكتملة. لا يُعامل كتقرير محاسبي نهائي قبل إدخال جميع التكاليف.</p>`);
};

newVersion=function(b){
  const c=state.catalog||{offerings:[],stock:[]};
  const current=(c.offerings||[]).filter(x=>x.family_id===b.dataset.family).sort((a,z)=>Number(z.version)-Number(a.version))[0];
  if(!current){toast('تعذر العثور على الإصدار الحالي',true);return}
  const stock=(c.stock||[]).filter(x=>x.active);
  const optionHtml=(selected='')=>`<option value="">اختر الصنف</option>`+stock.map(s=>`<option value="${esc(s.id)}" ${s.id===selected?'selected':''}>${esc(s.name)} — ${esc(s.base_unit)}</option>`).join('');
  const row=(comp={})=>`<div class="panel component-edit"><div class="row wrap"><label style="flex:2">صنف المخزون<select name="stock_id" required>${optionHtml(comp.stock_id||'')}</select></label><label style="flex:1">الكمية بوحدة الأساس<input name="base_qty" type="number" min="1" step="1" required value="${Number(comp.base_qty||1)}"></label><label style="flex:1">القيمة المرجعية (ر.س)<input name="list_price" inputmode="decimal" value="${(Number(comp.list_price_halalas||0)/100).toFixed(2)}"></label><button type="button" class="btn danger small" data-remove-component>حذف</button></div></div>`;
  const d=modal('إصدار منتج جديد',`<form id="version-form" class="stack">${field('name','اسم المنتج',{value:current.name})}${field('price','السعر الجديد بالريال',{value:(Number(current.price_halalas)/100).toFixed(2)})}<label>الوصف<textarea name="description" rows="3">${esc(current.description||'')}</textarea></label><div class="row between"><strong>مكونات المنتج/السلة</strong><button type="button" class="btn outline small" id="add-component">+ مكوّن</button></div><div id="component-editor" class="stack">${(current.components||[]).map(row).join('')}</div><p class="notice">الأسماء ووحدات الأساس تُعاد قراءتها من سجل المخزون في الخادم. الإصدار السابق لا يُعدّل.</p><button class="btn primary">إنشاء الإصدار الجديد</button></form>`);
  const editor=$('#component-editor',d);$('#add-component',d).onclick=()=>editor.insertAdjacentHTML('beforeend',row({}));
  editor.addEventListener('click',e=>{const x=e.target.closest('[data-remove-component]');if(!x)return;const rows=$$('.component-edit',editor);if(rows.length<=1){toast('يجب وجود مكوّن واحد على الأقل',true);return}x.closest('.component-edit').remove()});
  $('#version-form',d).onsubmit=e=>{e.preventDefault();const x=formData(e.target);const comps=$$('.component-edit',editor).map(r=>{const sid=$('select[name="stock_id"]',r).value;const qty=Number($('input[name="base_qty"]',r).value);const lp=parseMoney($('input[name="list_price"]',r).value||'0');if(!sid||!Number.isSafeInteger(qty)||qty<=0)throw new Error('راجع مكونات المنتج والكميات');return {stock_id:sid,base_qty:qty,list_price_halalas:lp}});busy($('button[type="submit"]',e.target),async()=>{await post(`/api/ops/families/${b.dataset.family}/versions`,{name:x.name,description:x.description||'',price_halalas:parseMoney(x.price),components:comps});state.catalog=null;closeModal();toast('تم إنشاء إصدار جديد بمكونات مثبتة في الخادم');await catalogPage()}).catch(()=>{})};
};
