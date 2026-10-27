"""The fixture's network peer for live tests: HTTP on 127.0.0.1:8765, WebSocket on 8766. Stdlib only."""
import base64, hashlib, socket, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAGE = (b'<html><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>'
        b'<body style="font-size:40px" ontouchstart="this.style.background=\'#fcc\'">'
        b'<a href="/slow">Slow link</a></body></html>')


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/slow"):
            time.sleep(2.5)
        if self.path.startswith("/medium"):
            time.sleep(1.2)
        if self.path.startswith("/fail"):
            return self.reply(500, b"failed")
        if self.path.startswith("/metrics"):
            return self.reply(204, b"")
        if self.path.startswith("/page"):
            return self.reply(200, PAGE, "text/html")
        self.reply(200, b"ok")

    def reply(self, code, body, kind="text/plain"):
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def websocket():
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 8766))
    s.listen()
    while True:
        c, _ = s.accept()
        request = c.recv(4096).decode(errors="replace")
        key = [l.split(": ", 1)[1] for l in request.split("\r\n") if l.lower().startswith("sec-websocket-key")]
        if not key:
            c.close()
            continue
        accept = base64.b64encode(hashlib.sha1((key[0] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        c.send(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               b"Sec-WebSocket-Accept: " + accept + b"\r\n\r\n")

        def tick(c=c):
            try:
                while True:
                    c.send(b"\x81\x04tick")
                    time.sleep(0.05)  # faster than chauffeur's 100 ms samples, so every sample sees it stream
            except OSError:
                pass

        threading.Thread(target=tick, daemon=True).start()


threading.Thread(target=websocket, daemon=True).start()
ThreadingHTTPServer.allow_reuse_address = True
ThreadingHTTPServer(("127.0.0.1", 8765), Handler).serve_forever()
