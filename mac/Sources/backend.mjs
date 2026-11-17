import { spawn } from 'node:child_process';
import { constants, accessSync } from 'node:fs';
import { createInterface } from 'node:readline';
import path from 'node:path';
import { Downloader, DownloadError } from './engine.mjs';

const [root, helper, downloads] = process.argv.slice(2);
const output = value => process.stdout.write(JSON.stringify(value) + '\n');
const executable = file => {
  try { accessSync(file, constants.X_OK); return true; } catch { return false; }
};
const aria = [path.join(path.dirname(process.execPath), 'aria2c'),
  '/opt/homebrew/bin/aria2c', '/usr/local/bin/aria2c', '/opt/local/bin/aria2c'].find(executable);
const invoke = (binary, args) => new Promise((resolve, reject) => {
  const child = spawn(binary, args, { stdio: 'ignore' });
  child.on('error', reject);
  child.on('close', code => code === 0 ? resolve() : reject(new Error('Command failed.')));
});
const app = new Downloader({
  root, aria, emit: output, publish: (from, to) => invoke(helper, ['--publish', from, to])
});
await app.load();
output({ type: 'ready', downloads, available: Boolean(aria) });

const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
let queue = Promise.resolve();
async function handle(line) {
  try {
    const msg = JSON.parse(line);
    if (msg.action === 'snapshot') { output({ type: 'ready', downloads, available: Boolean(aria) }); return; }
    if (msg.action === 'pause') { app.pause(); return; }
    if (msg.action === 'start' || msg.action === 'resume') {
      if (!aria) throw new DownloadError('Install aria2 with brew install aria2, then reopen this app.');
      if (msg.action === 'start') await app.start(msg);
      else {
        const job = app.jobs.get(msg.id);
        if (!job) throw new DownloadError('Select a download from History.');
        app.launch(job, msg.link || null, msg.restart === true);
      }
      return;
    }
    const job = app.jobs.get(msg.id);
    if (!job) return;
    if (msg.action === 'workingFolder') {
      await invoke('/usr/bin/open', [job.destination]);
    }
    if (msg.action === 'clearPartials') {
      if (app.active) throw new DownloadError('Pause the download before clearing saved data.');
      for (const file of await app.partialFiles(job)) await invoke(helper, ['--trash', file]);
      delete job.ready;
      delete job.source;
      job.metrics = null;
      await app.log(job, 'Saved partial downloads moved to Trash by the user.');
      await app.status(job, 'Paused', 'Saved data moved to Trash. Next attempt starts from zero. Empty Trash to reclaim disk space.');
    }
    if (msg.action === 'log') {
      await invoke('/usr/bin/open', ['-t', app.jobPath(job, 'download.log.txt')]);
    }
    if (msg.action === 'reveal') {
      await invoke('/usr/bin/open', ['-R', job.target]);
    }
  } catch (e) {
    output({ type: 'error', message: e instanceof DownloadError ? e.message : 'The requested action could not finish.' });
  } finally { app.send(); }
}
lines.on('line', line => { queue = queue.then(() => handle(line)); });
lines.on('close', async () => {
  await queue;
  const active = app.active;
  if (active) {
    app.pause();
    await active.task;
  }
  process.exitCode = 0;
});
