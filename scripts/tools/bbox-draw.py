"""把 `bbox-probe.mjs` 返回的坐标画到原图上，用来**目测**框准不准。

判据是人眼：框有没有套住那道题、有没有越过相邻题。
所以这里只做一件事 —— 画框，不做任何"修正"（比如自动扩大范围），
否则看到的就不是模型给的真实位置了。
"""
import json
import sys

from PIL import Image, ImageDraw, ImageFont

image_path, json_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

data = json.load(open(json_path, encoding="utf-8"))
image = Image.open(image_path).convert("RGB")
width, height = image.size
draw = ImageDraw.Draw(image)

# 字号按图宽缩放：照片动辄 3000px 宽，固定 20 号字等于看不见。
try:
    font = ImageFont.truetype("C:/Windows/Fonts/msyh.ttc", max(18, width // 55))
except OSError:
    font = ImageFont.load_default()

colors = [(235, 64, 52), (30, 144, 255), (46, 160, 67), (255, 140, 0), (150, 60, 200)]

for index, item in enumerate(data.get("items", [])):
    box = item.get("box") or []
    if len(box) != 4:
        continue
    x1, y1, x2, y2 = [max(0.0, min(1.0, float(v))) for v in box]
    left, right = int(x1 * width), int(x2 * width)
    top, bottom = int(y1 * height), int(y2 * height)
    color = colors[index % len(colors)]
    stroke = max(3, width // 400)
    draw.rectangle([left, top, right, bottom], outline=color, width=stroke)

    label = item.get("questionNo") or f"#{index + 1}"
    text_box = draw.textbbox((0, 0), label, font=font)
    text_w, text_h = text_box[2] - text_box[0], text_box[3] - text_box[1]
    draw.rectangle(
        [left, max(0, top - text_h - 8), left + text_w + 14, top],
        fill=color,
    )
    draw.text((left + 7, max(0, top - text_h - 5)), label, fill="white", font=font)

image.save(out_path)
print(f"{image.size[0]}x{image.size[1]} → {out_path}（{len(data.get('items', []))} 个框）")
