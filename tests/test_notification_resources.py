"""Startup failure cleanup only; no cloud requests or listening sockets."""
import sqlite3
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest.mock import MagicMock, patch

from notifications.persistence import SnapshotStore
from notifications.server import Inbox, NotificationServer
from test_notifications import config


class StartupResourcesTests(unittest.TestCase):
    def test_sqlite_initialization_failure_closes_open_connection(self):
        with tempfile.TemporaryDirectory() as directory:
            connection = MagicMock()
            failure = sqlite3.OperationalError("synthetic setup failure")
            connection.execute.side_effect = failure
            with patch("notifications.persistence.sqlite3.connect", return_value=connection):
                with self.assertRaises(sqlite3.OperationalError) as caught:
                    SnapshotStore(Path(directory) / "state.sqlite")
            self.assertIs(caught.exception, failure)
            connection.close.assert_called_once_with()

    def test_inbox_restore_failure_closes_state_without_discarding_it(self):
        state = MagicMock()
        state.load.return_value = {"version": 999}
        with patch("notifications.server.SnapshotStore", return_value=state):
            with self.assertRaisesRegex(ValueError, "unsupported persistent"):
                Inbox(replace(config(), state_path=Path("unused.sqlite")))
        state.close.assert_called_once_with()
        state.save.assert_not_called()

    def test_inbox_load_error_closes_state(self):
        state = MagicMock()
        state.load.side_effect = sqlite3.DatabaseError("synthetic read failure")
        with patch("notifications.server.SnapshotStore", return_value=state):
            with self.assertRaises(sqlite3.DatabaseError):
                Inbox(replace(config(), state_path=Path("unused.sqlite")))
        state.close.assert_called_once_with()

    def test_listener_bind_failure_closes_state(self):
        inbox = MagicMock()
        with patch("notifications.server.tls_context"), \
                patch("notifications.server.Inbox", return_value=inbox), \
                patch.object(NotificationServer, "server_bind", side_effect=OSError("address unavailable")):
            with self.assertRaisesRegex(OSError, "address unavailable"):
                NotificationServer(config())
        inbox.state.close.assert_called_once_with()

    def test_socket_creation_failure_preserves_error_and_closes_state(self):
        inbox = MagicMock()
        with patch("notifications.server.tls_context"), \
                patch("notifications.server.Inbox", return_value=inbox), \
                patch("notifications.server.socket.socket", side_effect=OSError("socket unavailable")):
            with self.assertRaisesRegex(OSError, "socket unavailable"):
                NotificationServer(config())
        inbox.state.close.assert_called_once_with()


if __name__ == "__main__":
    unittest.main()
