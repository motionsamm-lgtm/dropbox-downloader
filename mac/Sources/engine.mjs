import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { createReadStream } from 'node:fs';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import {discoverFolder} from './dropbox-folder.mjs';
import {createDriveClient, discoverGoogleDriveFolder, driveTransferRequest, GoogleDriveError, isGoogleDriveLink, parseGoogleDriveLink} from './google-drive.mjs';
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
    (parts[0] === 'sh' && parts.length >= 3)
  );
  const nested = folderPath && (parts[0] === 'scl' ? parts.length > 4 : parts.length > 3);
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

function allowedDriveRedirect(u) {
  return u.protocol === 'https:' && !u.username && !u.password && !u.port &&
    (/(?:^|\.)(?:googleapis\.com|googleusercontent\.com)$/.test(u.hostname) ||
      u.hostname === 'drive.usercontent.google.com');
}

export function retryWait(value, now = Date.now()) {
  if (!value) return 0;
  const seconds = /^\d+$/.test(value) ? Number(value) : Math.ceil((Date.parse(value) - now) / 1000);
  return Number.isFinite(seconds) ? Math.max(0, seconds) : 0;
}

export async function probe(url, folder, onePass, signal, request = fetch, allow = allowedRedirect, extraHeaders = {}, provider = 'Dropbox') {
  const timeout = AbortSignal.any([signal, AbortSignal.timeout(25000)]);
  let current = new URL(url);
  for (let hop = 0; hop <= 10; hop++) {
    if (!allow(current)) throw new DownloadError('The share link redirected outside its verified download hosts.');
    const response = await request(current, {
      redirect: 'manual', signal: timeout, headers: { Range: 'bytes=0-4095', 'Accept-Encoding': 'identity', ...extraHeaders }
    });
    const code = response.status;
    if (code === 416 && response.headers.get('content-range')?.trim() === 'bytes */0') {
      await response.body?.cancel();
      return {total:0,count:0,prefix:hash(Buffer.alloc(0)),tag:''};
    }
    if ([301, 302, 303, 307, 308].includes(code)) {
      const location = response.headers.get('location');
      await response.body?.cancel();
      if (!location) throw new DownloadError(`${provider} returned a redirect with no address.`);
      current = new URL(location, current);
      continue;
    }
    if (![200, 206].includes(code)) {
      const wait = retryWait(response.headers.get('retry-after'));
      await response.body?.cancel();
      const reason = provider === 'Google Drive' && code === 403
        ? 'Google Drive denied the file request. Check that Anyone with the link can download it; API quota or key restrictions may also block access.'
        : provider === 'Google Drive' && code === 404
          ? 'Google Drive could not find this file or its owner removed access.'
          : `${provider} returned HTTP ${code} while checking the link.`;
      throw new DownloadError(reason, code, wait);
    }
    if (code === 200 && !folder && !onePass) {
      const zipResponse = /application\/(?:x-zip-compressed|zip)/i.test(response.headers.get('content-type') || '') ||
        /filename[^\r\n]*\.zip(?:[";\s]|$)/i.test(response.headers.get('content-disposition') || '');
      await response.body?.cancel();
      throw Object.assign(new DownloadError(`${provider} did not accept a byte-range request.`, 200), {zipResponse});
    }
    if (response.headers.get('content-encoding') &&
        response.headers.get('content-encoding') !== 'identity') {
      await response.body?.cancel();
      throw new DownloadError(`${provider} returned encoded bytes. The download could not be verified.`);
    }
    const type = response.headers.get('content-type') || '';
    const range = response.headers.get('content-range')?.match(/^bytes 0-(\d+)\/(\d+)$/i);
    const total = code === 206 ? Number(range?.[2]) : Number(response.headers.get('content-length'));
    const sampleSize = code === 206 ? Number(range?.[1]) + 1 : Math.min(total || 4096, 4096);
    if (/^(text\/html|application\/xhtml\+xml)/i.test(type) || !response.body ||
        (code === 206 && (!Number.isSafeInteger(total) || !Number.isSafeInteger(sampleSize) || sampleSize < 1 || sampleSize > 4096 || sampleSize > total)) ||
        (code === 200 && !folder && (!Number.isSafeInteger(total) || total <= 0))) {
      await response.body?.cancel();
      throw new DownloadError(`${provider} did not return a verifiable file.`);
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
      throw new DownloadError(`${provider} returned an incomplete file sample.`);
    }
    if (folder && !['504b0304', '504b0506', '504b0708'].includes(prefix.subarray(0, 4).toString('hex'))) {
      throw new DownloadError('Dropbox did not return a ZIP for this folder link.');
    }
    const tag = response.headers.get('etag') || '';
    return { total: total || 0, prefix: hash(prefix), count, tag: /^"[^"]+"$/.test(tag) ? tag : '' };
  }
  throw new DownloadError('The share link redirected too many times.');
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
      if (signal.aborted) resolve(code ?? 1);
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
  constructor({ root, aria, publish, emit, inspect = probe, execute = runProcess, sleep = delay, discover = discoverFolder, driveApiKey = process.env.GOB_DRIVE_API_KEY || '', driveClient = null, archiveFolder, verifyArchive, version = 'GOB' }) {
    Object.assign(this, { root, aria, publish, emit, inspect, execute, sleep, discover, driveApiKey, driveClient, version });
    // Archive the folder's contents so the ZIP has the same relative paths as
    // the normal folder output, without exposing the internal "Files" staging name.
    this.archiveFolder = archiveFolder || ((folder, archive, signal) => runProcess('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', folder, archive], signal));
    this.verifyArchive = verifyArchive || ((archive, signal) => runProcess('/usr/bin/unzip', ['-tqq', archive], signal));
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
        if (['Listing', 'Checking', 'Downloading', 'Retrying', 'Verifying', 'Pausing'].includes(job.status)) {
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
    const jobs = [...this.jobs.values()].sort((a, b) => b.created.localeCompare(a.created)).map(({ link, source, ready, entries, directories, ...view }) => ({ ...view, canFinish: Boolean(ready) }));
    this.emit({ type: 'history', jobs, active: this.active?.id ?? null });
  }

  async save(job) {
    const target = this.jobPath(job, 'job.json');
    const temporary = target + '.tmp';
    await fs.writeFile(temporary, JSON.stringify(job), { mode: 0o600 });
    await fs.rename(temporary, target);
  }

  async log(job, message) {
    message = message.replace(/https?:\/\/\S+/g,'[share link]').replace(/'\/[^']*'/g,"'[local path omitted]'");
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
    const drive = isGoogleDriveLink(input.link);
    let link, driveFile = null;
    if (drive) {
      const parsed = parseGoogleDriveLink(input.link);
      const client = this.createDriveClient();
      driveFile = await client.metadata(parsed.id, parsed.resourceKey);
      const isFolder = driveFile.mimeType === 'application/vnd.google-apps.folder';
      if (parsed.folder !== isFolder) throw new DownloadError(parsed.folder ? 'This Google Drive link does not point to a folder.' : 'This Google Drive link points to a folder.');
      if (!isFolder && driveFile.mimeType.startsWith('application/vnd.google-apps.')) {
        throw new DownloadError('This is a Google Docs, Sheets, or Slides file. Workspace export is not available yet; use a downloadable binary file link.');
      }
      if (!isFolder && (!Number.isSafeInteger(Number(driveFile.size)) || Number(driveFile.size) < 0)) throw new DownloadError('Google Drive did not provide a reliable file size for this binary file.');
      if (!isFolder && driveFile.capabilities?.canDownload === false) throw new DownloadError('The owner has disabled downloading for this Google Drive item.');
      link = {provider:'google-drive', original:parsed.original, folder:isFolder, name:driveFile.name, key:parsed.identity, drive:parsed};
    } else {
      link = parseLink(input.link);
      link.provider = 'dropbox';
    }
    let chosenName = input.name?.trim() || (link.folder ? `${drive ? 'Google Drive' : 'Dropbox'} folder` : link.name);
    const sourceExtension = path.extname(link.name);
    if (!link.folder && !path.extname(chosenName) && sourceExtension) chosenName += sourceExtension;
    const name = cleanName(chosenName, false);
    if (typeof input.destination !== 'string' || !path.isAbsolute(input.destination)) {
      throw new DownloadError('Choose a save folder.');
    }
    let destination = await fs.realpath(input.destination).catch(() => {
      throw new DownloadError('The save folder is unavailable. Choose another folder.');
    });
    const checksum = (input.checksum || '').trim().toLowerCase();
    if (link.folder && checksum) throw new DownloadError('Expected SHA-256 applies to a single file. Leave it blank for a folder download.');
    if (checksum && !/^[a-f0-9]{64}$/.test(checksum)) throw new DownloadError('Enter a 64-character SHA-256.');
    if (input.subfolder && !link.folder) {
      destination = path.join(destination, path.parse(name).name);
      await fs.mkdir(destination).catch(e => { if (e.code !== 'EEXIST') throw e; });
    }
    if (!(await fileInfo(destination))?.isDirectory()) throw new DownloadError('Choose an available save folder.');
    const folderOutput = link.folder && input.folderOutput === 'zip' ? 'zip' : 'folder';
    const outputName = link.folder && folderOutput === 'zip' && !/\.zip$/i.test(name) ? `${name}.zip` : name;
    let createdFilenameSubfolder = false;
    if (link.folder && folderOutput === 'zip' && input.subfolder) {
      const subfolder = path.join(destination, path.parse(outputName).name);
      if (await fileInfo(subfolder)) throw new DownloadError('The filename subfolder already exists. Choose a new name or turn off Create filename subfolder.');
      destination = subfolder;
      createdFilenameSubfolder = true;
    }
    const target = path.join(destination, outputName);
    const folderRoot = link.folder && folderOutput === 'zip'
      ? path.join(destination, createdFilenameSubfolder ? 'Files' : path.parse(outputName).name)
      : target;
    if (await fileInfo(target) || (folderRoot !== target && await fileInfo(folderRoot))) throw new DownloadError('A file or folder already exists at that destination. Choose a different name.');
    const activeTarget = [...this.jobs.values()].find(j => j.status !== 'Completed' && j.target === target);
    if (activeTarget && !input.onePass) throw new DownloadError('This destination already has a History entry. Select it and use Resume.');
    if (createdFilenameSubfolder) {
      await fs.mkdir(destination).catch(() => { throw new DownloadError('Could not create the filename subfolder. Check the save location.'); });
      destination = await fs.realpath(destination);
    }
    const id = randomUUID();
    const job = {
      id, name:outputName, destination, target, folderRoot, folderOutput, createdFilenameSubfolder, link: link.original, provider:link.provider, driveFile:drive && !link.folder ? {
        id:driveFile.id, name:driveFile.name, mimeType:driveFile.mimeType, size:Number(driveFile.size),
        md5Checksum:driveFile.md5Checksum||'', resourceKey:driveFile.resourceKey||link.drive.resourceKey||''
      } : undefined, driveRoot:drive && link.folder ? {id:driveFile.id, resourceKey:driveFile.resourceKey||link.drive.resourceKey||''} : undefined,
      folder: link.folder, kind: link.folder ? 'folder' : 'file',
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

  createDriveClient() {
    if (!this.driveClient) this.driveClient = createDriveClient({apiKey:this.driveApiKey});
    return this.driveClient;
  }

  launch(job, newLink = null, restart = false) {
    if (this.active || job.status === 'Completed') throw new DownloadError('This download cannot start right now.');
    const controller = new AbortController();
    const active = { id: job.id, controller };
    this.active = active;
    this.send();
    active.task = (job.kind === 'folder' ? this.runFolder(job, controller.signal) : this.run(job, newLink, restart, controller.signal)).catch(() => {
      job.status = 'Interrupted';
      job.message = 'Could not write download history. Saved transfer files were kept.';
    }).finally(() => { this.active = null; this.send(); });
  }

  async partialFiles(job) {
    if (job.kind === 'folder') {
      const children = await this.folderChildren(job);
      return (await Promise.all(children.map(child => this.partialFiles(child)))).flat();
    }
    const names = await fs.readdir(job.destination);
    const recorded = job.partial && path.dirname(job.partial) === job.destination &&
      path.basename(job.partial).endsWith(`.${job.id}.part`) ? path.basename(job.partial) : null;
    return names.filter(original => {
      const name = original.normalize('NFC');
      return name === `.${job.id}.part` || name.startsWith(`.${job.id}.part.`) ||
      (recorded && (name === recorded || name.startsWith(recorded + '.'))) ||
      name === `${job.name}.${job.id}.part` || name.startsWith(`${job.name}.${job.id}.part.`);
    })
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
      const children = job.kind === 'folder' ? await this.folderChildren(job) : [job];
      const files = [];
      for (const child of children) {
        files.push(...await this.partialFiles(child));
        const final = await fileInfo(child.target);
        if (final && child.status === 'Completed') {
          if (!this.matchesFinished(child, final)) {
            throw new DownloadError('A finished file has changed. Check it in Finder before deleting it manually.');
          }
          files.push(child.target);
        }
      }
      if (job.kind === 'folder' && job.folderOutput === 'zip') {
        const archive = await fileInfo(job.target);
        if (archive && this.matchesFinished({ready:job.archiveReady}, archive)) files.push(job.target);
      }
      // Resolve every parent before moving anything. Never follow a replaced
      // save-folder symlink or recursively remove a user's destination folder.
      for (const file of files) {
        const fileRoot = job.folderRoot || job.target;
        const within = job.kind === 'folder'
          ? file === job.target && job.folderOutput === 'zip' ? path.dirname(file) === job.destination : file.startsWith(fileRoot + path.sep)
          : path.dirname(file) === job.destination;
        if (!within || (await fs.realpath(path.dirname(file))).normalize('NFC') !== path.dirname(file).normalize('NFC') ||
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

  matchesFinished(job, info) {
    return job.ready?.verified && info?.isFile() && info.size === job.ready.size &&
      info.ino === job.ready.ino && info.dev === job.ready.dev && info.mtimeMs === job.ready.modified;
  }

  async folderChildren(job) {
    const root = this.jobPath(job, 'children');
    const children = [];
    for (const entry of job.entries || []) {
      if (!/^[a-f0-9-]{36}$/.test(entry.id)) throw new DownloadError('The saved folder manifest is damaged.');
      const child = JSON.parse(await fs.readFile(path.join(root,entry.id,'job.json'),'utf8'));
      if (typeof entry.local !== 'string' || entry.local.split('/').some(p=>!p||p==='.'||p==='..'||p.includes('\\')))
        throw new DownloadError('The saved folder manifest contains an unsafe path.');
      if (child.id !== entry.id || child.target !== path.join(job.folderRoot || job.target,...entry.local.split('/'))) throw new DownloadError('The saved folder paths changed. Files were kept.');
      children.push(child);
    }
    return children;
  }

  async validateFolderStage(job, children) {
    const root = job.folderRoot || job.target;
    const rootInfo = await fileInfo(root);
    if (!rootInfo?.isDirectory() || rootInfo.isSymbolicLink() || (await fs.realpath(root)).normalize('NFC') !== root.normalize('NFC')) {
      throw new DownloadError('The folder being zipped was replaced or redirected. No ZIP was created; inspect the save location.');
    }
    const expected = new Map();
    const addDirectory = relative => {
      if (!relative) return;
      const parts = relative.split('/');
      if (parts.some(part => !part || part === '.' || part === '..' || part.includes('\\'))) throw new DownloadError('The saved folder manifest contains an unsafe path.');
      for (let i = 1; i <= parts.length; i++) expected.set(parts.slice(0, i).join('/'), 'directory');
    };
    for (const directory of job.directories || []) addDirectory(directory.local);
    for (let i = 0; i < (job.entries || []).length; i++) {
      const entry = job.entries[i];
      const parts = entry.local.split('/');
      if (parts.some(part => !part || part === '.' || part === '..' || part.includes('\\'))) throw new DownloadError('The saved folder manifest contains an unsafe path.');
      addDirectory(parts.slice(0, -1).join('/'));
      expected.set(entry.local, 'file');
      const info = await fileInfo(path.join(root, ...parts));
      if (!this.matchesFinished(children[i], info)) throw new DownloadError('A finished folder file changed or is missing. Check the saved folder before making a ZIP.');
    }
    const actual = new Map();
    const visit = async (directory, relative = '') => {
      for (const name of await fs.readdir(directory)) {
        const itemRelative = relative ? `${relative}/${name}` : name;
        const info = await fs.lstat(path.join(directory, name));
        if (info.isSymbolicLink() || (!info.isFile() && !info.isDirectory())) throw new DownloadError('The download folder contains an unexpected link or special file. No ZIP was created.');
        actual.set(itemRelative, info.isDirectory() ? 'directory' : 'file');
        if (info.isDirectory()) await visit(path.join(directory, name), itemRelative);
      }
    };
    await visit(root);
    if (actual.size !== expected.size || [...expected].some(([name, kind]) => actual.get(name) !== kind)) {
      throw new DownloadError('The download folder contains extra or missing items. No ZIP was created; your files were kept.');
    }
  }

  async createFolderZip(job, children, signal) {
    const existing = await fileInfo(job.target);
    if (existing) {
      if (this.matchesFinished({ready:job.archiveReady}, existing)) return 'The verified ZIP was already saved.';
      throw new DownloadError('A file already exists where the ZIP should be saved. The downloaded folder was kept.');
    }
    await this.validateFolderStage(job, children);
    const size = (job.entries || []).reduce((sum, entry) => sum + (Number(entry.size) || 0), 0);
    try {
      const space = await fs.statfs(job.destination);
      if (Number(space.bavail) * Number(space.bsize) < size) throw new DownloadError('There may not be enough free space to assemble a ZIP of this folder. Free up disk space and resume; the downloaded files were kept.');
    } catch (error) {
      if (error instanceof DownloadError) throw error;
    }
    const temporary = path.join(job.destination, `${job.name}.assembling-${job.id}.zip`);
    const staleAssembly = await fileInfo(temporary);
    if (staleAssembly) {
      if (!staleAssembly.isFile() || staleAssembly.isSymbolicLink()) throw new DownloadError('A previous ZIP assembly path is no longer a regular file. It was kept for inspection.');
      if (this.matchesFinished({ready:job.archiveReady}, staleAssembly)) {
        if (await this.verifyArchive(temporary, signal) !== 0) {
          throw new DownloadError('The ZIP failed its integrity check. Your downloaded folder was kept.');
        }
        signal.throwIfAborted();
        await this.publish(temporary, job.target);
        const recovered = await fileInfo(job.target);
        if (!this.matchesFinished({ready:job.archiveReady}, recovered)) throw new DownloadError('The saved ZIP assembly could not be confirmed after recovery.');
        try {
          await this.validateFolderStage(job, await this.folderChildren(job));
          for (const entry of job.entries || []) await fs.unlink(path.join(job.folderRoot || job.target, ...entry.local.split('/')));
          const dirs = [...new Set([...(job.directories || []).map(item => item.local), ...(job.entries || []).map(item => item.local.split('/').slice(0,-1).join('/'))])]
            .filter(Boolean).map(item => path.join(job.folderRoot || job.target, ...item.split('/')))
            .sort((a,b) => b.split(path.sep).length - a.split(path.sep).length);
          for (const dir of dirs) await fs.rmdir(dir);
          await fs.rmdir(job.folderRoot || job.target);
        } catch { /* A verified ZIP is enough to complete; leave any unconfirmed staging files in place. */ }
        return 'Recovered and verified the ZIP after an interruption.';
      }
      // The name is scoped by this job's UUID. An interrupted, unpublished
      // assembly is safe to discard; the resumable source files remain intact.
      await fs.unlink(temporary);
    }
    try {
      const archiveExit = await this.archiveFolder(job.folderRoot || job.target, temporary, signal);
      signal.throwIfAborted();
      if (archiveExit !== undefined && archiveExit !== 0) {
        throw new DownloadError('ZIP assembly failed. Your downloaded folder was kept.');
      }
      if (await this.verifyArchive(temporary, signal) !== 0) {
        throw new DownloadError('The ZIP failed its integrity check. Your downloaded folder was kept.');
      }
      signal.throwIfAborted();
      const before = await fileInfo(temporary);
      const header = Buffer.alloc(4);
      const handle = await fs.open(temporary, 'r');
      try { await handle.read(header, 0, 4, 0); } finally { await handle.close(); }
      if (!before?.isFile() || before.size < 22 || !['504b0304', '504b0506', '504b0708'].includes(header.toString('hex'))) {
        throw new DownloadError('The ZIP failed its integrity check. Your downloaded folder was kept.');
      }
      signal.throwIfAborted();
      job.archiveReady = {verified:true,size:before.size,ino:before.ino,dev:before.dev,modified:before.mtimeMs};
      await this.save(job);
      await this.publish(temporary, job.target);
      const final = await fileInfo(job.target);
      if (!final?.isFile() || final.size !== before.size || final.ino !== before.ino || final.dev !== before.dev) {
        throw new DownloadError('The ZIP could not be confirmed at its final save location. Your downloaded folder was kept.');
      }
      job.archiveReady.modified = final.mtimeMs;
      await this.save(job);
      let cleanup = '';
      try {
        await this.validateFolderStage(job, children);
        const paths = (job.entries || []).map(entry => path.join(job.folderRoot || job.target, ...entry.local.split('/')));
        for (const file of paths) await fs.unlink(file);
        const directories = [...new Set(['', ...(job.directories || []).map(item => item.local), ...(job.entries || []).map(item => item.local.split('/').slice(0, -1).join('/'))])]
          .filter(Boolean).map(item => path.join(job.folderRoot || job.target, ...item.split('/')))
          .sort((a, b) => b.split(path.sep).length - a.split(path.sep).length);
        for (const directory of directories) await fs.rmdir(directory);
        await fs.rmdir(job.folderRoot || job.target);
      } catch {
        cleanup = ' The verified ZIP is saved; the source folder was kept because safe cleanup could not be confirmed.';
      }
      return `ZIP verified and saved.${cleanup}`;
    } catch (error) {
      await fs.unlink(temporary).catch(() => {});
      throw error;
    }
  }

  async runFolder(job, signal) {
    const started = Date.now();
    await this.log(job, `--- Folder attempt started (${this.version}). Output: ${job.folderOutput === 'zip' ? 'one verified ZIP' : 'normal folder with separate files'}. ---`);
    try {
      const completedArchive = job.folderOutput === 'zip' && await fileInfo(job.target);
      if (completedArchive && this.matchesFinished({ready:job.archiveReady}, completedArchive)) {
        const message = `Completed. Verified ZIP saved as ${job.name}.`;
        await this.status(job, 'Completed', message);
        await this.log(job, `Result: ${message}`);
        return;
      }
      if (!job.listed) {
        await this.status(job,'Listing','Listing all folder pages and subfolders before starting files.');
        const manifest = job.provider === 'google-drive'
          ? await discoverGoogleDriveFolder(job.link, {client:this.createDriveClient(),signal,onProgress:progress=>{
            job.message=progress.message;this.send();
          }})
          : await this.discover(job.link,{signal,onProgress:progress=>{
            job.message=progress.message;this.send();
          }});
        signal.throwIfAborted();
        const unsupported = manifest.files.filter(entry => entry.state === 'Needs export' || entry.state === 'Unavailable');
        if (unsupported.length) {
          const docs = unsupported.filter(entry => entry.state === 'Needs export').length;
          const blocked = unsupported.length - docs;
          throw new DownloadError(`Folder listing found ${unsupported.length} item${unsupported.length===1?'':'s'} GOB cannot download yet (${docs} Workspace document${docs===1?'':'s'}${blocked?`, ${blocked} download-restricted`:''}). No files were started.`);
        }
        // Save the complete snapshot before creating any transfer. An interrupted
        // listing is never confused with an empty or successfully finished folder.
        // Keep Drive's remote file ID separate from the local History child ID.
        // They are different namespaces; replacing the remote ID with a UUID
        // makes a folder child request the wrong Drive object on resume/start.
        job.entries = manifest.files.map(entry=>({...entry,driveId:entry.id,id:randomUUID()}));
        job.directories = manifest.directories;
        const worker = new Downloader({root:this.jobPath(job,'children'),aria:this.aria,publish:this.publish,emit:()=>{}});
        await fs.mkdir(worker.root,{recursive:true,mode:0o700});
        for (const entry of job.entries) {
          const target=path.join(job.folderRoot || job.target,...entry.local.split('/'));
          const child={id:entry.id,name:path.basename(target),destination:path.dirname(target),target,
            link:entry.url||job.link,provider:job.provider||'dropbox',driveFile:job.provider==='google-drive'?{
              id:entry.driveId||entry.id,name:path.basename(target),mimeType:entry.mimeType,size:entry.size,
              md5Checksum:entry.md5Checksum||'',resourceKey:entry.resourceKey||''
            }:undefined,folder:false,kind:'file',onePass:false,brutal:job.brutal,
            notifications:false,checksum:'',created:job.created,status:'Queued',connections:job.connections,
            speedCap:job.speedCap,folderBudget:job.brutal?Math.floor(16/Math.max(1,Math.min(3,manifest.files.length))):job.connections,expectedSize:entry.size};
          await fs.mkdir(worker.jobPath(child,''),{recursive:true,mode:0o700});
          await worker.save(child);
        }
        job.listed = true;
        await this.save(job);
        await this.log(job, `Full listing saved: ${job.entries.length} files, ${manifest.directories.length} subfolders.`);
      }
      const children=await this.folderChildren(job);
      const ensureDirectory = async dir => {
        await fs.mkdir(dir,{recursive:true});
        if ((await fs.realpath(dir)).normalize('NFC') !== dir.normalize('NFC') || !(await fileInfo(dir))?.isDirectory()) throw new DownloadError('A folder destination contains a substituted link. Files were kept.');
      };
      await ensureDirectory(job.folderRoot || job.target);
      for(const dir of job.directories||[]) await ensureDirectory(path.join(job.folderRoot || job.target,...dir.local.split('/')));
      for(const child of children) await ensureDirectory(child.destination);
      let parallelLimit = job.brutal ? 3 : 1;
      const update = () => {
        if (children.some(child=>child.recovery)) parallelLimit = 1;
        job.children = children.slice(0,500).map((child,index)=>({id:child.id,name:job.entries[index].remote,status:child.status,metrics:child.metrics}));
        job.completedFiles=children.filter(child=>child.status==='Completed').length;
        job.fileCount=children.length;
        job.metrics={total:job.entries.reduce((sum,e)=>sum+e.size,0),done:children.reduce((sum,child,index)=>sum+(child.status==='Completed'?job.entries[index].size:Math.min(job.entries[index].size,child.metrics?.done||0)),0),
          speed:children.reduce((sum,child)=>sum+(child.status==='Downloading'?child.metrics?.speed||0:0),0),connections:children.reduce((sum,child)=>sum+(child.status==='Downloading'?child.metrics?.connections||0:0),0)};
        this.send();
      };
      for(const child of children) {
        if(child.status==='Completed'&&!this.matchesFinished(child,await fileInfo(child.target))) throw new DownloadError('A completed folder file changed or is missing. Check the saved folder before resuming.');
      }
      await this.status(job,'Downloading','Downloading folder files separately.');
      if(job.notifications)this.emit({type:'notification',title:'Folder download started',body:job.name});
      let cursor=0;
      const worker = async workerIndex => {
        while(cursor<children.length&&!signal.aborted&&workerIndex<parallelLimit) {
          const index=cursor++,child=children[index];
          if(child.status==='Completed') {update();continue;}
          if(parallelLimit===1&&job.brutal) {child.brutal=false;child.folderBudget=1;}
          const app = new Downloader({root:this.jobPath(job,'children'),aria:this.aria,publish:this.publish,emit:update,inspect:this.inspect,execute:this.execute,sleep:this.sleep,driveApiKey:this.driveApiKey,driveClient:this.driveClient});
          app.jobs.set(child.id,child);
          app.log=(_child,message)=>this.log(job,`File ${index+1}/${children.length}: ${message}`);
          await app.run(child,null,false,signal);
          update();
        }
      };
      update();
      const results = await Promise.allSettled(Array.from({length:job.brutal?3:1},(_,index)=>worker(index)));
      const rejected = results.find(result=>result.status==='rejected');
      if(rejected) throw rejected.reason;
      update();
      let status=signal.aborted?'Paused':children.every(child=>child.status==='Completed')?'Completed':'Failed';
      let message=status==='Completed'?`Completed. ${children.length} files saved and verified.`:
        status==='Paused'?`Paused. ${job.completedFiles}/${children.length} files completed; Resume keeps them.`:
        `${job.completedFiles}/${children.length} files completed. Resume retries unfinished files.`;
      if (status === 'Completed' && job.folderOutput === 'zip') {
        await this.status(job, 'Verifying', 'Every file is verified. Assembling and checking the ZIP…');
        message = await this.createFolderZip(job, children, signal);
        message = `Completed. ${children.length} files verified and saved as ${job.name}. ${message}`;
      }
      await this.status(job,status,message);
      await this.log(job,`Result: ${message}`);
      if(job.notifications&&status!=='Paused')this.emit({type:'notification',title:status==='Completed'?'Folder download completed':'Folder needs attention',body:message});
    } catch(e) {
      const message=signal.aborted?pauseText:e.message||'The folder could not finish. Saved files were kept.';
      await this.log(job,'Result: '+message);
      await this.status(job,signal.aborted?'Paused':'Failed',message);
    } finally {await this.log(job,`Folder attempt ended. Elapsed: ${Math.round((Date.now()-started)/1000)}s.`);}
  }

  async inspectWithRetry(job, link, signal, fallback = true) {
    let last;
    for (const url of fallback ? link.urls : link.urls.slice(0, 1)) {
      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          const sample = await this.inspect(url, job.folder, job.onePass, signal, fetch,
            link.provider === 'google-drive' ? allowedDriveRedirect : allowedRedirect, link.headers||{},
            link.provider === 'google-drive' ? 'Google Drive' : 'Dropbox');
          if (link.tag && !sample.tag) sample.tag = link.tag;
          return { url, sample: { ...sample, key: link.key } };
        } catch (e) {
          signal.throwIfAborted();
          last = e;
          if (e.zipResponse && job.expectedSize === undefined && /^https:\/\/(?:www\.)?dropbox\.com\/(?:scl\/fo|sh)\//.test(link.original)) throw e;
          if (!(e instanceof DownloadError)) last = new DownloadError(`The network timed out or could not reach ${link.provider === 'google-drive'?'Google Drive':'Dropbox'}.`, 503);
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
    const visibleName = job.name.startsWith('.') ? 'GOB' + job.name : job.name;
    const partial = job.partial || ((await fileInfo(legacy)) ? legacy : path.join(job.destination, `${visibleName}.${job.id}.part`));
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
    await this.log(job, `--- Attempt started (${this.version}) ---`);
    try {
      await this.status(job, 'Checking', 'Checking the link and saved progress.');
      if (job.notifications) this.emit({ type: 'notification', title: 'Download started', body: job.name });
      if (job.ready) {
        await this.finish(job, partial, signal);
        return;
      }
      if (await fileInfo(job.target)) throw new DownloadError('The final filename is already in use.');
      let link;
      if (job.provider === 'google-drive') {
        const parsed = parseGoogleDriveLink(refreshed || job.link);
        const isFolderChild = job.expectedSize !== undefined;
        const driveId = isFolderChild ? job.driveFile?.id : parsed.id;
        const resourceKey = isFolderChild ? (job.driveFile?.resourceKey||'') : parsed.resourceKey;
        const file = await this.createDriveClient().metadata(driveId, resourceKey, signal);
        if (file.mimeType === 'application/vnd.google-apps.folder' || file.mimeType.startsWith('application/vnd.google-apps.')) {
          throw new DownloadError('This Drive item is no longer a downloadable binary file. Check its sharing and file type.');
        }
        if (file.capabilities?.canDownload === false) throw new DownloadError('The owner has disabled downloading for this Google Drive item.');
        const driveFile = {id:file.id,name:file.name,mimeType:file.mimeType,size:Number(file.size),md5Checksum:file.md5Checksum||'',resourceKey:file.resourceKey||resourceKey||''};
        if (!Number.isSafeInteger(driveFile.size) || driveFile.size < 0) throw new DownloadError('Google Drive did not provide a reliable file size.');
        if (job.expectedSize !== undefined && driveFile.size !== job.expectedSize) throw new DownloadError('This Google Drive file changed size after the folder was listed. Saved files were kept.');
        job.driveFile = driveFile;
        const transfer = driveTransferRequest(driveFile, {apiKey:this.driveApiKey});
        link = {provider:'google-drive',original:parsed.original,folder:false,urls:[transfer.url],headers:transfer.headers,
          key:hash(`drive:${driveFile.id}:${driveFile.resourceKey}`),tag:driveFile.md5Checksum?`"${driveFile.md5Checksum}"`:''};
      } else {
        link = parseLink(refreshed || job.link);
        link.provider = 'dropbox';
      }
      if (link.folder !== job.folder) throw new DownloadError(`Use the same type of ${job.provider==='google-drive'?'Google Drive':'Dropbox'} link as the original download.`);
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
        if (error.zipResponse && job.expectedSize === undefined && /^https:\/\/(?:www\.)?dropbox\.com\/(?:scl\/fo|sh)\//.test(link.original)) {
          throw new DownloadError('Dropbox returned a folder ZIP. Paste the whole folder’s share link so GOB can list and download its files separately.');
        }
        job.onePass = true;
        streamOnly = true;
        await this.log(job, `${job.provider==='google-drive'?'Google Drive':'Dropbox'} ignored ranges. Automatically using one stream for this new download.`);
        checked = await this.inspectWithRetry(job, link, signal);
      }
      const { sample, url } = checked;
      if (job.provider === 'google-drive' && sample.total !== job.driveFile?.size) {
        throw new DownloadError('Google Drive returned a different file size than its metadata. Saved files were kept.');
      }
      if (job.expectedSize !== undefined && sample.total !== job.expectedSize) {
        throw new DownloadError(`This ${job.provider==='google-drive'?'Google Drive':'Dropbox'} file changed size after the folder was listed. Saved files were kept; download the changed folder under a new name.`);
      }
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
      await this.log(job, `Source checked. Provider: ${job.provider==='google-drive'?'Google Drive':'Dropbox'}. Size: ${sample.total || 'unknown'} bytes. Mode: ${streamOnly ? 'single stream' : 'resumable'}.`);

      let connections = streamOnly ? 1 : job.folderBudget || (job.brutal ? 16 : job.connections);
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
        for (const [name,value] of Object.entries(link.headers||{})) options.push(`--header=${name}: ${value}`);
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
        await this.log(job, `aria2 exit code ${code}.${lastHttp ? ` ${job.provider==='google-drive'?'Google Drive':'Dropbox'} returned HTTP ${lastHttp}. ${httpMeaning[lastHttp] || 'The server rejected the request.'}` : ''}`);
        const info = await fileInfo(partial);
        const controlExists = Boolean(await fileInfo(control));
        const checkpoint = !streamOnly && controlExists ? await readCheckpoint(control) : null;
        const completeCheckpoint = checkpoint?.complete && checkpoint.total === sample.total;
        if (info?.isFile() && ((code === 0 || resultOK) && !controlExists || completeCheckpoint)) {
          if ((sample.total && info.size !== sample.total) || info.size < sample.count) {
            throw new DownloadError(`The final byte count did not match ${job.provider==='google-drive'?'Google Drive':'Dropbox'}. The partial was kept.`);
          }
          if (code !== 0) await this.log(job, 'The final result or saved pieces confirm all bytes arrived. Checking the file locally.');
          job.ready = { size: info.size, ino: info.ino, dev: info.dev, modified: info.mtimeMs, checkpoint: Boolean(completeCheckpoint) };
          await this.save(job);
          await this.finish(job, partial, signal);
          return;
        }
        signal.throwIfAborted();
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
        e instanceof DownloadError || e instanceof GoogleDriveError ? e.message : 'The network, save volume, or download history became unavailable. Saved transfer files were kept.';
      await this.log(job, `Result: ${message}`);
      if (!signal.aborted && job.notifications) this.emit({ type: 'notification', title: 'Download needs attention', body: job.name });
      await this.status(job, signal.aborted ? 'Paused' : 'Failed', message);
    } finally {
      await this.log(job, `Attempt ended. Elapsed: ${Math.round((Date.now() - started) / 1000)}s.`);
    }
  }

  async finish(job, partial, signal) {
    signal.throwIfAborted();
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
        if (job.provider === 'google-drive' && /^[a-f0-9]{32}$/i.test(job.driveFile?.md5Checksum||'')) {
          const digest = createHash('md5');
          for await (const chunk of createReadStream(partial, { signal })) digest.update(chunk);
          if (digest.digest('hex').toLowerCase() !== job.driveFile.md5Checksum.toLowerCase()) {
            throw new DownloadError('Google Drive’s MD5 check did not match. The partial was kept for inspection.');
          }
        }
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
