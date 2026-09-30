#!/usr/bin/env python3
"""Independent reference DUML encoder used to generate test fixtures.

Written from the public description of the DUML v1 frame (dji_rev wiki,
samuelsadok/dji_protocol, o-gs/dji-firmware-tools comm_dissector). It shares no
code with the Swift implementation; the Swift tests must agree with its output.
"""
import json, sys

def make_table8(poly=0x8C):
    t = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (c >> 1) ^ poly if c & 1 else c >> 1
        t.append(c)
    return t

def make_table16(poly=0x8408):
    t = []
    for i in range(256):
        c = i
        for _ in range(8):
            c = (c >> 1) ^ poly if c & 1 else c >> 1
        t.append(c)
    return t

T8, T16 = make_table8(), make_table16()
# Sanity: first entries must equal the published tables in comm_dissector.
assert T8[:4] == [0x00, 0x5e, 0xbc, 0xe2], T8[:4]
assert T16[:4] == [0x0000, 0x1189, 0x2312, 0x329b], T16[:4]

def crc8(b, seed=0x77):
    c = seed
    for x in b: c = T8[c ^ x]
    return c

def crc16(b, seed=0x3692):
    c = seed
    for x in b: c = T16[(c ^ x) & 0xFF] ^ (c >> 8)
    return c

def encode(sender, receiver, seq, cmd_set, cmd_id, payload=b"", response=False, ack=2, enc=0, version=1):
    length = 11 + len(payload) + 2
    vl = (length & 0x3FF) | (version << 10)
    h = bytes([0x55, vl & 0xFF, vl >> 8])
    h += bytes([crc8(h)])
    body = bytes([sender, receiver, seq & 0xFF, seq >> 8, (0x80 if response else 0) | (ack << 5) | enc, cmd_set, cmd_id]) + payload
    frame = h + body
    c = crc16(frame)
    return frame + bytes([c & 0xFF, c >> 8])

CASES = [
    # name, sender, receiver, seq, set, id, payload, response, ack
    ("ping_pc_to_rc",            0x0A, 0x06, 1,     0x00, 0x00, b"",                      False, 2),
    ("get_version_pc_to_fc",     0x0A, 0x03, 0x1234,0x00, 0x01, b"",                      False, 2),
    ("get_version_response",     0x03, 0x0A, 0x1234,0x00, 0x01, bytes(range(0, 24)),      True,  0),
    ("rc_push_no_ack",           0x06, 0x0A, 7,     0x06, 0x05, bytes([0x00,0x04,0x00,0x04,0x00,0x04,0x00,0x04]), False, 0),
    ("camera_indexed_sender",    0x21, 0x0A, 65535, 0x02, 0x80, b"\x01\x02\x03",          True,  1),
    ("max_ish_payload",          0x0A, 0x01, 42,    0x02, 0x01, bytes([i & 0xFF for i in range(300)]), False, 2),
]

out = {"crc8_table_head": T8[:8], "crc16_table_head": T16[:8],
       "crc8_seed": 0x77, "crc16_seed": 0x3692,
       "crc8_of_55_0d_04": crc8(bytes([0x55, 0x0d, 0x04])),
       "packets": []}
for name, s, r, seq, cs, ci, pl, rsp, ack in CASES:
    f = encode(s, r, seq, cs, ci, pl, rsp, ack)
    out["packets"].append({"name": name, "sender": s, "receiver": r, "sequence": seq, "commandSet": cs,
                           "commandID": ci, "payload": pl.hex(), "isResponse": rsp, "ackType": ack, "frame": f.hex()})
json.dump(out, open(sys.argv[1], "w") if len(sys.argv) > 1 else sys.stdout, indent=1)
