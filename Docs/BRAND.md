# Pi Swift identity

The app and window are **Pi Swift**. The executable product is `PiSwift`; the command-line companion remains `pf`. The repository keeps the user-chosen `pi-swfit` spelling. Existing connection and JSONL storage under `~/.pf/agent` is unchanged; `playground.json` retains its legacy filename to preserve restoration.

## Celadon palette

| Token | Light | Dark |
| --- | --- | --- |
| Accent | `#216B5E` | `#A8D8C8` |
| Text on accent | `#F4F5EF` | `#163C32` |
| Canvas | `#FBFCFA` | `#181E1C` |
| Sidebar | `#F1F3EF` | `#141917` |

Calculated sRGB contrast: accent text on the canvas is 6.13:1 in light mode and 10.73:1 in dark mode; text on the accent is 5.75:1 and 7.72:1 respectively. These are palette checks, not a full accessibility audit.

The palette is defined in `Examples/PiSwift/PiBrand.swift`. The reusable PiUI library continues to accept a host-provided ChatTheme.

## Icon

The mark combines a flat ivory π with a small outward speech-tail terminal on a solid jade tile. No gradients, shadows or textures. The logo appears in Dock, the empty state and README; the toolbar uses only the Pi Swift name. The editable master is [PiSwift.svg](../Brand/PiSwift.svg); its deterministic 1024 px export is [AppIcon.png](../Examples/PiSwift/Assets/AppIcon.png). Both use genuine transparency outside the rounded tile.

The initial concept was explored with the built-in image_gen tool (not the API/CLI fallback). After the request for a flatter mark, the production asset was redrawn as a two-fill SVG. `scripts/render-icon.swift` exports that vector with Core Graphics; `scripts/build-app.sh` creates the standard 16–1024 pixel macOS ICNS representations and embeds the icon and resource bundle in `.build/Pi Swift.app`.

Final design brief:

```text
A minimalist flat app icon: a solid celadon #216B5E rounded square containing a solid ivory #F4F5EF Greek π. Preserve a gently curved top bar, two substantial stems, and an integrated small speech-tail terminal at lower right. Exactly two uniform fills, transparent outer margin, no gradients, shadows, texture, beveling or lettering.
```

README screenshots use the Rich Markdown content in sessions created through a local loopback fixture. No personal conversation, credentials or private workspace paths are included.
