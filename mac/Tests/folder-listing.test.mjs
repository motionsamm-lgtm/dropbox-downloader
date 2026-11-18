import test from 'node:test';
import assert from 'node:assert/strict';
import {discoverFolder,localComponent} from '../Sources/dropbox-folder.mjs';
const root='https://www.dropbox.com/scl/fo/root/hash?rlkey=public';
const href=(name,hash='hash')=>'https://www.dropbox.com/scl/fo/root/'+hash+'/'+encodeURIComponent(name)+'?rlkey=public';
const item=(filename,is_dir=false)=>({filename,is_dir,bytes:is_dir?null:123,href:href(filename,is_dir?'child-hash':'file-hash')});
function fixture(pages) {
 const calls=[];
 const request=async(url,options={})=>{
  if(options.method!=='POST')return new Response('',{headers:{'Set-Cookie':'__Host-js_csrf=anonymous-fixture; Secure; Path=/'}});
  const body=new URLSearchParams(options.body);calls.push(Object.fromEntries(body));
  assert.match(options.headers.Cookie,/__Host-js_csrf=anonymous-fixture/);
  const response=pages(body,calls.length);
  return new Response(JSON.stringify(response),{headers:{'Content-Type':'application/json'}});
 };
 return {request,calls};
}
test('public listing follows vouchers and each subfolder hash without signing in',async()=>{
 const f=fixture(body=>{
  if(body.get('sub_path')==='/nested'){
   assert.equal(body.get('secure_hash'),'child-hash');
   return {entries:[item('clip.mp4')],has_more_entries:false,total_num_entries:1};
  }
  if(!body.get('voucher'))return {entries:[item('first.mp4'),item('nested',true)],has_more_entries:true,next_request_voucher:'page-two',total_num_entries:3};
  return {entries:[item('last.mov')],has_more_entries:false,total_num_entries:3};
 });
 const manifest=await discoverFolder(root,f);
 assert.deepEqual(manifest.files.map(f=>f.local),['first.mp4','last.mov','nested/clip.mp4']);
 assert.equal(f.calls.length,3);assert.equal(f.calls[1].voucher,'page-two');
});
test('incomplete pages, repeated pages and wrong counts cannot become successful empty folders',async()=>{
 for(const page of [{entries:[]},{entries:[],has_more_entries:true},{entries:[],has_more_entries:false,total_num_entries:20}]){
  await assert.rejects(discoverFolder(root,fixture(()=>page)),/complete|next folder page|count changed/);
 }
 const f=fixture(()=>({entries:[item('repeat.mp4')],has_more_entries:true,next_request_voucher:'same'}));
 await assert.rejects(discoverFolder(root,f),/repeated/);
});
test('unsafe names and foreign links stop listing; Windows case collisions are mapped uniquely',async()=>{
 for(const name of ['..','../work','x\\work','\0'])assert.throws(()=>localComponent(name),/unsafe/);
 assert.equal(localComponent('CON.txt'),'~reserved-CON.txt');assert.equal(localComponent('take:1.mov'),'take~003a1.mov');
 const f=fixture(()=>({entries:[item('A.mp4'),item('a.mp4')],has_more_entries:false,total_num_entries:2}));
 const m=await discoverFolder(root,f);assert.notEqual(m.files[0].local.toLowerCase(),m.files[1].local.toLowerCase());
 const g=fixture(()=>({entries:[{...item('x'),href:'https://evil.example/x'}],has_more_entries:false,total_num_entries:1}));
 await assert.rejects(discoverFolder(root,g),/unsupported entry/);
});
test('verified empty folders are accepted; a cancelled retry stays cancelled',async()=>{
 const m=await discoverFolder(root,fixture(()=>({entries:[],has_more_entries:false,total_num_entries:0})));assert.equal(m.files.length,0);
 const c=new AbortController();let posts=0;
 const request=async(_url,options)=>{
  if(options.method!=='POST')return new Response('',{headers:{'Set-Cookie':'__Host-js_csrf=fixture; Secure; Path=/'}});
  posts++;return new Response('',{status:429,headers:{'Retry-After':'9'}});
 };
 await assert.rejects(discoverFolder(root,{signal:c.signal,request,sleep:async()=>{c.abort();c.signal.throwIfAborted();}}),/aborted/);
 assert.equal(posts,1);
});
