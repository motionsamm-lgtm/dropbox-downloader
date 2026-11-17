import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import * as fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { newer, selectUpdate, downloadUpdate } from '../Sources/updates.mjs';
test('update version comparisons handle numeric versions and reject downgrades',()=>{
 assert(newer('1.10.0','1.9.0'));
 assert(!newer('1.0.0','1.0.0'));
 assert(!newer('0.9.0','1.0.0'));
 assert(!newer('nonsense','1.0.0'));
});
test('manifest restricts update hosts, checksum and platform',()=>{
 const valid={version:'1.1.0',assets:{'mac-arm64':{url:'https://github.com/motionsamm-lgtm/dropbox-downloader/releases/download/v1.1.0/GOB.zip',size:10,sha256:'a'.repeat(64)}}};
 assert(selectUpdate(valid,'mac-arm64'));
 assert.throws(()=>selectUpdate(valid,'mac-x64'));
 valid.assets['mac-arm64'].url='https://untrusted.test/GOB.zip';
 assert.throws(()=>selectUpdate(valid,'mac-arm64'));
});
test('only verified bytes become installable update',async t=>{
 const root=await fs.mkdtemp(path.join(os.tmpdir(),'gob-update-'));
 t.after(()=>fs.rm(root,{recursive:true,force:true}));
 const bytes=Buffer.from('test archive');
 const asset={url:'https://github.com/test',size:bytes.length,sha256:createHash('sha256').update(bytes).digest('hex')};
 const result=await downloadUpdate(asset,root,async()=>new Response(bytes));
 assert.deepEqual(await fs.readFile(result),bytes);
 await assert.rejects(downloadUpdate({...asset,sha256:'0'.repeat(64)},root,async()=>new Response(bytes)),/verification failed/);
 assert.deepEqual(await fs.readFile(result),bytes);
});
