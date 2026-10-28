// Renders a square SVG to a transparent PNG at an exact pixel size (macOS only).
// For non-square targets the image is drawn at the smaller dimension, centered,
// so a round icon stays round instead of being stretched into an oval.
//
// Usage: swift tools/render_launcher_icon.swift <in.svg> <out.png> <width> [height]
// e.g.   swift tools/render_launcher_icon.swift ../resources/logos/launcher-round.svg \
//          resources/drawables/launcher_icon.png 70
//
// Targets (see the launcher icon section in monkey.jungle), all rendered from
// launcher-round.svg:
//   resources/drawables                70
//   resources-launcher-40x33/drawables 40 33
//   resources-launcher-38x33/drawables 38 33
import AppKit

let args = CommandLine.arguments
guard args.count == 4 || args.count == 5,
      let width = Int(args[3]), width > 0,
      let height = Int(args.count == 5 ? args[4] : args[3]), height > 0 else {
  FileHandle.standardError.write("usage: render_launcher_icon <in.svg> <out.png> <width> [height]\n".data(using: .utf8)!)
  exit(1)
}
guard let image = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
  FileHandle.standardError.write("cannot load \(args[1])\n".data(using: .utf8)!)
  exit(1)
}

let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: width, height: height)

let side = min(width, height)
let rect = NSRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: rect)
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
