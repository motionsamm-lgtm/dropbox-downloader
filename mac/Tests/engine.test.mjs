import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { createServer } from 'node:http';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { Downloader, assertSameSource, checkpointProgress, parseLink, parseProgress, probe } from '../Sources/engine.mjs';

const file = Buffer.from('A fixture that stands in for a Dropbox file.');
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const source = { total: file.length, count: file.length, prefix: sha(file), tag: '"fixture"' };
const link = 'https://www.dropbox.com/scl/fi/abc/test.mp4?rlkey=private&st=old&dl=0';

function control(done) {
  const bytes = Buffer.alloc(39);
  bytes.writeUInt16BE(1, 0);
  bytes.writeUInt32BE(file.length, 10);
  bytes.writeBigUInt64BE(BigInt(file.length), 14);
  bytes.writeUInt32BE(1, 30);
  bytes[34] = done ? 128 : 0;
  return bytes;
}
function option(args, name) { return args.find(arg => arg.startsWith('--' + name + '='))?.split(/=(.*)/s)[1]; }
function working(args) { return path.join(option(args, 'dir'), option(args, 'out')); }
async function fixture(t, overrides = {}) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'dropbox-test-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const destination = path.join(directory, 'out');
  await fs.mkdir(destination);
  const events = [];
  const app = new Downloader({
    root: path.join(directory, 'jobs'), aria: '/fixture/aria2c', emit: e => events.push(e),
    inspect: async () => source, sleep: async () => {},
    publish: async (a, b) => { await fs.link(a, b); await fs.unlink(a); },
    ...overrides
  });
  await app.load();
  return { app, destination, events, job: () => [...app.jobs.values()][0] };
}
const success = async (_bin, args) => {
  const p = working(args);
  await fs.writeFile(p, file);
  await fs.unlink(p + '.aria2').catch(() => {});
  return 0;
};

test('remove archives history but keeps download bytes and checkpoints across reload', async t => {
  const f = await fixture(t, { execute: success });
  await f.app.start({link, destination:f.destination, brutal:true});
  await f.app.active.task;
  const job = f.job();
  assert.equal(job.status, 'Completed');
  await f.app.remove(job.id);
  assert.deepEqual(await fs.readFile(job.target), file);
  assert.equal(f.app.jobs.size, 0);
  await f.app.load();
  assert.equal(f.app.jobs.size, 0);
  assert.ok(await fs.stat(path.join(f.app.root, 'Removed', job.id, 'job.json')));
});

test('delete trashes only owned files, keeps unrelated files, and refuses changed final files', async t => {
  const f = await fixture(t, {execute:success});
  await f.app.start({link, destination:f.destination});
  await f.app.active.task;
  const job = f.job(), unrelated = path.join(f.destination, 'client-project.prproj');
  await fs.writeFile(unrelated, 'keep');
  const moved = [];
  const trash = async p => { moved.push(p); await fs.rename(p, p+'.trashed'); };
  await f.app.remove(job.id, {deleteFiles:true, trash});
  assert.deepEqual(moved, [job.target]);
  assert.equal(await fs.readFile(unrelated,'utf8'), 'keep');
  const g = await fixture(t, {execute:success});
  await g.app.start({link, destination:g.destination});
  await g.app.active.task;
  const modified = g.job();
  await fs.writeFile(modified.target, 'replaced');
  await assert.rejects(g.app.remove(modified.id, {deleteFiles:true, trash}), /changed/);
  assert.ok(g.app.jobs.has(modified.id));
});

test('active jobs cannot be removed; pause saves state and Resume finishes the same job', async t => {
  let began;
  const started = new Promise(resolve => { began = resolve; });
  const f = await fixture(t, {execute: async (_bin,args,signal) => {
    await fs.writeFile(working(args), file);
    await fs.writeFile(working(args)+'.aria2', control(false));
    began();
    await new Promise((resolve,reject) => signal.addEventListener('abort',()=>reject(signal.reason),{once:true}));
  }});
  await f.app.start({link, destination:f.destination});
  await started;
  const job = f.job();
  await assert.rejects(f.app.remove(job.id), /Pause/);
  f.app.pause(job.id);
  await f.app.active.task;
  assert.equal(job.status, 'Paused');
  assert.ok(await fs.stat(job.partial+'.aria2'));
  f.app.execute = success;
  f.app.launch(job);
  await f.app.active.task;
  assert.equal(job.status, 'Completed');
});

test('delete refuses a substituted save-folder symlink before moving any file', async t => {
  const f = await fixture(t, {execute:success});
  await f.app.start({link, destination:f.destination});
  await f.app.active.task;
  const job = f.job();
  const movedFolder = f.destination+'-moved';
  await fs.rename(f.destination, movedFolder);
  await fs.symlink(movedFolder, f.destination);
  let calls=0;
  await assert.rejects(f.app.remove(job.id,{deleteFiles:true,trash:async()=>{calls++;}}), /path changed/);
  assert.equal(calls,0);
});

test('classifies links and separates session tokens from file identity', () => {
  assert.equal(parseLink(link).key, parseLink(link.replace('st=old', 'st=new')).key);
  assert.equal(parseLink(link).name, 'test.mp4');
  assert.equal(parseLink('https://www.dropbox.com/scl/fo/abc/def?rlkey=secret').folder, true);
  assert.equal(parseLink('https://www.dropbox.com/scl/fo/abc/def/movie.mp4?rlkey=secret').urls.length, 2);
  assert.throws(() => parseLink('https://www.dropbox.com.evil.test/scl/fi/a/b'));
  assert.throws(() => assertSameSource({ ...source, key: 'old', tag: '' }, { ...source, key: 'new', tag: '' }));
  assert.doesNotThrow(() => assertSameSource({ ...source, key: 'old' }, { ...source, key: 'new' }));
  assert.deepEqual(parseProgress('[#abcdef 50B/100B(50%) CN:4 DL:12B ETA:5s]'), { done: 50, total: 100, connections: 4, speed: 12 });
  assert.equal(checkpointProgress(control(false)).done, 0);
  assert.equal(checkpointProgress(control(true)).complete, true);
});

test('downloads a public Google Drive binary through the resumable engine and never logs its API key', async t => {
  const md5 = createHash('md5').update(file).digest('hex');
  const calls = [];
  const f = await fixture(t, {
    driveApiKey:'restricted-fixture-key',
    driveClient:{metadata:async(id,key)=>{
      calls.push(['metadata',id,key]);
      return {id:'drivefile123',name:'drive-clip.mp4',mimeType:'video/mp4',size:String(file.length),md5Checksum:md5,resourceKey:'rk123',capabilities:{canDownload:true}};
    }},
    inspect:async(url,folder,onePass,signal,request,allow,headers,provider)=>{
      assert.equal(folder,false); assert.equal(provider,'Google Drive');
      assert.equal(headers['X-Goog-Drive-Resource-Keys'],'drivefile123/rk123');
      assert.equal(allow(new URL('https://drive.usercontent.googleusercontent.com/download')),true);
      assert.equal(allow(new URL('https://drive.usercontent.google.com/download')),true);
      assert.equal(allow(new URL('https://evil.google.com/download')),false);
      assert.equal(new URL(url).searchParams.get('key'),'restricted-fixture-key');
      return {...source,total:file.length};
    },
    execute:async(_bin,args)=>{
      calls.push(['aria',args]);
      assert.ok(args.includes('--header=X-Goog-Drive-Resource-Keys: drivefile123/rk123'));
      assert.ok(args.at(-1).includes('key=restricted-fixture-key'));
      await fs.writeFile(working(args),file);
      await fs.unlink(working(args)+'.aria2').catch(()=>{});
      return 0;
    }
  });
  await f.app.start({link:'https://drive.google.com/file/d/drivefile123/view?resourcekey=rk123',destination:f.destination,brutal:true});
  await f.app.active.task;
  const job=f.job();
  assert.equal(job.provider,'google-drive');
  assert.equal(job.status,'Completed',job.message);
  assert.deepEqual(await fs.readFile(job.target),file);
  const log=await fs.readFile(f.app.jobPath(job,'download.log.txt'),'utf8');
  assert.match(log,/Provider: Google Drive/);
  assert.doesNotMatch(log,/restricted-fixture-key|resourcekey=rk123/);
  assert.equal(calls.filter(call=>call[0]==='metadata').length,2);
});

test('downloads a public Google Drive folder as tracked individual files under one parent job', async t => {
  const md5=createHash('md5').update(file).digest('hex');
  const metadataIds=[];
  const driveClient={
    metadata:async id=>{metadataIds.push(id);return id==='rootdrive123'
      ? {id,name:'Client Footage',mimeType:'application/vnd.google-apps.folder',resourceKey:'rootrk',capabilities:{canDownload:true}}
      : {id,name:'take.mp4',mimeType:'video/mp4',size:String(file.length),md5Checksum:md5,resourceKey:'filerk',capabilities:{canDownload:true}}},
    listPage:async()=>({files:[{id:'filedrive123',name:'take.mp4',mimeType:'video/mp4',size:String(file.length),md5Checksum:md5,resourceKey:'filerk'}]})
  };
  const f=await fixture(t,{driveApiKey:'restricted-fixture-key',driveClient,
    inspect:async(url,folder,_onePass,_signal,_request,allow,headers,provider)=>{
      assert.equal(provider,'Google Drive');assert.equal(folder,false);
      assert.equal(headers['X-Goog-Drive-Resource-Keys'],'filedrive123/filerk');
      assert.equal(allow(new URL('https://drive.usercontent.googleusercontent.com/download')),true);
      assert.equal(allow(new URL('https://drive.usercontent.google.com/download')),true);
      assert.match(url,/files%2Ffiledrive123|files\/filedrive123/);
      return {...source,total:file.length};
    },execute:success});
  await f.app.start({link:'https://drive.google.com/drive/folders/rootdrive123?resourcekey=rootrk',destination:f.destination,name:'Project Drive',brutal:true});
  await f.app.active.task;
  const job=f.job();
  assert.equal(job.provider,'google-drive');
  assert.equal(job.kind,'folder');
  const children=await f.app.folderChildren(job);
  const diag=await fs.readFile(f.app.jobPath(job,'download.log.txt'),'utf8');
  assert.equal(job.status,'Completed',`${job.message}; child: ${children[0]?.message}; ${diag}`);
  assert.equal(job.completedFiles,1);
  assert.ok(metadataIds.includes('filedrive123'),'folder child must request its actual Google Drive file ID');
  assert.deepEqual(await fs.readFile(path.join(job.target,'take.mp4')),file);
  assert.doesNotMatch(await fs.readFile(f.app.jobPath(job,'download.log.txt'),'utf8'),/restricted-fixture-key|resourcekey=rootrk/);
});

test('folder ZIP option downloads resumable files, verifies the archive, and leaves one final ZIP', async t => {
  const archiveBytes=Buffer.concat([Buffer.from('504b0506','hex'),Buffer.alloc(18)]);
  const f=await fixture(t,{
    discover:async()=>({files:[{id:'remote1',remote:'take.mp4',local:'take.mp4',url:link,size:file.length}],directories:[]}),
    execute:success,
    archiveFolder:async(_folder,archive)=>fs.writeFile(archive,archiveBytes),
    verifyArchive:async archive=>{assert.deepEqual(await fs.readFile(archive),archiveBytes);return 0;}
  });
  await f.app.start({link:'https://www.dropbox.com/scl/fo/share/key',name:'Client Assets',destination:f.destination,folderOutput:'zip',brutal:true});
  await f.app.active.task;
  const job=f.job();
  assert.equal(job.status,'Completed',job.message);
  assert.equal(job.name,'Client Assets.zip');
  assert.equal(job.folderOutput,'zip');
  assert.ok(job.archiveReady.verified);
  assert.deepEqual(await fs.readdir(f.destination),['Client Assets.zip']);
  assert.deepEqual(await fs.readFile(job.target),archiveBytes);
  await f.app.remove(job.id);
  assert.deepEqual(await fs.readFile(job.target),archiveBytes);
});

test('folder ZIP follows the filename-subfolder choice and leaves the archive inside that folder', async t => {
  const archiveBytes=Buffer.concat([Buffer.from('504b0506','hex'),Buffer.alloc(18)]);
  const f=await fixture(t,{discover:async()=>({files:[],directories:[]}),archiveFolder:async(_folder,archive)=>fs.writeFile(archive,archiveBytes),verifyArchive:async()=>0});
  await f.app.start({link:'https://www.dropbox.com/scl/fo/share/key',name:'Client Assets',destination:f.destination,folderOutput:'zip',subfolder:true});
  await f.app.active.task;
  const job=f.job();
  assert.equal(job.status,'Completed',job.message);
  assert.equal(await fs.realpath(job.target),path.join(await fs.realpath(f.destination),'Client Assets','Client Assets.zip'));
  assert.deepEqual(await fs.readdir(path.join(f.destination,'Client Assets')),['Client Assets.zip']);
});

test('Google Drive folder ZIP uses the same file-verification and archive path', async t => {
  const archiveBytes=Buffer.concat([Buffer.from('504b0506','hex'),Buffer.alloc(18)]),md5=createHash('md5').update(file).digest('hex');
  const driveClient={metadata:async id=>id==='rootdrive123'
    ? {id,name:'Client Footage',mimeType:'application/vnd.google-apps.folder',resourceKey:'rootrk',capabilities:{canDownload:true}}
    : {id,name:'take.mp4',mimeType:'video/mp4',size:String(file.length),md5Checksum:md5,resourceKey:'filerk',capabilities:{canDownload:true}},
    listPage:async()=>({files:[{id:'filedrive123',name:'take.mp4',mimeType:'video/mp4',size:String(file.length),md5Checksum:md5,resourceKey:'filerk'}]})};
  const f=await fixture(t,{driveApiKey:'restricted-fixture-key',driveClient,
    inspect:async()=>({...source,total:file.length}),execute:success,
    archiveFolder:async(_folder,archive)=>fs.writeFile(archive,archiveBytes),verifyArchive:async()=>0});
  await f.app.start({link:'https://drive.google.com/drive/folders/rootdrive123?resourcekey=rootrk',destination:f.destination,name:'Drive Assets',folderOutput:'zip'});
  await f.app.active.task;
  const job=f.job();
  assert.equal(job.status,'Completed',job.message);
  assert.deepEqual(await fs.readFile(job.target),archiveBytes);
  assert.deepEqual(await fs.readdir(f.destination),['Drive Assets.zip']);
});

test('delete files for a completed folder ZIP trashes only the verified archive', async t => {
  const archiveBytes=Buffer.concat([Buffer.from('504b0506','hex'),Buffer.alloc(18)]), moved=[];
  const f=await fixture(t,{discover:async()=>({files:[],directories:[]}),archiveFolder:async(_folder,archive)=>fs.writeFile(archive,archiveBytes),verifyArchive:async()=>0});
  await f.app.start({link:'https://www.dropbox.com/scl/fo/share/key',name:'Client Assets',destination:f.destination,folderOutput:'zip',subfolder:true});
  await f.app.active.task;
  const job=f.job();
  await f.app.remove(job.id,{deleteFiles:true,trash:async file=>{moved.push(file);await fs.unlink(file);}});
  assert.deepEqual(moved,[job.target]);
  assert.equal(await fs.readdir(path.join(f.destination,'Client Assets')).then(items=>items.length),0);
});

test('checks a real HTTP redirect and range response; rejects pages and ignored ranges', async t => {
  const server = createServer((req, res) => {
    if (req.url === '/redirect') { res.writeHead(302, { Location: '/range' }).end(); return; }
    if (req.url === '/range') {
      assert.equal(req.headers.range, 'bytes=0-4095');
      res.writeHead(206, { 'Content-Range': `bytes 0-${file.length - 1}/${file.length}`, ETag: '"fixture"' }).end(file);
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html', 'Content-Length': file.length }).end(file);
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = 'http://127.0.0.1:' + server.address().port;
  const signal = new AbortController().signal;
  const run = (route, onePass = false) => probe(base + route, false, onePass, signal, fetch, u => u.origin === base);
  assert.deepEqual(await run('/redirect'), source);
  await assert.rejects(run('/html'), /byte-range/);
  await assert.rejects(run('/html', true), /verifiable/);
});

test('HTTP 403 drops Brutal to one connection and keeps the checkpoint', async t => {
  const calls = [];
  const f = await fixture(t, { execute: async (bin, args, signal, line) => {
    calls.push(args);
    if (calls.length === 1) {
      const p = working(args);
      await fs.writeFile(p, Buffer.alloc(file.length));
      await fs.writeFile(p + '.aria2', control(false));
      line('response status is not successful. status=403');
      return 22;
    }
    assert.equal(working(args), working(calls[0]));
    assert.equal(option(args, 'continue'), 'true');
    return success(bin, args);
  } });
  await f.app.start({ link, destination: f.destination, brutal: true, speedCap: 3 });
  await f.app.active.task;
  assert.equal(option(calls[0], 'split'), '16');
  assert.equal(option(calls[1], 'split'), '1');
  assert.equal(option(calls[1], 'max-download-limit'), '3M');
  assert.equal(f.job().status, 'Completed');
  assert.deepEqual(await fs.readFile(f.job().target), file);
  const log = await fs.readFile(f.app.jobPath(f.job(), 'download.log.txt'), 'utf8');
  assert.match(log, /HTTP 403/);
  assert.match(log, /Brutal switched off/);
  assert.doesNotMatch(log, /rlkey|https:\/\//);
});

test('pause and manual resume append to one log; changed link preserves saved bytes', async t => {
  let calls = 0;
  let running;
  const began = new Promise(resolve => { running = resolve; });
  const f = await fixture(t, { inspect: async url => url.includes('/changed/') ? { ...source, prefix: 'wrong' } : source,
    execute: async (bin, args, signal) => {
      if (++calls > 1) return success(bin, args);
      const p = working(args);
      await fs.writeFile(p, Buffer.alloc(file.length));
      await fs.writeFile(p + '.aria2', control(false));
      running();
      signal.throwIfAborted();
      return new Promise((_, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true }));
    }
  });
  await f.app.start({ link, destination: f.destination });
  await began;
  f.app.pause();
  await f.app.active.task;
  assert.equal(f.job().status, 'Paused');
  f.app.launch(f.job(), link.replace('/abc/', '/changed/'));
  await f.app.active.task;
  assert.equal(f.job().status, 'Failed');
  assert.equal(calls, 1);
  f.app.launch(f.job(), link.replace('st=old', 'st=new'));
  await f.app.active.task;
  assert.equal(f.job().status, 'Completed');
  const files = await fs.readdir(f.app.jobPath(f.job(), ''));
  assert.deepEqual(files.sort(), ['download.log.txt', 'job.json']);
  const log = await fs.readFile(f.app.jobPath(f.job(), 'download.log.txt'), 'utf8');
  assert.equal(log.match(/Attempt started/g).length, 3);
  assert.match(log, /Paused/);
  assert.match(log, /Completed/);
});

test('a complete checkpoint recovers a late engine error; publication failure retries locally', async t => {
  let publishes = 0, requests = 0;
  const f = await fixture(t, {
    inspect: async () => { requests++; return source; },
    execute: async (_, args) => {
      const p = working(args);
      await fs.writeFile(p, file);
      await fs.writeFile(p + '.aria2', control(true));
      return 22;
    },
    publish: async (a, b) => {
      if (++publishes === 1) throw Error('destination temporarily unavailable');
      await fs.rename(a, b);
    }
  });
  await f.app.start({ link, destination: f.destination });
  await f.app.active.task;
  assert.equal(f.job().status, 'Failed');
  assert.equal(f.job().ready.verified, true);
  f.app.launch(f.job());
  await f.app.active.task;
  assert.equal(f.job().status, 'Completed');
  assert.equal(requests, 1);
  assert.deepEqual(await fs.readdir(f.destination), ['test.mp4']);
});

test('checksum failure keeps the partial and leaves no final file', async t => {
  const f = await fixture(t, { execute: success });
  await f.app.start({ link, destination: f.destination, checksum: '0'.repeat(64) });
  await f.app.active.task;
  assert.equal(f.job().status, 'Failed');
  assert.match(f.job().message, /SHA-256 did not match/);
  const files = await fs.readdir(f.destination);
  assert.equal(files.length, 1);
  assert.match(files[0], /\.part$/);
});

test('legacy folder ZIP checkpoints still use one stream and verify before publication', async t => {
  const data = Buffer.from('504b03041400000000008c92665d727958ca07000000070000000b000000666f6f746167652e74787446697874757265504b010214031400000000008c92665d727958ca07000000070000000b0000000000000000000000800100000000666f6f746167652e747874504b0506000000000100010039000000300000000000', 'hex');
  const f = await fixture(t, {
    inspect: async () => ({ total: data.length, count: data.length, prefix: sha(data), tag: '' }),
    execute: async (binary, args) => {
      if (binary === '/usr/bin/unzip') return spawnSync(binary, args).status;
      assert.equal(option(args, 'split'), '1');
      assert.equal(option(args, 'continue'), 'false');
      await fs.writeFile(working(args), data);
      return 0;
    }
  });
  const legacyExecute=f.app.execute,legacyInspect=f.app.inspect;f.app.execute=success;f.app.inspect=async()=>source;
  await f.app.start({link, name:'Footage.zip', destination:f.destination});
  await f.app.active.task;
  const legacy=f.job();
  await fs.unlink(legacy.target).catch(()=>{});
  delete legacy.ready; delete legacy.kind; legacy.folder=true;legacy.link='https://www.dropbox.com/scl/fo/abc/def';legacy.status='Interrupted';
  f.app.execute=legacyExecute;f.app.inspect=legacyInspect;f.app.launch(legacy);
  await f.app.active.task;
  assert.equal(f.job().status, 'Completed');
  assert.deepEqual(await fs.readdir(f.destination), ['Footage.zip']);
});

test('custom names retain the source suffix and ignored ranges fall back automatically', async t => {
  const f = await fixture(t, {
    inspect: async (_url, _folder, onePass) => {
      if (!onePass) throw Object.assign(new Error('Ignored range'), { http: 200 });
      return source;
    }, execute: async (binary, args) => {
      assert.equal(option(args, 'split'), '1');
      return success(binary, args);
    }
  });
  // Use the same typed failure the real probe returns.
  const { DownloadError } = await import('../Sources/engine.mjs');
  f.app.inspect = async (_u, _f, onePass) => {
    if (!onePass) throw new DownloadError('Ignored ranges', 200);
    return source;
  };
  await f.app.start({ link, name:'DAY 1', destination:f.destination, brutal:true });
  await f.app.active.task;
  assert.equal(f.job().name, 'DAY 1.mp4');
  assert.equal(f.job().status, 'Completed');
  assert.equal(f.job().onePass, true);
});

const folderLink='https://www.dropbox.com/scl/fo/root/hash?rlkey=public';
const folderFixture={files:[{remote:'a.mp4',local:'a.mp4',url:link,size:file.length},{remote:'nested/b.mp4',local:'nested/b.mp4',url:link,size:file.length}],directories:[{remote:'nested',local:'nested'}]};
test('folder files keep their tree, one parent log, aggregate completion and safe deletion',async t=>{
 const f=await fixture(t,{execute:success,discover:async()=>folderFixture});
 await f.app.start({link:folderLink,destination:f.destination,name:'Client footage',brutal:true});
 await f.app.active.task;
 const job=f.job();assert.equal(job.status,'Completed',job.message);assert.equal(job.completedFiles,2);
 assert.equal(job.metrics.done,2*file.length);
 assert.deepEqual(await fs.readFile(path.join(job.target,'nested/b.mp4')),file);
 const unrelated=path.join(job.target,'editing.prproj');await fs.writeFile(unrelated,'keep');
 const moved=[];await f.app.remove(job.id,{deleteFiles:true,trash:async p=>{moved.push(p);await fs.rename(p,p+'.trashed');}});
 assert.equal(moved.length,2);assert.equal(await fs.readFile(unrelated,'utf8'),'keep');
});
test('folder resume keeps completed files and retries only unfinished files',async t=>{
 let attempts=0;
 const f=await fixture(t,{discover:async()=>folderFixture,execute:async(bin,args)=>{
  attempts++;if(option(args,'out').startsWith('b.mp4'))return 1;return success(bin,args);
 }});
 await f.app.start({link:folderLink,destination:f.destination,name:'Footage'});await f.app.active.task;
 const job=f.job();assert.equal(job.status,'Failed');assert.equal(job.completedFiles,1);assert.equal(attempts,2);
 f.app.execute=async(bin,args)=>{assert.ok(option(args,'out').startsWith('b.mp4'));return success(bin,args);};
 f.app.launch(job);await f.app.active.task;assert.equal(job.status,'Completed',job.message);
});
test('folder listing interruption never reports an empty folder as complete',async t=>{
 const f=await fixture(t,{discover:async()=>{throw new Error('Incomplete folder page');},execute:success});
 await f.app.start({link:folderLink,destination:f.destination});await f.app.active.task;
 assert.equal(f.job().status,'Failed');assert.equal(f.job().listed,undefined);
 assert.deepEqual(await fs.readdir(f.destination),[]);
});

test('pause at the final byte preserves completion proof for a local-only resume',async t=>{
 let f;
 f=await fixture(t,{execute:async(bin,args)=>{await success(bin,args);f.app.pause();return 0;}});
 await f.app.start({link,destination:f.destination});await f.app.active.task;
 const job=f.job();assert.equal(job.status,'Paused');assert.ok(job.ready);
 f.app.inspect=async()=>{throw new Error('A late pause must not need the network again.');};
 f.app.launch(job);await f.app.active.task;assert.equal(job.status,'Completed',job.message);
});

test('a ZIP integrity failure preserves downloaded files and never publishes the archive', async t => {
  const f = await fixture(t, {
    discover: async () => ({files: [{remote:'take.mp4', local:'take.mp4', url:link, size:file.length}], directories: []}),
    execute: success,
    archiveFolder: async (_folder, archive) => fs.writeFile(archive, Buffer.from('504b0506' + '00'.repeat(18), 'hex')),
    verifyArchive: async () => 2
  });
  await f.app.start({
    link: 'https://www.dropbox.com/scl/fo/share/key',
    name: 'Client Assets',
    destination: f.destination,
    folderOutput: 'zip'
  });
  await f.app.active.task;
  const job = f.job();
  assert.equal(job.status, 'Failed');
  assert.match(job.message, /integrity check/);
  await assert.rejects(fs.stat(job.target), {code:'ENOENT'});
  assert.deepEqual(await fs.readFile(path.join(job.folderRoot, 'take.mp4')), file);
});


test('accepted links persist independently and the queue continues after pausing a waiting job', async t => {
  let unblock;
  const gate = new Promise(resolve => { unblock = resolve; });
  const f = await fixture(t, { execute: async (bin,args) => { await gate; return success(bin,args); } });
  const first = await f.app.start({link, destination:f.destination, name:'first'});
  const second = await f.app.start({link, destination:f.destination, name:'second'});
  const third = await f.app.start({link, destination:f.destination, name:'third'});
  const firstTask = f.app.active.task;
  assert.equal(f.app.active.id, first);
  assert.equal(f.app.jobs.get(second).status, 'Queued');
  await f.app.pause(second);
  assert.equal(f.app.jobs.get(second).status, 'Paused');
  unblock();
  await firstTask;
  assert.equal(f.app.active.id, third);
  await f.app.active.task;
  assert.equal(f.app.jobs.get(first).status, 'Completed');
  assert.equal(f.app.jobs.get(third).status, 'Completed');
  assert.equal(f.app.jobs.get(second).status, 'Paused');
  f.app.launch(f.app.jobs.get(second));
  await f.app.active.task;
  assert.equal(f.app.jobs.get(second).status, 'Completed');
  assert.equal((await fs.readdir(f.destination)).length, 3);
});


test('reports a Drive automated-query block separately from sharing permissions', async () => {
  const request = async () => new Response('<html><title>Sorry...</title>automated queries</html>', {
    status: 403, headers: {'content-type': 'text/html'}
  });
  await assert.rejects(probe('https://www.googleapis.com/drive/v3/files/example', false, false,
    new AbortController().signal, request, () => true, {}, 'Google Drive'),
    error => error.http === 403 && /blocked automated requests/.test(error.message));
});

test('348 Drive files keep their identities through transient retries and a partial folder resume', async t => {
  const files = Array.from({length:348}, (_,i)=>({
    id:'fixture'+String(i+1).padStart(3,'0'), name:'file'+String(i+1).padStart(3,'0')+'.bin',
    mimeType:'application/octet-stream', size:String(file.length), resourceKey:'key'+String(i+1).padStart(3,'0')
  }));
  const byId = new Map(files.map(item=>[item.id,item]));
  const attempts = new Map(), transfers = new Map();
  let inFlight=0, maximum=0, allowLast=false;
  const driveClient = {
    metadata:async id=>byId.get(id) || {id,name:'Folder',mimeType:'application/vnd.google-apps.folder'},
    listPage:async()=>({files})
  };
  const f=await fixture(t,{driveClient,driveApiKey:'fixture-only',
    inspect:async(url,folder,onePass,signal,_fetch,_allow,headers)=>{
      const id = new URL(url).pathname.split('/').at(-1);
      assert.ok(byId.has(id));
      assert.equal(headers['X-Goog-Drive-Resource-Keys'],id+'/'+byId.get(id).resourceKey);
      const count=(attempts.get(id)||0)+1;
      attempts.set(id,count);
      const code = id==='fixture001' && count===1 ? 429 :
        id==='fixture002' && count===1 ? 503 :
        id==='fixture348' && !allowLast ? 403 : 206;
      if (code!==206) return probe(url,folder,onePass,signal,async()=>new Response(null,{status:code}),()=>true,{},'Google Drive');
      return source;
    },
    execute:async(bin,args)=>{
      const id=new URL(args.at(-1)).pathname.split('/').at(-1);
      assert.equal(path.basename(option(args,'out')).includes(byId.get(id).name),true);
      assert.equal(option(args,'split'),'1');
      transfers.set(id,(transfers.get(id)||0)+1);
      maximum=Math.max(maximum,++inFlight);
      try { return await success(bin,args); }
      finally { inFlight--; }
    }});
  await f.app.start({link:'https://drive.google.com/drive/folders/rootfixture',destination:f.destination,brutal:true});
  await f.app.active.task;
  const job=f.job();
  assert.equal(job.status,'Failed');
  assert.equal(job.completedFiles,347);
  assert.equal(job.metrics.total,file.length*348);
  assert.equal(job.metrics.done,file.length*347);
  assert.equal(attempts.get('fixture001'),2);
  assert.equal(attempts.get('fixture002'),2);
  assert.equal(attempts.get('fixture348'),1);
  assert.equal(maximum,2);
  assert.match(job.message,/347\/348 verified; 1 failed; 0 unfinished/);
  assert.match(job.message,/HTTP 403/);
  allowLast=true;
  f.app.launch(job);
  await f.app.active.task;
  assert.equal(job.status,'Completed');
  assert.equal(transfers.size,348);
  assert.ok([...transfers.values()].every(count=>count===1));
});


test('automatic dispatch skips a queued download while its removal is in progress', async t => {
  let finishTransfer, finishRemoval, signalRemoving;
  const transfer = new Promise(resolve => { finishTransfer = resolve; });
  const removing = new Promise(resolve => { signalRemoving = resolve; });
  const removal = new Promise(resolve => { finishRemoval = resolve; });
  const f = await fixture(t, { execute: async (bin,args) => { await transfer; return success(bin,args); } });
  const first = await f.app.start({link, destination:f.destination, name:'first'});
  const second = await f.app.start({link, destination:f.destination, name:'second'});
  const third = await f.app.start({link, destination:f.destination, name:'third'});
  const log = f.app.log.bind(f.app);
  f.app.log = async (job,message) => {
    if (job.id === second && message.startsWith('Removed from History')) {
      signalRemoving();
      await removal;
    }
    await log(job,message);
  };
  const removingJob = f.app.remove(second);
  await removing;
  const firstTask = f.app.active.task;
  finishTransfer();
  await firstTask;
  assert.equal(f.app.active.id, third);
  assert.equal(f.app.jobs.get(first).status,'Completed');
  const thirdTask = f.app.active.task;
  finishRemoval();
  await Promise.all([removingJob,thirdTask]);
  assert.equal(f.app.jobs.has(second),false);
  assert.equal((await fs.readdir(f.destination)).length,2);
});
