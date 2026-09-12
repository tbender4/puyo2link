"""Run: py PuyoPuyo2\\re_notes\\test_lan.py (no MAME launch or dependencies)."""

import importlib.util
import _thread
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import threading
import time
import unittest
from unittest.mock import Mock, patch
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("puyo2_lan", ROOT / "plugins" / "puyo2link" / "lan.py")
lan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lan)
A, B = b"a" * 16, b"b" * 16


def record(kind=b"R", epoch=1, peer=0, payload=b""):
    return lan.RECORD.pack(b"P2" + kind + b"1", epoch, peer, len(payload)) + payload


def sockets():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        client = socket.create_connection(listener.getsockname(), timeout=1)
        server, _ = listener.accept()
    client.settimeout(1)
    server.settimeout(1)
    client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    server.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return client, server


class LimitedSocket:
    def __init__(self, sock):
        self.sock, self.blocked = sock, False

    def __getattr__(self, name):
        return getattr(self.sock, name)

    def send(self, data):
        if self.blocked:
            raise BlockingIOError
        return self.sock.send(data[:3])


class LANTests(unittest.TestCase):
    def setUp(self):
        # All test evidence is inside cwd, never a system temporary directory.
        self.directory = Path.cwd() / (".puyo2-lan-test-" + uuid.uuid4().hex)
        self.directory.mkdir()
        self.open_sockets = []

    def tearDown(self):
        for sock in self.open_sockets:
            sock.close()
        shutil.rmtree(self.directory)

    def pair(self):
        pair = sockets()
        self.open_sockets.extend(pair)
        return pair

    def bridge(self):
        sock, remote = self.pair()
        bridge = lan.Bridge(sock, self.directory, "A", A, B)
        return bridge, remote

    def progress(self, bridge, position=0, failed=0):
        bridge.progress_path.write_bytes(f"P2P1 {A.hex()} {position} {failed}\n".encode("ascii"))

    def test_fragmented_and_coalesced_frames(self):
        records = [record(), record(b"F", peer=1), record(b"D", peer=1, payload=bytes(range(255)))]
        wire = b"".join(lan.frame(b"D", A, B, value) for value in records) + lan.frame(b"H", A, B)
        for chunk_size in (1, 2, 5, 14, 33, 256, len(wire)):
            buffer, result = bytearray(), []
            for pos in range(0, len(wire), chunk_size):
                buffer.extend(wire[pos:pos + chunk_size])
                while True:
                    message = lan.pop_frame(buffer, B, A)
                    if message is None:
                        break
                    result.append(message)
            self.assertEqual(result, [(b"D", value) for value in records] + [(b"H", b"")])
            self.assertEqual(buffer, b"")

    def test_reject_network_and_journal_corruption(self):
        bad = [
            b"BAD!" + b"\0\x21" + b"x" * 33,
            lan.HEADER.pack(b"P2N1", 65535),
            lan.HEADER.pack(b"P2N1", 32),
            lan.frame(b"X", A, B),
            lan.frame(b"H", A, B, b"x"),
            lan.frame(b"Q", A, B, b"x"),
            lan.frame(b"D", A, B),
            lan.frame(b"D", A, B, record() + b"x"),
            lan.frame(b"D", A, B, record(epoch=0)),
            lan.frame(b"D", A, B, record(peer=1)),
            lan.frame(b"D", A, B, record(b"F")),
            lan.frame(b"D", A, B, record(b"D", peer=1)),
            lan.frame(b"D", A, B, lan.RECORD.pack(b"P2D1", 1, 1, 256)),
            lan.frame(b"D", A, B, record(b"X")),
            lan.frame(b"H", B, A),
            lan.frame(b"H", bytes(16), B),
        ]
        for data in bad:
            with self.subTest(data=data[:24]), self.assertRaises(lan.LinkError):
                lan.pop_frame(bytearray(data), B, A)

    def test_hello_version_role_game_and_session(self):
        good = lan.HELLO.pack(b"P2LAN001", b"B", B, b"puyopuy2")
        cases = [
            (good, True),
            (lan.HELLO.pack(b"P2LAN002", b"B", B, b"puyopuy2"), False),
            (lan.HELLO.pack(b"P2LAN001", b"A", B, b"puyopuy2"), False),
            (lan.HELLO.pack(b"P2LAN001", b"X", B, b"puyopuy2"), False),
            (lan.HELLO.pack(b"P2LAN001", b"B", B, b"otherrom"), False),
            (lan.HELLO.pack(b"P2LAN001", b"B", A, b"puyopuy2"), False),
            (lan.HELLO.pack(b"P2LAN001", b"B", bytes(16), b"puyopuy2"), False),
        ]
        for hello, valid in cases:
            local, remote = self.pair()
            remote.sendall(hello)
            if valid:
                self.assertEqual(lan.exchange_hello(LimitedSocket(local), "A", A,
                                                   time.monotonic() + 1), B)
                sent = bytearray()
                while len(sent) < lan.HELLO.size:
                    sent.extend(remote.recv(lan.HELLO.size - len(sent)))
                self.assertEqual(sent, lan.HELLO.pack(b"P2LAN001", b"A", A, b"puyopuy2"))
            else:
                with self.assertRaises(lan.LinkError):
                    lan.exchange_hello(local, "A", A, time.monotonic() + 1)
        local, remote = self.pair()
        with self.assertRaises((TimeoutError, lan.LinkError)):
            lan.exchange_hello(local, "A", A, time.monotonic() + 0.03)
        remote.close()
        with self.assertRaises((OSError, lan.LinkError)):
            lan.exchange_hello(local, "A", A, time.monotonic() + 1)

    def test_partial_send_and_local_handled_offset(self):
        bridge, remote = self.bridge()
        bridge.sock = LimitedSocket(bridge.sock)
        payload = record(b"D", peer=1, payload=b"abc")
        bridge.wire.write_bytes(record() + payload[:15])
        bridge.read_local()
        self.assertEqual(bridge.tx_pos, 14)  # Not the prefetched partial record.
        self.assertTrue(bridge.status_path.read_text().endswith("up 14\n"))
        self.assertNotIn(b"\r", bridge.status_path.read_bytes())
        before = bytes(bridge.send_buffer)
        bridge.sock.blocked = True
        bridge.send(time.monotonic())
        self.assertEqual(bridge.send_buffer, before)
        bridge.sock.blocked = False
        bridge.send(time.monotonic())
        self.assertEqual(bytes(bridge.send_buffer), before[3:])
        with bridge.wire.open("ab") as stream:
            stream.write(payload[15:])
        bridge.read_local()
        self.assertEqual(bridge.tx_pos, 14 + len(payload))
        while bridge.send_buffer:
            bridge.send(time.monotonic())
        expected = lan.frame(b"D", A, B, record()) + lan.frame(b"D", A, B, payload)
        received = b""
        while len(received) < len(expected):
            received += remote.recv(4096)
        self.assertEqual(received, expected)

    def test_bounded_send_queue_and_outgoing_unread_journal(self):
        bridge, _ = self.bridge()
        bridge.wire.write_bytes(record() * (lan.LIMIT // 14))
        for _ in range(30):
            bridge.read_local()
        self.assertLessEqual(len(bridge.send_buffer), lan.LIMIT)
        self.assertGreater(bridge.tx_pos, 0)
        self.assertLess(bridge.tx_pos, bridge.wire.stat().st_size)
        self.assertEqual(bridge.tx_pos % 14, 0)
        self.assertTrue(bridge.status_path.read_text().endswith(f"up {bridge.tx_pos}\n"))
        with bridge.wire.open("ab") as stream:
            stream.write(b"x" * lan.LIMIT)
        with self.assertRaisesRegex(lan.LinkError, "backlog limit"):
            bridge.read_local()

    def test_reset_generation_relay_and_progress(self):
        bridge, remote = self.bridge()
        records = [record(), record(b"F", peer=1), record(b"D", peer=1, payload=b"old"),
                   record(epoch=2), record(b"F", epoch=2, peer=3),
                   record(b"D", epoch=2, peer=3, payload=b"\0\xffnew")]
        wire = b"".join(lan.frame(b"D", B, A, value) for value in records)
        for byte in wire:
            remote.sendall(bytes([byte]))
            bridge.receive(time.monotonic())
        self.assertEqual(bridge.incoming.read_bytes(), b"".join(records))
        self.assertEqual(bridge.progress, 0)
        self.progress(bridge, len(records[0]))
        bridge.read_progress(time.monotonic())
        self.assertEqual(bridge.progress, 14)
        bridge.progress_path.write_bytes(b"P2P1 " + A.hex().encode() + b" 2")
        bridge.read_progress(time.monotonic())
        self.assertEqual(bridge.progress, 14)
        for position, failed in ((13, 0), (bridge.rx_pos + 1, 0), (14, 1)):
            self.progress(bridge, position, failed)
            with self.assertRaises(lan.LinkError):
                bridge.read_progress(time.monotonic())

    def test_incoming_limit_fails_closed_while_mame_paused(self):
        bridge, remote = self.bridge()
        payload = record(b"D", peer=1, payload=b"x" * 255)
        for _ in range(lan.LIMIT // len(payload)):
            remote.sendall(lan.frame(b"D", B, A, payload))
            bridge.receive(time.monotonic())
        previous = bridge.incoming.read_bytes()
        remote.sendall(lan.frame(b"D", B, A, payload))
        with self.assertRaisesRegex(lan.LinkError, "incoming unread"):
            bridge.receive(time.monotonic())
        self.assertEqual(bridge.incoming.read_bytes(), previous)
        self.assertLessEqual(len(previous), lan.LIMIT)

    def test_deadlines_disconnect_and_normal_quit(self):
        bridge, remote = self.bridge()
        now = bridge.started + 61
        bridge.last_rx = now
        with self.assertRaisesRegex(lan.LinkError, "plugin did not"):
            bridge.check_deadlines(now)
        bridge.progress_seen = True
        bridge.rx_pos = 14
        with self.assertRaisesRegex(lan.LinkError, "receive progress"):
            bridge.check_deadlines(now)
        bridge.progress = 14
        bridge.last_rx = now - 11
        with self.assertRaisesRegex(lan.LinkError, "heartbeat"):
            bridge.check_deadlines(now)
        bridge.last_rx = now
        bridge.send_buffer.extend(b"x")
        with self.assertRaisesRegex(lan.LinkError, "send stalled"):
            bridge.check_deadlines(now)
        bridge.send_buffer.clear()
        remote.sendall(lan.frame(b"Q", B, A))
        bridge.receive(time.monotonic())
        self.assertTrue(bridge.peer_quit)
        remote.close()
        with self.assertRaisesRegex(lan.LinkError, "disconnected"):
            bridge.receive(time.monotonic())

    def test_progress_releases_incoming_budget(self):
        bridge, remote = self.bridge()
        payload = record(b"D", peer=1, payload=b"x" * 255)
        for _ in range(300):
            remote.sendall(lan.frame(b"D", B, A, payload))
            bridge.receive(time.monotonic())
            self.progress(bridge, bridge.rx_pos)
            bridge.read_progress(time.monotonic())
        self.assertGreater(bridge.rx_pos, lan.LIMIT)  # History may grow; unread must not.
        self.assertEqual(bridge.progress, bridge.rx_pos)

    def test_startup_wait_retry_and_failure(self):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        result, errors = [], []

        def connector():
            try:
                result.append(lan.connect_peer("B", "127.0.0.1", port, 2))
            except Exception as error:
                errors.append(error)

        thread = threading.Thread(target=connector)
        thread.start()
        time.sleep(0.05)
        server, _ = lan.connect_peer("A", "127.0.0.1", port, 2)
        self.open_sockets.append(server)
        thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertFalse(errors)
        self.open_sockets.append(result[0][0])
        server.close()
        result[0][0].close()
        with self.assertRaises((lan.LinkError, OSError)):
            lan.connect_peer("B", "127.0.0.1", port, 0.03)
        with self.assertRaisesRegex(lan.LinkError, "waiting for PC B timed out"):
            lan.connect_peer("A", "127.0.0.1", port, 0.03)
        # The failed listener must release its socket.
        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", port))

    def test_ctrl_c_interrupts_listener_and_silent_hello_promptly(self):
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        local, remote = self.pair()
        waits = (
            lambda: lan.connect_peer("A", "127.0.0.1", port, 5),
            lambda: lan.exchange_hello(local, "A", A, time.monotonic() + 5),
        )
        for wait in waits:
            timer = threading.Timer(0.2, _thread.interrupt_main)
            started = time.monotonic()
            timer.start()
            try:
                with self.assertRaises(KeyboardInterrupt):
                    wait()
            finally:
                timer.cancel()
                timer.join()
            self.assertLess(time.monotonic() - started, 2,
                            "Ctrl+C was deferred until the startup timeout")
        with socket.socket() as listener:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            listener.bind(("127.0.0.1", port))

    def test_supervisor_kills_only_own_stub_on_network_failure(self):
        bridge, remote = self.bridge()
        original_stop = lan.stop_child
        children = []
        original_popen = subprocess.Popen

        def spawn(*args, **kwargs):
            child = original_popen(*args, **kwargs)
            children.append(child)
            return child

        with (self.directory / "stub.log").open("w") as output:
            with patch.object(lan.subprocess, "Popen", side_effect=spawn), \
                    patch.object(lan, "stop_child", side_effect=lambda child: original_stop(child, 0.03)), \
                    patch.object(bridge, "step", side_effect=lan.LinkError("test disconnect")):
                with self.assertRaisesRegex(lan.LinkError, "test disconnect"):
                    lan.supervise(bridge, [sys.executable, "-c", "import time; time.sleep(60)"],
                                  os.environ.copy(), output)
        self.assertIsNotNone(children[0].poll())
        self.assertIn(" down ", bridge.status_path.read_text())
        self.assertEqual(remote.recv(1), b"")

    def test_supervisor_normal_exit_and_spawn_failure(self):
        bridge, remote = self.bridge()
        child = Mock(pid=123)
        child.poll.return_value = 0
        with patch.object(lan.subprocess, "Popen", return_value=child):
            self.assertEqual(lan.supervise(bridge, ["stub"], {}, None), 0)
        self.assertEqual(lan.pop_frame(bytearray(remote.recv(4096)), B, A), (b"Q", b""))
        bridge.sock, remote = self.pair()
        with patch.object(lan.subprocess, "Popen", side_effect=OSError("test missing executable")):
            with self.assertRaises(OSError):
                lan.supervise(bridge, ["stub"], {}, None)
        self.assertEqual(remote.recv(1), b"")

    def test_paired_bridge_steps_bidirectional_and_quit(self):
        first, second = self.pair()
        other_directory = self.directory / "B"
        other_directory.mkdir()
        a = lan.Bridge(first, self.directory, "A", A, B)
        b = lan.Bridge(second, other_directory, "B", B, A)
        forward = record() + record(b"F", peer=1) + record(b"D", peer=1, payload=b"forward")
        reverse = record() + record(b"F", peer=1) + record(b"D", peer=1, payload=b"reverse")
        a.wire.write_bytes(forward)
        b.wire.write_bytes(reverse)
        deadline = time.monotonic() + 1
        while (a.rx_pos != len(reverse) or b.rx_pos != len(forward)) and time.monotonic() < deadline:
            a.step()
            b.step()
        self.assertEqual(a.incoming.read_bytes(), reverse)
        self.assertEqual(b.incoming.read_bytes(), forward)
        a.quit()
        self.assertTrue(lan.select.select([b.sock], [], [], 1)[0])
        b.queue(b"H")
        with patch.object(b, "send", side_effect=AssertionError("sent after peer quit")):
            while not b.peer_quit and time.monotonic() < deadline:
                b.step()
        self.assertTrue(b.peer_quit)

    def test_launcher_command_environment_and_fresh_runs(self):
        parent_environment = dict(os.environ)
        calls = []

        def supervise(bridge, command, environment, output):
            calls.append((command, environment))
            bridge.status("down")
            return 0

        for _ in range(2):
            first, _ = self.pair()
            with patch.object(lan, "connect_peer", return_value=(first, time.monotonic() + 1)), \
                    patch.object(lan, "exchange_hello", return_value=B), \
                    patch.object(lan, "supervise", side_effect=supervise):
                self.assertEqual(lan.main(["--side", "A", "--runs", str(self.directory),
                                           "--mame", "test-mame"]), 0)
        self.assertEqual(dict(os.environ), parent_environment)
        self.assertNotEqual(calls[0][1]["PUYO2_LINK_DIR"], calls[1][1]["PUYO2_LINK_DIR"])
        for command, environment in calls:
            self.assertEqual(command[:4], ["test-mame", "puyopuy2", "-plugin", "puyo2link"])
            self.assertIn("-throttle", command)
            self.assertEqual(command[command.index("-speed") + 1], "1")
            self.assertIn("-norefreshspeed", command)
            self.assertIn("-nosyncrefresh", command)
            self.assertIn("-joystick", command)
            self.assertEqual(environment["PUYO2_LINK_SIDE"], "A")
            self.assertTrue(Path(environment["PUYO2_LINK_DIR"]).is_absolute())
            self.assertEqual(len(environment["PUYO2_LINK_SESSION"]), 32)

    def test_stop_child_escalates_and_reaps(self):
        child = Mock()
        child.poll.return_value = None
        child.wait.side_effect = [subprocess.TimeoutExpired("stub", 1),
                                  subprocess.TimeoutExpired("stub", 1), 0]
        lan.stop_child(child, 0.01)
        child.terminate.assert_called_once()
        child.kill.assert_called_once()
        self.assertEqual(child.wait.call_count, 3)

    def test_lua_failure_is_not_mistaken_for_normal_child_exit(self):
        bridge, remote = self.bridge()
        self.progress(bridge, failed=1)
        child = Mock(pid=123)
        child.poll.return_value = 0
        with patch.object(lan.subprocess, "Popen", return_value=child):
            with self.assertRaisesRegex(lan.LinkError, "Lua transport failed"):
                lan.supervise(bridge, ["stub"], {}, None)
        self.assertEqual(remote.recv(1), b"")

    def test_status_windows_sharing_retry_is_bounded(self):
        path = self.directory / "test.status"
        replace = os.replace
        attempts = []

        def retry(source, destination):
            attempts.append(1)
            if len(attempts) == 1:
                raise PermissionError("reader holds snapshot")
            replace(source, destination)

        with patch.object(lan.os, "replace", side_effect=retry):
            lan.atomic_status(path, A, "up", 42)
        self.assertEqual(len(attempts), 2)
        self.assertEqual(path.read_bytes(), f"P2S1 {A.hex()} up 42\n".encode())
        with patch.object(lan.os, "replace", side_effect=PermissionError), \
                patch.object(lan.time, "monotonic", side_effect=[0, 1]):
            with self.assertRaises(PermissionError):
                lan.atomic_status(path, A, "down", 42)

    def test_cli_closed_defaults_and_invalid_roles(self):
        self.assertEqual(lan.arguments(["--side", "A"]).address, "127.0.0.1")
        self.assertEqual(lan.arguments(["--side", "B", "--connect", "192.168.1.2"]).address, "192.168.1.2")
        for args in (["--side", "B"], ["--side", "A", "--connect", "127.0.0.1"],
                     ["--side", "A", "--listen", "example.com"], ["--side", "A", "--timeout", "nan"],
                     ["--side", "A", "--port", "0"]):
            with self.subTest(args=args), patch("sys.stderr"), self.assertRaises(SystemExit):
                lan.arguments(args)


if __name__ == "__main__":
    unittest.main(verbosity=2)
