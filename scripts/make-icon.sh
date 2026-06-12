#!/usr/bin/env bash
# Regenerate assets/icon.png from an SF Symbol (default: sparkles), sized for the menu bar.
# Usage: ./scripts/make-icon.sh [symbol-name] [point-size]
set -euo pipefail
SYMBOL="${1:-sparkles}"
SIZE="${2:-13}"
OUT="$(cd "$(dirname "$0")/.." && pwd)/assets/icon.png"

swift - "$SYMBOL" "$SIZE" "$OUT" <<'SW'
import AppKit
let a = CommandLine.arguments
let cfg = NSImage.SymbolConfiguration(pointSize: Double(a[2]) ?? 13, weight: .semibold)
guard let img = NSImage(systemSymbolName: a[1], accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg),
      let rep = NSBitmapImageRep(data: img.tiffRepresentation!),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("symbol render failed\n".data(using: .utf8)!); exit(1)
}
try! png.write(to: URL(fileURLWithPath: a[3]))
print("wrote \(a[3]) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
SW
