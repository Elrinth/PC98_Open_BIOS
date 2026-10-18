# Font specification (clean room)

The Open BIOS font must look like a real PC-98 without containing NEC's
character bitmaps. Typeface designs (the look of letters) are generally not
protected; the risk lies in the font data itself. This directory therefore
holds only facts measured from observation, and the glyphs are always the
free font's own shapes, adjusted to those facts.

## Rules

1. **No NEC font data.** Never read, copy, convert or trace a font ROM, a
   `boot.rom` containing one, or bitmaps extracted from one. Nothing in this
   repository is derived from such data.
2. **Observation only.** Measurements come from screenshots of real PC-98
   software output (text screens). The screenshots are not committed;
   `observations.json` identifies them by SHA-256 and lists the text on them.
3. **Dimensions, not shapes.** `tools/measure_metrics.py` records per
   character only the inked bounding box (rows, columns) and the ink pixel
   count. No pixel patterns are stored or used.
4. **Free sources for every pixel.** Glyphs come from the public-domain
   Shinonome fonts (`LICENSES/Shinonome.txt`) or are drawn in this project.
   `tools/fontmetrics.py` fits each free glyph into its observed box by
   merging or repeating its own most similar rows and columns.
5. **Conventions may be followed, drawings may not be copied.** Generic
   style conventions seen on screen (for example a slashed zero, the blank
   left column) are drawn here from scratch, never transferred pixel by pixel.

## Pipeline

```
Shinonome BDF --mkfont.py--> render, NEC alignment (blank column 0)
             --fontmetrics.py--> fit 8x16 ANK to observed_metrics.json
             --> font/pc98font.rom
```

`mkfont.py` runs all steps when it builds from BDF. For the shipped image,
`python tools/fontmetrics.py font/pc98font.rom -o font/pc98font.rom` is
idempotent.

## Files

- `observations.json`: screenshots used (SHA-256, description) and the
  transcribed text per row/column (half-width and full-width cells).
- `observed_metrics.json`: measured boxes, 94 half-width characters and 41
  full-width characters (2026-10-18).

## Findings (2026-10-18)

- Half-width text characters: capitals and digits use rows 3-13, lowercase
  x-height rows 6-13, descenders reach row 15, column 0 is blank. The free
  font's glyphs were 1-2 rows taller; they are now fitted.
- Full-width characters already match within about one pixel (column 0
  blank, rows 0-15).
