# HollerShare logo

A solid megaphone and one outgoing arrow. Broad silhouettes and two simple
paths keep the mark readable at 24–48 pixels. The launcher uses a deep green
background (`#234b3a`), a warm white horn (`#fff7ea`) and a coral arrow
(`#ff957d`).

- `hollershare-icon.svg` / `.png`: desktop launcher, 1024px PNG.
- `hollershare-mark.svg`: transparent green/coral mark for light backgrounds.
- `hollershare-mark-dark.svg`: sage/coral mark for dark backgrounds.
- `hollershare-tray.png`: transparent 128px tray icon.
- `frontend/brand-mark.png` and `brand-mark-dark.png`: header marks.

Android resources are in `src/android/res`. Adaptive icons on Android 8+
use a full-bleed green background and a separate vector foreground, so the
launcher can apply its circle, squircle or other mask without adding a white
tile. The foreground fits inside the 66dp safe circle of its 108dp viewport.
Android 13+ also gets a monochrome foreground for themed icons. Older Android
versions use Oriel's generated PNG launcher icons.

The Android foreground paths match the SVG mark, scaled to 70% and centered
in the 108dp viewport. Keep the vector paths in sync when editing the mark.
`build.zig` copies these resources into the generated Android project on build.

Regenerate PNGs from the repository root with librsvg:

```sh
rsvg-convert -w 1024 -h 1024 assets/brand/hollershare-icon.svg -o assets/brand/hollershare-icon.png
rsvg-convert -w 128 -h 128 assets/brand/hollershare-mark.svg -o assets/brand/hollershare-tray.png
rsvg-convert -w 160 -h 160 assets/brand/hollershare-mark.svg -o frontend/brand-mark.png
rsvg-convert -w 160 -h 160 assets/brand/hollershare-mark-dark.svg -o frontend/brand-mark-dark.png
cp assets/brand/hollershare-icon.png icon.png
```
