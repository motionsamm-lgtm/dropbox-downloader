from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import argparse,time
p=argparse.ArgumentParser();p.add_argument('--port',type=int,required=True);a=p.parse_args()
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_GET(self):
  if self.path=='/forbidden':
   self.send_response(403);self.end_headers();return
  total=64*1024*1024 if self.path=='/slow' else 128*1024
  start=0;end=total-1
  if self.headers.get('Range'):
   import re
   m=re.fullmatch(r'bytes=(\d+)-(\d*)',self.headers['Range'])
   if not m:self.send_error(416);return
   start=int(m[1]);end=min(int(m[2]) if m[2] else end,end)
   if start>end:self.send_error(416);return
  self.send_response(206 if self.headers.get('Range') else 200)
  self.send_header('Content-Length',str(end-start+1));self.send_header('Accept-Ranges','bytes')
  if self.headers.get('Range'):self.send_header('Content-Range',f'bytes {start}-{end}/{total}')
  self.end_headers()
  left=end-start+1
  try:
   while left:
    n=min(left,65536);self.wfile.write(b'G'*n);self.wfile.flush();left-=n
    if self.path=='/slow':time.sleep(.03)
  except (BrokenPipeError,ConnectionResetError,ConnectionAbortedError):pass
ThreadingHTTPServer(('127.0.0.1',a.port),Handler).serve_forever()
