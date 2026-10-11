# Tabler icons for AppKit

SVG is the editable source. The app loads vector PDFs through the reusable `IconUI` library in `Packages/IDE`; no SVG engine, Python or network is needed to build or run SwiftIDE. Only the curated set in `manifest.json` is shipped, loaded lazily on the main actor. PDFs and the generated Swift enum are committed with their SVGs.

Upstream: https://github.com/tabler/tabler-icons, pinned to **v3.49.0**, MIT (see `LICENSE`). SVGs are unchanged upstream copies, verified against manifest SHA-256 values. The generation step maps `currentColor` to black and applies a common 1.5-point stroke on the 24-point grid. Template controls supply the actual dynamic colour. Edit `strokeWidth` to change the set; per-control colours belong to AppKit, not SVG edits.

```swift
import IconUI

button.image = TablerIcon.folder.image(accessibilityDescription: "Open folder")
button.contentTintColor = .labelColor
```

Every request returns an independent image copy; resizing, descriptions and template changes cannot mutate other controls. A missing bundled resource is an explicit programming failure. The MIT notice also ships inside the resource bundle.

## Regenerate (development only)

Use Python 3.12 and an isolated environment. Dependency versions, including transitive packages, are pinned in `requirements.txt`.

```sh
python3.12 -m venv /private/tmp/swiftide-icons
/private/tmp/swiftide-icons/bin/python -m pip install -r Tools/Icons/requirements.txt
/private/tmp/swiftide-icons/bin/python Tools/Icons/generate.py
/private/tmp/swiftide-icons/bin/python Tools/Icons/generate.py --check
```

The converter accepts the simple shapes used by this curated outline set; external references, CSS and other SVG elements fail rather than produce partial output. It is not a general user SVG viewer. PDF output uses invariant metadata for reproducible bytes. Normal Swift builds only copy existing resources.

To add an icon, copy its SVG from the pinned official tag into `SVG/`, add its name, Swift case and SHA-256 to the manifest, then regenerate and run `TablerIconTests`. Update the source pin and review SVG differences when upgrading. `--check` compares all generated files without modifying them.

Workspace's existing SF Symbol tool descriptors remain compatible. Standard controls map to Tabler; custom tools can use `symbol: "tabler:brand-docker"`, or keep an SF Symbol name. File type icons from macOS remain in the Files tree.

Verification: every PDF remains vector and draws at 16/24/48 px; cached templates are isolated; native views apply contrasting template tint in Aqua and Dark Aqua. Gallery renders are written to `/private/tmp/swiftide-tabler-light.png` and `swiftide-tabler-dark.png` by the appearance test. Live accessibility/disabled-state acceptance remains in the manual checklist.
