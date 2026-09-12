#!/usr/bin/env python3
"""Own one puyopuy2 MAME child and its trusted-LAN journal bridge (stdlib only)."""

import argparse
import ipaddress
import os
from pathlib import Path
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import time
import uuid

LIMIT = 65536
POLL = 0.003
STARTUP_POLL = 0.1
HEARTBEAT = 1.0
HELLO = struct.Struct("!8sc16s8s")
HEADER = struct.Struct("!4sH")
RECORD = struct.Struct("!4sIIH")
MAX_BODY = 33 + RECORD.size + 255


class LinkError(Exception):
    pass


def journal_size(data):
    """Validate even an incomplete record's header before accepting its payload."""
    if len(data) < RECORD.size:
        return None
    magic, epoch, peer, size = RECORD.unpack_from(data)
    if (not epoch or size > 255 or magic not in (b"P2R1", b"P2F1", b"P2D1")
            or (magic == b"P2R1" and (size or peer))
            or (magic == b"P2F1" and (size or not peer))
            or (magic == b"P2D1" and (not size or not peer))):
        raise LinkError("invalid journal record")
    return RECORD.size + size


def frame(kind, local, remote, payload=b""):
    body = kind + local + remote + payload
    return HEADER.pack(b"P2N1", len(body)) + body


def pop_frame(buffer, local, remote):
    if len(buffer) < HEADER.size:
        return None
    magic, size = HEADER.unpack_from(buffer)
    if magic != b"P2N1" or not 33 <= size <= MAX_BODY:
        raise LinkError("invalid network magic/length")
    end = HEADER.size + size
    if len(buffer) < end:
        return None
    body = bytes(buffer[HEADER.size:end])
    kind, sender, receiver, payload = body[:1], body[1:17], body[17:33], body[33:]
    if sender != remote or receiver != local:
        raise LinkError("wrong network session")
    if kind == b"D":
        if journal_size(payload) != len(payload):
            raise LinkError("network data must contain exactly one journal record")
    elif kind not in (b"H", b"Q") or payload:
        raise LinkError("invalid network message type/length")
    del buffer[:end]
    return kind, payload


def exchange_hello(sock, side, local, deadline):
    sock.setblocking(False)
    outgoing = memoryview(HELLO.pack(b"P2LAN001", side.encode("ascii"), local, b"puyopuy2"))
    data = bytearray()
    while outgoing or len(data) < HELLO.size:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise LinkError("startup handshake timed out")
        readable, writable, _ = select.select(
            [sock] if len(data) < HELLO.size else [], [sock] if outgoing else [],
            [], min(STARTUP_POLL, remaining))
        if writable:
            try:
                sent = sock.send(outgoing)
            except BlockingIOError:
                continue
            if not sent:
                raise LinkError("peer closed during startup handshake")
            outgoing = outgoing[sent:]
        if readable:
            try:
                part = sock.recv(HELLO.size - len(data))
            except BlockingIOError:
                continue
            if not part:
                raise LinkError("peer closed during startup handshake")
            data.extend(part)
    version, role, remote, game = HELLO.unpack(data)
    if version != b"P2LAN001" or game != b"puyopuy2":
        raise LinkError("incompatible LAN version/game (both need plugin 0.7.0)")
    if role != (b"B" if side == "A" else b"A"):
        raise LinkError("peer must have the opposite cabinet role")
    if remote == bytes(16) or remote == local:
        raise LinkError("invalid or reused session identity")
    return remote


def connect_peer(side, address, port, timeout):
    """One bounded startup attempt; B retries refusals, never reconnects a session."""
    deadline = time.monotonic() + timeout
    if side == "A":
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind((address, port))
            listener.listen(1)
            print(f"Waiting for PC B on {address}:{port} (up to {timeout:g}s; Ctrl+C cancels).\n"
                  "MAME has NOT started; its window opens after the peer connects.", flush=True)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise LinkError("waiting for PC B timed out; start B with --connect " + address)
                # Long Winsock waits defer Python's Ctrl+C handling on Windows.
                listener.settimeout(min(STARTUP_POLL, remaining))
                try:
                    sock, _ = listener.accept()
                    return sock, deadline
                except socket.timeout:
                    continue
    print(f"Connecting to PC A at {address}:{port} (up to {timeout:g}s; Ctrl+C cancels).\n"
          "MAME has NOT started; its window opens after the peer connects.", flush=True)
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            sock = socket.create_connection((address, port), min(STARTUP_POLL, remaining))
            return sock, deadline
        except OSError:
            time.sleep(min(0.1, max(0, deadline - time.monotonic())))
    raise LinkError("startup connection timed out; check A's address, listener and firewall")


def atomic_status(path, session, state, position):
    replacement = path.with_suffix(path.suffix + ".new")
    replacement.write_bytes(f"P2S1 {session.hex()} {state} {position}\n".encode("ascii"))
    deadline = time.monotonic() + 0.25
    while True:
        try:
            os.replace(replacement, path)
            return
        except PermissionError:
            # Windows CRT readers can briefly deny rename while Lua reads.
            if time.monotonic() >= deadline:
                raise
            time.sleep(POLL)


class Bridge:
    def __init__(self, sock, directory, side, local, remote, timeout=10.0, startup=60.0):
        self.sock, self.local, self.remote = sock, local, remote
        peer = "B" if side == "A" else "A"
        self.out = directory / f"{side}_to_{peer}.bin"
        self.incoming = directory / f"{peer}_to_{side}.bin.wire"
        self.wire = self.out.with_suffix(".bin.wire")
        self.status_path = self.out.with_suffix(".bin.status")
        self.progress_path = self.out.with_suffix(".bin.progress")
        self.tx_pos = self.rx_pos = self.progress = 0
        self.send_buffer, self.receive_buffer = bytearray(), bytearray()
        self.timeout, self.startup = timeout, startup
        now = time.monotonic()
        self.started = self.last_rx = self.last_tx = self.last_progress = now
        self.last_heartbeat = now
        self.progress_seen = False
        self.peer_quit = False
        for path in (self.wire, self.incoming):
            with path.open("xb"):
                pass
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, LIMIT)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, LIMIT)
        sock.setblocking(False)
        self.status("up")

    def status(self, state):
        atomic_status(self.status_path, self.local, state, self.tx_pos)

    def queue(self, kind, payload=b""):
        packet = frame(kind, self.local, self.remote, payload)
        if len(self.send_buffer) + len(packet) > LIMIT:
            return False
        if not self.send_buffer:
            self.last_tx = time.monotonic()
        self.send_buffer.extend(packet)
        return True

    def read_progress(self, now):
        try:
            with self.progress_path.open("rb") as stream:
                text = stream.read(160)
        except FileNotFoundError:
            text = b""
        match = re.fullmatch(rb"P2P1 ([0-9a-f]{32}) ([0-9]{1,20}) ([01])\n", text)
        if not match:
            # Lua writes in place. A partial snapshot is not progress.
            return
        session, position, failed = match.groups()
        position = int(position)
        if session.decode("ascii") != self.local.hex() or not self.progress <= position <= self.rx_pos:
            raise LinkError("invalid local plugin progress/session")
        if failed == b"1":
            raise LinkError("Lua transport failed; see proto log")
        if position != self.progress or not self.progress_seen:
            self.last_progress = now
        self.progress, self.progress_seen = position, True

    def read_local(self):
        old_position = self.tx_pos
        with self.wire.open("rb") as stream:
            size = stream.seek(0, os.SEEK_END)
            if not self.tx_pos <= size <= self.tx_pos + LIMIT:
                raise LinkError("local journal truncated or unread backlog limit exceeded")
            stream.seek(self.tx_pos)
            for _ in range(128):
                data = stream.read(RECORD.size)
                length = journal_size(data)
                if length is None:
                    break
                data += stream.read(length - RECORD.size)
                if len(data) != length:
                    break
                if not self.queue(b"D", data):
                    break
                self.tx_pos += length
        if old_position != self.tx_pos:
            # Acceptance into a bounded Python buffer, NOT TCP or remote consumption.
            self.status("up")

    def receive(self, now):
        remaining = LIMIT - len(self.receive_buffer)
        if not remaining:
            raise LinkError("network receive buffer limit exceeded")
        try:
            data = self.sock.recv(min(4096, remaining))
        except BlockingIOError:
            return
        if not data:
            raise LinkError("peer disconnected without a normal quit; restart both launchers")
        self.receive_buffer.extend(data)
        while True:
            message = pop_frame(self.receive_buffer, self.local, self.remote)
            if message is None:
                break
            self.last_rx = now
            kind, payload = message
            if kind == b"Q":
                self.peer_quit = True
                return
            if kind == b"D":
                if self.rx_pos - self.progress + len(payload) > LIMIT:
                    raise LinkError("incoming unread journal limit exceeded (MAME paused/stalled?)")
                if self.rx_pos == self.progress:
                    self.last_progress = now
                with self.incoming.open("ab") as stream:
                    if stream.write(payload) != len(payload):
                        raise LinkError("incoming journal append failed (not retryable)")
                self.rx_pos += len(payload)

    def send(self, now):
        if not self.send_buffer:
            return
        try:
            count = self.sock.send(self.send_buffer)
        except BlockingIOError:
            return
        if count <= 0:
            raise LinkError("TCP send made no progress")
        del self.send_buffer[:count]
        self.last_tx = now

    def check_deadlines(self, now):
        if now - self.last_rx > self.timeout:
            raise LinkError("peer heartbeat timed out")
        if self.send_buffer and now - self.last_tx > self.timeout:
            raise LinkError("TCP send stalled")
        if not self.progress_seen:
            if now - self.started > self.startup:
                raise LinkError("MAME plugin did not publish progress; check plugin installation/log")
        elif self.rx_pos > self.progress and now - self.last_progress > self.timeout:
            raise LinkError("MAME receive progress stalled (paused?); restart both launchers")

    def step(self):
        now = time.monotonic()
        self.read_progress(now)
        self.check_deadlines(now)
        self.read_local()
        if now - self.last_heartbeat >= HEARTBEAT and self.queue(b"H"):
            self.last_heartbeat = now
        readable, writable, _ = select.select([self.sock], [self.sock] if self.send_buffer else [], [], POLL)
        now = time.monotonic()
        if readable:
            self.receive(now)
            if self.peer_quit:
                return
        if writable:
            self.send(now)

    def quit(self):
        # Preserve any partially sent frame before Q; never splice Q into it.
        if not self.queue(b"Q"):
            raise LinkError("cannot queue normal quit: TCP buffer full")
        deadline = time.monotonic() + 1.0
        while self.send_buffer and time.monotonic() < deadline:
            _, ready, _ = select.select([], [self.sock], [], POLL)
            if ready:
                self.send(time.monotonic())
        if self.send_buffer:
            raise LinkError("normal quit could not be sent")


def stop_child(child, grace=3.0):
    if child is None or child.poll() is not None:
        return
    # The down sidecar asks Lua's next frame to call machine:exit(), also on
    # Windows. A paused/hung child cannot cooperate; terminate only this PID.
    try:
        child.wait(timeout=grace)
        return
    except subprocess.TimeoutExpired:
        child.terminate()
    try:
        child.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()


def supervise(bridge, command, environment, output):
    child = None
    try:
        child = subprocess.Popen(command, env=environment, stdout=output, stderr=subprocess.STDOUT)
        print(f"MAME PID {child.pid}; quit MAME or Ctrl+C to end BOTH cabinets.", flush=True)
        while not bridge.peer_quit:
            code = child.poll()
            if code is not None:
                bridge.read_progress(time.monotonic())
                if code:
                    raise LinkError(f"MAME exited with status {code}; see mame.log")
                bridge.quit()
                return 0
            bridge.step()
        print("Peer quit normally; ending this cabinet.", flush=True)
        return 0
    except KeyboardInterrupt:
        bridge.quit()
        return 130
    finally:
        # Close TCP before waiting for our child: the peer sees failure promptly.
        try:
            bridge.status("down")
        finally:
            bridge.sock.close()
            stop_child(child)


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "Run from your MAME installation. A listens; B connects. Quit MAME or Ctrl+C "
        "ends both cabinets. Failures require two fresh launches; no reconnect. "
        "Trusted wired LAN only: no authentication/encryption or Internet exposure."))
    parser.add_argument("--side", required=True, choices=("A", "B"))
    endpoint = parser.add_mutually_exclusive_group()
    endpoint.add_argument("--listen", metavar="IP", help="A's local IPv4; default 127.0.0.1")
    endpoint.add_argument("--connect", metavar="IP", help="B's A-host IPv4 (required for B)")
    parser.add_argument("--port", type=int, default=24872)
    parser.add_argument("--mame", default="mame.exe" if os.name == "nt" else "mame",
                        help="MAME executable, e.g. .\\mame.exe or /usr/bin/mame")
    parser.add_argument("--runs", type=Path, default=Path("puyo2-lan-runs"),
                        help="persistent run directories; default ./puyo2-lan-runs")
    parser.add_argument("--startup-timeout", type=float, default=60.0,
                        help="seconds for connection/hello and separately plugin startup (default 60)")
    parser.add_argument("--timeout", type=float, default=10.0,
                        help="heartbeat/send/receive-stall seconds, minimum 3 (default 10)")
    args = parser.parse_args(argv)
    if (args.side == "A" and args.connect) or (args.side == "B" and (args.listen or not args.connect)):
        parser.error("use --side A [--listen IP], or --side B --connect IP")
    args.address = args.listen or args.connect or "127.0.0.1"
    try:
        ipaddress.IPv4Address(args.address)
    except ipaddress.AddressValueError:
        parser.error("endpoint must be an explicit IPv4 address")
    if not 1 <= args.port <= 65535 or not 0 < args.startup_timeout <= 3600 or not 3 <= args.timeout <= 300:
        parser.error("port must be 1..65535, startup-timeout 0..3600, timeout 3..300")
    return args


def main(argv=None):
    args = arguments(argv)
    local = uuid.uuid4().bytes
    directory = args.runs.resolve() / (time.strftime("%Y%m%d-%H%M%S-") + args.side + "-" + local.hex())
    directory.mkdir(parents=True)
    print(f"LAN {args.side}: {args.address}:{args.port}; logs: {directory}", flush=True)
    log_path = directory / "bridge.log"
    log_path.write_text(f"side={args.side} local_session={local.hex()} endpoint={args.address}:{args.port}\n",
                        encoding="utf-8")
    sock = None
    try:
        sock, deadline = connect_peer(args.side, args.address, args.port, args.startup_timeout)
        print("TCP connected; exchanging cabinet identities (Ctrl+C cancels).", flush=True)
        remote = exchange_hello(sock, args.side, local, deadline)
        bridge = Bridge(sock, directory, args.side, local, remote, args.timeout, args.startup_timeout)
        with log_path.open("a", encoding="utf-8") as log:
            log.write(f"peer={sock.getpeername()} peer_session={remote.hex()} "
                      f"socket_send={sock.getsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF)} "
                      f"socket_receive={sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)}\n")
        environment = os.environ.copy()
        environment.update(PUYO2_LINK_SIDE=args.side, PUYO2_LINK_DIR=str(directory),
                           PUYO2_LINK_SESSION=local.hex())
        cabinet = args.runs.resolve() / ("cabinet-" + args.side)
        for name in ("cfg", "nvram"):
            (cabinet / name).mkdir(parents=True, exist_ok=True)
        # No autoboot/input automation, speed hacks, or caller-provided commands.
        command = [args.mame, "puyopuy2", "-plugin", "puyo2link", "-window", "-skip_gameinfo",
                   "-throttle", "-speed", "1", "-noautoframeskip", "-frameskip", "0",
                   "-norefreshspeed", "-nowaitvsync", "-nosyncrefresh", "-joystick",
                   "-cfg_directory", str(cabinet / "cfg"),
                   "-nvram_directory", str(cabinet / "nvram")]
        with (directory / "mame.log").open("w", encoding="utf-8") as output:
            print("Link ready. Opening the MAME window...", flush=True)
            code = supervise(bridge, command, environment, output)
        with log_path.open("a", encoding="utf-8") as log:
            log.write(f"session ended: exit={code} tx_handled={bridge.tx_pos} "
                      f"rx_appended={bridge.rx_pos} rx_parsed={bridge.progress}\n")
        return code
    except (LinkError, OSError) as error:
        message = f"LAN FAILED: {error}. Fresh restart required on both PCs."
        print(message, file=sys.stderr, flush=True)
        with log_path.open("a", encoding="utf-8") as log:
            log.write(message + "\n")
        return 1
    except KeyboardInterrupt:
        print("Startup cancelled.", file=sys.stderr)
        return 130
    finally:
        if sock is not None:
            sock.close()


if __name__ == "__main__":
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
