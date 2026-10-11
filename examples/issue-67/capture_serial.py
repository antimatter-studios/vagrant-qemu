import socket
import sys
import time

# Connect as soon as QEMU exposes its serial channel; never send guest input.
deadline = time.monotonic() + 1200
while time.monotonic() < deadline:
    try:
        channel = socket.create_connection(('127.0.0.1', 33334), timeout=1)
        break
    except OSError:
        time.sleep(0.1)
else:
    sys.exit('Serial channel never became available')
with channel:
    channel.settimeout(1)
    while time.monotonic() < deadline:
        try:
            data = channel.recv(4096)
        except socket.timeout:
            continue
        if not data:
            break
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
