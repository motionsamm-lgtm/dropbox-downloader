from pathlib import Path
import sys,re,plistlib
version=sys.argv[1]
if not re.fullmatch(r'\d+\.\d+\.\d+',version): raise SystemExit('Use a numeric three-part version.')
def change(name,pattern,replacement):
 p=Path(name); raw=p.read_bytes(); bom=raw.startswith(b'\xef\xbb\xbf')
 text,count=re.subn(pattern,replacement,raw.decode('utf-8-sig'))
 if not count: raise SystemExit('Missing version field in '+name)
 p.write_bytes((b'\xef\xbb\xbf' if bom else b'')+text.encode())
change('windows/Launcher.cs',r'(Assembly(?:File)?Version\(")[\d.]+("\))',lambda m:m[1]+version+'.0'+m[2])
change('windows/GOB-Update.ps1',r"(\[version\]')\d+\.\d+\.\d+(')",lambda m:m[1]+version+m[2])
change('windows/GOB-Setup.iss',r'(#define AppVersion ")[\d.]+(")',lambda m:m[1]+version+m[2])
change('windows/Dropbox-Downloader.ps1',r'GOB \d+\.\d+\.\d+', 'GOB '+version)
change('mac/Sources/updates.mjs',r"(export const currentVersion = ')[\d.]+(')",lambda m:m[1]+version+m[2])
change('mac/Sources/interface.html',r'(font-size:14px">)[\d.]+(</span>)',lambda m:m[1]+version+m[2])
p=Path('mac/Info.plist'); d=plistlib.loads(p.read_bytes());d['CFBundleShortVersionString']=version;d['CFBundleVersion']=version;p.write_bytes(plistlib.dumps(d))
# Keep the manifest test's sample newer than the release under test.
p=Path('mac/Tests/updates.test.mjs');text=p.read_text();text=re.sub(r"(const valid=\{version:')[\d.]+(')",lambda m:m[1]+str(int(version.split('.')[0])+1)+'.0.0'+m[2],text);p.write_text(text)
