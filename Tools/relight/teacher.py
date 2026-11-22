"""Makes "photoreal" target images for the neural grade with FLUX.1-schnell (Apache 2.0).

    Tools/relight/.venv/bin/python Tools/relight/teacher.py [--strength 0.35] [--limit 8] [--seed 1]

Reads Tools/relight/data/frames/*.png (from extract.swift) and writes the same names to
Tools/relight/data/teacher/s<strength>/. This runs once, offline, on the developer's Mac: the app
never uses FLUX. Only the small network trained on these pairs (train.py) ships.

Light image-to-image: low strength keeps the layout, so what changes is mostly light, colour and
material response, which is all the student network can learn anyway (it can't move pixels).
"""

import argparse
import pathlib
import time

import torch
from diffusers import FluxImg2ImgPipeline
from PIL import Image

PROMPT = ("a real photograph taken with a full-frame camera, natural sunlight and soft bounce light, "
          "realistic materials and skin, true-to-life colour, subtle film look, high dynamic range")

root = pathlib.Path(__file__).parent / "data"
ap = argparse.ArgumentParser()
ap.add_argument("--strength", type=float, default=0.35)
ap.add_argument("--limit", type=int, default=0, help="only the first N frames (spread across the set)")
ap.add_argument("--seed", type=int, default=1)
ap.add_argument("--width", type=int, default=0, help="resize frames to this width first (training only needs ~512)")
args = ap.parse_args()

frames = sorted((root / "frames").glob("*.png"))
if args.limit:
    step = max(len(frames) // args.limit, 1)
    frames = frames[::step][: args.limit]
out = root / "teacher" / (f"s{args.strength:.2f}" + (f"_w{args.width}" if args.width else ""))
out.mkdir(parents=True, exist_ok=True)

device = "mps" if torch.backends.mps.is_available() else "cpu"
t0 = time.time()
pipe = FluxImg2ImgPipeline.from_pretrained("black-forest-labs/FLUX.1-schnell", torch_dtype=torch.bfloat16).to(device)
pipe.set_progress_bar_config(disable=True)
print(f"loaded in {time.time() - t0:.0f} s on {device}", flush=True)

for i, f in enumerate(frames):
    dst = out / f.name
    if dst.exists():
        continue
    img = Image.open(f).convert("RGB")
    if args.width:
        img = img.resize((args.width, round(img.height * args.width / img.width / 16) * 16), Image.LANCZOS)
    t = time.time()
    res = pipe(prompt=PROMPT, image=img, width=img.width, height=img.height, strength=args.strength,
               num_inference_steps=4, guidance_scale=0.0, max_sequence_length=256,
               generator=torch.Generator("cpu").manual_seed(args.seed)).images[0]
    res.save(dst)
    print(f"{i + 1}/{len(frames)} {f.name} {time.time() - t:.1f} s", flush=True)
