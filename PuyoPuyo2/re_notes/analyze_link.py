"""Read-only audit of puyo2link journals and ROM-framed application packets.

Usage: py PuyoPuyo2\\re_notes\\analyze_link.py PuyoPuyo2\\run_directory [...]
Counts on the wire prove transmission, NOT game acceptance or garbage landing.
"""
import argparse
from collections import Counter, defaultdict
from pathlib import Path
import struct

HEADER = struct.Struct(">4sIIH")
LENGTHS = ((2, 2), (3, 4), (4, 14), (5, 17))


def audit(path):
    wire = path.read_bytes()
    groups = defaultdict(bytearray)
    raw = bytearray()
    offset = 0
    while offset + HEADER.size <= len(wire):
        magic, epoch, peer, size = HEADER.unpack_from(wire, offset)
        if magic not in (b"P2R1", b"P2F1", b"P2D1") or size > 255:
            raise ValueError(f"{path}: invalid record at {offset}")
        end = offset + HEADER.size + size
        if end > len(wire):
            break
        if magic == b"P2D1":
            payload = wire[offset + HEADER.size:end]
            groups[epoch, peer].extend(payload)
            raw.extend(payload)
        offset = end
    raw_path = path.with_suffix("")
    print(f"{path}: wire_tail={len(wire) - offset} "
          f"raw_matches={raw_path.exists() and raw_path.read_bytes() == raw}")
    for epochs, data in groups.items():
        position, expected, errors = 0, 0, 0
        flags_seen, commands, attacks = Counter(), Counter(), Counter()
        while position + 3 <= len(data):
            seq, flags, status = data[position:position + 3]
            length = 3 + sum(n for bit, n in LENGTHS if flags & (1 << bit))
            if position + length > len(data):
                break
            errors += seq != expected
            expected = (seq + 1) & 255
            flags_seen[flags] += 1
            cursor = position + 3
            if flags & 4:
                commands[data[cursor]] += 1
                cursor += 2
            if flags & 8:
                attacks[struct.unpack_from(">HH", data, cursor)] += 1
            position += length
        positive = sum(n for pair, n in attacks.items()
                       if any(word != 0xffff and word & 0x7fff for word in pair))
        print(f"  generations={epochs} bytes={len(data)} packets={sum(flags_seen.values())} "
              f"sequence_errors={errors} packet_tail={len(data) - position}")
        print("  flags=" + " ".join(f"{k:02x}:{v}" for k, v in sorted(flags_seen.items())))
        print(f"  attack_packets={sum(attacks.values())} positive_attack_packets={positive} "
              + " ".join(f"{a:04x},{b:04x}:{n}" for (a, b), n in sorted(attacks.items())))
        print("  commands=" + " ".join(f"{k:02x}:{v}" for k, v in sorted(commands.items())))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directories", nargs="+", type=Path)
    args = parser.parse_args()
    for directory in args.directories:
        for journal in sorted(directory.glob("*.bin.wire")):
            audit(journal)
