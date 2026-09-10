// Geographic editing is a client input aid; PostGIS remains the coverage authority.
const MAX_POINTS=2000, TILE=256, MERCATOR_LIMIT=85.0511287798066;
const clone=value=>JSON.parse(JSON.stringify(value));
const same=(a,b)=>a[0]===b[0]&&a[1]===b[1];
export function coordinate(value){
 if(!Array.isArray(value)||value.length!==2||!value.every(Number.isFinite)||Math.abs(value[0])>180||Math.abs(value[1])>90)throw Error('إحداثيات غير صالحة: خط الطول ثم خط العرض');
 return [...value];
}
export function polygonRings(polygon){
 if(polygon?.type!=='Polygon'||!Array.isArray(polygon.coordinates)||!polygon.coordinates.length)throw Error('اختر حدودًا من نوع Polygon');
 let count=0;
 return polygon.coordinates.map(ring=>{
  if(!Array.isArray(ring)||ring.length<4||(count+=ring.length)>MAX_POINTS)throw Error('الحدود تحتاج ثلاث نقاط على الأقل، وبحد أقصى 2000 نقطة إجمالًا');
  const points=ring.map(coordinate);if(!same(points[0],points.at(-1)))throw Error('يجب إغلاق حدود المضلع');
  return points.slice(0,-1);
 });
}
export function closedPolygon(rings){
 const polygon={type:'Polygon',coordinates:rings.map(r=>r.length?[...r.map(coordinate),coordinate(r[0])]:[])};
 polygonRings(polygon);return polygon;
}
export function project(point,zoom){
 const [lng,latitude]=coordinate(point),lat=Math.max(-MERCATOR_LIMIT,Math.min(MERCATOR_LIMIT,latitude))*Math.PI/180,size=TILE*2**zoom;
 return [(lng+180)/360*size,(1-Math.asinh(Math.tan(lat))/Math.PI)/2*size];
}
export function unproject([x,y],zoom){
 const size=TILE*2**zoom;
 return [Math.max(-180,Math.min(180,x/size*360-180)),Math.atan(Math.sinh(Math.PI*(1-2*Math.max(0,Math.min(size,y))/size)))*180/Math.PI];
}
export function fitView(rings,width,height){
 const points=rings.flat();if(!points.length)return {center:[42.57,16.9],zoom:12};
 const world=points.map(p=>project(p,0)),xs=world.map(p=>p[0]),ys=world.map(p=>p[1]);
 const minX=Math.min(...xs),maxX=Math.max(...xs),minY=Math.min(...ys),maxY=Math.max(...ys);
 const zoom=Math.max(3,Math.min(18,Math.floor(Math.log2(Math.min(Math.max(50,width-90)/Math.max(maxX-minX,.000001),Math.max(50,height-90)/Math.max(maxY-minY,.000001))))));
 return {center:unproject([(minX+maxX)/2,(minY+maxY)/2],0),zoom};
}
export function visibleTiles(center,zoom,width,height){
 const c=project(center,zoom),left=c[0]-width/2,top=c[1]-height/2,n=2**zoom,tiles=[];
 for(let y=Math.max(0,Math.floor(top/TILE));y<=Math.min(n-1,Math.floor((top+height-1)/TILE));y++)for(let x=Math.max(0,Math.floor(left/TILE));x<=Math.min(n-1,Math.floor((left+width-1)/TILE));x++){
  tiles.push({key:`${zoom}/${x}/${y}`,left:x*TILE-left,top:y*TILE-top,url:`https://tile.openstreetmap.org/${zoom}/${x}/${y}.png`});
 }
 return tiles;
}
export function zoneMapMarkup(){return `<section class="zone-editor stack" aria-label="رسم حدود منطقة التوصيل">
 <p>ارسم الحدود بالنقر على الخريطة، أو أضف الإحداثيات أدناه. اسحب النقاط لتعديلها. يمكنك إضافة نطاق مستثنى من التوصيل داخل الحدود.</p>
 <div class="row wrap zone-toolbar"><button type="button" class="btn outline" data-map-mode="draw" aria-pressed="true">رسم نقاط</button><button type="button" class="btn outline" data-map-mode="pan" aria-pressed="false">تحريك الخريطة</button><button type="button" class="btn outline" data-map="undo">تراجع</button><button type="button" class="btn outline" data-map="fit">إظهار الحدود</button><button type="button" class="btn outline" data-map="tiles" aria-pressed="false">عرض خريطة الشوارع</button></div>
 <div class="zone-map" dir="ltr"><div class="zone-tiles" aria-hidden="true"></div><svg class="zone-canvas" tabindex="0" role="img" aria-label="حدود التوصيل: الأسهم لتحريك العرض، وأزرار التكبير لتغيير المقياس"><g class="zone-shapes"></g><g class="zone-handles"></g></svg><div class="zone-zoom"><button type="button" class="btn outline" data-map="zoom-in" aria-label="تكبير الخريطة">+</button><button type="button" class="btn outline" data-map="zoom-out" aria-label="تصغير الخريطة">−</button></div><div class="zone-attribution" hidden>© <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener noreferrer">OpenStreetMap contributors</a> · <a href="https://www.openstreetmap.org/fixthemap" target="_blank" rel="noopener noreferrer">تصحيح الخريطة</a></div></div>
 <p class="zone-map-status" role="status" aria-live="polite"></p><p class="zone-map-error" role="alert"></p>
 <div class="two-col"><label>النطاق<select data-map-ring></select></label><label>النقطة<select data-map-point></select></label></div>
 <div class="row wrap"><button type="button" class="btn outline" data-map="hole">إضافة نطاق مستثنى</button><button type="button" class="btn outline" data-map="remove-ring">حذف النطاق المحدد</button></div>
 <div class="two-col"><label>خط العرض<input data-map-lat type="number" min="-90" max="90" step="any" dir="ltr" inputmode="decimal"></label><label>خط الطول<input data-map-lng type="number" min="-180" max="180" step="any" dir="ltr" inputmode="decimal"></label></div>
 <div class="row wrap"><button type="button" class="btn outline" data-map="add-point">إضافة نقطة بالإحداثيات</button><button type="button" class="btn outline" data-map="update-point">تعديل النقطة المحددة</button><button type="button" class="btn outline" data-map="remove-point">حذف النقطة المحددة</button></div>
 <details class="zone-advanced"><summary>استيراد أو مراجعة GeoJSON</summary><label>الحدود بالإحداثيات<textarea name="polygon" rows="5" dir="ltr" spellcheck="false"></textarea></label><button type="button" class="btn outline" data-map="import">عرض الحدود المستوردة</button></details>
 </section>`}
export function mountZoneMap(container,initial=null){
 const root=container.querySelector('.zone-editor'),map=root.querySelector('.zone-map'),svg=root.querySelector('svg'),shapes=root.querySelector('.zone-shapes'),handles=root.querySelector('.zone-handles'),tileLayer=root.querySelector('.zone-tiles');
 const raw=root.querySelector('[name=polygon]'),ringSelect=root.querySelector('[data-map-ring]'),pointSelect=root.querySelector('[data-map-point]'),lat=root.querySelector('[data-map-lat]'),lng=root.querySelector('[data-map-lng]'),status=root.querySelector('.zone-map-status'),error=root.querySelector('.zone-map-error');
 let rings=initial?polygonRings(initial):[[]],ringIndex=0,pointIndex=-1,mode='draw',view=fitView(rings,map.clientWidth||600,map.clientHeight||360),showTiles=false,drag=null,history=[],lastRaw='',closed=false;
 const tileNodes=new Map(),ns='http://www.w3.org/2000/svg';
 function message(text=''){error.textContent=text}
 function dimensions(){return [map.clientWidth||600,map.clientHeight||360]}
 function remember(){history.push(clone(rings));if(history.length>30)history.shift()}
 function syncRaw(){try{raw.value=JSON.stringify(closedPolygon(rings),null,2)}catch{raw.value=''}lastRaw=raw.value}
 function importRaw(){if(!raw.value.trim())throw Error('ارسم ثلاث نقاط على الأقل للحدود');const next=polygonRings(JSON.parse(raw.value));remember();rings=next;ringIndex=0;pointIndex=-1;syncRaw();view=fitView(rings,...dimensions());render()}
 function ensureSynced(){if(raw.value!==lastRaw)importRaw()}
 function screen(point){const [w,h]=dimensions(),c=project(view.center,view.zoom),p=project(point,view.zoom);return [p[0]-c[0]+w/2,p[1]-c[1]+h/2]}
 function geo(x,y){const [w,h]=dimensions(),c=project(view.center,view.zoom);return unproject([c[0]+x-w/2,c[1]+y-h/2],view.zoom).map(n=>Number(n.toFixed(7)))}
 function selectOptions(element,values,selected){element.replaceChildren(...values.map(([value,label])=>{const option=document.createElement('option');option.value=String(value);option.textContent=label;return option}));element.value=String(selected)}
 function tiles(){
  tileLayer.style.transform='';
  if(!showTiles){tileLayer.replaceChildren();tileNodes.clear();return}
  const [w,h]=dimensions(),wanted=visibleTiles(view.center,view.zoom,w,h),keys=new Set(wanted.map(t=>t.key));
  for(const [key,node]of tileNodes)if(!keys.has(key)){node.remove();tileNodes.delete(key)}
  for(const t of wanted){let node=tileNodes.get(t.key);if(!node){node=document.createElement('img');node.alt='';node.width=TILE;node.height=TILE;node.draggable=false;node.referrerPolicy='origin';node.decoding='async';node.onload=()=>{if(!closed)node.dataset.loaded='true'};node.onerror=()=>{if(!closed&&showTiles){node.hidden=true;message('تعذر تحميل بعض الشوارع. يمكنك متابعة تحرير الإحداثيات؛ تحقّق من الحدود قبل الحفظ.')}};node.src=t.url;tileNodes.set(t.key,node);tileLayer.append(node)}node.style.left=t.left+'px';node.style.top=t.top+'px'}
 }
 function renderMap(loadTiles=true){
  const [w,h]=dimensions();svg.setAttribute('viewBox',`0 0 ${w} ${h}`);shapes.replaceChildren();handles.replaceChildren();
  const path=document.createElementNS(ns,'path');path.setAttribute('d',rings.filter(r=>r.length).map(r=>r.map((p,i)=>(i?'L':'M')+screen(p).join(' ')).join(' ')+(r.length>2?' Z':'')).join(' '));path.setAttribute('fill-rule','evenodd');path.setAttribute('class','zone-polygon');shapes.append(path);
  rings[ringIndex].forEach((point,i)=>{const [x,y]=screen(point),circle=document.createElementNS(ns,'circle');circle.setAttribute('cx',x);circle.setAttribute('cy',y);circle.setAttribute('r',i===pointIndex?'12':'10');circle.setAttribute('class','zone-vertex'+(i===pointIndex?' selected':''));circle.dataset.vertex=String(i);const title=document.createElementNS(ns,'title');title.textContent='النقطة '+(i+1);circle.append(title);handles.append(circle)});
  if(loadTiles)tiles();
 }
 function render(){
  ringIndex=Math.min(ringIndex,rings.length-1);pointIndex=Math.min(pointIndex,rings[ringIndex].length-1);
  selectOptions(ringSelect,rings.map((_,i)=>[i,i?'نطاق مستثنى '+i:'الحدود الخارجية']),ringIndex);
  selectOptions(pointSelect,[[-1,'اختر نقطة للتعديل'],...rings[ringIndex].map((_,i)=>[i,'نقطة '+(i+1)])],pointIndex);
  if(pointIndex>=0){lng.value=String(rings[ringIndex][pointIndex][0]);lat.value=String(rings[ringIndex][pointIndex][1])}else{lng.value='';lat.value=''}
  status.textContent=`${rings[ringIndex].length} نقطة في النطاق المحدد · تكبير ${view.zoom} · ${showTiles?'خريطة الشوارع':'عرض إحداثي، حمّل الشوارع للمراجعة'}`;
  root.querySelector('[data-map=undo]').disabled=!history.length;
  root.querySelector('[data-map=remove-ring]').disabled=ringIndex===0;
  for(const action of ['update-point','remove-point'])root.querySelector('[data-map='+action+']').disabled=pointIndex<0;
  root.querySelector('[data-map=zoom-in]').disabled=view.zoom>=18;root.querySelector('[data-map=zoom-out]').disabled=view.zoom<=3;
  for(const b of root.querySelectorAll('[data-map-mode]'))b.setAttribute('aria-pressed',String(b.dataset.mapMode===mode));
  root.querySelector('[data-map=tiles]').setAttribute('aria-pressed',String(showTiles));root.querySelector('.zone-attribution').hidden=!showTiles;
  map.dataset.mode=mode;renderMap();
 }
 function change(fn){ensureSynced();remember();fn();syncRaw();message();render()}
 function entered(){if(!lng.value.trim()||!lat.value.trim())throw Error('أدخل خط العرض وخط الطول');return coordinate([Number(lng.value),Number(lat.value)])}
 function add(point){if(rings.reduce((n,r)=>n+r.length+1,0)>=MAX_POINTS)throw Error('الحد الأقصى 2000 نقطة');if(rings[ringIndex].some(p=>same(p,point)))throw Error('هذه النقطة موجودة في النطاق');const position=pointIndex>=0?pointIndex+1:rings[ringIndex].length;rings[ringIndex].splice(position,0,point);pointIndex=position}
 const abort=new AbortController(),options={signal:abort.signal};
 root.addEventListener('click',e=>{
  const button=e.target.closest('[data-map],[data-map-mode]');if(!button)return;e.preventDefault();
  try{message();if(button.dataset.mapMode){mode=button.dataset.mapMode;render();return}
   switch(button.dataset.map){
    case 'zoom-in':view.zoom=Math.min(18,view.zoom+1);render();break;
    case 'zoom-out':view.zoom=Math.max(3,view.zoom-1);render();break;
    case 'tiles':showTiles=!showTiles;render();break;
    case 'fit':ensureSynced();view=fitView(rings,...dimensions());render();break;
    case 'undo':if(history.length){rings=history.pop();ringIndex=Math.min(ringIndex,rings.length-1);pointIndex=-1;syncRaw();render()}break;
    case 'hole':change(()=>{if(rings.some(r=>r.length<3))throw Error('أكمل النطاق الحالي بثلاث نقاط أولًا');rings.push([]);ringIndex=rings.length-1;pointIndex=-1});break;
    case 'remove-ring':if(ringIndex&&confirm('حذف هذا الاستثناء يضيف مساحته إلى نطاق التوصيل عند حفظ المنطقة. هل تؤكد؟'))change(()=>{rings.splice(ringIndex,1);ringIndex=0;pointIndex=-1});break;
    case 'add-point':{const point=entered();change(()=>add(point));break}
    case 'update-point':{const point=entered();if(pointIndex>=0)change(()=>{rings[ringIndex][pointIndex]=point});break}
    case 'remove-point':if(pointIndex>=0)change(()=>{rings[ringIndex].splice(pointIndex,1);pointIndex=-1});break;
    case 'import':importRaw();break;
   }
  }catch(err){message(err instanceof SyntaxError?'GeoJSON غير صالح':err.message)}
 },options);
 ringSelect.addEventListener('change',()=>{ringIndex=Number(ringSelect.value);pointIndex=-1;render()},options);
 pointSelect.addEventListener('change',()=>{pointIndex=Number(pointSelect.value);render()},options);
 function local(event){const b=svg.getBoundingClientRect();return [event.clientX-b.left,event.clientY-b.top]}
 svg.addEventListener('pointerdown',e=>{
  if(e.button!==0||drag)return;try{ensureSynced();message();const [x,y]=local(e),vertex=e.target.closest('[data-vertex]');drag={id:e.pointerId,x,y,lastX:x,lastY:y,center:[...view.center],before:clone(rings),vertex:vertex?Number(vertex.dataset.vertex):null,moved:false};if(vertex){pointIndex=drag.vertex;render()}svg.setPointerCapture(e.pointerId);e.preventDefault()}catch(err){message(err.message)}
 },options);
 svg.addEventListener('pointermove',e=>{
  if(!drag||drag.id!==e.pointerId)return;const [x,y]=local(e);drag.lastX=x;drag.lastY=y;if(Math.hypot(x-drag.x,y-drag.y)>4)drag.moved=true;
  if(drag.vertex!==null&&drag.moved){rings[ringIndex][drag.vertex]=geo(x,y);renderMap(false)}else if(mode==='pan'&&drag.moved){const center=project(drag.center,view.zoom);view.center=unproject([center[0]-(x-drag.x),center[1]-(y-drag.y)],view.zoom);tileLayer.style.transform=`translate(${x-drag.x}px,${y-drag.y}px)`;renderMap(false)}
 },options);
 function finish(e,cancel=false){if(!drag||drag.id!==e.pointerId)return;const d=drag;drag=null;try{
  if(cancel){rings=d.before;view.center=d.center}else if(d.vertex!==null&&d.moved){history.push(d.before);if(history.length>30)history.shift();syncRaw()}else if(d.vertex===null&&!d.moved&&mode==='draw'){remember();add(geo(d.lastX,d.lastY));syncRaw()}
  render();
 }catch(err){rings=d.before;syncRaw();render();message(err.message)}}
 svg.addEventListener('pointerup',e=>finish(e),options);svg.addEventListener('pointercancel',e=>finish(e,true),options);
 svg.addEventListener('keydown',e=>{const movement={ArrowLeft:[-70,0],ArrowRight:[70,0],ArrowUp:[0,-70],ArrowDown:[0,70]}[e.key];if(movement){e.preventDefault();const p=project(view.center,view.zoom);view.center=unproject([p[0]+movement[0],p[1]+movement[1]],view.zoom);render()}},options);
 const resize=new ResizeObserver(()=>renderMap());resize.observe(map);
 function destroy(){if(closed)return;closed=true;abort.abort();resize.disconnect();tileLayer.replaceChildren();tileNodes.clear()}
 container.addEventListener('close',destroy,{once:true});syncRaw();render();
 return {polygon(){ensureSynced();return closedPolygon(rings)},destroy};
}
