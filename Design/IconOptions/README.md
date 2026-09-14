# Cairn — App icon options

Four 1024×1024 icon concepts for Cairn, plus a re-runnable generator.

| File | Concept | Field | Cairn mark |
| --- | --- | --- | --- |
| `01-stacked-stones.png` | Stacked Stones — literal cairn | teal gradient `#3CBAD2 → #16869C` | warm stones `#F2E9DA → #C9B392`, walnut capstone `#8A6540 → #4E3418` |
| `02-cairn-mark.png` | Cairn Mark — iconic stack | deep walnut `#3A2A1A → #170F08` | off-white pills `#F7F2E9 → #DACBB2`, teal capstone `#4FC7DC → #1E8CA2` |
| `03-trailhead.png` | Trailhead — light-field stack | warm sand `#FBF7EF → #EADFCB` | dark walnut pills `#5A4128 → #2A1B0E`, teal ground + capstone |
| `04-summit.png` | Summit — abstract minimal stack | dark ink `#103039 → #050F14` | single-hue teal stack `#B7EDF6 → #2090A6` |

Regenerate everything with:

```sh
swift Design/IconOptions/generate_icons.swift
```

The generator uses Core Graphics (Pillow is not installed in this environment) and
writes fully opaque sRGB PNGs **without an alpha channel**.

## Why these work at 40 pt

All four reduce to a single bold silhouette: three or four rounded stones stacked
into a stable pyramid. There is no text, no thin strokes, no baked-in lighting or
rounded corners, and the mark occupies the central ~80% of the canvas so the
system mask never clips it. Contrast is high in every case — light stones on a
dark field or dark stones on a light field — so the icon survives the iOS 26
Clear and Tinted rendering modes, which discard most colour and keep only shape.

## Recommendation

**Ship `02-cairn-mark.png`.** It has the cleanest, most symmetrical silhouette, the
strongest light/dark contrast, and the teal capstone ties directly to the app's
existing accent (`#30B0C7`). Because it is an off-white glyph on a dark field, it
also degrades gracefully into the monochrome Tinted/Clear modes.

**Runner-up: `01-stacked-stones.png`** — warmer and more literal, with the teal
brand field most people already associate with Cairn. Slightly busier at 40 pt
than option 2.

`03-trailhead.png` is the best choice if you prefer a light icon (matches the
light appearance of the app); `04-summit.png` is the most abstract/minimal and the
most legible in tinted mode, but reads less specifically as a cairn.

## Installing a chosen icon

Nothing in the Xcode project or asset catalog is changed by this folder. To
install, run the steps below (or `./install_icon.sh 02-cairn-mark.png`). The
targets are iOS 26 / macOS 26, whose systems both apply the rounded-rect mask, so
a full-bleed square master is correct — **do not bake in rounded corners.**

### 1. Copy the master and generate sizes

```sh
cd Design/IconOptions
ICON=02-cairn-mark.png                       # <-- pick your concept
DEST=../../CairnApp/Resources/Assets.xcassets/AppIcon.appiconset

cp "$ICON" "$DEST/AppIcon-1024.png"          # iOS universal 1024 slot

# macOS slots (source is 1024², so -z resampling stays square)
sips -z 16   16   "$ICON" --out "$DEST/icon_16x16.png"
sips -z 32   32   "$ICON" --out "$DEST/icon_16x16@2x.png"
sips -z 32   32   "$ICON" --out "$DEST/icon_32x32.png"
sips -z 64   64   "$ICON" --out "$DEST/icon_32x32@2x.png"
sips -z 128  128  "$ICON" --out "$DEST/icon_128x128.png"
sips -z 256  256  "$ICON" --out "$DEST/icon_128x128@2x.png"
sips -z 256  256  "$ICON" --out "$DEST/icon_256x256.png"
sips -z 512  512  "$ICON" --out "$DEST/icon_256x256@2x.png"
sips -z 512  512  "$ICON" --out "$DEST/icon_512x512.png"
cp "$ICON" "$DEST/icon_512x512@2x.png"       # 1024
```

### 2. Replace `AppIcon.appiconset/Contents.json`

```json
{
  "images" : [
    { "filename" : "AppIcon-1024.png",     "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "filename" : "icon_16x16.png",       "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png",    "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",       "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png",    "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",     "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",     "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",     "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png",  "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
```

### 3. Build and verify

Build the `Cairn` scheme. `ASSETCATALOG_COMPILER_APPICON_NAME` is already
`AppIcon` in `project.yml`, so no other change is needed. Check the Home Screen,
the macOS Dock, and the App Store Connect icon preview once uploaded.

Apple requires: 1024×1024 master, sRGB, **no transparency**, no pre-rendered
rounded corners or gloss. These files satisfy that (verify with
`sips -g hasAlpha your.png` → `hasAlpha: no`).

## Icon Composer (`.icon`) — worth doing later

Since the deployment target is **26.0** for both platforms, Cairn can adopt the
layered Liquid Glass format. A flat 1024 PNG still renders fine on iOS/macOS 26
(the system adds a generic specular edge), so the steps above are a complete,
shippable solution. But a `.icon` gives per-layer depth and proper Default / Dark
/ Clear / Tinted renditions.

When to do it: after launch, using **Icon Composer** (ships with Xcode 26+; the
standalone tool requires macOS 26.4+). Workflow:

1. Split the chosen artwork into flat layers — solid/gradient **background** and
   the **foreground cairn** (optionally a separate capstone/ground layer). Export
   SVG (preferred) or 1024² PNG; never include the rounded-rect mask.
2. In `Xcode → Open Developer Tool → Icon Composer`, create a new App Icon, stack
   the layers (max four groups), and tune specular/refraction/shadow per layer.
3. Fix Dark, then Tinted (the silhouette must read in one tone), then Clear
   (test over busy wallpapers).
4. Save `Cairn.icon`, drag it into `Assets.xcassets`, keep `AppIcon.appiconset`
   as the fallback for anything older, and select it in the target's App Icon
   setting.

The concepts here are intentionally flat, opaque and mask-safe so they can be
dropped straight into that pipeline later without redesigning.
