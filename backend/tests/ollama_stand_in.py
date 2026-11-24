# A stand-in for the Spark's Ollama, for running the backend on this Mac:
# nothing is ever loaded, and every chat is answered with rice and chicken
# (458 kcal before oil, judged fried). Prints what each chat asked for.
#
#   python3 -I backend/tests/ollama_stand_in.py 11499
#   LYFE_OLLAMA_URL=http://127.0.0.1:11499 cargo run -- serve
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
ANSWER = {"items": [{"name": "Rice", "grams": 200, "kcal": 260, "protein_g": 5.4},
                    {"name": "Chicken", "grams": 120, "kcal": 198, "protein_g": 27.6}],
          "fried_sauced_or_restaurant": True}
class Handler(BaseHTTPRequestHandler):
    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        self.reply({"models": []})
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        sys.stderr.write("chat: images=%d num_ctx=%s think=%s\n" % (len(request["messages"][0].get("images", [])), request["options"]["num_ctx"], request["think"]))
        self.reply({"message": {"role": "assistant", "content": json.dumps(ANSWER)}, "done": True})
HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
