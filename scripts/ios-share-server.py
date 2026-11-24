"""Loopback static server for over-the-air development builds and Tron artifacts.

`scripts/tron-ios-device share-host enable` embeds this source in the
com.tron.ios-builds LaunchAgent (`python3 -c`), so the running server never
depends on a checkout path. Tailscale Serve terminates HTTPS with the node's
*.ts.net certificate and proxies to it; the macOS Tailscale app cannot serve a
directory itself (sandbox). It binds loopback only, serves files, never lists
directories, and disables caching so pages always show the newest content.
`/artifacts/` and `/reports/` map to the internal workspace's folders of the
same names; every other path maps to the builds folder. Hidden names, traversal and symlinks that
leave their folder are not found.
"""

import functools
import http.server
import os
import posixpath
import sys
import urllib.parse

directory, artifacts, reports, port = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
mounts = {"/artifacts": artifacts, "/reports": reports}


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
        for prefix, folder in mounts.items():
            if route == prefix or route.startswith(prefix + "/"):
                root, route = folder, route[len(prefix):]
                break
        if "\x00" in route:
            return None
        candidate = os.path.join(root, *[part for part in route.split("/") if part])
        real_root, real = os.path.realpath(root), os.path.realpath(candidate)
        if os.path.commonpath([real_root, real]) != real_root:
            return None
        if any(part.startswith(".") for part in os.path.relpath(real, real_root).split(os.sep) if part != "."):
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
