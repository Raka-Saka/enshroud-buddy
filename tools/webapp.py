"""The web app (tools/build_web.py) as the agent serves it at /app/: from app/build/web when run from source,
else from build/web.zip in the exe. Text files go gzipped to browsers that take it (the game texts are most
of the page's weight), and each file has an ETag, so a browser that has it already gets a 304.
"""
import gzip
import hashlib
import pathlib
import threading
import zipfile

TYPES = {".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
         ".mjs": "text/javascript; charset=utf-8", ".json": "application/json; charset=utf-8",
         ".wasm": "application/wasm", ".png": "image/png", ".jpg": "image/jpeg", ".webp": "image/webp",
         ".svg": "image/svg+xml", ".ico": "image/x-icon", ".otf": "font/otf", ".ttf": "font/ttf",
         ".txt": "text/plain; charset=utf-8", ".bin": "application/octet-stream"}
PACK = {".html", ".js", ".mjs", ".json", ".wasm", ".txt", ".otf", ".ttf", ".bin", ".svg"}


class WebApp:
    def __init__(self, folder, zipped):
        self.folder = folder if (folder / "index.html").exists() else None
        self.zip = zipfile.ZipFile(zipped) if self.folder is None and zipped.exists() else None
        self.lock = threading.Lock()
        self.packed = {}  # path -> (gzip bytes), kept: the texts are asked again on every page load
        self.tags = {}

    @property
    def ok(self):
        return bool(self.folder or self.zip)

    def _read(self, rel):
        if self.folder:
            f = (self.folder / rel).resolve()
            if self.folder.resolve() not in f.parents or not f.is_file():
                return None
            return f.read_bytes()
        try:
            with self.lock:
                return self.zip.read(rel)
        except KeyError:
            return None

    def get(self, rel, gz):
        """(body, content type, etag, gzipped) for a path under /app/, or None."""
        rel = rel.lstrip("/") or "index.html"
        if ".." in rel.split("/") or "\\" in rel:
            return None
        body = self._read(rel)
        if body is None:
            return None
        ext = pathlib.PurePosixPath(rel).suffix.lower()
        tag = self.tags.get(rel)
        if tag is None or self.folder:  # from source the files change with each build
            tag = self.tags[rel] = '"' + hashlib.sha1(body).hexdigest()[:20] + '"'
        if gz and ext in PACK and len(body) > 1024:
            packed = self.packed.get((rel, tag))
            if packed is None:
                packed = self.packed[(rel, tag)] = gzip.compress(body, 6)
            return packed, TYPES.get(ext, "application/octet-stream"), tag, True
        return body, TYPES.get(ext, "application/octet-stream"), tag, False
