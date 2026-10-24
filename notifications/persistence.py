"""Bounded private SQLite snapshot; event and cloud-click state commit together."""
import json
import os
import sqlite3
import stat
from pathlib import Path


class SnapshotStore:
    def __init__(self, path: Path):
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(descriptor)
        except FileExistsError:
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
                raise ValueError("notification state must be a private regular file")
        self.connection = sqlite3.connect(path, check_same_thread=False)
        self.connection.execute("PRAGMA journal_mode=DELETE")
        self.connection.execute("PRAGMA synchronous=FULL")
        self.connection.execute("PRAGMA secure_delete=ON")
        self.connection.execute("CREATE TABLE IF NOT EXISTS snapshot (id INTEGER PRIMARY KEY CHECK(id=1), body TEXT NOT NULL)")
        self.connection.commit()
        self.last_raw = None

    def load(self):
        row = self.connection.execute("SELECT body FROM snapshot WHERE id=1").fetchone()
        self.last_raw = None if row is None else row[0]
        return None if row is None else json.loads(row[0])

    def save(self, state: dict):
        raw = json.dumps(state, ensure_ascii=False, separators=(",", ":"))
        if raw == self.last_raw:
            return
        with self.connection:
            self.connection.execute("INSERT OR REPLACE INTO snapshot(id,body) VALUES(1,?)", (raw,))
        self.last_raw = raw

    def close(self):
        self.connection.close()
