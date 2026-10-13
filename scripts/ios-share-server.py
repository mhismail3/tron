"""Loopback static server for over-the-air development builds.

`scripts/tron-ios-device share-host enable` embeds this source in the
com.tron.ios-builds LaunchAgent (`python3 -c`), so the running server never
depends on a checkout path. Tailscale Serve terminates HTTPS with the node's
*.ts.net certificate and proxies to it; the macOS Tailscale app cannot serve a
directory itself (sandbox). It binds loopback only, serves files, never lists
directories, and disables caching so the index always shows the newest build.
"""

import functools
import http.server
import sys

directory, port = sys.argv[1], int(sys.argv[2])


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".plist": "text/xml",
        ".ipa": "application/octet-stream",
        ".json": "application/json",
    }

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def list_directory(self, path):
        self.send_error(404)
        return None


http.server.ThreadingHTTPServer(
    ("127.0.0.1", port), functools.partial(Handler, directory=directory)
).serve_forever()
