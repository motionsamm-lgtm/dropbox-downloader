// Public press-kit link printed by the Banipal Trust in its 2023 shortlist
// press release. Never put a client's private shared link in this CI check.
import {discoverFolder} from '../../shared/dropbox-folder.mjs';
import {parseLink,probe} from '../../mac/Sources/engine.mjs';
const url='https://www.dropbox.com/scl/fo/hsynj5331wvy39wer5egb/h?rlkey=oxhfrqft9ufoo3y0es4a2f8wz&dl=0';
const signal=AbortSignal.timeout(90000);
const manifest=await discoverFolder(url,{signal});
if(!manifest.files.length)throw new Error('Public press-kit folder returned no files.');
console.log(`Public listing: ${manifest.files.length} files, ${manifest.directories.length} subfolders.`);
let checked;
for(const candidate of parseLink(manifest.files.find(f=>f.size>0).url).urls){
 try{checked=await probe(candidate,false,false,signal);break;}catch{}
}
if(!checked)throw new Error('No public file accepted a verifiable range response.');
console.log('A listed file accepted a verified byte-range response. No file was saved.');
