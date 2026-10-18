#!/usr/bin/env python3
"""Throttled static server with Range support: serve.py ROOT PORT BYTES_PER_SEC.
/assets/X and /api/X both serve ROOT/assets/X; everything else is ROOT/<path>."""
import http.server, os, re, sys, time
root, port, rate = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _log(self):
        with open(os.path.join(root, "requests.log"), "a") as f: f.write(self.path + " " + self.headers.get("Range", "-") + "\n")
    def do_GET(self):
        self._log(); p = self.path.split("?")[0]
        for pre in ("/assets/", "/api/"):
            if p.startswith(pre): p = "/assets/" + p[len(pre):]
        fp = os.path.join(root, p.lstrip("/"))
        if not os.path.isfile(fp): self.send_error(404); return
        size = os.path.getsize(fp); start = 0
        m = re.match(r"bytes=(\d+)-", self.headers.get("Range", ""))
        if m: start = int(m.group(1))
        if start >= size and m: self.send_response(416); self.send_header("Content-Range", f"bytes */{size}"); self.end_headers(); return
        self.send_response(206 if m else 200)
        self.send_header("Content-Length", str(size - start))
        if m: self.send_header("Content-Range", f"bytes {start}-{size-1}/{size}")
        self.end_headers()
        with open(fp, "rb") as f:
            f.seek(start)
            while True:
                b = f.read(16384)
                if not b: break
                try: self.wfile.write(b)
                except Exception: return
                time.sleep(len(b) / rate if p.startswith("/assets/") and fp.endswith(".zst") else 0)
http.server.ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
