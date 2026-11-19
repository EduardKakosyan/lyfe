"""Draws meal photos as Poster illustrations with FLUX.2 klein 4B, for lyfe-server.

lyfe-server starts this when a photo is waiting and the Spark has memory
free (backend/src/illustrator.rs); nothing else should. It loads the model
once, then reads one request per line on standard input and answers each
with one line on standard output, until standard input closes, when it
exits and gives its memory back.

  first line out:  {"ready": true, "seconds": 93.2}
                   or {"ready": false, "error": "..."}, then it exits
  each line in:    {"id": "<uuid>", "prompt": "...", "jpeg": "<base64>"}
  each line out:   {"id": "<uuid>", "png": "<base64>", "seconds": 7.1}
                   or {"id": "<uuid>", "error": "..."}

The photo is redrawn from the prompt, which keeps the food in its own
colours (ADR 0006). The background the model leaves is then set to exactly
the app's paper colour, so the drawing sits on the screen without a box
around it, and it is sent back shrunk, as a PNG of at most 64 colours.
Nothing is downloaded at run time (the wrapper sets HF_HUB_OFFLINE), and
nothing about the meal is written anywhere but the answer.

  python3 lyfe-illustrate.py --self-test   checks the finishing only
"""

import base64
import io
import json
import os
import sys
import time

MODEL = "black-forest-labs/FLUX.2-klein-4B"
# The revision tried on the Spark in the test behind ADR 0005.
REVISION = "e7b7dc27f91deacad38e78976d1f2b499d76a294"
SIZE = 1024
# The side the drawing is sent back at: enough for the phone's screen.
SENT_SIZE = 768
# Flat fills need few colours; this keeps a drawing near 100 kB.
SENT_COLOURS = 64
# The model is step-distilled: four steps and no guidance, as in the test.
STEPS = 4
GUIDANCE = 1.0
# The same seed every time, so the same photo is drawn the same way.
SEED = 7

# The app's paper, as in apps/LyfeKit/Sources/LyfeKit/Poster/Poster.swift.
PAPER = (0xF3, 0xEF, 0xE6)
# A background lighter than this on every channel is taken to be the plain
# one that was asked for; a darker one is left as the model drew it.
LIGHT_BACKGROUND = 170
# How far a pixel may be from the background's colour, summed over the
# three channels, and still be background.
BACKGROUND_REACH = 42


def on_paper(image):
    """The picture with its background set to exactly the app's paper: every
    pixel close to the colour of the edges and joined to an edge. A light
    patch inside the drawing, such as a white plate, is not joined to an
    edge and is left alone."""
    import numpy
    from PIL import Image, ImageDraw

    image = image.convert("RGB")
    pixels = numpy.asarray(image).astype(int)
    height, width, _ = pixels.shape
    edges = numpy.concatenate([pixels[0], pixels[-1], pixels[:, 0], pixels[:, -1]])
    background = numpy.median(edges, axis=0)
    if background.min() < LIGHT_BACKGROUND:
        return image
    near = numpy.abs(pixels - background).sum(axis=2) < BACKGROUND_REACH
    # A copy: an image made straight from an array cannot be written to,
    # and the fill would then quietly do nothing.
    mask = Image.fromarray((near * 255).astype(numpy.uint8), "L").copy()
    joined = 128
    border = [(x, y) for x in range(0, width, 8) for y in (0, height - 1)]
    border += [(x, y) for y in range(0, height, 8) for x in (0, width - 1)]
    for point in border:
        if mask.getpixel(point) == 255:
            ImageDraw.floodfill(mask, point, joined)
    out = numpy.asarray(image).copy()
    out[numpy.asarray(mask) == joined] = PAPER
    return Image.fromarray(out)


def finished(image):
    """The drawing as it is sent: on paper, shrunk, and in few colours, with
    the paper still exactly the paper."""
    from PIL import Image

    image = on_paper(image).resize((SENT_SIZE, SENT_SIZE), Image.LANCZOS)
    few = image.quantize(colors=SENT_COLOURS, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    # Cutting the colours down moves each a little; the one the paper
    # became is put back.
    corners = [(0, 0), (SENT_SIZE - 1, 0), (0, SENT_SIZE - 1), (SENT_SIZE - 1, SENT_SIZE - 1)]
    palette = few.getpalette()
    for corner in corners:
        if image.getpixel(corner) == PAPER:
            index = few.getpixel(corner)
            palette[index * 3 : index * 3 + 3] = PAPER
    few.putpalette(palette)
    return few


def png_bytes(image):
    out = io.BytesIO()
    image.save(out, "PNG", optimize=True)
    return out.getvalue()


def self_test():
    from PIL import Image, ImageDraw

    # A cream background, as the model leaves it, with a blue plate that has
    # a cream middle, and a dark photo that has no plain background at all.
    cream, blue = (255, 250, 238), (40, 72, 255)
    drawn = Image.new("RGB", (SIZE, SIZE), cream)
    ImageDraw.Draw(drawn).ellipse((200, 200, 820, 820), fill=blue)
    ImageDraw.Draw(drawn).ellipse((400, 400, 620, 620), fill=cream)
    clean = on_paper(drawn)
    assert clean.getpixel((0, 0)) == PAPER and clean.getpixel((SIZE - 1, SIZE // 2)) == PAPER, clean.getpixel((0, 0))
    assert clean.getpixel((510, 300)) == blue
    assert clean.getpixel((510, 510)) == cream, "the middle of the plate is not background"
    dark = Image.new("RGB", (SIZE, SIZE), (40, 30, 20))
    assert on_paper(dark).getpixel((0, 0)) == (40, 30, 20)

    sent = finished(drawn)
    assert sent.size == (SENT_SIZE, SENT_SIZE) and sent.mode == "P"
    assert sent.convert("RGB").getpixel((0, 0)) == PAPER, sent.convert("RGB").getpixel((0, 0))
    assert sent.convert("RGB").getpixel((SENT_SIZE // 2, SENT_SIZE // 4)) == blue
    data = png_bytes(sent)
    assert data.startswith(b"\x89PNG\r\n\x1a\n")
    print("finishing a drawing works: on paper, shrunk, in few colours")
    return 0


def main():
    if "--self-test" in sys.argv[1:]:
        return self_test()

    # Answers go on a private copy of standard output. Anything the
    # libraries print goes to standard error, which ends in lyfe's log, so
    # it can never be mistaken for an answer.
    answers = os.fdopen(os.dup(1), "w", buffering=1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr

    def say(answer):
        answers.write(json.dumps(answer) + "\n")
        answers.flush()

    started = time.monotonic()
    try:
        os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
        import torch
        from diffusers import Flux2KleinPipeline
        from diffusers.utils import logging as diffusers_logging
        from PIL import Image, ImageOps

        diffusers_logging.set_verbosity_error()
        diffusers_logging.disable_progress_bar()
        if not torch.cuda.is_available():
            raise RuntimeError("no GPU is available to this account")
        pipe = Flux2KleinPipeline.from_pretrained(MODEL, revision=REVISION, dtype=torch.bfloat16).to("cuda")
        pipe.set_progress_bar_config(disable=True)
    except Exception as error:  # Said in the answer; lyfe tries again later.
        say({"ready": False, "error": f"{type(error).__name__}: {error}"[:300]})
        return 1
    say({"ready": True, "seconds": round(time.monotonic() - started, 1)})

    for line in sys.stdin:
        if not line.strip():
            continue
        began = time.monotonic()
        request = {}
        try:
            request = json.loads(line)
            photo = Image.open(io.BytesIO(base64.b64decode(request["jpeg"])))
            photo = ImageOps.fit(ImageOps.exif_transpose(photo).convert("RGB"), (SIZE, SIZE))
            with torch.inference_mode():
                drawn = pipe(
                    prompt=request["prompt"],
                    image=photo,
                    height=SIZE,
                    width=SIZE,
                    guidance_scale=GUIDANCE,
                    num_inference_steps=STEPS,
                    generator=torch.Generator(device="cuda").manual_seed(SEED),
                ).images[0]
            png = png_bytes(finished(drawn))
            say({"id": request["id"], "png": base64.b64encode(png).decode(), "seconds": round(time.monotonic() - began, 1)})
        except Exception as error:
            say({"id": request.get("id"), "error": f"{type(error).__name__}: {error}"[:300]})
    return 0


if __name__ == "__main__":
    sys.exit(main())
