"""Read-only smart HTTP Git server for the disposable fixture repository."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
import subprocess
from urllib.parse import urlsplit


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.serve()

    def do_POST(self):
        self.serve()

    def serve(self):
        url = urlsplit(self.path)
        if self.command == "GET" and url.path == "/healthz":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ready\n")
            return
        if url.path not in ("/repo.git/info/refs", "/repo.git/git-upload-pack") or (
            url.query and url.query != "service=git-upload-pack"
        ):
            self.send_error(403)
            return
        env = dict(os.environ, GIT_PROJECT_ROOT="/srv", GIT_HTTP_EXPORT_ALL="1",
                   PATH_INFO=url.path, QUERY_STRING=url.query,
                   REQUEST_METHOD=self.command, CONTENT_TYPE=self.headers.get("Content-Type", ""),
                   CONTENT_LENGTH=self.headers.get("Content-Length", "0"),
                   GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="safe.directory",
                   GIT_CONFIG_VALUE_0="/srv/repo.git")
        body = self.rfile.read(int(env["CONTENT_LENGTH"]))
        result = subprocess.run(["git", "http-backend"], input=body, capture_output=True,
                                env=env, timeout=60, check=True)
        headers, content = result.stdout.split(b"\r\n\r\n", 1)
        parsed = [line.decode().split(": ", 1) for line in headers.split(b"\r\n")]
        status = next((int(value.split()[0]) for key, value in parsed if key == "Status"), 200)
        self.send_response(status)
        for key, value in parsed:
            if key != "Status":
                self.send_header(key, value)
        self.end_headers()
        self.wfile.write(content)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
