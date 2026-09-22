import Cocoa

// Best-effort app icon: render the tomato emoji into a .iconset directory.
let args = CommandLine.arguments
guard args.count >= 2 else { exit(1) }
let outDir = args[1]

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func render(_ px: Int) -> Data? {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let emoji = "\u{1F345}" as NSString
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: CGFloat(px) * 0.74),
        .paragraphStyle: style,
    ]
    let size = emoji.size(withAttributes: attrs)
    let rect = NSRect(x: (CGFloat(px) - size.width) / 2,
                      y: (CGFloat(px) - size.height) / 2,
                      width: size.width, height: size.height)
    emoji.draw(in: rect, withAttributes: attrs)
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [:])
}

for s in sizes {
    guard let data = render(s.px) else { continue }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(s.name + ".png")
    try? data.write(to: url)
}
