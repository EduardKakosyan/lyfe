"""Draws meal photos as Poster pictograms with FLUX.2 klein 4B, for lyfe-server.

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

The photo is redrawn from the prompt, then snapped to the five Poster
colours with dithering off (ADR 0005), and sent back as a palette PNG.
Nothing is downloaded at run time (the wrapper sets HF_HUB_OFFLINE), and
nothing about the meal is written anywhere but the answer.

  python3 lyfe-illustrate.py --self-test   checks the colour snapping only
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
# The model is step-distilled: four steps and no guidance, as in the test.
STEPS = 4
GUIDANCE = 1.0
# The same seed every time, so the same photo is drawn the same way.
SEED = 7

# The Poster colours, as in apps/LyfeKit/Sources/LyfeKit/Poster/Poster.swift:
# paper, ink, red-orange, cobalt blue and yellow.
PALETTE = [(0xF3, 0xEF, 0xE6), (0x0E, 0x0E, 0x0E), (0xFF, 0x4A, 0x1C), (0x28, 0x48, 0xFF), (0xFF, 0xD2, 0x1F)]


def snap(image):
    """The picture in the five colours only, each pixel the nearest, with no
    dithering, as a palette image."""
    from PIL import Image

    palette = Image.new("P", (1, 1))
    flat = [channel for colour in PALETTE for channel in colour]
    palette.putpalette(flat + flat[:3] * (256 - len(PALETTE)))
    return image.convert("RGB").quantize(palette=palette, dither=Image.Dither.NONE)


def png_bytes(image):
    out = io.BytesIO()
    # Only the five colours are used, so the palette is cut to them.
    image.save(out, "PNG", optimize=True)
    return out.getvalue()


def self_test():
    from PIL import Image

    noisy = Image.new("RGB", (4, 1))
    noisy.putdata([(250, 240, 228), (30, 20, 20), (230, 90, 40), (60, 80, 230)])
    snapped = snap(noisy).convert("RGB")
    pixels = [snapped.getpixel((x, 0)) for x in range(4)]
    assert pixels == PALETTE[:4], pixels
    data = png_bytes(snap(noisy))
    assert data.startswith(b"\x89PNG\r\n\x1a\n")
    assert len(Image.open(io.BytesIO(data)).convert("RGB").getcolors()) == 4
    print("snapping to the five colours works")
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
        pipe = Flux2KleinPipeline.from_pretrained(MODEL, revision=REVISION, torch_dtype=torch.bfloat16).to("cuda")
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
            png = png_bytes(snap(drawn))
            say({"id": request["id"], "png": base64.b64encode(png).decode(), "seconds": round(time.monotonic() - began, 1)})
        except Exception as error:
            say({"id": request.get("id"), "error": f"{type(error).__name__}: {error}"[:300]})
    return 0


if __name__ == "__main__":
    sys.exit(main())
