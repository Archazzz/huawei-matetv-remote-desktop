"""Forward RustDesk direct-IP TCP connections without terminating its protocol.

No desktop credentials, arbitrary destination endpoint, discovery service, or
public listener is required. RustDesk must still authenticate every connection.
"""
from __future__ import annotations

import argparse
import asyncio
import ipaddress
import json
import logging
import signal
import socket
import time
from dataclasses import dataclass
from pathlib import Path

LOG = logging.getLogger("matetv.bridge")


@dataclass(frozen=True)
class Forward:
    name: str
    listen_host: str
    listen_port: int
    target_host: str
    target_port: int
    allowed_clients: tuple[str, ...]
    max_connections: int = 4
    idle_seconds: float = 300
    connect_timeout: float = 10

    def __post_init__(self) -> None:
        if not self.name.strip() or not self.target_host.strip():
            raise ValueError("name and target_host are required")
        for port in (self.listen_port, self.target_port):
            if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
                raise ValueError("ports must be integers between 1 and 65535")
        if self.max_connections < 1 or self.idle_seconds <= 0 or self.connect_timeout <= 0:
            raise ValueError("connection and timeout limits must be positive")
        if not self.allowed_clients:
            raise ValueError("allowed_clients must explicitly allow at least one address/CIDR")
        ipaddress.ip_address(self.listen_host)
        for cidr in self.allowed_clients:
            network = ipaddress.ip_network(cidr, strict=False)
            if network.prefixlen == 0:
                raise ValueError("an unrestricted client allowlist is not supported")

    def permits(self, address: str) -> bool:
        addr = ipaddress.ip_address(address.split("%", 1)[0])
        if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped:
            addr = addr.ipv4_mapped
        return any(addr in ipaddress.ip_network(cidr, strict=False) for cidr in self.allowed_clients)


def load_config(path: Path) -> list[Forward]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or set(data) != {"forwards"}:
        raise ValueError("configuration must contain only a forwards array")
    if not isinstance(data["forwards"], list) or not data["forwards"]:
        raise ValueError("forwards must be a nonempty array")
    result: list[Forward] = []
    names: set[str] = set()
    listeners: set[tuple[str, int]] = set()
    for row in data["forwards"]:
        row = dict(row)
        row["allowed_clients"] = tuple(row.get("allowed_clients", []))
        forward = Forward(**row)
        address = (forward.listen_host, forward.listen_port)
        if forward.name in names or address in listeners:
            raise ValueError("forward names and listener addresses must be unique")
        names.add(forward.name)
        listeners.add(address)
        result.append(forward)
    return result


async def close_writer(writer: asyncio.StreamWriter) -> None:
    writer.close()
    try:
        await asyncio.wait_for(writer.wait_closed(), 2)
    except (OSError, asyncio.TimeoutError):
        pass


class Relay:
    def __init__(self, config: Forward):
        self.config = config
        self.active: set[asyncio.Task] = set()

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        task = asyncio.current_task()
        peer = writer.get_extra_info("peername")
        if not peer or not self.config.permits(peer[0]) or len(self.active) >= self.config.max_connections:
            LOG.warning("%s: rejected client (allowlist or capacity)", self.config.name)
            await close_writer(writer)
            return
        assert task is not None
        self.active.add(task)
        remote_writer = None
        workers: list[asyncio.Task] = []
        try:
            remote_reader, remote_writer = await asyncio.wait_for(
                asyncio.open_connection(self.config.target_host, self.config.target_port),
                self.config.connect_timeout,
            )
            for stream in (writer, remote_writer):
                sock = stream.get_extra_info("socket")
                if sock:
                    sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            LOG.info("%s: session connected", self.config.name)
            activity = [time.monotonic()]

            async def pump(source: asyncio.StreamReader, destination: asyncio.StreamWriter) -> None:
                while chunk := await source.read(65536):
                    activity[0] = time.monotonic()
                    destination.write(chunk)
                    await destination.drain()
                if destination.can_write_eof():
                    destination.write_eof()
                    await destination.drain()

            async def idle_watch() -> None:
                while True:
                    remaining = self.config.idle_seconds - (time.monotonic() - activity[0])
                    if remaining <= 0:
                        raise asyncio.TimeoutError("idle session")
                    await asyncio.sleep(min(remaining, 1))

            workers = [asyncio.create_task(pump(reader, remote_writer)),
                       asyncio.create_task(pump(remote_reader, writer))]
            transfer = asyncio.gather(*workers)
            watchdog = asyncio.create_task(idle_watch())
            workers.append(watchdog)
            try:
                done, _ = await asyncio.wait([transfer, watchdog], return_when=asyncio.FIRST_COMPLETED)
                for finished in done:
                    finished.result()
            finally:
                transfer.cancel()
                await asyncio.gather(transfer, return_exceptions=True)
        except (OSError, asyncio.TimeoutError) as exc:
            LOG.warning("%s: connection ended (%s)", self.config.name, type(exc).__name__)
        finally:
            for worker in workers:
                worker.cancel()
            await asyncio.gather(*workers, return_exceptions=True)
            if remote_writer:
                await close_writer(remote_writer)
            await close_writer(writer)
            self.active.discard(task)

    async def stop(self) -> None:
        tasks = list(self.active)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


async def serve(forwards: list[Forward]) -> None:
    servers: list[asyncio.Server] = []
    relays: list[Relay] = []
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, stop.set)
        except (NotImplementedError, RuntimeError):
            pass
    try:
        for config in forwards:
            relay = Relay(config)
            server = await asyncio.start_server(relay.handle, config.listen_host, config.listen_port)
            servers.append(server)
            relays.append(relay)
            LOG.info("%s: listening on port %d", config.name, config.listen_port)
        await stop.wait()
    finally:
        for server in servers:
            server.close()
        await asyncio.gather(*(server.wait_closed() for server in servers))
        await asyncio.gather(*(relay.stop() for relay in relays))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--check", action="store_true", help="validate configuration without opening ports")
    args = parser.parse_args()
    try:
        forwards = load_config(args.config)
    except (OSError, ValueError, TypeError, KeyError) as exc:
        parser.error(str(exc))
    if args.check:
        print(f"Valid configuration: {len(forwards)} forward(s)")
        return
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        asyncio.run(serve(forwards))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
