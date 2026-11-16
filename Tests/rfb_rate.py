"""Drive the native RFB decoder with a fast local framebuffer source."""
import socket
import struct
import subprocess
import sys
import threading
import time

server = socket.socket()
server.bind(('127.0.0.1', 0))
server.listen()


def serve():
    connection, _ = server.accept()
    def read(count):
        data = b''
        while len(data) < count:
            packet = connection.recv(count - len(data))
            if not packet:
                raise EOFError()
            data += packet
        return data
    try:
        connection.sendall(b'RFB 003.008\n')
        read(12)
        connection.sendall(b'\x01\x01')
        read(1)
        connection.sendall(bytes(4))
        read(1)
        width, height = 128, 96
        connection.sendall(struct.pack('>HH',width,height)+bytes(16)+struct.pack('>I',4)+b'fast')
        read(20)
        read(12)
        pixels = bytes((17, 31, 57, 0)) * width * height
        frame = struct.pack('>BBHHHHHi',0,0,1,0,0,width,height,0)+pixels
        while True:
            assert read(1) == b'\x03'
            read(9)
            time.sleep(.002)
            connection.sendall(frame)
    except (EOFError, ConnectionError):
        pass
    finally:
        connection.close()


thread = threading.Thread(target=serve, daemon=True)
thread.start()
try:
    subprocess.run([sys.argv[1],f'vnc://127.0.0.1:{server.getsockname()[1]}'],check=True,timeout=10)
finally:
    server.close()
    thread.join(timeout=2)
