import asyncio
import dataclasses
import json
import tempfile
import unittest
from pathlib import Path

from bridge.server import Forward, Relay, close_writer, load_config


class ConfigTests(unittest.TestCase):
    def test_allowlist_and_mapped_ipv6(self):
        c = Forward("test", "127.0.0.1", 20000, "127.0.0.1", 20001, ("192.168.50.7/32",))
        self.assertTrue(c.permits("192.168.50.7"))
        self.assertTrue(c.permits("::ffff:192.168.50.7"))
        self.assertFalse(c.permits("192.168.50.8"))
        self.assertFalse(c.permits("::1"))
        with self.assertRaises(ValueError):
            dataclasses.replace(c, allowed_clients=("0.0.0.0/0",))

    def test_reject_duplicate_listener(self):
        row = dataclasses.asdict(Forward("a", "127.0.0.1", 20000, "127.0.0.1", 20001, ("127.0.0.1",)))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            path.write_text(json.dumps({"forwards": [row, {**row, "name": "b"}]}))
            with self.assertRaises(ValueError):
                load_config(path)


class RelayTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.servers = []
        self.relays = []
        self.writers = []

    async def asyncTearDown(self):
        for writer in self.writers:
            await close_writer(writer)
        for server in self.servers:
            server.close()
            await server.wait_closed()
        for relay in self.relays:
            await relay.stop()

    async def start(self, handler, **overrides):
        target = await asyncio.start_server(handler, "127.0.0.1", 0)
        self.servers.append(target)
        target_port = target.sockets[0].getsockname()[1]
        config = Forward("test", "127.0.0.1", 21119, "127.0.0.1", target_port, ("127.0.0.1/32",))
        relay = Relay(dataclasses.replace(config, **overrides))
        self.relays.append(relay)
        server = await asyncio.start_server(relay.handle, "127.0.0.1", 0)
        self.servers.append(server)
        reader, writer = await asyncio.open_connection("127.0.0.1", server.sockets[0].getsockname()[1])
        self.writers.append(writer)
        return reader, writer

    async def test_binary_transfer_and_half_close(self):
        async def target(reader, writer):
            data = await reader.read()
            writer.write(data[::-1])
            await writer.drain()
            await close_writer(writer)
        reader, writer = await self.start(target)
        payload = bytes(range(256)) * 1024
        writer.write(payload)
        await writer.drain()
        writer.write_eof()
        self.assertEqual(await asyncio.wait_for(reader.read(), 3), payload[::-1])

    async def test_deny_client_before_opening_target(self):
        called = []
        async def target(reader, writer):
            called.append(True)
            await close_writer(writer)
        reader, _ = await self.start(target, allowed_clients=("192.0.2.1/32",))
        self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")
        self.assertEqual(called, [])

    async def test_downstream_activity_keeps_idle_upload_alive(self):
        async def target(reader, writer):
            try:
                for _ in range(8):
                    writer.write(b"x")
                    await writer.drain()
                    await asyncio.sleep(0.03)
            finally:
                await close_writer(writer)
        reader, writer = await self.start(target, idle_seconds=0.12)
        self.assertEqual(await asyncio.wait_for(reader.readexactly(8), 2), b"x" * 8)
        writer.write_eof()

    async def test_idle_connection_is_closed(self):
        async def target(reader, writer):
            await reader.read()
            await close_writer(writer)
        reader, _ = await self.start(target, idle_seconds=0.05)
        self.assertEqual(await asyncio.wait_for(reader.read(), 1), b"")


if __name__ == "__main__":
    unittest.main()
