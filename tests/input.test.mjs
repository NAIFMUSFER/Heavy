import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {moneyValue,integerValue,saudiDateValue} from '../mobile/input.mjs';
import {parseMoney,workspacePath} from '../assets/common.js';
test('web and mobile share number/date validation with only the import extension differing',()=>assert.equal(readFileSync('assets/input.js','utf8').replace("'./address.js'","'./address.mjs'"),readFileSync('mobile/input.mjs','utf8')));
test('amounts support Arabic, Persian and Latin digits without floating-point rounding',()=>{
 for(const parse of [moneyValue,parseMoney]){
  for(const value of ['12.34','١٢٫٣٤','۱۲٫۳۴','\u200f١٢.٣٤\u200e'])assert.equal(parse(value),1234);
  assert.equal(parse('0.29'),29);assert.equal(parse('١٢'),1200);assert.equal(parse('0001.1'),110);assert.equal(parse('0'),0);
  assert.equal(parse('90071992547409.91'),Number.MAX_SAFE_INTEGER);
 }
});
test('ambiguous, negative, empty, excessive-precision and unsafe amounts are rejected',()=>{
 for(const value of ['12.345','١٢٫٣٤٥','',' ',null,undefined,true,{},'1,000','١٬٠٠٠','١،٥','-1','+1','1e2','0x10','1.2.3','90071992547409.92'])assert.throws(()=>moneyValue(value));
});
test('localized list quantities and ratings preserve integer bounds',()=>{
 assert.equal(integerValue('۲۰',{min:0,max:20}),20);assert.equal(integerValue('٥',{min:1,max:5}),5);
 for(const value of ['','١٫٥','-1','21','2e1',null])assert.throws(()=>integerValue(value,{min:0,max:20}));
});
test('Saudi dates support Arabic digits and reject impossible calendar values',()=>{
 assert.equal(saudiDateValue('٢٠٢٧-٠١-٣١ ١٠:٠٠'),Date.parse('2027-01-31T07:00:00Z'));
 for(const value of ['2027-02-30 10:00','2027-01-31 24:00','2027-01-31 10:60',null,'31/01/2027 10:00'])assert.throws(()=>saudiDateValue(value));
});
test('every permitted operations role points to an actual served workspace',()=>{
 for(const role of ['admin','inventory','finance','support'])assert.equal(workspacePath(role),'/admin.html');
 assert.equal(workspacePath('picker'),'/picker.html');assert.equal(workspacePath('courier'),'/courier.html');assert.equal(workspacePath('customer'),null);assert.equal(workspacePath('unknown'),null);
});
