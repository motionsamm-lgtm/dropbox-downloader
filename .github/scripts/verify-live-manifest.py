import sys,json,hashlib,urllib.request
manifest=json.load(open(sys.argv[1]))
for platform,asset in manifest['assets'].items():
 digest=hashlib.sha256();size=0
 with urllib.request.urlopen(asset['url'],timeout=120) as response:
  while chunk:=response.read(1024*1024):digest.update(chunk);size+=len(chunk)
 assert size==asset['size'] and digest.hexdigest()==asset['sha256'],platform+' public asset mismatch'
 print('PASS: anonymous public download and SHA-256 for',platform)
