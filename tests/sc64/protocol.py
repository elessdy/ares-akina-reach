"""Regression tests against an unpaused, disposable SC64 emulator session.

No ROM, credentials, server address, or third-party Python dependency is needed
in this repository. The caller owns starting/stopping the emulator and supplies
its loopback port. Do not run while a bridge is connected.
"""
import argparse
import socket
import struct
import time
import unittest

PORT = 9064
MAX_PAYLOAD = 16 * 1024 * 1024


def command(mode, name, arg0=0, arg1=0, payload=b''):
    name = name.encode('ascii')
    if mode == 'remote':
        return struct.pack('>IBIII', 1, name[0], arg0, arg1, len(payload)) + payload
    return b'CMD' + name + struct.pack('>II', arg0, arg1) + payload


def exact(sock, count):
    data = bytearray()
    while len(data) < count:
        block = sock.recv(count - len(data))
        if not block:
            raise EOFError('SC64 disconnected')
        data.extend(block)
    return bytes(data)


def response(sock, mode, name):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        prefix = exact(sock, 4)
        if mode == 'remote':
            kind, = struct.unpack('>I', prefix)
            if kind == 0xCAFEBEEF:
                continue
            if kind not in (2, 3):
                raise AssertionError(f'bad remote frame type: {kind}')
            identity = exact(sock, 1)
            error = bool(exact(sock, 1)[0]) if kind == 2 else False
        else:
            if prefix[:3] not in (b'CMP', b'ERR', b'PKT'):
                raise AssertionError(f'bad direct token: {prefix!r}')
            kind = 3 if prefix[:3] == b'PKT' else 2
            identity = prefix[3:4]
            error = prefix[:3] == b'ERR'
        length, = struct.unpack('>I', exact(sock, 4))
        if length > MAX_PAYLOAD + 4:
            raise AssertionError(f'oversized emulator response: {length}')
        data = exact(sock, length)
        if kind == 2:
            if identity != name.encode('ascii'):
                raise AssertionError(f'unexpected response: {identity!r}')
            return error, data
    raise TimeoutError('response timeout')


class ProtocolTests(unittest.TestCase):
    def client(self):
        sock = socket.create_connection(('127.0.0.1', PORT), timeout=5)
        self.addCleanup(sock.close)
        return sock

    def identity(self, sock, mode):
        sock.sendall(command(mode, 'v'))
        self.assertEqual(response(sock, mode, 'v'), (False, b'SCv2'))

    def test_all_header_splits(self):
        for mode in ('direct', 'remote'):
            message = command(mode, 'v')
            for split in range(len(message) + 1):
                with self.subTest(mode=mode, split=split), self.client() as sock:
                    sock.sendall(message[:split])
                    time.sleep(0.002)
                    sock.sendall(message[split:])
                    self.assertEqual(response(sock, mode, 'v'), (False, b'SCv2'))

    def test_bytewise_and_coalesced_commands(self):
        for mode in ('direct', 'remote'):
            with self.subTest(mode=mode), self.client() as sock:
                for byte in command(mode, 'v'):
                    sock.sendall(bytes([byte]))
                    time.sleep(0.001)
                self.assertEqual(response(sock, mode, 'v'), (False, b'SCv2'))
                # Cross multiple emulation polls repeatedly, including room
                # for unrelated asynchronous cartridge output between polls.
                for _ in range(4):
                    sock.sendall(command(mode, 'v') * 130)
                    for _ in range(130):
                        self.assertEqual(response(sock, mode, 'v'), (False, b'SCv2'))

    def test_memory_bounds_before_allocation(self):
        for mode in ('direct', 'remote'):
            with self.subTest(mode=mode), self.client() as sock:
                self.identity(sock, mode)
                for address, length in ((0, 0xFFFFFFFF), (0, MAX_PAYLOAD + 1),
                                        (0xFFFFFFFF, 4), (0x05002C7F, 2)):
                    sock.sendall(command(mode, 'm', address, length))
                    self.assertEqual(response(sock, mode, 'm'), (True, b''))
                    self.identity(sock, mode)
                # A temporary MCU buffer, unrelated to cartridge save data.
                data = bytes(range(32))
                address = 0x05002800
                sock.sendall(command(mode, 'M', address, len(data), data))
                self.assertEqual(response(sock, mode, 'M'), (False, b''))
                sock.sendall(command(mode, 'm', address, len(data)))
                self.assertEqual(response(sock, mode, 'm'), (False, data))

    def test_malformed_frame_disconnect_and_clean_reconnect(self):
        for mode in ('direct', 'remote'):
            with self.subTest(mode=mode), self.client() as sock:
                self.identity(sock, mode)
                if mode == 'direct':
                    bad = command(mode, 'M', 0, MAX_PAYLOAD + 1)
                else:
                    bad = struct.pack('>IBIII', 1, ord('M'), 0, 1, MAX_PAYLOAD + 1)
                sock.sendall(bad)
                try:
                    self.assertEqual(sock.recv(1), b'')
                except ConnectionResetError:
                    pass
            with self.client() as sock:
                self.identity(sock, 'remote' if mode == 'direct' else 'direct')

    def test_partial_old_connection_cannot_prefix_new_connection(self):
        for mode in ('direct', 'remote'):
            with self.subTest(mode=mode), self.client() as sock:
                sock.sendall(command(mode, 'v')[:7])
            # Accept and EOF can be adjacent polls. A new client must start
            # clean even if the old client never completed its first command.
            with self.client() as sock:
                self.identity(sock, 'remote' if mode == 'direct' else 'direct')

    def test_standalone_keepalive_then_command(self):
        with self.client() as sock:
            self.identity(sock, 'remote')
            sock.sendall(struct.pack('>I', 0xCAFEBEEF))
            time.sleep(0.05)
            self.identity(sock, 'remote')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, required=True)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error('port must be 1..65535')
    PORT = args.port
    unittest.main(argv=['protocol.py'], verbosity=2)
