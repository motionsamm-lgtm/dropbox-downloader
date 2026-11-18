// Public shared-link adapter. Dropbox's web interface is unversioned: validate
// every page and stop explicitly if its contract changes. No account cookies,
// access tokens, or embedded app secrets are used.
import {createHash} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';
export class FolderListingError extends Error {}
const fail = detail => { throw new FolderListingError(detail+' Saved downloads were kept.'); };
export function folderAddress(value) {
 let u;
 try { u=new URL(value); } catch { fail('Paste a valid Dropbox folder link.'); }
 if(u.protocol!=='https:' || !['www.dropbox.com','dropbox.com'].includes(u.hostname) || u.username || u.password || u.port) fail('Use an HTTPS Dropbox shared-folder link.');
 const p=u.pathname.split('/').filter(Boolean);
 const modern=p[0]==='scl'&&p[1]==='fo'&&p.length>=4;
 const legacy=p[0]==='sh'&&p.length>=3;
 if(!modern&&!legacy) fail('This is not a shared-folder link.');
 u.hostname='www.dropbox.com';u.hash='';u.searchParams.delete('st');u.searchParams.delete('dl');u.searchParams.delete('raw');
 const offset=modern?4:3;
 let subpath;
 try{subpath=p.slice(offset).map(decodeURIComponent).join('/');}catch{fail('The folder link contains an invalid path.');}
 if(subpath.split('/').some(x=>x==='.'||x==='..'||x.includes('\\')||x.includes('\0'))) fail('The folder link contains an unsafe path.');
 return {url:u.href,key:p[modern?2:1],secureHash:p[modern?3:2],rlkey:u.searchParams.get('rlkey')||'',subpath:subpath?'/'+subpath:'',modern};
}
export function localComponent(name) {
 if(typeof name!=='string'||!name||name==='.'||name==='..'||/[\/\\\x00-\x1f\x7f]/.test(name)) fail('Dropbox returned an unsafe filename.');
 let result=name.normalize('NFC').replace(/[~<>:"|?*]/g,c=>'~'+c.codePointAt(0).toString(16).padStart(4,'0'));
 result=result.replace(/[. ]+$/,s=>[...s].map(c=>'~'+c.charCodeAt(0).toString(16).padStart(4,'0')).join(''));
 if(/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(result))result='~reserved-'+result;
 if(Buffer.byteLength(result,'utf8')>100) {
  const digest=createHash('sha256').update(name).digest('hex').slice(0,16);
  result=[...result].slice(0,40).join('')+'~'+digest;
 }
 return result;
}
const responseText=async response=>{
 const reader=response.body?.getReader();if(!reader)fail('Dropbox returned an empty folder response.');
 const chunks=[];let size=0;
 try {while(true){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>8*1024*1024)fail('Dropbox returned an oversized folder page.');chunks.push(value);}}
 finally {await reader.cancel().catch(()=>{});}
 return Buffer.concat(chunks).toString('utf8');
};
export async function discoverFolder(link,{signal,request=fetch,sleep=delay,onProgress=()=>{}}={}) {
 const root=folderAddress(link),cookies=new Map();
 const capture=response=>{for(const raw of response.headers.getSetCookie?.()||[]){const m=/^([^=;\s]+)=([^;\r\n]*)/.exec(raw);if(m)cookies.set(m[1],m[2]);}};
 const cookie=()=>[...cookies].map(([k,v])=>k+'='+v).join('; ');
 async function session() {
  let url=root.url;
  for(let n=0;n<6;n++) {
   const r=await request(url,{signal,redirect:'manual',headers:{Cookie:cookie()}});capture(r);
   await r.body?.cancel();
   if([301,302,303,307,308].includes(r.status)) {
    const next=new URL(r.headers.get('location'),url);
    if(next.origin!=='https://www.dropbox.com')fail('Dropbox requires a sign-in or an unsupported redirect for this folder.');
    url=next.href;continue;
   }
   if(!r.ok)fail('Dropbox could not open the shared folder (HTTP '+r.status+').');
   const token=cookies.get('__Host-js_csrf')||cookies.get('t');
   if(!token)fail('Dropbox’s public folder interface changed or requires sign-in. GOB could not confirm a full file list.');
   return token;
  }
  fail('Dropbox redirected this folder too many times.');
 }
 let token=await session();
 async function page(address,voucher) {
  for(let attempt=0;attempt<4;attempt++) {
   signal?.throwIfAborted();
   const form=new URLSearchParams({t:token,link_key:root.key,secure_hash:address.secureHash,rlkey:root.rlkey,sub_path:address.subpath,link_type:'s'});
   if(voucher)form.set('voucher',voucher);
   const r=await request('https://www.dropbox.com/list_shared_link_folder_entries',{method:'POST',signal,redirect:'manual',headers:{Cookie:cookie(),'Content-Type':'application/x-www-form-urlencoded','X-Requested-With':'XMLHttpRequest',Origin:'https://www.dropbox.com',Referer:root.url},body:form.toString()});capture(r);
   if([400,403,408,429,500,502,503,504].includes(r.status)&&attempt<3) {
    const seconds=Math.min(120,Math.max(5,Number(r.headers.get('retry-after'))||5*2**attempt));
    await r.body?.cancel();onProgress({message:'Dropbox asked GOB to retry the folder listing in '+seconds+' seconds.'});
    await sleep(seconds*1000,undefined,{signal});token=await session();continue;
   }
   if(!r.ok) {await r.body?.cancel();fail('Dropbox refused the folder listing (HTTP '+r.status+'). Check that anyone with the link can download it.');}
   let data;try{data=JSON.parse(await responseText(r));}catch(e){if(e instanceof FolderListingError)throw e;fail('Dropbox returned a web page instead of a folder listing.');}
   if(!Array.isArray(data.entries)||typeof data.has_more_entries!=='boolean')fail('Dropbox returned an unrecognised folder listing. GOB cannot confirm it is complete.');
   return data;
  }
 }
 const files=[],directories=[],pending=[{address:root,remote:'',local:''}],seenRemote=new Set(),seenLocal=new Set();
 for(let index=0;index<pending.length;index++) {
  if(pending.length>100000)fail('This folder exceeds GOB’s file-list safety limit.');
  const dir=pending[index];let voucher='',count=0;const vouchers=new Set();
  do {
   const data=await page(dir.address,voucher);
   for(const entry of data.entries) {
    if(typeof entry.is_dir!=='boolean')fail('Dropbox omitted an entry’s file type.');
    const component=localComponent(entry.filename),remote=[dir.remote,entry.filename].filter(Boolean).join('/');
    let local=[dir.local,component].filter(Boolean).join('/');
    if(seenRemote.has(remote))fail('Dropbox repeated a folder entry while listing. Retry to get a consistent file list.');
    if(seenLocal.has(local.toLocaleLowerCase('en-US'))) {
     const suffix=createHash('sha256').update(remote).digest('hex').slice(0,12);local+='~'+suffix;
    }
    if(seenLocal.has(local.toLocaleLowerCase('en-US')))fail('Two Dropbox filenames map to the same local path.');
    seenRemote.add(remote);seenLocal.add(local.toLocaleLowerCase('en-US'));count++;
    if(seenRemote.size>100000)fail('This folder exceeds GOB’s 100,000-entry limit.');
    let address;try{address=folderAddress(new URL(entry.href,'https://www.dropbox.com').href);}catch{fail('Dropbox returned an unsupported entry link.');}
    if(address.key!==root.key)fail('Dropbox returned an entry outside the shared folder.');
    if(entry.is_dir) {
     const subpath=[root.subpath,remote].filter(Boolean).join('/').replace(/^\/*/,'/');
     directories.push({remote,local});pending.push({address:{...address,subpath},remote,local});
     if(remote.split('/').length>128)fail('This folder is nested more than 128 levels deep.');
    } else {
     if(!Number.isSafeInteger(entry.bytes)||entry.bytes<0)fail('Dropbox omitted a file’s exact size.');
     files.push({remote,local,url:address.url,size:entry.bytes});
    }
   }
   onProgress({files:files.length,folders:directories.length,message:'Found '+files.length+' files in '+directories.length+' subfolders…'});
   if(!data.has_more_entries) {
    if(data.total_num_entries!==undefined&&(!Number.isSafeInteger(data.total_num_entries)||data.total_num_entries!==count))fail('Dropbox’s folder count changed during listing. Retry to get a complete snapshot.');
    break;
   }
   voucher=data.next_request_voucher;
   if(typeof voucher!=='string'||!voucher||vouchers.has(voucher))fail('Dropbox did not provide a usable next folder page.');
   vouchers.add(voucher);if(vouchers.size>4096)fail('Dropbox returned too many folder pages.');
  } while(true);
 }
 return {schema:1,source:root.url,files,directories,listedAt:new Date().toISOString()};
}
