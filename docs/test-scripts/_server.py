#!/usr/bin/env python3
"""
Static docs server + test-results sink.

Serves the docs directory for GET (so test scripts render in the preview),
and accepts POST /api/test-results/<slug>.json writing to
docs/test-scripts/<slug>.results.json. Restricted to a whitelisted subdirectory
so no path traversal.

Usage:
  python3 _server.py <docs-root> <port>
"""
import http.server
import json
import os
import sys
from urllib.parse import urlparse


def main():
    docs_root = os.path.realpath(sys.argv[1]) if len(sys.argv) > 1 else os.getcwd()
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 3457
    results_dir = os.path.realpath(os.path.join(docs_root, 'test-scripts'))
    os.makedirs(results_dir, exist_ok=True)

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=docs_root, **kwargs)

        def _send_json(self, code, payload):
            body = json.dumps(payload).encode('utf-8')
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            self.send_header('Access-Control-Allow-Headers', 'Content-Type')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_OPTIONS(self):
            self.send_response(204)
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
            self.send_header('Access-Control-Allow-Headers', 'Content-Type')
            self.end_headers()

        def _resolve_results_path(self, slug):
            if not slug.endswith('.json'):
                return None
            if '/' in slug or '\\' in slug or '..' in slug:
                return None
            target = os.path.realpath(os.path.join(results_dir, slug))
            if not target.startswith(results_dir + os.sep) and target != results_dir:
                return None
            return target

        def do_POST(self):
            if not self.path.startswith('/api/test-results/'):
                self.send_error(404, 'Not found')
                return
            slug = self.path[len('/api/test-results/'):].split('?')[0]
            target = self._resolve_results_path(slug)
            if not target:
                self.send_error(400, 'Invalid slug')
                return
            length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(length) if length else b'{}'
            try:
                data = json.loads(body)
            except json.JSONDecodeError:
                self.send_error(400, 'Invalid JSON')
                return
            with open(target, 'w') as f:
                json.dump(data, f, indent=2, sort_keys=True)
            self._send_json(200, {'ok': True, 'path': os.path.relpath(target, docs_root)})

    srv = http.server.ThreadingHTTPServer(('127.0.0.1', port), Handler)
    print(f'serving docs: {docs_root}')
    print(f'results sink: POST http://127.0.0.1:{port}/api/test-results/<slug>.json  -> {results_dir}/<slug>.json')
    srv.serve_forever()


if __name__ == '__main__':
    main()
