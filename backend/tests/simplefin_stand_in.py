"""A stand-in for SimpleFIN Bridge, for trying money on this machine.

    python3 -I backend/tests/simplefin_stand_in.py 11498

It answers GET /simplefin/accounts for the user `lyfe` with the password
`stand-in` with two made-up banks: a chequing account, two cards, a
savings account and an account in another currency, with a month and a
half of made-up transactions ending today. Point lyfe-server at it with an
access file holding

    http://lyfe:stand-in@127.0.0.1:11498/simplefin

Standard library only. Nothing here is a real account or a real payee.
"""

import base64
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlsplit

DAY = 86400


def noon(days_ago):
    today = int(time.time()) // DAY * DAY
    return today - days_ago * DAY + DAY // 2


def posted(account, n, days_ago, amount, payee):
    return {
        "id": f"TRN-{account}-{n}",
        "posted": noon(days_ago),
        "transacted_at": noon(days_ago),
        "amount": amount,
        "description": f"POS {payee.upper()} 0031",
        "payee": payee,
        "memo": "",
    }


def accounts():
    chequing = [
        (0, "-33.50", "City Transit"), (2, "3100.00", "Employer"), (4, "-850.00", "Card payment"),
        (5, "40.00", "E-transfer from R."), (9, "-92.40", "Power Company"), (12, "-1450.00", "Landlord"),
        (13, "-400.00", "To savings"), (16, "3100.00", "Employer"), (30, "-88.10", "Power Company"),
        (33, "-790.00", "Card payment"), (42, "-1450.00", "Landlord"),
    ]
    card = [
        (1, "-64.12", "Corner Grocer #12"), (2, "-71.50", "Harbour Fuel"), (3, "-32.99", "Bookshop on Main"),
        (4, "850.00", "Payment received"), (5, "-28.60", "Noodle Bar"), (7, "12.50", "Corner Grocer #12"),
        (8, "-118.40", "Corner Grocer #7"), (20, "-54.30", "Corner Grocer #12"), (24, "-66.00", "Harbour Fuel"),
        (32, "790.00", "Payment received"), (35, "-97.25", "Corner Grocer #7"), (38, "-41.00", "Noodle Bar"),
    ]
    travel = [(6, "-16.99", "Streaming Co"), (10, "-45.18", "Hardware & Co"), (36, "-16.99", "Streaming Co")]
    savings = [(12, "400.00", "Deposit"), (25, "3.12", "Interest")]
    dollars = [(15, "-19.00", "Bookshop Abroad")]

    def account(number, name, conn, currency, balance, rows):
        return {
            "id": f"ACT-{number}", "name": name, "conn_id": conn, "currency": currency, "balance": balance,
            "available-balance": balance, "balance-date": int(time.time()) - 3600,
            "transactions": [posted(number, n, *row) for n, row in enumerate(rows)], "holdings": [],
        }

    return [
        account(1, "Chequing", "CON-1", "CAD", "2845.12", chequing),
        account(2, "Everyday Card", "CON-1", "CAD", "-417.33", card),
        account(3, "Travel Card", "CON-2", "CAD", "-62.17", travel),
        account(4, "Savings", "CON-1", "CAD", "12500.00", savings),
        account(5, "Dollars", "CON-2", "USD", "310.00", dollars),
    ]


class Bridge(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        expected = "Basic " + base64.b64encode(b"lyfe:stand-in").decode()
        if self.headers.get("Authorization") != expected:
            return self.answer(403, {"error": "forbidden"})
        if url.path != "/simplefin/accounts":
            return self.answer(404, {"error": "not found"})
        query = parse_qs(url.query)
        start = int(query.get("start-date", ["0"])[0])
        end = int(query.get("end-date", [str(2**40)])[0])
        listed = accounts()
        for account in listed:
            account["transactions"] = [t for t in account["transactions"] if start <= t["posted"] < end]
        connections = [
            {"conn_id": "CON-1", "name": "First Bank", "org_id": "ORG-1", "org_name": "First Bank",
             "org_url": "https://firstbank.invalid", "sfin_url": "https://bridge.invalid/simplefin"},
            {"conn_id": "CON-2", "name": "Second Bank", "org_id": "ORG-2", "org_name": "Second Bank",
             "org_url": "https://secondbank.invalid", "sfin_url": "https://bridge.invalid/simplefin"},
        ]
        self.answer(200, {"errlist": [], "accounts": listed, "connections": connections})

    def answer(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), Bridge).serve_forever()
