#!/usr/bin/env python3
# Pull a few seconds of /stream, de-chunk the HTTP body, parse the app framing
# ([1B type:0=delta,1=key,2=orient,3=reset][4B BE len][payload]), where video
# payload is [8B BE pts_us][Annex-B access unit]. Writes the video NALs as
# Annex-B. Used to self-verify capture/wake without WebCodecs.
#   python3 grab_frame.py <ip> <seconds> <out.h264>
import socket, struct, sys, time

ip   = sys.argv[1] if len(sys.argv) > 1 else "192.168.178.45"
secs = float(sys.argv[2]) if len(sys.argv) > 2 else 4.0
out  = sys.argv[3] if len(sys.argv) > 3 else "/tmp/rctl_grab.h264"

s = socket.create_connection((ip, 8080), timeout=6)
s.sendall(b"GET /stream HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
buf = b""
while b"\r\n\r\n" not in buf:
    buf += s.recv(4096)
_, buf = buf.split(b"\r\n\r\n", 1)

# de-chunk HTTP/1.1 chunked transfer-encoding into the raw app byte stream
data = buf
app = b""
s.settimeout(1.0)
end = time.time() + secs
while time.time() < end:
    while True:
        nl = data.find(b"\r\n")
        if nl < 0:
            break
        try:
            clen = int(data[:nl], 16)
        except ValueError:
            data = b""
            break
        if clen == 0:
            end = 0
            break
        if len(data) < nl + 2 + clen + 2:
            break
        app += data[nl + 2: nl + 2 + clen]
        data = data[nl + 2 + clen + 2:]
    if end == 0:
        break
    try:
        more = s.recv(65536)
    except socket.timeout:
        continue
    if not more:
        break
    data += more
s.close()

# parse app frames -> Annex-B video
i = 0
nals = b""
nkey = ndelta = 0
while i + 5 <= len(app):
    t = app[i]
    ln = struct.unpack(">I", app[i + 1:i + 5])[0]
    if i + 5 + ln > len(app):
        break
    payload = app[i + 5:i + 5 + ln]
    i += 5 + ln
    if t == 1 and len(payload) >= 8:
        nals += payload[8:]; nkey += 1
    elif t == 0 and len(payload) >= 8:
        nals += payload[8:]; ndelta += 1

open(out, "wb").write(nals)
print(f"app={len(app)}B video={len(nals)}B keyframes={nkey} deltas={ndelta}")
