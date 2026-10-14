"""Builds the fake library for README screenshots: drawn thumbnails, short clips, library.json and
playlists.json in screenshots/demo. The screenshots workflow copies that folder into the simulator.

    python screenshots/make_demo.py      (needs Pillow, numpy and ffmpeg)
"""
import json
import math
import random
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

W, H = 1280, 720
OUT = Path(__file__).parent / "demo"


# Drawing helpers

def gradient(top, bottom, h=H):
    t = np.linspace(0, 1, h)[:, None, None]
    col = (1 - t) * np.array(top) + t * np.array(bottom)
    return np.repeat(col, W, axis=1)


def ridge(rng, base, amp, rough):
    x = np.arange(W)
    y = np.full(W, float(base))
    for octave in range(6):
        f = rough * 2 ** octave / W
        y += amp / 2.1 ** octave * np.sin(2 * math.pi * f * x + rng.uniform(0, 6.3))
    return y


def fill_below(img, ys, color):
    mask = np.arange(H)[:, None] >= ys[None, :]
    img[mask] = color


def glow(img, cx, cy, r, color, strength=1.0):
    yy, xx = np.mgrid[0:H, 0:W]
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    a = np.clip(1 - d / r, 0, 1) ** 2.2 * strength
    img[:] = img * (1 - a[..., None]) + np.array(color) * a[..., None]


def disc(img, cx, cy, r, color):
    yy, xx = np.mgrid[0:H, 0:W]
    img[(xx - cx) ** 2 + (yy - cy) ** 2 <= r * r] = color


def mix(a, b, t):
    return tuple(a[i] * (1 - t) + b[i] * t for i in range(3))


def mountains(img, rng, sky_col, near, layers=4, base=0.55, amp=90):
    for i in range(layers):
        t = (i + 1) / layers
        ys = ridge(rng, H * (base + 0.08 * i), amp * (1.2 - 0.2 * i), 1.2 + 0.5 * i)
        fill_below(img, ys, mix(sky_col, near, 0.25 + 0.75 * t))


def water(img, horizon, tint):
    rows = H - horizon
    src = img[horizon - rows:horizon][::-1] if horizon >= rows else img[:horizon][::-1]
    src = np.resize(src, (rows, W, 3))
    img[horizon:] = src * 0.55 + np.array(tint) * 0.45
    for y in range(horizon + 4, H, 7):
        img[y, :, :] = img[y, :, :] * 0.85


def stars(img, rng, n=260, max_y=0.5):
    for _ in range(n):
        x, y = rng.randrange(W), rng.randrange(int(H * max_y))
        b = rng.uniform(150, 255)
        img[y, x] = (b, b, b)


def finish(img, rng):
    im = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(0.7))
    a = np.asarray(im).astype(float)
    a += np.random.default_rng(rng.randrange(1 << 30)).normal(0, 4, a.shape)
    yy, xx = np.mgrid[0:H, 0:W]
    v = 1 - 0.35 * (((xx - W / 2) / (W / 2)) ** 2 + ((yy - H / 2) / (H / 2)) ** 2) / 2
    a *= v[..., None]
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))


# Scenes

def sunset_mountains(rng, warm=(255, 140, 70)):
    sky_top, sky_bot = (40, 30, 90), warm
    img = gradient(sky_top, sky_bot)
    glow(img, W * rng.uniform(0.3, 0.7), H * 0.52, 420, (255, 210, 140), 0.9)
    disc(img, W * 0.55, H * 0.5, 38, (255, 236, 200))
    mountains(img, rng, sky_bot, (25, 15, 40))
    return img


def alpine_morning(rng):
    img = gradient((110, 170, 230), (230, 220, 200))
    glow(img, W * 0.25, H * 0.25, 500, (255, 250, 230), 0.7)
    mountains(img, rng, (210, 220, 235), (30, 60, 55), layers=5, base=0.42, amp=120)
    return img


def lake_mountains(rng):
    img = gradient((60, 110, 170), (250, 190, 140))
    mountains(img, rng, (250, 190, 140), (35, 45, 70), layers=3, base=0.42, amp=110)
    water(img, int(H * 0.62), (30, 50, 80))
    return img


def aurora(rng):
    img = gradient((5, 10, 30), (15, 35, 60))
    stars(img, rng)
    yy, xx = np.mgrid[0:H, 0:W]
    for k in range(3):
        center = H * (0.22 + 0.08 * k) + 50 * np.sin(xx / W * math.pi * (1.5 + k) + rng.uniform(0, 6))
        band = np.exp(-((yy - center) / (35 + 15 * k)) ** 2) * (0.85 - 0.2 * k)
        col = np.array([(60, 255, 160), (90, 220, 255), (190, 120, 255)][k])
        img[:] = img * (1 - band[..., None]) + col * band[..., None]
    mountains(img, rng, (20, 40, 60), (5, 8, 15), layers=2, base=0.68, amp=60)
    water(img, int(H * 0.82), (5, 15, 30))
    return img


def glacier(rng):
    img = gradient((150, 190, 220), (220, 235, 245))
    mountains(img, rng, (220, 235, 245), (90, 120, 150), layers=3, base=0.38, amp=80)
    water(img, int(H * 0.6), (40, 90, 120))
    for _ in range(14):
        x, y, s = rng.randrange(W), rng.randrange(int(H * 0.62), H - 40), rng.randrange(18, 60)
        d = ImageDraw.Draw(im := Image.fromarray(img.astype(np.uint8)))
        d.polygon([(x - s, y), (x - s // 3, y - s // 2), (x + s // 2, y - s // 3), (x + s, y)], fill=(225, 240, 250))
        img[:] = np.asarray(im)
    return img


def black_beach(rng):
    img = gradient((120, 135, 150), (190, 195, 200))
    mountains(img, rng, (190, 195, 200), (50, 55, 60), layers=2, base=0.45, amp=70)
    sea = int(H * 0.55)
    img[sea:] = gradient((60, 80, 95), (40, 50, 60), H - sea)
    sand = int(H * 0.78)
    img[sand:] = gradient((35, 35, 38), (15, 15, 18), H - sand)
    for i, y in enumerate(range(sand - 30, sand, 10)):
        img[y:y + 3] = img[y:y + 3] * 0.3 + 230 * 0.7
    return img


def fuji(rng):
    img = gradient((250, 170, 190), (255, 225, 200))
    glow(img, W * 0.7, H * 0.3, 380, (255, 245, 230), 0.6)
    im = Image.fromarray(img.astype(np.uint8))
    d = ImageDraw.Draw(im)
    peak = (W * 0.5, H * 0.22)
    d.polygon([(W * 0.1, H * 0.75), peak, (W * 0.9, H * 0.75)], fill=(70, 80, 120))
    d.polygon([(W * 0.4, H * 0.36), peak, (W * 0.6, H * 0.36), (W * 0.55, H * 0.4), (W * 0.5, H * 0.35), (W * 0.45, H * 0.41)],
              fill=(245, 245, 250))
    img = np.asarray(im).astype(float)
    water(img, int(H * 0.75), (90, 80, 120))
    return img


def city_night(rng, neon=False):
    img = gradient((10, 10, 35), (70, 30, 80) if neon else (30, 40, 80))
    stars(img, rng, 80, 0.3)
    im = Image.fromarray(img.astype(np.uint8))
    d = ImageDraw.Draw(im)
    x = 0
    while x < W:
        w, h = rng.randrange(50, 130), rng.randrange(150, 470)
        top = H * 0.8 - h
        d.rectangle([x, top, x + w, H], fill=(12, 12, 25))
        for wy in range(int(top) + 10, int(H * 0.8), 16):
            for wx in range(x + 8, x + w - 8, 14):
                if rng.random() < 0.45:
                    c = rng.choice([(255, 210, 120), (255, 240, 200), (120, 220, 255), (255, 90, 180)] if neon else [(255, 210, 120), (255, 240, 200)])
                    d.rectangle([wx, wy, wx + 5, wy + 7], fill=c)
        x += w + rng.randrange(2, 12)
    img = np.asarray(im).astype(float)
    img[int(H * 0.8):] = gradient((25, 20, 40), (10, 10, 15), H - int(H * 0.8))
    for _ in range(40):
        y = rng.randrange(int(H * 0.82), H)
        x0 = rng.randrange(W)
        img[y:y + 2, x0:x0 + rng.randrange(40, 160)] = rng.choice([(255, 60, 60), (255, 230, 180)])
    return img


def kyoto_evening(rng):
    img = gradient((50, 40, 90), (240, 130, 90))
    glow(img, W * 0.5, H * 0.65, 450, (255, 190, 120), 0.7)
    im = Image.fromarray(img.astype(np.uint8))
    d = ImageDraw.Draw(im)
    cx, base = W * 0.5, H * 0.82
    for i in range(5):
        w = 300 - i * 50
        y = base - i * 85
        d.polygon([(cx - w, y), (cx + w, y), (cx + w * 0.6, y - 40), (cx - w * 0.6, y - 40)], fill=(25, 15, 30))
        d.rectangle([cx - w * 0.45, y - 85, cx + w * 0.45, y - 40], fill=(30, 18, 35))
    d.rectangle([cx - 4, base - 520, cx + 4, base - 420], fill=(25, 15, 30))
    d.rectangle([0, base, W, H], fill=(20, 12, 25))
    for i in range(12):
        lx = 80 + i * 105
        d.ellipse([lx - 9, base - 30, lx + 9, base - 10], fill=(255, 180, 90))
    return np.asarray(im).astype(float)


def pine_valley(rng):
    img = gradient((150, 190, 210), (225, 230, 215))
    mountains(img, rng, (225, 230, 215), (60, 90, 80), layers=2, base=0.4, amp=100)
    im = Image.fromarray(img.astype(np.uint8))
    d = ImageDraw.Draw(im)
    for row, (shade, y0) in enumerate([((40, 70, 55), 0.62), ((25, 50, 38), 0.72), ((12, 28, 20), 0.85)]):
        for _ in range(28 + row * 8):
            x, h = rng.randrange(-20, W + 20), rng.randrange(90, 200) * (1 + row * 0.4)
            y = H * y0 + rng.randrange(0, 40)
            d.polygon([(x - h * 0.28, y), (x, y - h), (x + h * 0.28, y)], fill=shade)
        d.rectangle([0, H * y0 + 30, W, H], fill=shade)
    return np.asarray(im).astype(float)


def summit(rng):
    img = gradient((30, 70, 150), (180, 210, 240))
    glow(img, W * 0.8, H * 0.2, 300, (255, 255, 240), 0.8)
    im = Image.fromarray(img.astype(np.uint8))
    d = ImageDraw.Draw(im)
    d.polygon([(0, H), (W * 0.15, H * 0.55), (W * 0.42, H * 0.18), (W * 0.62, H * 0.5), (W, H * 0.7), (W, H)], fill=(235, 240, 250))
    d.polygon([(W * 0.42, H * 0.18), (W * 0.62, H * 0.5), (W, H * 0.7), (W, H), (W * 0.5, H)], fill=(170, 185, 210))
    d.ellipse([W * 0.3 - 8, H * 0.52 - 30, W * 0.3 + 8, H * 0.52 - 14], fill=(200, 40, 40))
    d.rectangle([W * 0.3 - 7, H * 0.52 - 14, W * 0.3 + 7, H * 0.52 + 14], fill=(200, 40, 40))
    return np.asarray(im).astype(float)


def desert_road(rng):
    img = gradient((80, 150, 220), (250, 210, 160))
    mountains(img, rng, (250, 210, 160), (170, 100, 70), layers=2, base=0.48, amp=50)
    ground = int(H * 0.6)
    img[ground:] = gradient((220, 160, 110), (190, 120, 80), H - ground)
    im = Image.fromarray(img.astype(np.uint8))
    d = ImageDraw.Draw(im)
    vx = W * 0.5
    d.polygon([(vx - 4, ground), (vx + 4, ground), (W * 0.85, H), (W * 0.15, H)], fill=(50, 50, 55))
    for i in range(12):
        t0, t1 = (i / 12) ** 2, ((i + 0.5) / 12) ** 2
        y0, y1 = ground + (H - ground) * t0, ground + (H - ground) * t1
        d.polygon([(vx - 1 - 6 * t0, y0), (vx + 1 + 6 * t0, y0), (vx + 1 + 6 * t1, y1), (vx - 1 - 6 * t1, y1)], fill=(250, 220, 90))
    return np.asarray(im).astype(float)


def coast(rng):
    img = gradient((90, 160, 220), (200, 225, 240))
    sea = int(H * 0.5)
    img[sea:] = gradient((30, 100, 150), (20, 70, 110), H - sea)
    im = Image.fromarray(img.astype(np.uint8))
    d = ImageDraw.Draw(im)
    d.polygon([(0, H * 0.3), (W * 0.25, H * 0.42), (W * 0.45, H * 0.6), (W * 0.55, H), (0, H)], fill=(80, 100, 60))
    d.line([(W * 0.05, H * 0.55), (W * 0.2, H * 0.6), (W * 0.35, H * 0.75), (W * 0.42, H)], fill=(70, 70, 75), width=26)
    return np.asarray(im).astype(float)


def golden_waves(rng):
    img = gradient((250, 170, 90), (255, 220, 160))
    disc(img, W * 0.5, H * 0.48, 55, (255, 240, 210))
    glow(img, W * 0.5, H * 0.48, 400, (255, 200, 120), 0.8)
    sea = int(H * 0.52)
    img[sea:] = gradient((200, 120, 70), (60, 60, 80), H - sea)
    for y in range(sea + 6, H, 12):
        img[y:y + 2, :] = img[y:y + 2, :] * 0.6 + np.array((255, 220, 170)) * 0.4
    img[sea:, int(W * 0.47):int(W * 0.53)] = img[sea:, int(W * 0.47):int(W * 0.53)] * 0.5 + 255 * 0.5
    return img


def paddle(rng):
    img = sunset_mountains(rng, warm=(255, 120, 110))
    water(img, int(H * 0.68), (60, 40, 70))
    im = Image.fromarray(img.astype(np.uint8))
    d = ImageDraw.Draw(im)
    d.polygon([(W * 0.4, H * 0.8), (W * 0.6, H * 0.8), (W * 0.58, H * 0.82), (W * 0.42, H * 0.82)], fill=(15, 10, 20))
    d.rectangle([W * 0.495, H * 0.68, W * 0.505, H * 0.8], fill=(15, 10, 20))
    d.ellipse([W * 0.49, H * 0.65, W * 0.51, H * 0.685], fill=(15, 10, 20))
    return np.asarray(im).astype(float)


def stage(rng, hue=0):
    img = gradient((10, 5, 25), (30, 10, 40))
    beams = [(255, 60, 120), (80, 120, 255), (255, 200, 60), (120, 255, 200)]
    layer = np.zeros_like(img)
    for i in range(7):
        im = Image.new("L", (W, H), 0)
        d = ImageDraw.Draw(im)
        x = W * (0.1 + 0.8 * i / 6)
        tx = x + rng.uniform(-300, 300)
        d.polygon([(x - 8, 0), (x + 8, 0), (tx + 120, H * 0.85), (tx - 120, H * 0.85)], fill=150)
        m = np.asarray(im.filter(ImageFilter.GaussianBlur(18))) / 255.0
        layer += m[..., None] * np.array(beams[(i + hue) % 4])
    img = np.clip(img + layer * 0.7, 0, 255)
    im = Image.fromarray(img.astype(np.uint8))
    d = ImageDraw.Draw(im)
    for _ in range(90):
        x, y = rng.randrange(W), H * 0.82 + rng.randrange(0, 80)
        r = rng.randrange(14, 24)
        d.ellipse([x - r, y - r, x + r, y + r], fill=(5, 3, 10))
        if rng.random() < 0.15:
            d.line([(x, y), (x + rng.randrange(-30, 30), y - 90)], fill=(5, 3, 10), width=9)
    d.rectangle([0, H * 0.9, W, H], fill=(5, 3, 10))
    return np.asarray(im).astype(float)


def album(rng, a, b):
    img = gradient(a, b)
    im = Image.fromarray(img.astype(np.uint8))
    d = ImageDraw.Draw(im)
    cx, cy = W * 0.5, H * 0.5
    for r in range(320, 20, -22):
        shade = mix(a, b, r / 320)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=tuple(int(c * 0.6) for c in shade), width=3)
    d.ellipse([cx - 40, cy - 40, cx + 40, cy + 40], fill=(245, 245, 245))
    return np.asarray(im).astype(float)


# Library

def v(key, scene, size_mb, days, minutes, watched=None):
    return dict(key=key, scene=scene, size=int(size_mb * 1_048_576), daysAgo=days, duration=round(minutes * 2) * 30, watched=watched)


VIDEOS = [
    v("Travel/Iceland 2025/Glacier lagoon.mp4", glacier, 412, 34, 6.5),
    v("Travel/Iceland 2025/Iceland day 1.mp4", lake_mountains, 1830, 36, 18.2, 1.0),
    v("Travel/Iceland 2025/Iceland day 2.mp4", black_beach, 1544, 35, 16.0, 0.45),
    v("Travel/Iceland 2025/Iceland day 3.mp4", alpine_morning, 1720, 34, 21.4),
    v("Travel/Iceland 2025/Iceland day 4.mp4", sunset_mountains, 1390, 33, 14.9),
    v("Travel/Iceland 2025/Northern lights timelapse.mp4", aurora, 655, 33, 4.2, 0.7),
    v("Travel/Japan/Fuji from Kawaguchiko.mp4", fuji, 980, 120, 9.8),
    v("Travel/Japan/Kyoto evening walk.mp4", kyoto_evening, 1210, 122, 24.1, 0.3),
    v("Travel/Japan/Shibuya crossing.mp4", lambda r: city_night(r, neon=True), 520, 121, 5.3),
    v("Travel/Japan/Tokyo night drive.mp4", city_night, 1460, 119, 19.7),
    v("Hiking/Alpine ridge sunrise.mp4", alpine_morning, 760, 12, 11.2, 0.6),
    v("Hiking/Pine valley trail.mp4", pine_valley, 1105, 9, 15.3),
    v("Hiking/Summit push.mp4", summit, 890, 8, 12.6),
    v("Road trips/Coast highway.mp4", coast, 1320, 60, 22.0),
    v("Road trips/Desert highway.mp4", desert_road, 1180, 58, 17.5, 0.25),
    v("Beach/Golden hour waves.mp4", golden_waves, 430, 2, 3.8),
    v("Beach/Sunset paddle.mp4", paddle, 615, 1, 7.1),
    v("Concerts/Encore.mp4", lambda r: stage(r, 2), 1020, 18, 9.4),
    v("Concerts/Festival main stage.mp4", stage, 2210, 19, 31.0, 0.55),
    v("Music/Late night mix.mp3", lambda r: album(r, (40, 20, 90), (240, 80, 120)), 86, 25, 58.0),
    v("Music/Lo-fi set.m4a", lambda r: album(r, (20, 80, 90), (230, 200, 120)), 64, 27, 42.0),
]


def entry(key):
    return {"video": {"bucket": "media", "key": key}}


REF = 978307200  # 2001-01-01, Swift's date reference


def playlists():
    now = 1_790_000_000 - REF
    return [
        dict(id="00000000-0000-0000-0000-00000000FA7E", name="Favorites", created=now, updated=now,
             entries=[entry(k) for k in ["Travel/Iceland 2025/Northern lights timelapse.mp4", "Beach/Golden hour waves.mp4",
                                         "Travel/Japan/Kyoto evening walk.mp4", "Hiking/Summit push.mp4",
                                         "Concerts/Festival main stage.mp4"]]),
        dict(id="3F1C2A6E-7B8D-4C2E-9A10-5D6E7F8A9B01", name="Iceland highlights", created=now, updated=now,
             entries=[{"folder": {"bucket": "media", "prefix": "Travel/Iceland 2025/", "recursive": False}}]),
        dict(id="8A2B4C6D-1E3F-4A5B-8C7D-9E0F1A2B3C04", name="Road trip mix", created=now, updated=now,
             entries=[entry(k) for k in ["Road trips/Desert highway.mp4", "Road trips/Coast highway.mp4",
                                         "Travel/Japan/Tokyo night drive.mp4", "Beach/Sunset paddle.mp4"]]),
        dict(id="C4D5E6F7-0819-4A2B-BC3D-4E5F60718293", name="Chill audio", created=now, updated=now,
             entries=[entry("Music/Late night mix.mp3"), entry("Music/Lo-fi set.m4a")]),
    ]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for i, item in enumerate(VIDEOS):
        rng = random.Random(i * 7919 + 13)
        title = Path(item["key"]).stem
        jpg = OUT / f"{title}.jpg"
        finish(item["scene"](rng), rng).save(jpg, quality=86)
        # A still frame every 30 s: full-length clips (the player shows real durations) in ~150 KB.
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-loop", "1", "-framerate", "1/30", "-i", str(jpg),
             "-t", str(item["duration"]), "-vf", "scale=960:540", "-c:v", "libx264", "-tune", "stillimage",
             "-g", "1000", "-crf", "30", "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(OUT / f"{title}.mp4")],
            check=True)
    library = dict(playFrom="Travel/Iceland 2025/Iceland day 2.mp4",
                   videos=[{k: x[k] for k in ("key", "size", "daysAgo", "duration", "watched") if x[k] is not None} for x in VIDEOS])
    (OUT / "library.json").write_text(json.dumps(library, indent=1))
    (OUT / "playlists.json").write_text(json.dumps(playlists(), indent=1))


if __name__ == "__main__":
    main()
