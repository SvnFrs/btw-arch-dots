import socket
import json as js
import os

def get_msg_template(method: str):
    message = {}
    message["method"] = method
    message["data"] = {}
    return message

def geometry_to_json(x: int, y: int, w: int, h: int):
    geometry = {}
    geometry["x"] = x
    geometry["y"] = y
    geometry["width"] = w
    geometry["height"] = h
    return geometry

class WayfireSocket:
    def __init__(self, socket_name=None):
        if socket_name is None:
            socket_name = os.getenv('WAYFIRE_SOCKET')

        if not socket_name:
            raise Exception("WAYFIRE_SOCKET environment variable not set")

        # Xử lý đường dẫn socket nếu nó chưa đầy đủ
        if '/' not in socket_name:
             xdg_runtime = os.getenv('XDG_RUNTIME_DIR', f"/run/user/{os.getuid()}")
             socket_name = os.path.join(xdg_runtime, socket_name)

        self.client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.client.connect(socket_name)

    def read_exact(self, n):
        response = bytes()
        while n > 0:
            read_this_time = self.client.recv(n)
            if not read_this_time:
                raise Exception("Failed to read anything from the socket!")
            n -= len(read_this_time)
            response += read_this_time
        return response

    def read_message(self):
        try:
            length_bytes = self.read_exact(4)
            rlen = int.from_bytes(length_bytes, byteorder="little")
            response_message = self.read_exact(rlen)
            response = js.loads(response_message)
            if "error" in response:
                # In lỗi nhưng không crash để script tiếp tục chạy
                print(f"Wayfire IPC Error: {response['error']}")
                return None
            return response
        except Exception as e:
            print(f"Socket read error: {e}")
            return None

    def send_json(self, msg):
        try:
            data = js.dumps(msg).encode('utf8')
            header = len(data).to_bytes(4, byteorder="little")
            self.client.send(header)
            self.client.send(data)
            return self.read_message()
        except Exception as e:
            print(f"Socket send error: {e}")
            return None

    def close(self):
      self.client.close()

    def watch(self, events = None):
        message = get_msg_template("window-rules/events/watch")
        if events:
            message["data"]["events"] = events
        return self.send_json(message)

    def list_views(self):
        return self.send_json(get_msg_template("window-rules/list-views"))

    def set_view_alpha(self, view_id: int, alpha: float):
        message = get_msg_template("wf/alpha/set-view-alpha")
        message["data"] = {}
        message["data"]["view-id"] = view_id
        message["data"]["alpha"] = alpha
        return self.send_json(message)