import * as fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
export const currentVersion = '1.1.3';
export const manifestURL = 'https://github.com/motionsamm-lgtm/dropbox-downloader/releases/latest/download/gob-update.json';
export function newer(a, b) {
  if (!/^\d+\.\d+\.\d+$/.test(a)) return false;
  const x=a.split('.').map(Number), y=b.split('.').map(Number);
  for(let i=0;i<3;i++) { if(x[i]!==y[i]) return x[i]>y[i]; }
  return false;
}
export function selectUpdate(manifest, platform) {
  if (!newer(manifest.version,currentVersion)) return null;
  const asset=manifest.assets?.[platform];
  if (!asset || !/^[a-f0-9]{64}$/.test(asset.sha256) || !Number.isSafeInteger(asset.size) || asset.size<=0 || asset.size>300*1024*1024) throw Error('Invalid update manifest.');
  const url=new URL(asset.url);
  if(url.origin!=='https://github.com' || !url.pathname.startsWith('/motionsamm-lgtm/dropbox-downloader/releases/download/') || url.username || url.password) throw Error('Invalid update address.');
  return {...asset,version:manifest.version};
}
export async function checkUpdate(platform, request=fetch) {
  const response=await request(manifestURL,{signal:AbortSignal.timeout(15000)});
  if(!response.ok) throw Error('Updates are unavailable. Check your connection or release access.');
  const body=await response.text();
  if(body.length>65536) throw Error('Invalid update manifest.');
  return selectUpdate(JSON.parse(body),platform);
}
export async function downloadUpdate(asset, directory, request=fetch) {
  await fs.mkdir(directory,{recursive:true,mode:0o700});
  const target=path.join(directory,'GOB-update.zip');
  const temporary=target+'.tmp';
  const response=await request(asset.url,{signal:AbortSignal.timeout(300000)});
  if(!response.ok||!response.body) throw Error('The update download failed.');
  const digest=createHash('sha256');
  const fd=await fs.open(temporary,'w',0o600);
  let size=0;
  try {
    for await(const bytes of response.body) {
      size+=bytes.length;
      if(size>asset.size) throw Error('The update is larger than expected.');
      digest.update(bytes);
      await fd.writeFile(bytes);
    }
    await fd.sync();
  } finally { await fd.close(); }
  if(size!==asset.size || digest.digest('hex')!==asset.sha256) {
    await fs.unlink(temporary).catch(()=>{});
    throw Error('Update verification failed. Your installed app was kept.');
  }
  await fs.rename(temporary,target);
  return target;
}
