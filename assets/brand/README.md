# HollerShare logo

The holler: a megaphone blasting arrows across the room — your voice, and
the files it sends onward. Two colors from the app's palette: the megaphone
in the green tone, the arrows in coral.

- `hollershare-mark.svg`: transparent scalable mark (megaphone `#45624b`,
  arrows `#d95e43`).
- `hollershare-icon.svg` / `.png`: launcher icon, the mark on a rounded
  warm-paper tile, 1024px PNG.
- `hollershare-tray.png`: transparent 128px tray icon.

The app header uses raster PNGs (`frontend/brand-mark.png` and
`brand-mark-dark.png`, sage `#aec79f` and coral `#f07a5a` for dark mode),
because the marks' distinctive hand-traced shapes are too intricate for the
native renderer's SVG parser to paint faithfully at small sizes.

Export the PNGs with librsvg:

```sh
rsvg-convert -w 1024 -h 1024 hollershare-icon.svg -o hollershare-icon.png
rsvg-convert -w 128 -h 128 hollershare-mark.svg -o hollershare-tray.png
rsvg-convert -w 160 -h 160 ../frontend/brand-mark.png hollershare-mark.svg 2>/dev/null || \
  rsvg-convert -w 160 -o ../frontend/brand-mark.png hollershare-mark.svg
```
