// Draws the app icons: swift mkicon.swift <game|packager> <out dir> [logo.png]
// game: the title logo (the launcher caches it as Caches/nx-ui/logo.png) over a sky; packager: original art.
// Writes the 1024 master plus the sizes the Info.plist lists (iPhone 120/180, iPad 152/167).
import AppKit
import ImageIO

func rgb(_ h: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

func draw(_ kind: String, _ c: CGContext) {
    let cs = CGColorSpaceCreateDeviceRGB()
    let g = CGGradient(colorsSpace: cs, colors: [rgb(0x7FD0FF), rgb(0xFFF2CA)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 0, y: 0), options: [])
    c.setFillColor(rgb(0xFFFFFF, 0.85))
    for (x, y, r) in [(250, 790, 70), (330, 820, 95), (420, 790, 70), (700, 880, 55), (770, 905, 75), (850, 880, 55)] {
        c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
    }
    if kind == "game" {
        // The game's own title logo (the launcher's cached Title_WW_LogoS, 420x360), centred on the sky.
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: logoPath) as CFURL, nil), let logo = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            print("no logo at \(logoPath)"); exit(1)
        }
        let w: CGFloat = 800, h = w * CGFloat(logo.height) / CGFloat(logo.width)
        c.setFillColor(rgb(0x4FB6E8, 0.0))
        c.draw(logo, in: CGRect(x: (1024 - w) / 2, y: (1024 - h) / 2 - 10, width: w, height: h))
    } else {
        c.setFillColor(rgb(0x000000, 0.12)); c.fillEllipse(in: CGRect(x: 250, y: 140, width: 524, height: 70))
        c.setFillColor(rgb(0xFFFFFF)); c.addPath(CGPath(roundedRect: CGRect(x: 232, y: 200, width: 560, height: 560), cornerWidth: 120, cornerHeight: 120, transform: nil)); c.fillPath()
        c.setStrokeColor(rgb(0xFF8A00)); c.setLineWidth(60); c.setLineCap(.round); c.setLineJoin(.round)
        c.move(to: CGPoint(x: 512, y: 640)); c.addLine(to: CGPoint(x: 512, y: 330)); c.strokePath()
        c.move(to: CGPoint(x: 382, y: 460)); c.addLine(to: CGPoint(x: 512, y: 330)); c.addLine(to: CGPoint(x: 642, y: 460)); c.strokePath()
    }
}

func png(_ kind: String, _ px: Int, _ path: String) {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    c.interpolationQuality = .high
    c.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(kind, c)
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let a = CommandLine.arguments
guard a.count >= 3 else { print("usage: mkicon.swift <game|packager> <out dir> [logo.png]"); exit(1) }
let logoPath = a.count > 3 ? a[3] : NSHomeDirectory() + "/Library/Caches/nx-ui/logo.png"
try? FileManager.default.createDirectory(atPath: a[2], withIntermediateDirectories: true)
png(a[1], 1024, a[2] + "/AppIcon1024.png")
for (name, px) in [("AppIcon60x60@2x", 120), ("AppIcon60x60@3x", 180), ("AppIcon76x76@2x~ipad", 152), ("AppIcon83.5x83.5@2x~ipad", 167)] {
    png(a[1], px, a[2] + "/\(name).png")
}
