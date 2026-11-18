import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createReadStream } from 'node:fs';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const MiB = 1024 ** 2;
const retryCodes = new Set([2, 3, 4, 5, 6, 8, 19, 22, 23, 24, 29]);
const httpRetry = new Set([403, 408, 410, 429, 500, 502, 503, 504]);
const httpMeaning = {
  403: 'Dropbox refused the request. Its temporary address may have expired.',
  410: 'The temporary Dropbox address is no longer available.',
  416: 'Dropbox refused the requested file range.',
  429: 'Dropbox asked the app to slow down.'
};
const iso = () => new Date().toISOString();
const hash = data => createHash('sha256').update(data).digest('hex');
const fileInfo = p => fs.lstat(p).catch(e => {
  if (e.code !== 'ENOENT') throw e;
  return null;
});

export class DownloadError extends Error {
  constructor(message, http = 0, wait = 0) {
    super(message);
    this.http = http;
    this.wait = wait;
  }
}

export function parseLink(value) {
  let u;
  try { u = new URL(value.trim()); }
  catch { throw new DownloadError('Paste a valid HTTPS Dropbox link.'); }
  if (u.protocol !== 'https:' || u.username || u.password || u.port) {
    throw new DownloadError('Paste a valid HTTPS Dropbox link.');
  }
  const shared = ['www.dropbox.com', 'dropbox.com'].includes(u.hostname);
  const direct = /^(?:[a-z0-9-]+\.)*dl\.dropboxusercontent\.com$/.test(u.hostname);
  const parts = u.pathname.split('/').filter(Boolean);
  const folderPath = shared && (
    (parts[0] === 'scl' && parts[1] === 'fo' && parts.length >= 4) ||
    (parts[0] === 'sh' && parts.length === 3)
  );
  const nested = folderPath && parts[0] === 'scl' && parts.length > 4;
  const folder = folderPath && !nested;
  if (!direct && !folderPath && !(shared && (
    (parts[0] === 'scl' && parts[1] === 'fi' && parts.length === 4) ||
    (parts[0] === 's' && parts.length === 3)
  ))) throw new DownloadError('Use a Dropbox file link or a shared-folder link.');
  if (folder && (u.searchParams.has('preview') || u.searchParams.has('select'))) {
    throw new DownloadError('Open the file in Dropbox and copy its own link.');
  }
  u.hash = '';
  const original = u.href;
  const urls = [];
  if (direct) urls.push(original);
  else {
    u.searchParams.delete('dl');
    u.searchParams.delete('raw');
    u.searchParams.set('dl', '1');
    urls.push(u.href);
    if (nested) {
      u.searchParams.delete('dl');
      u.searchParams.set('raw', '1');
      urls.push(u.href);
    }
    u.searchParams.delete('raw');
    u.searchParams.delete('dl');
    u.searchParams.delete('st');
    u.searchParams.sort();
    u.hostname = 'www.dropbox.com';
  }
  let name = 'Dropbox file';
  if (folder) name = 'Dropbox folder.zip';
  else if (!direct) {
    try { name = decodeURIComponent(parts.at(-1)); } catch {}
  }
  return { original, urls, name, folder, key: hash(u.href) };
}

function cleanName(name, folder) {
  let value = name.trim().normalize('NFC');
  if (folder && !/\.zip$/i.test(value)) value += '.zip';
  if (!value || value.startsWith('.') || /[/\\:\x00-\x1f]/.test(value) ||
      Buffer.byteLength(value) > 180) {
    throw new DownloadError('Choose a regular filename of 180 bytes or fewer.');
  }
  return value;
}

export function parseProgress(line) {
  const m = line.match(/\[#\w+\s+(\d+)(?:B)?\/(\d+)(?:B)?(?:\(\d+%\))?\s+CN:(\d+)\s+DL:(\d+)(?:B)?(?:\s|\])/);
  if (!m) return null;
  const [done, total, connections, speed] = m.slice(1).map(Number);
  return { done, total, connections, speed };
}

// aria2 v1 HTTP control file. Count only completed pieces, not allocated bytes.
export function checkpointProgress(bytes) {
  if (bytes.length < 38 || bytes.readUInt16BE(0) !== 1 || bytes.readUInt32BE(6) !== 0) return null;
  const pieceSize = bytes.readUInt32BE(10);
  const total = Number(bytes.readBigUInt64BE(14));
  const fieldSize = bytes.readUInt32BE(30);
  if (!pieceSize || total <= 0 || !Number.isSafeInteger(total) || fieldSize > bytes.length - 38) return null;
  const pieces = Math.ceil(total / pieceSize);
  if (Math.ceil(pieces / 8) !== fieldSize) return null;
  let done = 0;
  for (let piece = 0; piece < pieces; piece++) {
    if (bytes[34 + (piece >> 3)] & (128 >> (piece % 8))) {
      done += Math.min(pieceSize, total - piece * pieceSize);
    }
  }
  const inFlight = bytes.readUInt32BE(34 + fieldSize);
  return { done, total, complete: done === total && inFlight === 0, speed: 0, connections: 0 };
}

async function readCheckpoint(file) {
  const info = await fileInfo(file);
  if (!info?.isFile() || info.size > MiB) return null;
  return checkpointProgress(await fs.readFile(file));
}

function allowedRedirect(u) {
  return u.protocol === 'https:' && !u.username && !u.password && !u.port &&
    /(?:^|\.)(?:dropbox\.com|dropboxusercontent\.com)$/.test(u.hostname);
}

export function retryWait(value, now = Date.now()) {
  if (!value) return 0;
  const seconds = /^\d+$/.test(value) ? Number(value) : Math.ceil((Date.parse(value) - now) / 1000);
  return Number.isFinite(seconds) ? Math.max(0, seconds) : 0;
}

export async function probe(url, folder, onePass, signal, request = fetch, allow = allowedRedirect) {
  const timeout = AbortSignal.any([signal, AbortSignal.timeout(25000)]);
  let current = new URL(url);
  for (let hop = 0; hop <= 10; hop++) {
    if (!allow(current)) throw new DownloadError('Dropbox redirected outside its download hosts.');
    const response = await request(current, {
      redirect: 'manual', signal: timeout, headers: { Range: 'bytes=0-4095', 'Accept-Encoding': 'identity' }
    });
    const code = response.status;
    if ([301, 302, 303, 307, 308].includes(code)) {
      const location = response.headers.get('location');
      await response.body?.cancel();
      if (!location) throw new DownloadError('Dropbox returned a redirect with no address.');
      current = new URL(location, current);
      continue;
    }
    if (![200, 206].includes(code)) {
      const wait = retryWait(response.headers.get('retry-after'));
      await response.body?.cancel();
      throw new DownloadError(`Dropbox returned HTTP ${code} while checking the link.`, code, wait);
    }
    if (code === 200 && !folder && !onePass) {
      await response.body?.cancel();
      throw new DownloadError('Dropbox did not accept a byte-range request.', 200);
    }
    if (response.headers.get('content-encoding') &&
        response.headers.get('content-encoding') !== 'identity') {
      await response.body?.cancel();
      throw new DownloadError('Dropbox returned encoded bytes. The download could not be verified.');
    }
    const type = response.headers.get('content-type') || '';
    const range = response.headers.get('content-range')?.match(/^bytes 0-(\d+)\/(\d+)$/i);
    const total = code === 206 ? Number(range?.[2]) : Number(response.headers.get('content-length'));
    const sampleSize = code === 206 ? Number(range?.[1]) + 1 : Math.min(total || 4096, 4096);
    if (/^(text\/html|application\/xhtml\+xml)/i.test(type) || !response.body ||
        (code === 206 && (!Number.isSafeInteger(total) || !Number.isSafeInteger(sampleSize) || sampleSize < 1 || sampleSize > 4096 || sampleSize > total)) ||
        (code === 200 && !folder && (!Number.isSafeInteger(total) || total <= 0))) {
      await response.body?.cancel();
      throw new DownloadError('Dropbox did not return a verifiable file.');
    }
    const reader = response.body.getReader();
    let count = 0;
    const chunks = [];
    try {
      while (count < sampleSize) {
        const { value, done } = await reader.read();
        if (done) break;
        const chunk = value.subarray(0, sampleSize - count);
        chunks.push(chunk);
        count += chunk.length;
      }
    } finally { await reader.cancel().catch(() => {}); }
    const prefix = Buffer.concat(chunks);
    if ((code === 206 && count !== sampleSize) || count === 0) {
      throw new DownloadError('Dropbox returned an incomplete file sample.');
    }
    if (folder && !['504b0304', '504b0506', '504b0708'].includes(prefix.subarray(0, 4).toString('hex'))) {
      throw new DownloadError('Dropbox did not return a ZIP for this folder link.');
    }
    const tag = response.headers.get('etag') || '';
    return { total: total || 0, prefix: hash(prefix), count, tag: /^"[^"]+"$/.test(tag) ? tag : '' };
  }
  throw new DownloadError('Dropbox redirected too many times.');
}

export function assertSameSource(previous, next) {
  if (previous.total !== next.total || previous.count !== next.count || previous.prefix !== next.prefix ||
      (previous.tag && next.tag && previous.tag !== next.tag) ||
      (previous.key !== next.key && (!previous.tag || previous.tag !== next.tag))) {
    throw new DownloadError('The refreshed link could not be confirmed as the same file. Saved progress was kept.');
  }
}

async function runProcess(binary, args, signal, onLine = () => {}) {
  signal.throwIfAborted();
  return await new Promise((resolve, reject) => {
    const child = spawn(binary, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    const stop = () => child.kill('SIGTERM');
    signal.addEventListener('abort', stop, { once: true });
    const listen = stream => {
      let tail = '';
      stream.setEncoding('utf8');
      stream.on('data', chunk => {
        const lines = (tail + chunk).split(/[\r\n]+/);
        tail = lines.pop().slice(-4096);
        for (const line of lines) onLine(line);
      });
      stream.on('end', () => { if (tail) onLine(tail); });
    };
    listen(child.stdout);
    listen(child.stderr);
    child.once('error', e => reject(new DownloadError(`Could not start ${path.basename(binary)} (${e.code || 'process error'}).`)));
    child.once('close', (code, term) => {
      signal.removeEventListener('abort', stop);
      if (signal.aborted) reject(signal.reason);
      else if (term) reject(new DownloadError('The download process was interrupted.'));
      else resolve(code);
    });
  });
}

async function verifyPrefix(file, sample) {
  const fd = await fs.open(file, 'r');
  try {
    const bytes = Buffer.alloc(sample.count);
    const { bytesRead } = await fd.read(bytes, 0, bytes.length, 0);
    if (bytesRead !== bytes.length || hash(bytes) !== sample.prefix) {
      throw new DownloadError('The downloaded file does not match the source. The partial was kept.');
    }
  } finally { await fd.close(); }
}

const pauseText = 'Paused. Use Resume to continue.';
const missingPair = 'A partial or its checkpoint is missing. The saved files were kept.';

export class Downloader {
  constructor({ root, aria, publish, emit, inspect = probe, execute = runProcess, sleep = delay }) {
    Object.assign(this, { root, aria, publish, emit, inspect, execute, sleep });
    this.jobs = new Map();
    this.active = null;
  }

  async load() {
    await fs.mkdir(this.root, { recursive: true, mode: 0o700 });
    for (const id of await fs.readdir(this.root)) {
      if (!/^[a-f0-9-]{36}$/.test(id)) continue;
      try {
        const job = JSON.parse(await fs.readFile(path.join(this.root, id, 'job.json'), 'utf8'));
        if (job.id !== id) continue;
        if (['Checking', 'Downloading', 'Retrying', 'Verifying', 'Pausing'].includes(job.status)) {
          job.status = 'Interrupted';
          job.message = 'Interrupted. Resume checks the saved progress.';
          await this.save(job);
          await this.log(job, job.message);
        }
        this.jobs.set(id, job);
      } catch { this.emit({ type: 'error', message: 'One saved History entry could not be opened.' }); }
    }
    this.send();
  }

  jobPath(job, name) { return path.join(this.root, job.id, name); }

  send() {
    const jobs = [...this.jobs.values()].sort((a, b) => b.created.localeCompare(a.created)).map(({ link, source, ready, ...view }) => ({ ...view, canFinish: Boolean(ready) }));
    this.emit({ type: 'history', jobs, active: this.active?.id ?? null });
  }

  async save(job) {
    const target = this.jobPath(job, 'job.json');
    const temporary = target + '.tmp';
    await fs.writeFile(temporary, JSON.stringify(job), { mode: 0o600 });
    await fs.rename(temporary, target);
  }

  async log(job, message) {
    try {
      await fs.appendFile(this.jobPath(job, 'download.log.txt'), `[${iso()}] ${message}\n`, { mode: 0o600 });
    } catch {
      if (!job.logUnavailable) {
        job.logUnavailable = true;
        this.emit({ type: 'error', message: 'The text log could not be written. Download history is tracked separately.' });
      }
    }
  }

  async status(job, status, message) {
    Object.assign(job, { status, message, updated: iso() });
    await this.save(job);
    this.send();
  }

  async start(input) {
    if (this.active) throw new DownloadError('Pause or finish the current download first.');
    const link = parseLink(input.link);
    let chosenName = input.name?.trim() || link.name;
    const sourceExtension = path.extname(link.name);
    if (!link.folder && !path.extname(chosenName) && sourceExtension) chosenName += sourceExtension;
    const name = cleanName(chosenName, link.folder);
    if (typeof input.destination !== 'string' || !path.isAbsolute(input.destination)) {
      throw new DownloadError('Choose a save folder.');
    }
    let destination = await fs.realpath(input.destination).catch(() => {
      throw new DownloadError('The save folder is unavailable. Choose another folder.');
    });
    const checksum = (input.checksum || '').trim().toLowerCase();
    if (checksum && !/^[a-f0-9]{64}$/.test(checksum)) throw new DownloadError('Enter a 64-character SHA-256.');
    if (input.subfolder) {
      destination = path.join(destination, path.parse(name).name);
      await fs.mkdir(destination).catch(e => { if (e.code !== 'EEXIST') throw e; });
    }
    if (!(await fileInfo(destination))?.isDirectory()) throw new DownloadError('Choose an available save folder.');
    const target = path.join(destination, name);
    if (await fileInfo(target)) throw new DownloadError('A file already exists at that destination. Choose a different name.');
    const activeTarget = [...this.jobs.values()].find(j => j.status !== 'Completed' && j.target === target);
    if (activeTarget && !input.onePass) throw new DownloadError('This destination already has a History entry. Select it and use Resume.');
    const id = randomUUID();
    const job = {
      id, name, destination, target, link: link.original, folder: link.folder,
      onePass: !link.folder && Boolean(input.onePass), brutal: Boolean(input.brutal),
      notifications: Boolean(input.notifications), checksum, created: iso(), status: 'Queued',
      speedCap: Math.min(999, Math.max(0, Math.floor(Number(input.speedCap) || 0))),
      connections: Math.min(4, Math.max(1, Math.floor(Number(input.connections) || 4)))
    };
    await fs.mkdir(this.jobPath(job, ''), { mode: 0o700 });
    await this.save(job);
    this.jobs.set(id, job);
    this.launch(job);
  }

  launch(job, newLink = null, restart = false) {
    if (this.active || job.status === 'Completed') throw new DownloadError('This download cannot start right now.');
    const controller = new AbortController();
    const active = { id: job.id, controller };
    this.active = active;
    this.send();
    active.task = this.run(job, newLink, restart, controller.signal).catch(() => {
      job.status = 'Interrupted';
      job.message = 'Could not write download history. Saved transfer files were kept.';
    }).finally(() => { this.active = null; this.send(); });
  }

  async partialFiles(job) {
    const names = await fs.readdir(job.destination);
    return names.filter(name => name === `.${job.id}.part` || name.startsWith(`.${job.id}.part.`) ||
      name === `${job.name}.${job.id}.part` || name.startsWith(`${job.name}.${job.id}.part.`))
      .map(name => path.join(job.destination, name));
  }

  pause(id = this.active?.id) {
    if (this.active?.id !== id) throw new DownloadError('Select the active download to pause it.');
    this.active?.controller.abort(new DownloadError(pauseText));
  }

  async remove(id, { deleteFiles = false, trash } = {}) {
    const job = this.jobs.get(id);
    if (!job) throw new DownloadError('Select a download from History.');
    if (this.active?.id === id) throw new DownloadError('Pause this download and wait for Paused before removing it.');
    if (deleteFiles) {
      if (typeof trash !== 'function') throw new DownloadError('Trash is unavailable. No files were removed.');
      const files = await this.partialFiles(job);
      const final = await fileInfo(job.target);
      if (final && job.status === 'Completed') {
        if (!job.ready?.verified || !final.isFile() || final.size !== job.ready.size ||
            final.ino !== job.ready.ino || final.dev !== job.ready.dev || final.mtimeMs !== job.ready.modified) {
          throw new DownloadError('The finished file has changed. Check it in Finder before deleting it manually.');
        }
        files.push(job.target);
      }
      // Resolve every parent before moving anything. Never follow a replaced
      // save-folder symlink or recursively remove a user's destination folder.
      for (const file of files) {
        if (path.dirname(file) !== job.destination ||
            await fs.realpath(path.dirname(file)) !== job.destination ||
            !(await fileInfo(file))?.isFile()) {
          throw new DownloadError('A saved path changed. No deletion started; inspect the saved-data folder.');
        }
      }
      for (const file of files) {
        await trash(file);
        await this.log(job, 'Moved a tracked download file to Trash.');
      }
    }
    await this.log(job, deleteFiles ? 'Removed from History after moving tracked files to Trash.' :
      'Removed from History. Download files and saved progress were kept.');
    const archive = path.join(this.root, 'Removed');
    await fs.mkdir(archive, { recursive: true, mode: 0o700 });
    await fs.rename(this.jobPath(job, ''), path.join(archive, job.id));
    this.jobs.delete(id);
    this.send();
  }

  async inspectWithRetry(job, link, signal, fallback = true) {
    let last;
    for (const url of fallback ? link.urls : link.urls.slice(0, 1)) {
      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          return { url, sample: { ...await this.inspect(url, job.folder, job.onePass, signal), key: link.key } };
        } catch (e) {
          signal.throwIfAborted();
          last = e;
          if (!(e instanceof DownloadError)) last = new DownloadError('The network timed out or could not reach Dropbox.', 503);
          if (attempt === 2 || !httpRetry.has(last.http) || [403, 410].includes(last.http) || last.wait > 120) break;
          const seconds = Math.max(last.wait, last.http === 429 ? 30 : 5);
          await this.log(job, `Link check failed. Waiting ${seconds}s before checking again.`);
          await this.sleep(seconds * 1000, undefined, { signal });
        }
      }
      if (last.http === 429 || last.wait > 120) break;
    }
    throw last;
  }

  async run(job, refreshed, restart, signal) {
    const started = Date.now();
    let streamOnly = job.folder || job.onePass;
    const legacy = path.join(job.destination, `.${job.id}.part`);
    const partial = job.partial || ((await fileInfo(legacy)) ? legacy : path.join(job.destination, `${job.name}.${job.id}.part`));
    job.partial = partial;
    const control = partial + '.aria2';
    const pair = async () => {
      const bytes = await fileInfo(partial), checkpoint = await fileInfo(control);
      if ((bytes && !bytes.isFile()) || (checkpoint && !checkpoint.isFile())) {
        throw new DownloadError('The working path is occupied by an unexpected item.');
      }
      if (Boolean(bytes) !== Boolean(checkpoint) || (checkpoint && !job.source)) {
        throw new DownloadError(missingPair);
      }
      return Boolean(checkpoint);
    };
    job.metrics = null;
    job.recovery = false;
    await this.log(job, '--- Attempt started ---');
    try {
      await this.status(job, 'Checking', 'Checking the link and saved progress.');
      if (job.notifications) this.emit({ type: 'notification', title: 'Download started', body: job.name });
      if (job.ready) {
        await this.finish(job, partial, signal);
        return;
      }
      if (await fileInfo(job.target)) throw new DownloadError('The final filename is already in use.');
      const link = parseLink(refreshed || job.link);
      if (link.folder !== job.folder) throw new DownloadError('Use the same type of Dropbox link as the original download.');
      let resumed = false;
      if (streamOnly && restart) {
        // Keep the interrupted stream available for inspection.
        const suffix = `.interrupted-${randomUUID()}`;
        for (const p of [partial, control]) {
          if (await fileInfo(p)) await fs.rename(p, p + suffix);
        }
      }
      resumed = await pair();
      if (streamOnly && resumed) throw new DownloadError('This transfer requires a fresh start. Use Restart.');
      let checked;
      try { checked = await this.inspectWithRetry(job, link, signal); }
      catch (error) {
        if (error.http !== 200 || resumed || streamOnly) throw error;
        job.onePass = true;
        streamOnly = true;
        await this.log(job, 'Dropbox ignored ranges. Automatically using one stream for this new download.');
        checked = await this.inspectWithRetry(job, link, signal);
      }
      const { sample, url } = checked;
      if (resumed) {
        assertSameSource(job.source, sample);
        const savedProgress = await readCheckpoint(control);
        if (savedProgress?.total === sample.total) job.metrics = savedProgress;
        await this.log(job, 'Matched the source and found saved progress. Resuming.');
      }
      const capacity = await fs.statfs(job.destination).catch(() => null);
      if (!resumed && sample.total && capacity && capacity.bavail * capacity.bsize < sample.total) {
        throw new DownloadError('The save volume has less free space than this download requires.');
      }
      job.source = sample;
      job.link = link.original;
      await this.save(job);
      await this.log(job, `Source checked. Size: ${sample.total || 'unknown'} bytes. Mode: ${streamOnly ? 'single stream' : 'resumable'}.`);

      let connections = streamOnly ? 1 : job.brutal ? 16 : job.connections;
      let brutal = job.brutal;
      let transferURL = url;
      for (let attempt = 1; attempt <= 6; attempt++) {
        const mode = job.recovery ? 'Recovery' : brutal ? 'Brutal' : 'Normal';
        await this.status(job, 'Downloading', `${mode} · ${connections} connection${connections === 1 ? '' : 's'}`);
        await this.log(job, `Transfer ${attempt}. ${mode}, up to ${connections} connections.`);
        const options = [
          '--no-conf=true', `--continue=${!streamOnly}`, `--always-resume=${!streamOnly}`,
          '--allow-overwrite=false', '--auto-file-renaming=false', '--auto-save-interval=5',
          '--file-allocation=none', '--retry-wait=5', '--timeout=30', '--connect-timeout=15',
          '--summary-interval=2', '--human-readable=false', '--show-console-readout=true',
          '--truncate-console-readout=false', '--enable-color=false', '--console-log-level=warn',
          `--stop-with-process=${process.pid}`, `--max-tries=${streamOnly ? 1 : brutal ? 4 : 12}`,
          `--max-connection-per-server=${connections}`, `--split=${connections}`,
          `--dir=${job.destination}`, `--out=${path.basename(partial)}`
        ];
        if (!brutal && job.speedCap) options.push(`--max-download-limit=${job.speedCap}M`);
        let resultOK = false, lastHttp = 0, lastUpdate = 0, lastLog = 0;
        let progressLog = Promise.resolve();
        const code = await this.execute(this.aria, [...options, '--', transferURL], signal, line => {
          if (/^\s*[0-9a-f]{6,16}\|\s*OK\s*\|/i.test(line)) resultOK = true;
          const status = line.match(/(?:status\s*=\s*|HTTP\s+)([45]\d\d)\b/i);
          if (status) lastHttp = Number(status[1]);
          const metrics = parseProgress(line);
          const now = Date.now();
          if (metrics && now - lastUpdate >= 350) {
            job.metrics = metrics;
            lastUpdate = now;
            this.send();
            if (now - lastLog >= 30000) {
              lastLog = now;
              progressLog = progressLog.then(() => this.log(job, `Progress: ${metrics.done} bytes, ${metrics.speed} bytes/s.`));
            }
          }
        }).finally(async () => { await progressLog; });
        await this.log(job, `aria2 exit code ${code}.${lastHttp ? ` Dropbox returned HTTP ${lastHttp}. ${httpMeaning[lastHttp] || 'The server rejected the request.'}` : ''}`);
        const info = await fileInfo(partial);
        const controlExists = Boolean(await fileInfo(control));
        const checkpoint = !streamOnly && controlExists ? await readCheckpoint(control) : null;
        const completeCheckpoint = checkpoint?.complete && checkpoint.total === sample.total;
        if (info?.isFile() && ((code === 0 || resultOK) && !controlExists || completeCheckpoint)) {
          if ((sample.total && info.size !== sample.total) || info.size < sample.count) {
            throw new DownloadError('The final byte count did not match Dropbox. The partial was kept.');
          }
          if (code !== 0) await this.log(job, 'The final result or saved pieces confirm all bytes arrived. Checking the file locally.');
          job.ready = { size: info.size, ino: info.ino, dev: info.dev, modified: info.mtimeMs, checkpoint: Boolean(completeCheckpoint) };
          await this.save(job);
          await this.finish(job, partial, signal);
          return;
        }
        if (streamOnly || attempt === 6 || !retryCodes.has(code)) {
          throw new DownloadError(code === 9 ? 'The save volume ran out of space. Free space before resuming.'
            : `The transfer could not finish (aria2 ${code}${lastHttp ? `, HTTP ${lastHttp}` : ''}). Saved files were kept.`);
        }
        await pair();
        if (brutal) {
          brutal = false;
          job.recovery = true;
          connections = 1;
          await this.log(job, 'Brutal switched off after a retryable error. Resuming with one connection.');
        } else connections = Math.max(1, Math.floor(connections / 2));
        const wait = lastHttp || [22, 29].includes(code) ? Math.min(60, 30 * attempt) : Math.min(60, 5 * 2 ** (attempt - 1));
        job.metrics = job.metrics ? { ...job.metrics, speed: 0 } : null;
        await this.status(job, 'Retrying', `${job.recovery ? 'Recovery · ' : ''}Retrying with ${connections} connection(s) in ${wait}s.`);
        await this.log(job, `Retrying in ${wait}s after rechecking the source.`);
        await this.sleep(wait * 1000, undefined, { signal });
        const fresh = await this.inspectWithRetry(job, link, signal);
        assertSameSource(job.source, fresh.sample);
        transferURL = fresh.url;
      }
    } catch (e) {
      const message = signal.aborted ? pauseText :
        e instanceof DownloadError ? e.message : 'The network, save volume, or download history became unavailable. Saved transfer files were kept.';
      await this.log(job, `Result: ${message}`);
      if (!signal.aborted && job.notifications) this.emit({ type: 'notification', title: 'Download needs attention', body: job.name });
      await this.status(job, signal.aborted ? 'Paused' : 'Failed', message);
    } finally {
      await this.log(job, `Attempt ended. Elapsed: ${Math.round((Date.now() - started) / 1000)}s.`);
    }
  }

  async finish(job, partial, signal) {
    await this.status(job, 'Verifying', 'Checking the saved file.');
    const matchesReady = info => info?.isFile() && info.size === job.ready.size &&
      info.ino === job.ready.ino && info.dev === job.ready.dev && info.mtimeMs === job.ready.modified;
    const final = await fileInfo(job.target);
    if (final) {
      if (!job.ready.verified || !matchesReady(final)) throw new DownloadError('The final filename is already in use.');
    } else {
      if (!matchesReady(await fileInfo(partial))) throw new DownloadError('The completed partial changed or disappeared.');
      if (job.ready.checkpoint) {
        const checkpoint = await readCheckpoint(partial + '.aria2');
        if (!checkpoint?.complete || checkpoint.total !== job.ready.size) {
          throw new DownloadError('The completion checkpoint changed or disappeared. The partial was kept.');
        }
      }
      if (!job.ready.verified) {
        await verifyPrefix(partial, job.source);
        if (job.checksum) {
          const digest = createHash('sha256');
          for await (const chunk of createReadStream(partial, { signal })) digest.update(chunk);
          if (digest.digest('hex') !== job.checksum) throw new DownloadError('SHA-256 did not match. The partial was kept.');
        }
        if (job.folder) {
          const result = await this.execute('/usr/bin/unzip', ['-tqq', partial], signal);
          const empty = result === 1 && job.ready.size === 22 &&
            (await fs.readFile(partial)).equals(Buffer.concat([Buffer.from('504b0506', 'hex'), Buffer.alloc(18)]));
          if (result !== 0 && !empty) {
            throw new DownloadError('The ZIP did not pass its integrity check. The partial was kept.');
          }
        }
        if (!matchesReady(await fileInfo(partial))) throw new DownloadError('The completed partial changed during verification.');
        job.ready.verified = true;
        await this.save(job);
      }
      signal.throwIfAborted();
      await this.publish(partial, job.target).catch(() => {
        throw new DownloadError('The verified file could not be saved under its final name. Check the destination and use Resume to retry saving.');
      });
    }
    if (job.ready.checkpoint) await fs.unlink(partial + '.aria2').catch(() => {});
    job.metrics = { done: job.ready.size, total: job.ready.size, speed: 0, connections: 0 };
    await this.log(job, `Result: Completed. Saved ${job.ready.size} verified bytes.`);
    await this.status(job, 'Completed', 'File verified and saved.');
    if (job.notifications) this.emit({ type: 'notification', title: 'Download completed', body: job.name });
  }
}
