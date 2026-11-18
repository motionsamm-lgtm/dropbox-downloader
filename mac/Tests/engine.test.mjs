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

test('folder ZIP uses one stream and passes unzip verification before publication', async t => {
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
  await f.app.start({ link: 'https://www.dropbox.com/scl/fo/abc/def', name: 'Footage', destination: f.destination, brutal: true });
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
