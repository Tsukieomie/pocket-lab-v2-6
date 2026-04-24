#!/usr/bin/env python3
"""fs_cloud client — connects Kenny's machine to Perplexity's filesystem bridge."""
import asyncio, os, socket, struct, sys, threading, subprocess

# Try system websockets first (no pip needed)
try:
    import websockets
except ImportError:
    # Try apt install
    print("[fs_cloud] Installing python3-websockets via apt...")
    r = os.system("sudo apt-get install -y python3-websockets 2>/dev/null || apt-get install -y python3-websockets 2>/dev/null")
    if r != 0:
        os.system(f"{sys.executable} -m pip install websockets --break-system-packages -q 2>/dev/null")
    import websockets

SERVER_URI = "ws://34.83.65.248:9000"
HEADER_FMT = "!II"
HEADER_SIZE = struct.calcsize(HEADER_FMT)

class MuxClient:
    def __init__(self, ws, sftp_port):
        self.ws = ws
        self.sftp_port = sftp_port
        self.streams = {}
        self.lock = threading.Lock()
        self.loop = asyncio.get_event_loop()

    def send_frame(self, stream_id, data):
        frame = struct.pack(HEADER_FMT, stream_id, len(data)) + data
        asyncio.run_coroutine_threadsafe(self.ws.send(frame), self.loop)

    def handle_new_stream(self, stream_id):
        def worker():
            try:
                conn = socket.create_connection(('127.0.0.1', self.sftp_port), timeout=5)
                with self.lock:
                    self.streams[stream_id] = conn
                while True:
                    data = conn.recv(65536)
                    if not data: break
                    self.send_frame(stream_id, data)
                self.send_frame(0, b'E' + struct.pack('!I', stream_id))
            except Exception as e:
                print(f"[stream {stream_id}] {e}", file=sys.stderr)
            finally:
                with self.lock: self.streams.pop(stream_id, None)
        threading.Thread(target=worker, daemon=True).start()

    async def run(self):
        buf = bytearray()
        async for msg in self.ws:
            if isinstance(msg, str): msg = msg.encode()
            buf.extend(msg)
            while len(buf) >= HEADER_SIZE:
                sid, length = struct.unpack_from(HEADER_FMT, buf)
                if len(buf) < HEADER_SIZE + length: break
                payload = bytes(buf[HEADER_SIZE:HEADER_SIZE+length])
                del buf[:HEADER_SIZE+length]
                if sid == 0:
                    if payload[:1] == b'N':
                        new_id = struct.unpack_from('!I', payload, 1)[0]
                        self.handle_new_stream(new_id)
                    elif payload[:1] == b'M':
                        print("[fs_cloud] Filesystem mounted on Perplexity Computer!")
                        sys.stdout.flush()
                else:
                    with self.lock: conn = self.streams.get(sid)
                    if conn:
                        try: conn.sendall(payload)
                        except: pass

async def main():
    print(f"[fs_cloud] Connecting to {SERVER_URI}...")
    sys.stdout.flush()
    async with websockets.connect(SERVER_URI, max_size=None, ping_interval=10) as ws:
        print("[fs_cloud] Connected — serving your filesystem to Perplexity Computer")
        print("[fs_cloud] Keep this running. Press Ctrl+C to disconnect.")
        sys.stdout.flush()
        mux = MuxClient(ws, 22)  # relay to local sshd on port 22
        await mux.run()

if __name__ == '__main__':
    asyncio.run(main())
