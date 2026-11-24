#!/usr/bin/env python3
# A stand-in for the Spark's illustrator (deploy/spark/lyfe-illustrate.py),
# for the tests and for running the backend on this Mac: nothing is loaded,
# and every photo is answered with the same plate drawn in the five Poster
# colours. A request with no photo is a food's icon, and is answered with
# the same plate, smaller. It speaks the same lines of JSON.
#
#   LYFE_ILLUSTRATOR=$PWD/backend/tests/illustrator_stand_in.py cargo run -- serve
#
# Arguments, for the tests:
#   --log FILE        append each request to FILE, one JSON line each
#   --fail-load       say the model would not load, and exit
#   --cannot-draw     answer every photo with an error
#   --exit-on-draw    exit on the first photo without answering
#   --picture FILE    answer with this PNG instead, such as one the Spark drew
import base64, json, struct, sys, zlib

PAPER, INK, RED, BLUE, YELLOW = (243, 239, 230), (14, 14, 14), (255, 74, 28), (40, 72, 255), (255, 210, 31)


def plate(size=256):
    """A plate seen from above: a blue rim, an egg and a red slab."""
    rows = []
    c = size / 2
    for y in range(size):
        row = bytearray([0])
        for x in range(size):
            d = ((x - c) ** 2 + (y - c) ** 2) ** 0.5
            colour = PAPER
            if d < size * 0.44:
                colour = BLUE
            if d < size * 0.40:
                colour = PAPER
            ex, ey = x - size * 0.40, y - size * 0.42
            if ex * ex + ey * ey < (size * 0.17) ** 2:
                colour = PAPER if ex * ex + ey * ey > (size * 0.16) ** 2 else YELLOW
                if ex * ex + ey * ey > (size * 0.15) ** 2 and ex * ex + ey * ey <= (size * 0.17) ** 2:
                    colour = INK
            if size * 0.50 < x < size * 0.72 and size * 0.36 < y < size * 0.66:
                colour = RED
            if abs(d - size * 0.44) < 2:
                colour = INK
            row.extend(colour)
        rows.append(bytes(row))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")


def say(answer):
    sys.stdout.write(json.dumps(answer) + "\n")
    sys.stdout.flush()


def main(arguments):
    log = arguments[arguments.index("--log") + 1] if "--log" in arguments else None
    if "--fail-load" in arguments:
        say({"ready": False, "error": "CUDA out of memory (stand-in)"})
        return 1
    say({"ready": True, "seconds": 0.0})
    drawn = open(arguments[arguments.index("--picture") + 1], "rb").read() if "--picture" in arguments else plate()
    picture = base64.b64encode(drawn).decode()
    icon = picture if "--picture" in arguments else base64.b64encode(plate(96)).decode()
    for line in sys.stdin:
        request = json.loads(line)
        if log:
            with open(log, "a") as file:
                file.write(json.dumps({"id": request["id"], "prompt": request["prompt"], "jpeg": request.get("jpeg")}) + "\n")
        sys.stderr.write("illustrator stand-in: drawing one %s\n" % ("photo" if "jpeg" in request else "icon"))
        if "--exit-on-draw" in arguments:
            return 1
        if "--cannot-draw" in arguments:
            say({"id": request["id"], "error": "cannot identify image file (stand-in)"})
            continue
        say({"id": request["id"], "png": picture if "jpeg" in request else icon, "seconds": 0.0})
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
