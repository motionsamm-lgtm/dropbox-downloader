// Google Drive provider adapter. Uses Drive API v3 metadata/listing rather
// than parsing the Drive website's private HTML. Callers supply either a
// restricted API key for public links or an OAuth access token.
import {createHash} from 'node:crypto';
import {setTimeout as delay} from 'node:timers/promises';

const API = 'https://www.googleapis.com/drive/v3';
const FOLDER_MIME = 'application/vnd.google-apps.folder';
const MAX_ENTRIES = 100000;
const MAX_DEPTH = 128;

export class GoogleDriveError extends Error {
  constructor(message, status = 0, retryAfter = 0) {
    super(message);
    this.status = status;
    this.retryAfter = retryAfter;
  }
}

function fail(message) { throw new GoogleDriveError(message); }

export function parseGoogleDriveLink(value) {
  let url;
  try { url = new URL(String(value).trim()); }
  catch { fail('Paste a valid Google Drive share link.'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.port ||
      !['drive.google.com', 'www.drive.google.com', 'docs.google.com'].includes(url.hostname)) {
    fail('Use an HTTPS Google Drive or Docs share link.');
  }

  const segments = url.pathname.split('/').filter(Boolean);
  let id = '';
  let folder = false;
  if (segments[0] === 'drive' && segments[1] === 'folders' && segments[2]) {
    id = segments[2]; folder = true;
  } else if (['file', 'document', 'spreadsheets', 'presentation'].includes(segments[0]) &&
      segments[1] === 'd' && segments[2]) {
    id = segments[2];
  } else if (['open', 'uc'].includes(segments[0])) {
    id = url.searchParams.get('id') || '';
  }
  if (!/^[A-Za-z0-9_-]{5,200}$/.test(id)) fail('The Google Drive link does not contain a supported file or folder ID.');

  const resourceKey = url.searchParams.get('resourcekey') || url.searchParams.get('resourceKey') || '';
  if (resourceKey && !/^[A-Za-z0-9_-]{1,256}$/.test(resourceKey)) fail('The Google Drive link has an invalid resource key.');
  url.hash = '';
  url.searchParams.sort();
  return {
    provider: 'google-drive', original: url.href, id, folder, resourceKey,
    identity: createHash('sha256').update(`drive:${id}:${resourceKey}`).digest('hex')
  };
}

export function isGoogleDriveLink(value) {
  try {
    const url = new URL(String(value).trim());
    return ['drive.google.com', 'www.drive.google.com', 'docs.google.com'].includes(url.hostname);
  } catch { return false; }
}

export function driveLocalComponent(name) {
  if (typeof name !== 'string' || !name.trim() || name === '.' || name === '..' ||
      /[\\/\x00-\x1f\x7f]/.test(name)) fail('Google Drive returned an unsafe filename.');
  let local = name.normalize('NFC').replace(/[<>:"|?*]/g, c => `~${c.codePointAt(0).toString(16).padStart(4, '0')}`);
  local = local.replace(/[. ]+$/, suffix => [...suffix].map(c => `~${c.codePointAt(0).toString(16).padStart(4, '0')}`).join(''));
  if (/^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(local)) local = `~reserved-${local}`;
  if (Buffer.byteLength(local, 'utf8') > 100) {
    const suffix = createHash('sha256').update(name).digest('hex').slice(0, 16);
    local = [...local].slice(0, 40).join('') + '~' + suffix;
  }
  return local;
}

export function driveTransferRequest(file, {apiKey} = {}) {
  if (!file || !/^[A-Za-z0-9_-]{5,200}$/.test(file.id) ||
      typeof file.mimeType !== 'string' || file.mimeType.startsWith('application/vnd.google-apps.')) {
    fail('This Google Drive item is not a downloadable binary file.');
  }
  if (!apiKey) fail('Google Drive public-link access is not configured.');
  const url = new URL(`${API}/files/${encodeURIComponent(file.id)}`);
  url.searchParams.set('alt', 'media');
  url.searchParams.set('key', apiKey);
  const headers = {};
  if (file.resourceKey) headers['X-Goog-Drive-Resource-Keys'] = `${file.id}/${file.resourceKey}`;
  return {url: url.href, headers, size: Number(file.size), md5Checksum: file.md5Checksum || ''};
}

function retrySeconds(response, attempt) {
  const value = response.headers.get('retry-after') || '';
  if (/^\d+$/.test(value)) return Math.max(1, Math.min(120, Number(value)));
  const date = Date.parse(value);
  if (Number.isFinite(date)) return Math.max(1, Math.min(120, Math.ceil((date - Date.now()) / 1000)));
  return Math.min(60, 2 ** attempt * 2);
}

function safeResourceKeys(entries) {
  return entries.filter(x => x?.id && x?.resourceKey)
    .map(x => `${x.id}/${x.resourceKey}`).join(',');
}

export function createDriveClient({apiKey = '', accessToken = '', request = fetch, sleep = delay} = {}) {
  if (!apiKey && !accessToken) fail('Google Drive access is not configured yet.');
  const credentials = {apiKey, accessToken};

  async function json(endpoint, {params = {}, resourceKeys = [], signal, fields = 'error'} = {}) {
    const query = new URLSearchParams(params);
    if (credentials.apiKey) query.set('key', credentials.apiKey);
    const headers = {Accept: 'application/json'};
    if (credentials.accessToken) headers.Authorization = `Bearer ${credentials.accessToken}`;
    const keyHeader = safeResourceKeys(resourceKeys);
    if (keyHeader) headers['X-Goog-Drive-Resource-Keys'] = keyHeader;
    for (let attempt = 0; attempt < 4; attempt++) {
      signal?.throwIfAborted();
      let response;
      try {
        response = await request(`${API}${endpoint}?${query}`, {signal, headers});
      } catch (error) {
        if (signal?.aborted) throw error;
        if (attempt === 3) throw new GoogleDriveError('Could not reach Google Drive. Check the connection and try again.');
        await sleep(Math.min(60, 2 ** attempt * 2) * 1000, undefined, {signal});
        continue;
      }
      if (response.ok) {
        const type = response.headers.get('content-type') || '';
        if (!/application\/json/i.test(type)) {
          await response.body?.cancel();
          throw new GoogleDriveError('Google Drive returned an unexpected response. The download was not started.');
        }
        try { return await response.json(); }
        catch { throw new GoogleDriveError('Google Drive returned an incomplete metadata response.'); }
      }
      const status = response.status;
      let errorData = {};
      try { errorData = await response.json(); } catch { await response.body?.cancel().catch(() => {}); }
      const errorText = `${errorData?.error?.message||''} ${errorData?.error?.status||''} ${(errorData?.error?.errors||[]).map(x=>x?.reason||'').join(' ')}`;
      const quota = status === 429 || /rateLimitExceeded|userRateLimitExceeded|dailyLimitExceeded|quotaExceeded|too many requests/i.test(errorText);
      const retryable = [408, 429, 500, 502, 503, 504].includes(status) || quota;
      const wait = retrySeconds(response, attempt);
      if (retryable && attempt < 3) {
        await sleep(wait * 1000, undefined, {signal});
        continue;
      }
      if (quota) throw new GoogleDriveError('Google Drive is limiting requests or the project quota is exhausted. Wait a little, then resume.', status, wait);
      if (status === 401 || status === 403) {
        if (/API_KEY_[A-Z_]+|SERVICE_DISABLED|accessNotConfigured/i.test(errorText)) {
          throw new GoogleDriveError('GOB could not use its Google Drive API configuration. Check for a newer app build or contact the GOB developer.', status);
        }
        throw new GoogleDriveError('This Google Drive link needs public access. Set General access to “Anyone with the link” and allow viewers to download, then paste the link again. GOB does not sign in to Google.', status);
      }
      if (status === 404) throw new GoogleDriveError('Google Drive could not find this item or it is not available publicly. Confirm it exists and set General access to “Anyone with the link”; GOB does not sign in to Google.', status);
      if (status === 429) throw new GoogleDriveError('Google Drive is limiting requests. Wait a little, then resume.', status, wait);
      throw new GoogleDriveError(`Google Drive returned HTTP ${status}. The job and saved files were kept.`, status, retryable ? wait : 0);
    }
    throw new GoogleDriveError('Google Drive could not complete the metadata request.');
  }

  async function metadata(id, resourceKey = '', signal) {
    const data = await json(`/files/${encodeURIComponent(id)}`, {
      params: {fields: 'id,name,mimeType,size,md5Checksum,resourceKey,capabilities(canDownload),shortcutDetails(targetId,targetMimeType,targetResourceKey)'},
      resourceKeys: [{id, resourceKey}], signal
    });
    if (data.id !== id || typeof data.name !== 'string' || !data.mimeType) {
      throw new GoogleDriveError('Google Drive returned incomplete file details.');
    }
    if (data.capabilities?.canDownload === false) throw new GoogleDriveError('The owner has disabled downloading for this Google Drive item.');
    return data;
  }

  async function listPage(folderId, resourceKey, pageToken, signal) {
    const params = {
      q: `'${folderId.replace(/\\/g, '\\\\').replace(/'/g, "\\'")}' in parents and trashed = false`,
      pageSize: '1000',
      orderBy: 'name',
      supportsAllDrives: 'true',
      includeItemsFromAllDrives: 'true',
      fields: 'nextPageToken,files(id,name,mimeType,size,md5Checksum,resourceKey,capabilities(canDownload),shortcutDetails(targetId,targetMimeType,targetResourceKey))'
    };
    if (pageToken) params.pageToken = pageToken;
    const data = await json('/files', {params, resourceKeys: [{id: folderId, resourceKey}], signal});
    if (!Array.isArray(data.files)) throw new GoogleDriveError('Google Drive returned an incomplete folder page. GOB stopped before starting downloads.');
    if (data.nextPageToken !== undefined && (typeof data.nextPageToken !== 'string' || !data.nextPageToken)) {
      throw new GoogleDriveError('Google Drive returned an invalid next-page token.');
    }
    return data;
  }

  return {metadata, listPage};
}

function uniqueLocal(remotePath, seen) {
  let local = remotePath;
  const key = local.toLocaleLowerCase('en-US');
  if (seen.has(key)) {
    const suffix = createHash('sha256').update(remotePath).digest('hex').slice(0, 12);
    const slash = local.lastIndexOf('/');
    const parent = slash < 0 ? '' : local.slice(0, slash + 1);
    const base = slash < 0 ? local : local.slice(slash + 1);
    const dot = base.lastIndexOf('.');
    local = dot > 0 ? `${parent}${base.slice(0, dot)}~${suffix}${base.slice(dot)}` : `${parent}${base}~${suffix}`;
  }
  if (seen.has(local.toLocaleLowerCase('en-US'))) fail('Two Google Drive items map to the same local path.');
  seen.add(local.toLocaleLowerCase('en-US'));
  return local;
}

export async function discoverGoogleDriveFolder(link, {client, signal, onProgress = () => {}} = {}) {
  const root = typeof link === 'string' ? parseGoogleDriveLink(link) : link;
  if (!root?.folder) fail('Use a Google Drive folder link for a folder download.');
  if (!client?.metadata || !client?.listPage) fail('Google Drive access is not configured yet.');
  const rootMetadata = await client.metadata(root.id, root.resourceKey, signal);
  if (rootMetadata.mimeType !== FOLDER_MIME) fail('This Google Drive link points to a file, not a folder.');

  const files = [], directories = [], pending = [{id: root.id, key: root.resourceKey, remote: '', local: '', depth: 0}];
  const seenFolders = new Set([root.id]);
  const seenPaths = new Set();
  const pageTokens = new Set();
  for (let cursor = 0; cursor < pending.length; cursor++) {
    signal?.throwIfAborted();
    if (pending.length + files.length > MAX_ENTRIES) fail('This Google Drive folder exceeds GOB’s 100,000-item safety limit.');
    const folder = pending[cursor];
    let pageToken = '';
    const seenTokens = new Set();
    do {
      const page = await client.listPage(folder.id, folder.key, pageToken || undefined, signal);
      for (const listed of page.files) {
        if (!listed || typeof listed.id !== 'string' || !/^[A-Za-z0-9_-]{5,200}$/.test(listed.id) ||
            typeof listed.name !== 'string' || !listed.name || typeof listed.mimeType !== 'string') {
          fail('Google Drive returned an item with missing or invalid details.');
        }
        if (listed.capabilities?.canDownload === false) {
          files.push({id: listed.id, remote: listed.name, local: '', size: 0, mimeType: listed.mimeType,
            resourceKey: listed.resourceKey || '', state: 'Unavailable', reason: 'The owner disabled downloading.'});
          continue;
        }
        let item = listed;
        if (listed.mimeType === 'application/vnd.google-apps.shortcut') {
          const targetId = listed.shortcutDetails?.targetId;
          if (!targetId) fail('Google Drive returned a shortcut without its target.');
          item = await client.metadata(targetId, listed.shortcutDetails.targetResourceKey || '', signal);
          item = {...item, name: listed.name, id: targetId,
            resourceKey: listed.shortcutDetails.targetResourceKey || item.resourceKey || ''};
        }
        const component = driveLocalComponent(item.name);
        const remote = [folder.remote, item.name].filter(Boolean).join('/');
        const localPath = uniqueLocal([folder.local, component].filter(Boolean).join('/'), seenPaths);
        if (item.mimeType === FOLDER_MIME) {
          if (folder.depth + 1 > MAX_DEPTH) fail('This Google Drive folder exceeds GOB’s 128-level nesting limit.');
          if (seenFolders.has(item.id)) {
            files.push({id: item.id, remote, local: localPath, size: 0, mimeType: item.mimeType,
              resourceKey: item.resourceKey || '', state: 'Skipped', reason: 'A folder shortcut points to a folder already included.'});
            continue;
          }
          seenFolders.add(item.id);
          directories.push({remote, local: localPath, id: item.id});
          pending.push({id: item.id, key: item.resourceKey || '', remote, local: localPath, depth: folder.depth + 1});
          continue;
        }
        const isWorkspace = item.mimeType.startsWith('application/vnd.google-apps.');
        const size = isWorkspace ? 0 : Number(item.size);
        if (!isWorkspace && (!Number.isSafeInteger(size) || size < 0)) fail(`Google Drive omitted the size for “${item.name}”.`);
        files.push({id: item.id, remote, local: localPath, size, mimeType: item.mimeType,
          md5Checksum: item.md5Checksum || '', resourceKey: item.resourceKey || '',
          state: isWorkspace ? 'Needs export' : 'Queued', reason: isWorkspace ? 'Google Workspace document export must be selected.' : ''});
        if (files.length + pending.length > MAX_ENTRIES) fail('This Google Drive folder exceeds GOB’s 100,000-item safety limit.');
      }
      onProgress({files: files.length, folders: directories.length, message: `Found ${files.length} items in ${directories.length} subfolders…`});
      pageToken = page.nextPageToken || '';
      if (!pageToken) break;
      if (seenTokens.has(pageToken) || pageTokens.has(`${folder.id}:${pageToken}`)) fail('Google Drive repeated a folder page. The listing is incomplete.');
      seenTokens.add(pageToken); pageTokens.add(`${folder.id}:${pageToken}`);
      if (seenTokens.size > 10000) fail('Google Drive returned too many folder pages.');
    } while (true);
  }
  return {schema: 1, provider: 'google-drive', source: root.original, rootId: root.id,
    files, directories, listedAt: new Date().toISOString()};
}
