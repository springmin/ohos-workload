#!/usr/bin/env python3
# ============================================================================
# serve-blazor-wwwroot.py — serve a published Blazor wwwroot with the MIME types ArkWeb needs.
#
# Companion to the hello-blazorwasm ArkTS host (test/hello-blazorwasm/arkts-host):
# same site, served to a desktop browser before it is packed into a hap. `application/wasm`
# is required for WebAssembly.instantiateStreaming (Blazor falls back to ArrayBuffer when the
# MIME is wrong but it is slower); precompressed `.br`/`.gz` are returned with their
# Content-Encoding when the client advertises it, otherwise the uncompressed sibling is used.
#
# Usage: python3 scripts/serve-blazor-wwwroot.py <wwwroot> [port]     (default port: 8199)
# ============================================================================
import os, sys, http.server, functools

class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        '.wasm': 'application/wasm',
        '.js': 'text/javascript',
        '.mjs': 'text/javascript',
        '.json': 'application/json',
        '.dll': 'application/octet-stream',
        '.dat': 'application/octet-stream',
        '.blat': 'application/octet-stream',
        '.webcil': 'application/octet-stream',
        '.br': 'application/octet-stream',
        '.gz': 'application/octet-stream',
    }

    def send_head(self):
        path = self.translate_path(self.path)
        enc = None
        for candidate, coding in ((path + '.br', 'br'), (path + '.gz', 'gzip')):
            if os.path.isfile(candidate) and coding in self.headers.get('Accept-Encoding', ''):
                path, enc = candidate, coding
                break
        if enc is None:
            return super().send_head()
        try:
            f = open(path, 'rb')
        except OSError:
            self.send_error(404, "File not found")
            return None
        fs = os.fstat(f.fileno())
        self.send_response(200)
        self.send_header('Content-Type', self.guess_type(path[:-len(enc) - 1]))
        self.send_header('Content-Encoding', enc)
        self.send_header('Content-Length', str(fs[6]))
        self.send_header('Last-Modified', self.date_time_string(fs.st_mtime))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        return f

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

if __name__ == '__main__':
    root = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else '.')
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8199
    http.server.ThreadingHTTPServer(('127.0.0.1', port), functools.partial(Handler, directory=root)).serve_forever()
