# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy==2.4.3", "opencv-python-headless==4.13.0.92", "pillow==12.1.1"]
# ///
"""Extract the approved artwork into glass layers and render native previews.

Run with `uv run Tools/app-icon/build_icons.py`. No image-generation calls.
The masks below describe this seven-icon family, not a general image tracer.
"""

import argparse
import json
from pathlib import Path
import subprocess

import cv2
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "Ladle/Resources/Assets.xcassets"
ICONS = ROOT / "Ladle/Resources/AppIcons"
OPTIONS = [
    ("Egg", "AppIcon", "OvereasyMark"),
    ("Avocado", "AppIcon-PlantBased", "OvereasyMarkPlantBased"),
    ("Tomato", "AppIcon-Tomato", "OvereasyMarkTomato"),
    ("Strawberry", "AppIcon-Strawberry", "OvereasyMarkStrawberry"),
    ("Cherries", "AppIcon-Cherries", "OvereasyMarkCherries"),
    ("Carrot", "AppIcon-Carrot", "OvereasyMarkCarrot"),
    ("Mushroom", "AppIcon-Mushroom", "OvereasyMarkMushroom"),
]
RENDITIONS = ["Default", "Dark", "ClearLight", "ClearDark", "TintedLight", "TintedDark"]


def silhouette(mask, *, largest=False):
    """Close sampling gaps and discard specks; fill painted shine/shadow holes."""
    mask = cv2.morphologyEx(mask.astype(np.uint8), cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    contours = [c for c in contours if cv2.contourArea(c) > 80]
    if largest:
        contours = [max(contours, key=cv2.contourArea)]
    result = np.zeros_like(mask)
    cv2.drawContours(result, contours, -1, 1, cv2.FILLED)
    return result.astype(bool)


def layers_for(name, rgb):
    h, s, v = cv2.split(cv2.cvtColor(rgb, cv2.COLOR_RGB2HSV))
    r, g, b = cv2.split(rgb)
    y, x = np.indices(h.shape)
    green = (h > 24) & (h < 85) & (s > 65) & (v > 45)
    red = ((h < 15) | (h > 170)) & (s > 125) & (v > 90)
    orange = (h < 25) & (s > 110) & (v > 95)
    cream = (r > 210) & (g > 185) & (s < 100)
    vein_threshold = {"Carrot": 180, "Cherries": 165}.get(name, 155)
    foliage = [(silhouette(green), "#668B38"), (green & (g > vein_threshold), "#AAC45B")]

    match name:
        case "Egg":
            return [("White", [(silhouette(cream, largest=True), "#FCF9F2")]),
                    ("Yolk", [(silhouette(orange, largest=True), "#D8622E")])]
        case "Avocado":
            return [("Rind", [(silhouette(green, largest=True), "#244D24")]),
                    ("Flesh", [(silhouette(green & (v > 150)), "#B4CF60"),
                               (silhouette(green & (v > 210)), "#EAED97")]),
                    ("Stone", [(silhouette(orange, largest=True), "#914C2E")])]
        case "Tomato":
            return [("Tomato", [(silhouette(red, largest=True), "#E74525")]),
                    ("Basil", foliage)]
        case "Strawberry":
            seeds = (r > 235) & (g > 200) & (b < 195) & (h > 15) & ~green
            return [("Berry", [(silhouette(red, largest=True), "#DC302D")]),
                    ("Leaves", foliage),
                    ("Seeds", [(silhouette(seeds), "#FCE8AD")])]
        case "Cherries":
            # The original overlap has a strong color edge. Watershed follows
            # that edge between two interior seeds without inventing new shapes.
            fruit = silhouette(red)
            markers = np.zeros(h.shape, np.int32)
            markers[~fruit] = 1
            markers[(x - 320) ** 2 + (y - 470) ** 2 < 60 ** 2] = 2
            markers[(x - 650) ** 2 + (y - 670) ** 2 < 65 ** 2] = 3
            labels = cv2.watershed(cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR), markers)
            back_distance = cv2.distanceTransform((labels != 2).astype(np.uint8), cv2.DIST_L2, 5)
            front_distance = cv2.distanceTransform((labels != 3).astype(np.uint8), cv2.DIST_L2, 5)
            front = fruit & (front_distance < back_distance)
            return [("Back cherry", [(silhouette(fruit & ~front), "#C7192D")]),
                    ("Front cherry", [(silhouette(front), "#CD1E2D")]),
                    ("Stems and leaf", foliage)]
        case "Carrot":
            body = silhouette(orange, largest=True)
            # The two grooves are dark regions inside the carrot, while the
            # old underside shadow touches its boundary and is excluded.
            interior = cv2.erode(body.astype(np.uint8), np.ones((13, 13), np.uint8)).astype(bool)
            _, components, stats, _ = cv2.connectedComponentsWithStats(
                (orange & (r < 210) & body).astype(np.uint8))
            grooves = np.zeros_like(body)
            for index, stat in enumerate(stats[1:], 1):
                component = components == index
                if 500 < stat[cv2.CC_STAT_AREA] < 15000 and np.all(interior[component]):
                    grooves |= component
            return [("Carrot", [(body, "#FC751F"), (silhouette(grooves), "#C5511A")]),
                    ("Leaves", foliage)]
        case "Mushroom":
            brown = (h < 25) & (s > 100) & (v > 70)
            return [("Cap", [(silhouette(brown, largest=True), "#A7653C")]),
                    ("Underside", [(silhouette(brown & (v < 105), largest=True), "#66351F")]),
                    ("Stem", [(silhouette(cream & (y > 450), largest=True), "#F6E4C6")])]
    raise ValueError(name)


def save_layer(parts, path):
    """Trace only existing boundaries, then supersample for clean alpha edges."""
    canvas = Image.new("RGBA", (4096, 4096))
    for mask, color in parts:
        contours, _ = cv2.findContours(mask.astype(np.uint8), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        alpha = np.zeros((4096, 4096), np.uint8)
        contours = [cv2.approxPolyDP(c, 0.6, True) * 4 for c in contours if cv2.contourArea(c) > 80]
        cv2.drawContours(alpha, contours, -1, 255, cv2.FILLED)
        paint = Image.new("RGBA", canvas.size, color)
        paint.putalpha(Image.fromarray(alpha))
        canvas.alpha_composite(paint)
    canvas.resize((1024, 1024), Image.Resampling.LANCZOS).save(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gallery", type=Path, help="Also render all six appearances to this folder")
    args = parser.parse_args()
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    renderer = developer.parent / "Applications/Icon Composer.app/Contents/Executables/ictool"
    if args.gallery:
        args.gallery.mkdir(parents=True, exist_ok=True)

    for name, icon, mark in OPTIONS:
        source = Path(__file__).parent / "originals" / f"{icon}.png"
        rgb = np.array(Image.open(source).convert("RGB"))
        package = ICONS / f"{icon}.icon"
        (package / "Assets").mkdir(parents=True, exist_ok=True)
        groups = []
        for title, parts in layers_for(name, rgb):
            filename = title.replace(" ", "-") + ".png"
            save_layer(parts, package / "Assets" / filename)
            groups.append({
                "layers": [{"image-name": filename, "name": title}],
                "shadow": {"kind": "neutral", "opacity": 0.3},
                "translucency": {"enabled": True, "value": 0.3},
            })
        document = {
            "fill": {"linear-gradient": [
                "extended-srgb:0.29412,0.22745,0.27059,1.00000",
                "extended-srgb:0.23922,0.18431,0.21961,1.00000",
            ]},
            # Icon Composer stores groups front to back, like its sidebar.
            "groups": list(reversed(groups)),
            "supported-platforms": {"squares": "shared", "circles": []},
        }
        (package / "icon.json").write_text(json.dumps(document, indent=2) + "\n")
        images = []
        for rendition in RENDITIONS if args.gallery else RENDITIONS[:2]:
            filename = f"{mark}{'Dark' if rendition == 'Dark' else ''}.png"
            output = ASSETS / f"{mark}.imageset" / filename
            if rendition not in RENDITIONS[:2]:
                output = args.gallery / f"{name}-{rendition}.png"
            # The largest in-app mark is 96pt; 512px covers even a 3x display.
            size = "512" if rendition in RENDITIONS[:2] else "1024"
            subprocess.run([str(renderer), str(package), "--export-image", "--output-file", str(output),
                            "--platform", "iOS", "--rendition", rendition,
                            "--width", size, "--height", size, "--scale", "1"],
                           check=True, stdout=subprocess.DEVNULL)
            if rendition in RENDITIONS[:2]:
                entry = {"filename": filename, "idiom": "universal"}
                if rendition == "Dark":
                    entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
                images.append(entry)
                if args.gallery:
                    (args.gallery / f"{name}-{rendition}.png").write_bytes(output.read_bytes())
        (ASSETS / f"{mark}.imageset/Contents.json").write_text(
            json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
        print(f"{name}: {len(groups)} foreground layers, native glass previews")


if __name__ == "__main__":
    main()
