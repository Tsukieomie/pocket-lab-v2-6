#!/usr/bin/env python3
"""
fs_cloud client — runs on Kenny's machine.
Connects to Perplexity Computer's WebSocket server (port 9000)
and serves local SFTP, mounting Kenny's filesystem on the server side.

Usage: python3 fs_cloud_client.py
"""
import asyncio
import os
import socket
import subprocess
import struct
import sys
import threading

try:
    import websockets
except ImportError:
    print("Installing websockets...")
    os.system(f"{sys.executable} -m pip install websockets -q")
    import websockets

SERVER_URI = "ws://34.83.65.248:9000"
SFTP_PORT_RANGE = range(10022, 10122)

HEADER_FMT = "!II"
HEADER_SIZE = struct.calcsize(HEADER_FMT)

def find_free_port():
    for p in SFTP_PORT_RANGE:
        try:
            s = socket.socket()
            s.bind(('127.0.0.1', p))
            s.close()
            return p
        except:
            continue
    return None

def pipe(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except:
        pass
    finally:
        try: dst.shutdown(socket.SHUT_WR)
        except: pass

class MuxClient:
    def __init__(self, ws):
        self.ws = ws
        self.streams = {}
        self.lock = threading.Lock()
        self.loop = asyncio.get_event_loop()
        self._wbuf = bytearray()

    def _send_frame(self, stream_id, data):
        hdr = struct.pack(HEADER_FMT, stream_id, len(data))
        asyncio.run_coroutine_threadsafe(self.ws.send(hdr + data), self.loop)

    async def read_loop(self, sftp_port):
        buf = bytearray()
        async for msg in self.ws:
            if isinstance(msg, str):
                msg = msg.encode()
            buf.extend(msg)
            while len(buf) >= HEADER_SIZE:
                stream_id, length = struct.unpack_from(HEADER_FMT, buf)
                if len(buf) < HEADER_SIZE + length:
                    break
                payload = bytes(buf[HEADER_SIZE:HEADER_SIZE+length])
                del buf[:HEADER_SIZE+length]
                
                if stream_id == 0:
                    # Control message
                    if payload and payload[0:1] == b'N':
                        new_id = struct.unpack_from('!I', payload, 1)[0]
                        # Server opened a new stream -> connect to local sshd
                        self._handle_new_stream(new_id, sftp_port)
                    elif payload and payload[0:1] == b'M':
                        print("[fs_cloud] Mount ready signal received — filesystem mounted!")
                        sys.stdout.flush()
                else:
                    # Data for a stream
                    with self.lock:
                        conn = self.streams.get(stream_id)
                    if conn:
                        try:
                            conn.sendall(payload)
                        except:
                            pass

    def _handle_new_stream(self, stream_id, sftp_port):
        def worker():
            try:
                conn = socket.create_connection(('127.0.0.1', sftp_port), timeout=5)
                with self.lock:
                    self.streams[stream_id] = conn
                # Read from local SFTP and send to mux
                while True:
                    data = conn.recv(65536)
                    if not data:
                        break
                    self._send_frame(stream_id, data)
                # Send end-of-stream
                ctrl = b'E' + struct.pack('!I', stream_id)
                self._send_frame(0, ctrl)
            except Exception as e:
                print(f"[stream {stream_id}] error: {e}", file=sys.stderr)
            finally:
                with self.lock:
                    self.streams.pop(stream_id, None)
        threading.Thread(target=worker, daemon=True).start()

async def main():
    # Start local sshd on a high port for SFTP
    sftp_port = find_free_port()
    if not sftp_port:
        print("ERROR: No free port found")
        sys.exit(1)

    print(f"[fs_cloud] Starting local SFTP server on port {sftp_port}...")
    sys.stdout.flush()
    
    # Start sshd on high port
    sshd_cmd = ['sshd', '-D', '-p', str(sftp_port), '-o', 'Subsystem=sftp /usr/lib/openssh/sftp-server']
    try:
        proc = subprocess.Popen(sshd_cmd, stderr=subprocess.PIPE)
        await asyncio.sleep(1)
        if proc.poll() is not None:
            err = proc.stderr.read().decode()
            print(f"sshd failed: {err}")
            # Try alternative sftp server
            raise Exception("sshd failed")
    except Exception as e:
        print(f"[fs_cloud] sshd method failed: {e}")
        # Fallback: use python sftp server  
        try:
            import paramiko
        except ImportError:
            print("[fs_cloud] Installing paramiko...")
            os.system(f"{sys.executable} -m pip install paramiko -q")
        # Use a simple socket relay to system sshd port 22
        print(f"[fs_cloud] Using relay to sshd port 22...")
        sftp_port = 22
        proc = None

    print(f"[fs_cloud] Connecting to {SERVER_URI}...")
    sys.stdout.flush()
    
    async with websockets.connect(SERVER_URI, max_size=None, ping_interval=10) as ws:
        print(f"[fs_cloud] Connected! Server will mount your filesystem.")
        print(f"[fs_cloud] Perplexity Computer now has access to your files.")
        sys.stdout.flush()
        
        mux = MuxClient(ws)
        await mux.read_loop(sftp_port)
    
    print("[fs_cloud] Disconnected.")

if __name__ == '__main__':
    asyncio.run(main())
