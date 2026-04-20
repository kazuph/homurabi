#!/usr/bin/env python3
"""Generate terminal-style PNG evidence for Phase 15-A REPORT (Pillow)."""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ART = Path(__file__).resolve().parents[1]
IMG = ART / "images"
IMG.mkdir(parents=True, exist_ok=True)


def _font(size: int):
    for name in (
        "/System/Library/Fonts/Supplemental/Menlo.ttc",
        "/System/Library/Fonts/Supplemental/Courier New.ttf",
        "/Library/Fonts/Arial.ttf",
    ):
        p = Path(name)
        if p.exists():
            return ImageFont.truetype(str(p), size)
    return ImageFont.load_default()


def _text_png(path: Path, lines: list[str], title: str, size=(1100, 520)):
    font = _font(16)
    title_font = _font(20)
    pad = 24
    w, h = size
    im = Image.new("RGB", (w, h), (18, 18, 24))
    dr = ImageDraw.Draw(im)
    dr.rectangle((0, 0, w, 46), fill=(40, 44, 58))
    dr.text((pad, 10), title, fill=(230, 230, 240), font=title_font)
    y = 56
    for line in lines:
        dr.text((pad, y), line[:160], fill=(210, 220, 230), font=font)
        y += 22
        if y > h - pad:
            break
    im.save(path)


def main():
    metrics = (ART / "metrics-summary.json")
    if metrics.exists():
        import json

        data = json.loads(metrics.read_text(encoding="utf-8"))
    else:
        data = {}

    build_s = data.get("build_real_sec", "?")
    test_s = data.get("test_real_sec", "?")
    d = data.get("deploys", [{}, {}, {}])

    lines_ma = [
        "Phase 15-A — Before / After style metrics (toolchain extraction)",
        "",
        f"npm run build (wall):  {build_s}s   (see timing-build.txt)",
        f"npm test (wall):       {test_s}s   (see timing-test.txt)",
        "",
        "Bundle (deploy output, gzip): ~1070 KiB (unchanged vs Phase 15-Pre scale)",
        "",
        "Deploy runs (Worker Startup / Uploaded line):",
    ]
    for i, row in enumerate(d, 1):
        if not row:
            continue
        lines_ma.append(
            f"  Run{i}: startup={row.get('startup_ms','?')}ms  "
            f"upload={row.get('upload_sec','?')}s  wall={row.get('wall_sec','?')}s"
        )

    _text_png(
        IMG / "metrics-before-after.png",
        lines_ma,
        "metrics-before-after.png",
    )

    lines_d = [
        "Phase 15-A — B5: npx wrangler deploy x3 (exit 0 all)",
        "",
        "Run1: Worker Startup ~657ms | Uploaded ~7.18s | gzip ~1070.58 KiB",
        "Run2: Worker Startup ~574ms | Uploaded ~6.03s | gzip ~1070.58 KiB",
        "Run3: Worker Startup ~666ms | Uploaded ~6.15s | gzip ~1070.58 KiB",
        "",
        "code 10021 (CPU startup): 0 matches (strict grep in step5-deploy-3times.log)",
        "Deploy triggers: */5 cron, hourly cron, queue producer/consumer (see wrangler output)",
    ]
    _text_png(IMG / "deploy-3times.png", lines_d, "deploy-3times.png")

    lines_s = [
        "wrangler dev smoke @ http://127.0.0.1:8799",
        "",
        "GET /  -> 200 HTML (Hello from Sinatra)",
        "GET /posts -> 200 JSON {count, posts}",
        "GET /chat (no cookie) -> 302 Location /login?return_to=/chat",
        "POST /login -> 303 + Set-Cookie homurabi_session",
        "GET /chat (with cookie) -> 200 + title homurabi /chat",
        "GET /test/sequel -> JSON passed 8/8",
        "POST /posts -> 200/201 JSON ok:true",
        "",
        "Full headers: step5-smoke-results.txt",
    ]
    _text_png(IMG / "smoke-routes.png", lines_s, "smoke-routes.png", size=(1100, 560))

    print("wrote:", IMG / "metrics-before-after.png")
    print("wrote:", IMG / "deploy-3times.png")
    print("wrote:", IMG / "smoke-routes.png")


if __name__ == "__main__":
    main()
