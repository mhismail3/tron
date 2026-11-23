"""Loopback static server for over-the-air development builds and Tron artifacts.

`scripts/tron-ios-device share-host enable` embeds this source in the
com.tron.ios-builds LaunchAgent (`python3 -c`), so the running server never
depends on a checkout path. Tailscale Serve terminates HTTPS with the node's
*.ts.net certificate and proxies to it; the macOS Tailscale app cannot serve a
directory itself (sandbox). It binds loopback only, serves files, never lists
directories, and disables caching so pages always show the newest content.
`/artifacts/` maps to the internal workspace's artifacts folder; every other
path maps to the builds folder. Hidden names, traversal and symlinks that
leave their folder are not found.
"""

import functools
import http.server
import os
import posixpath
import sys
import urllib.parse

directory, artifacts, port = sys.argv[1], sys.argv[2], int(sys.argv[3])


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".plist": "text/xml",
        ".ipa": "application/octet-stream",
        ".json": "application/json",
    }

    def translate_path(self, path):
        route = posixpath.normpath(urllib.parse.unquote(urllib.parse.urlsplit(path).path))
        root = self.directory
        if route == "/artifacts" or route.startswith("/artifacts/"):
            root, route = artifacts, route[len("/artifacts"):]
        parts = [part for part in route.split("/") if part]
        if any(part.startswith(".") for part in parts):
            return None
        candidate = os.path.join(root, *parts)
        real_root = os.path.realpath(root)
        if os.path.commonpath([real_root, os.path.realpath(candidate)]) != real_root:
            return None
        return candidate + "/" if path.split("?", 1)[0].endswith("/") else candidate

    def send_head(self):
        if self.translate_path(self.path) is None:
            self.send_error(404)
            return None
        return super().send_head()

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def list_directory(self, path):
        self.send_error(404)
        return None


http.server.ThreadingHTTPServer(
    ("127.0.0.1", port), functools.partial(Handler, directory=directory)
).serve_forever()
