import {Downloader} from '../../mac/Sources/engine.mjs';
import {discoverFolder} from '../../shared/dropbox-folder.mjs';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
const [aria,helper]=process.argv.slice(2);
if(!aria||!helper)throw new Error('Pass the tested aria2 and native GOB helper paths.');
const url='https://www.dropbox.com/scl/fo/hsynj5331wvy39wer5egb/h?rlkey=oxhfrqft9ufoo3y0es4a2f8wz&dl=0';
const temp=await fs.mkdtemp(path.join(os.tmpdir(),'gob-real-folder-'));
const invoke=(...args)=>new Promise((resolve,reject)=>{
 const child=spawn(helper,args,{stdio:'ignore'});child.once('error',reject);child.once('exit',code=>code===0?resolve():reject(new Error('Native helper failed: '+args[0])));
});
let app;
const timeout=setTimeout(()=>{app?.pause();process.exitCode=1;console.error('Real folder integration exceeded six minutes.');},360000);
try {
 const manifest=await discoverFolder(url,{signal:AbortSignal.timeout(90000)});
 const total=manifest.files.reduce((sum,f)=>sum+f.size,0);
 assert.ok(manifest.files.length>0&&total<100*1024**2,'Public fixture must remain below 100 MiB.');
 const destination=path.join(temp,'saved');await fs.mkdir(destination);
 let pauseScheduled=false;
 const options={root:path.join(temp,'jobs'),aria,publish:(a,b)=>invoke('--publish',a,b),discover:async()=>manifest};
 app=new Downloader({...options,emit:event=>{
  if(!pauseScheduled&&event.type==='history'&&event.jobs.some(job=>job.children?.some(child=>child.status==='Downloading'))){
   pauseScheduled=true;setTimeout(()=>app.pause(),250);
  }
 }});
 await app.load();await app.start({link:url,destination,name:'Public press kit',brutal:true});await app.active.task;
 let job=[...app.jobs.values()][0];assert.equal(job.status,'Paused',job.message);assert.ok(pauseScheduled);
 const id=job.id;
 // Reopen saved metadata, so this tests restart recovery rather than keeping
 // the running objects or open file handles from the first attempt.
 app=new Downloader({...options,emit:()=>{}});await app.load();job=app.jobs.get(id);
 app.launch(job);await app.active.task;
 assert.equal(job.status,'Completed',job.message);assert.equal(job.completedFiles,manifest.files.length);
 assert.equal(job.metrics.done,total);
 for(const entry of job.entries)assert.equal((await fs.stat(path.join(job.target,...entry.local.split('/')))).size,entry.size);
 const unrelated=path.join(job.target,'unrelated-editing-project.txt');await fs.writeFile(unrelated,'keep');
 await app.remove(id,{deleteFiles:true,trash:file=>invoke('--trash',file)});
 assert.equal(await fs.readFile(unrelated,'utf8'),'keep');assert.equal(app.jobs.size,0);
 console.log(`PASS: real folder pause, process restart, ${manifest.files.length} verified files (${total} bytes), native publication, native Trash and unrelated-file preservation.`);
} finally {clearTimeout(timeout);await fs.rm(temp,{recursive:true,force:true});}
