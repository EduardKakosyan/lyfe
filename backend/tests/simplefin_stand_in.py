"""A stand-in for SimpleFIN Bridge, for trying money on this machine.

    python3 -I backend/tests/simplefin_stand_in.py 11498

It answers GET /simplefin/accounts for the user `lyfe` with the password
`stand-in` with two made-up banks and a broker: a chequing account, two
cards, a savings account, an account in another currency, and two
investment accounts with what they hold; with four and a half months of
made-up transactions ending today, so that a few months are held whole.
Point lyfe-server at it with an access file holding

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
        (13, "-400.00", "To savings"), (16, "3100.00", "Employer"), (30, "3100.00", "Employer"),
        (30, "-88.10", "Power Company"),
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
    brokerage = [(13, "500.00", "Contribution")]

    # The three months before those: much the same each, a little less
    # spent the further back. A card payment and what goes to savings and
    # to the broker leave one account and arrive in another.
    for back in (1, 2, 3):
        start = 45 + 30 * (back - 1)
        less = 6 * back
        paid = f"{820 - 15 * back}.00"
        chequing += [(start + day, amount, payee) for day, amount, payee in [
            (1, "3100.00", "Employer"), (15, "3100.00", "Employer"), (4, f"-{paid}", "Card payment"),
            (11, "-1450.00", "Landlord"), (9, f"-{96 - less}.30", "Power Company"), (12, "-400.00", "To savings"),
            (13, "-500.00", "To the broker"), (20, "-33.50", "City Transit"),
        ]]
        card += [(start + day, amount, payee) for day, amount, payee in [
            (3, paid, "Payment received"), (1, f"-{70 - less}.12", "Corner Grocer #12"),
            (8, f"-{124 - less}.40", "Corner Grocer #7"), (15, f"-{77 - less}.25", "Corner Grocer #12"),
            (22, f"-{103 - less}.25", "Corner Grocer #7"), (2, "-71.50", "Harbour Fuel"), (17, "-66.00", "Harbour Fuel"),
            (6, "-28.60", "Noodle Bar"), (19, f"-{47 - less}.00", "Noodle Bar"), (10, "-32.99", "Bookshop on Main"),
        ]]
        travel += [(start + 6, "-16.99", "Streaming Co")]
        savings += [(start + 11, "400.00", "Deposit"), (start + 25, "3.12", "Interest")]
        brokerage += [(start + 12, "500.00", "Contribution")]

    def holding(number, symbol, name, shares, value, cost):
        return {
            "id": f"HOL-{number}", "created": int(time.time()) - 3600, "currency": "CAD", "cost_basis": cost,
            "description": name, "market_value": value, "purchase_price": "0.00", "shares": shares, "symbol": symbol,
        }

    def account(number, name, conn, currency, balance, rows, holdings=()):
        return {
            "id": f"ACT-{number}", "name": name, "conn_id": conn, "currency": currency, "balance": balance,
            "available-balance": balance, "balance-date": int(time.time()) - 3600,
            "transactions": [posted(number, n, *row) for n, row in enumerate(rows)], "holdings": list(holdings),
        }

    return [
        account(1, "Chequing", "CON-1", "CAD", "2845.12", chequing),
        account(2, "Everyday Card", "CON-1", "CAD", "-417.33", card),
        account(3, "Travel Card", "CON-2", "CAD", "-62.17", travel),
        account(4, "Savings", "CON-1", "CAD", "12500.00", savings),
        account(5, "Dollars", "CON-2", "USD", "310.00", dollars),
        # What these hold comes to a little less than the brokerage's
        # balance: the rest is waiting in it, in no holding. The same fund
        # is in both, one fund is down on what was paid for it, and for
        # one the broker does not say what was paid.
        account(6, "Brokerage", "CON-3", "CAD", "22104.55", brokerage, [
            holding(61, "WRLD", "Whole World Equity Fund", "310.4", "15480.20", "13200.00"),
            holding(62, "HOME", "Home Market Index Fund", "120", "4310.75", "0.00"),
            holding(63, "BOND", "Bond Fund", "150.25", "1950.10", "2050.00"),
        ]),
        account(7, "Retirement", "CON-3", "CAD", "3989.75", [], [
            holding(71, "WRLD", "Whole World Equity Fund", "80", "3989.75", "3500.00"),
        ]),
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
            {"conn_id": "CON-3", "name": "Broker", "org_id": "ORG-3", "org_name": "Broker",
             "org_url": "https://broker.invalid", "sfin_url": "https://bridge.invalid/simplefin"},
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
