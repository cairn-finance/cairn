# Cairn — App icon options

Five abstract 1024×1024 concepts, plus a re-runnable generator. Deliberately no
literal cairn, no stacked stones, no text, no axes.

| File | Concept | Field | Mark |
| --- | --- | --- | --- |
| `01-monogram.png` | **Monogram** — a single heavy two-tone **C** | deep ink `#0A2A34 → #04151B` | teal→cream gradient stroke `#3FC6DE → #F4F1EA` |
| `02-aperture.png` | **Aperture** — nested rounded frames | deep ink `#10222B → #051016` | `#2FB3CB` / `#7FD9E8` / `#F2F7F8` |
| `03-ascent.png` | **Ascent** — ascending bar series | teal ink `#0E3A47 → #061A21` | `#F4F1EA → #37BBD3` |
| `04-peak.png` | **Peak** — nested chevrons | deep ink `#0B2430 → #04121A` | cream `#F4F1EA` + teal `#3FC6DE` |
| `05-pulse.png` | **Pulse** — one market line | warm sand `#FCF9F3 → #ECE2D1` | dark teal `#0E5E6E` + dot `#2AA6BE` |

Regenerate everything:

```sh
swift Design/IconOptions/generate_icons.swift
```

The generator uses Core Graphics (Pillow is not installed here) and writes fully
opaque sRGB PNGs **without an alpha channel**. Marks sit inside the central ~80%
so the system rounded-rect mask never clips them, and there are no baked-in
corners, borders, or gloss.

## How to choose

- **`03-ascent.png`** — the most immediately readable as *money/growth*, and the
  bars still read as a bold silhouette at 40 pt. Safe, on-brand default.
- **`01-monogram.png`** — the most brandable and app-like; a letterform ages well
  and reads instantly at any size.
- **`04-peak.png`** — the most confident/abstract; a single upward gesture with no
  chart metaphor at all.
- **`02-aperture.png`** — the most "designed" and premium; least obviously
  finance, most obviously a considered brand mark.
- **`05-pulse.png`** — the only light field; a market line with no axes or labels.
  Great in light mode, and the dot gives a clear focal point.

Because they are single bold shapes with high contrast, all five survive iOS 26
Clear/Tinted rendering, which mostly discards colour and keeps the silhouette.

## Installing a chosen icon

Nothing in the Xcode project or asset catalog is changed by this folder. To
install, run the helper (or the steps below). Both targets are iOS 26 / macOS 26,
whose systems apply the rounded-rect mask, so a full-bleed square master is
correct — **do not bake in rounded corners.**

```sh
cd Design/IconOptions
./install_icon.sh 03-ascent.png     # <-- pick your concept
```

That copies the master, generates all 10 macOS sizes with `sips`, and writes a
valid `AppIcon.appiconset/Contents.json`. Then build the `Cairn` scheme —
`ASSETCATALOG_COMPILER_APPICON_NAME` is already `AppIcon` in `project.yml`.

Apple requires: 1024×1024 master, sRGB, **no transparency**, no pre-rendered
rounded corners or gloss. Verify with `sips -g hasAlpha <png>` → `hasAlpha: no`.

## Icon Composer (`.icon`) — worth doing later

Since the deployment target is **26.0** for both platforms, Cairn can adopt the
layered Liquid Glass format. A flat 1024 PNG still renders fine on iOS/macOS 26
(the system adds a generic specular edge), so the steps above are complete and
shippable. A `.icon` adds per-layer depth and proper Default / Dark / Clear /
Tinted renditions.

When to do it: after launch, using **Icon Composer** (ships with Xcode 26+; the
standalone tool needs macOS 26.4+). Split the chosen artwork into flat layers
(background + mark, optionally a separate accent layer), export SVG or 1024² PNG,
stack them in Icon Composer, then fix Dark → Tinted → Clear. The concepts here
are intentionally flat, opaque, and mask-safe so they drop straight into that
pipeline later without redesigning.
