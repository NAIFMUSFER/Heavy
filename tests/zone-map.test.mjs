import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const map=await import('data:text/javascript;base64,'+Buffer.from(readFileSync(new URL('../assets/zone-map.js',import.meta.url),'utf8')).toString('base64'));
const outer=[[42,16],[43,16],[43,17],[42,17],[42,16]],hole=[[42.4,16.4],[42.6,16.4],[42.6,16.6],[42.4,16.6],[42.4,16.4]];
test('closed geographic boundaries retain exact coordinates and every exclusion without mutating source',()=>{
 const original={type:'Polygon',coordinates:[outer,hole]},before=JSON.stringify(original),rings=map.polygonRings(original);
 assert.equal(rings[0].length,4);assert.equal(rings[1].length,4);assert.deepEqual(map.closedPolygon(rings),original);rings[0][0][0]=0;assert.equal(JSON.stringify(original),before);
});
test('unfinished or malformed geometry cannot become a valid save payload',()=>{
 for(const bad of [null,{type:'MultiPolygon',coordinates:[]},{type:'Polygon',coordinates:[[[42,16],[43,16],[42,17]]]},{type:'Polygon',coordinates:[[[42,16],[43,16],[42,16]]]},{type:'Polygon',coordinates:[[...outer.slice(0,4),[42,15]]]},{type:'Polygon',coordinates:[[...outer.slice(0,4),[42,'16']]]}])assert.throws(()=>map.polygonRings(bad));
 assert.throws(()=>map.closedPolygon([outer.slice(0,-1),[]]));
 for(const p of [[181,1],[1,91],[NaN,16],[42,null],[42,16,2]])assert.throws(()=>map.coordinate(p));
});
test('point budget includes closing points and exclusions before server submission',()=>{
 const ring=Array.from({length:1999},(_,i)=>[42+i/100000,16]);assert.equal(map.polygonRings({type:'Polygon',coordinates:[[...ring,ring[0]]]}).length,1);
 assert.throws(()=>map.closedPolygon([ring,hole.slice(0,-1)]));
});
test('Mercator projection uses longitude first and geographic roundtrips remain accurate',()=>{
 assert.deepEqual(map.project([0,0],0),[128,128]);assert.deepEqual(map.unproject([128,128],0),[0,0]);
 for(const point of [[42.57,16.9],[46.6753,24.7136],[39.1925,21.4858],[-73.98,40.75]])for(const zoom of [3,12,18]){const actual=map.unproject(map.project(point,zoom),zoom);assert.ok(Math.abs(actual[0]-point[0])<1e-8);assert.ok(Math.abs(actual[1]-point[1])<1e-8)}
 assert.ok(map.project([43,17],12)[1]<map.project([43,16],12)[1]);
});
test('fit keeps all geographic rings in view on a narrow phone canvas',()=>{
 const rings=map.polygonRings({type:'Polygon',coordinates:[outer,hole]}),w=280,h=300,v=map.fitView(rings,w,h),center=map.project(v.center,v.zoom);
 for(const point of rings.flat()){const p=map.project(point,v.zoom);assert.ok(Math.abs(p[0]-center[0])<=w/2-40);assert.ok(Math.abs(p[1]-center[1])<=h/2-40)}
});
test('street tile requests are limited to the visible viewport and fixed HTTPS origin',()=>{
 const tiles=map.visibleTiles([42.57,16.9],12,600,360);assert.ok(tiles.length>=6&&tiles.length<=12);
 for(const tile of tiles){assert.match(tile.url,/^https:\/\/tile\.openstreetmap\.org\/12\/\d+\/\d+\.png$/);assert.ok(tile.left<600&&tile.left+256>0);assert.ok(tile.top<360&&tile.top+256>0)}
 for(const edge of [[180,85],[-180,-85]])for(const tile of map.visibleTiles(edge,3,600,360)){const [z,x,y]=tile.key.split('/').map(Number);assert.ok(x>=0&&y>=0&&x<2**z&&y<2**z)}
});
