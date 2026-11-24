import test from 'node:test';
import assert from 'node:assert/strict';
import {createDriveClient, discoverGoogleDriveFolder, driveLocalComponent, driveTransferRequest, GoogleDriveError, parseGoogleDriveLink} from '../Sources/google-drive.mjs';

test('recognizes Drive file/folder/Docs links and preserves link resource keys', () => {
  assert.deepEqual(
    (({id, folder, resourceKey}) => ({id, folder, resourceKey}))(parseGoogleDriveLink('https://drive.google.com/drive/folders/Folder_12345?resourcekey=key_abc')),
    {id:'Folder_12345', folder:true, resourceKey:'key_abc'}
  );
  assert.equal(parseGoogleDriveLink('https://docs.google.com/document/d/File_12345/edit').folder, false);
  assert.equal(parseGoogleDriveLink('https://drive.google.com/open?id=File_12345').id, 'File_12345');
  for (const link of ['http://drive.google.com/file/d/File_12345', 'https://drive.google.com.evil.test/file/d/File_12345',
    'https://drive.google.com/file/d/%2e%2e']) assert.throws(() => parseGoogleDriveLink(link), GoogleDriveError);
});

test('sanitizes Windows-reserved, trailing-dot and unsafe file names', () => {
  assert.equal(driveLocalComponent('CON.txt'), '~reserved-CON.txt');
  assert.match(driveLocalComponent('clip. '), /~002e~0020$/);
  for (const name of ['..', '../escape', 'a\\b', '']) assert.throws(() => driveLocalComponent(name), GoogleDriveError);
});

function fakeDrive({metadata, pages}) {
  const calls=[];
  return {
    calls,
    metadata: async (id, key) => { calls.push(['metadata', id, key]); if (!metadata[id]) throw new GoogleDriveError('missing'); return metadata[id]; },
    listPage: async (id, key, token) => { calls.push(['list', id, key, token]); return pages(id, token); }
  };
}

test('lists every nested page and keeps resource keys and relative folder structure', async () => {
  const drive=fakeDrive({
    metadata:{root__12345:{id:'root__12345',name:'Root',mimeType:'application/vnd.google-apps.folder'},
      nested:{id:'nested_12345',name:'Sub',mimeType:'application/vnd.google-apps.folder',resourceKey:'subkey'},
      movie:{id:'movie_12345',name:'take.mov',mimeType:'video/quicktime',size:'4096',md5Checksum:'a'.repeat(32),resourceKey:'filekey'}},
    pages:(id,token)=> id==='root__12345' && !token ? {files:[
      {id:'nested_12345',name:'Sub',mimeType:'application/vnd.google-apps.folder',resourceKey:'subkey'},
      {id:'movie_12345',name:'one.mp4',mimeType:'video/mp4',size:'123',md5Checksum:'b'.repeat(32),resourceKey:'filekey'}],nextPageToken:'page2'}
      : id==='root__12345' ? {files:[{id:'movie_12345',name:'two.mp4',mimeType:'video/mp4',size:'456'}]}
      : {files:[{id:'movie_12345',name:'take.mov',mimeType:'video/quicktime',size:'4096',resourceKey:'filekey'}]}
  });
  const manifest=await discoverGoogleDriveFolder(parseGoogleDriveLink('https://drive.google.com/drive/folders/root__12345?resourcekey=rootkey'),{client:drive});
  assert.deepEqual(manifest.files.map(x=>x.local),['one.mp4','two.mp4','Sub/take.mov']);
  assert.deepEqual(manifest.files.map(x=>x.size),[123,456,4096]);
  assert.deepEqual(manifest.directories.map(x=>x.local),['Sub']);
  assert.ok(drive.calls.some(c=>c[0]==='list'&&c[1]==='nested_12345'&&c[2]==='subkey'));
});

test('does not report Workspace files as resumable binary downloads', async () => {
  const drive=fakeDrive({metadata:{root__12345:{id:'root__12345',name:'Root',mimeType:'application/vnd.google-apps.folder'}},
    pages:()=>({files:[{id:'doc__12345',name:'Brief',mimeType:'application/vnd.google-apps.document'}]})});
  const result=await discoverGoogleDriveFolder('https://drive.google.com/drive/folders/root__12345',{client:drive});
  assert.equal(result.files[0].state,'Needs export');
  assert.equal(result.files[0].size,0);
});

test('rejects repeated pagination tokens and reports private access without claiming the link is malformed', async () => {
  const repeated=fakeDrive({metadata:{root__12345:{id:'root__12345',name:'Root',mimeType:'application/vnd.google-apps.folder'}},pages:()=>({files:[],nextPageToken:'again'})});
  await assert.rejects(discoverGoogleDriveFolder('https://drive.google.com/drive/folders/root__12345',{client:repeated}),/repeated a folder page/i);
  const request=async()=>new Response(JSON.stringify({error:{message:'login required'}}),{status:403,headers:{'content-type':'application/json'}});
  const client=createDriveClient({apiKey:'test-only',request,sleep:async()=>{}});
  await assert.rejects(client.metadata('file_12345','key',undefined),/Anyone with the link/i);
  const missing=createDriveClient({apiKey:'test-only',request:async()=>new Response(JSON.stringify({error:{message:'not found'}}),{status:404,headers:{'content-type':'application/json'}})});
  await assert.rejects(missing.metadata('file_12345'),/not available publicly.*Anyone with the link/i);
});

test('uses API key and X-Goog-Drive-Resource-Keys header, and retries rate limits', async () => {
  let calls=0;
  const request=async(url,{headers})=>{
    calls++;
    assert.match(url,/key=test-only/);
    assert.equal(headers['X-Goog-Drive-Resource-Keys'],'file_12345/key_123');
    if(calls===1)return new Response('',{status:429,headers:{'retry-after':'1'}});
    return new Response(JSON.stringify({id:'file_12345',name:'clip.mp4',mimeType:'video/mp4',size:'42'}),{headers:{'content-type':'application/json'}});
  };
  const slept=[];
  const client=createDriveClient({apiKey:'test-only',request,sleep:async ms=>slept.push(ms)});
  const result=await client.metadata('file_12345','key_123');
  assert.equal(result.name,'clip.mp4');
  assert.equal(calls,2);
  assert.deepEqual(slept,[1000]);
});

test('builds a balanced Google Drive folder-list field mask', async () => {
  let requested;
  const client=createDriveClient({apiKey:'test-only',request:async url=>{
    requested=new URL(url);
    return new Response(JSON.stringify({files:[]}),{headers:{'content-type':'application/json'}});
  }});
  await client.listPage('folder_12345','resource_key_123');
  const fields=requested.searchParams.get('fields');
  assert.ok(fields.startsWith('nextPageToken,files('));
  assert.equal([...fields].filter(char=>char==='(').length,[...fields].filter(char=>char===')').length);
  assert.match(fields,/targetResourceKey\)\)$/);
});

test('recognizes Drive quota 403s separately from private-link permissions', async () => {
  let calls=0;
  const slept=[];
  const request=async()=>{
    calls++;
    if(calls===1)return new Response(JSON.stringify({error:{message:'Rate Limit Exceeded',errors:[{reason:'userRateLimitExceeded'}]}}),{status:403,headers:{'content-type':'application/json'}});
    return new Response(JSON.stringify({id:'file_12345',name:'clip.mp4',mimeType:'video/mp4',size:'42'}),{headers:{'content-type':'application/json'}});
  };
  const client=createDriveClient({apiKey:'test-only',request,sleep:async ms=>slept.push(ms)});
  const result=await client.metadata('file_12345');
  assert.equal(result.id,'file_12345');
  assert.equal(calls,2);
  assert.deepEqual(slept,[2000]);
});

test('builds binary-only range-capable Drive download requests without dropping resource keys', () => {
  const request=driveTransferRequest({id:'file_12345',name:'clip.mov',mimeType:'video/quicktime',size:'64',md5Checksum:'c'.repeat(32),resourceKey:'key_123'}, {apiKey:'restricted-test-key'});
  const url=new URL(request.url);
  assert.equal(url.origin,'https://www.googleapis.com');
  assert.equal(url.pathname,'/drive/v3/files/file_12345');
  assert.equal(url.searchParams.get('alt'),'media');
  assert.equal(url.searchParams.get('key'),'restricted-test-key');
  assert.equal(request.headers['X-Goog-Drive-Resource-Keys'],'file_12345/key_123');
  assert.equal(request.size,64);
  assert.throws(()=>driveTransferRequest({id:'doc_12345',mimeType:'application/vnd.google-apps.document'},{apiKey:'test'}),/binary file/i);
});
