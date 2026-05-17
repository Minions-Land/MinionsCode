#!/usr/bin/env swift
import AppKit

// Generates AppIcon.icns from a programmatic Minion-style drawing.
// Output: Resources/AppIcon.icns

let baseSize: CGFloat = 1024

func render(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }

    // Background — soft black with subtle vignette
    let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
    ctx.setFillColor(NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1).cgColor)
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: size * 0.22, cornerHeight: size * 0.22, transform: nil)
    ctx.addPath(bgPath); ctx.fillPath()

    // Subtle inner gradient
    let gradient = CGGradient(colorsSpace: nil,
        colors: [
            NSColor(red: 0.10, green: 0.09, blue: 0.06, alpha: 1).cgColor,
            NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1).cgColor
        ] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addPath(bgPath); ctx.clip()
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: size, y: 0),
                           options: [])
    ctx.restoreGState()

    // Minion body (centered, occupies ~70% of frame)
    let bodyDiameter = size * 0.68
    let bodyRect = CGRect(x: (size - bodyDiameter) / 2,
                          y: (size - bodyDiameter) / 2,
                          width: bodyDiameter,
                          height: bodyDiameter)

    // Body gold gradient
    let goldGradient = CGGradient(colorsSpace: nil,
        colors: [
            NSColor(red: 1.0, green: 0.88, blue: 0.30, alpha: 1).cgColor,
            NSColor(red: 0.95, green: 0.65, blue: 0.05, alpha: 1).cgColor
        ] as CFArray, locations: [0, 1])!

    ctx.saveGState()
    ctx.addEllipse(in: bodyRect)
    ctx.clip()
    ctx.drawLinearGradient(goldGradient,
                           start: CGPoint(x: bodyRect.minX, y: bodyRect.maxY),
                           end: CGPoint(x: bodyRect.maxX, y: bodyRect.minY),
                           options: [])
    ctx.restoreGState()

    // Body outline
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor)
    ctx.setLineWidth(size * 0.012)
    ctx.strokeEllipse(in: bodyRect)

    // Goggle band — horizontal black band across the eyes
    let bandHeight = bodyDiameter * 0.22
    let bandY = bodyRect.midY - bandHeight * 0.15
    let bandRect = CGRect(x: bodyRect.minX, y: bandY - bandHeight / 2,
                          width: bodyDiameter, height: bandHeight)
    ctx.saveGState()
    ctx.addEllipse(in: bodyRect); ctx.clip()
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.85).cgColor)
    ctx.fill(bandRect)
    ctx.restoreGState()

    // Two eye lenses (silver rims, white sclera, dark gold iris, black pupil)
    let eyeDiameter = bodyDiameter * 0.26
    let eyeY = bandY
    let eyeSpacing = bodyDiameter * 0.20
    for dx in [-eyeSpacing, eyeSpacing] {
        let eyeRect = CGRect(x: bodyRect.midX + dx - eyeDiameter / 2,
                             y: eyeY - eyeDiameter / 2,
                             width: eyeDiameter, height: eyeDiameter)
        // Silver rim
        ctx.setFillColor(NSColor(red: 0.78, green: 0.78, blue: 0.80, alpha: 1).cgColor)
        ctx.fillEllipse(in: eyeRect)
        // White sclera
        let scleraRect = eyeRect.insetBy(dx: eyeDiameter * 0.10, dy: eyeDiameter * 0.10)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: scleraRect)
        // Iris (warm brown-gold)
        let irisDiameter = eyeDiameter * 0.42
        let irisRect = CGRect(x: eyeRect.midX - irisDiameter / 2,
                              y: eyeRect.midY - irisDiameter / 2,
                              width: irisDiameter, height: irisDiameter)
        ctx.setFillColor(NSColor(red: 0.45, green: 0.28, blue: 0.10, alpha: 1).cgColor)
        ctx.fillEllipse(in: irisRect)
        // Pupil
        let pupilDiameter = eyeDiameter * 0.18
        let pupilRect = CGRect(x: eyeRect.midX - pupilDiameter / 2,
                               y: eyeRect.midY - pupilDiameter / 2,
                               width: pupilDiameter, height: pupilDiameter)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillEllipse(in: pupilRect)
        // Catchlight
        let catchSize = eyeDiameter * 0.10
        let catchRect = CGRect(x: eyeRect.midX - catchSize * 0.3,
                               y: eyeRect.midY + eyeDiameter * 0.08,
                               width: catchSize, height: catchSize)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.fillEllipse(in: catchRect)
    }

    // Smile — small upward arc below the band
    let smileWidth = bodyDiameter * 0.30
    let smileY = bodyRect.midY - bodyDiameter * 0.18
    let smilePath = CGMutablePath()
    smilePath.move(to: CGPoint(x: bodyRect.midX - smileWidth / 2, y: smileY))
    smilePath.addQuadCurve(to: CGPoint(x: bodyRect.midX + smileWidth / 2, y: smileY),
                            control: CGPoint(x: bodyRect.midX, y: smileY - bodyDiameter * 0.08))
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.8).cgColor)
    ctx.setLineWidth(size * 0.014)
    ctx.setLineCap(.round)
    ctx.addPath(smilePath); ctx.strokePath()

    img.unlockFocus()
    return img
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("Failed to encode PNG: \(path)")
        return
    }
    let url = URL(fileURLWithPath: path)
    try? png.write(to: url)
    print("Wrote \(url.lastPathComponent)")
}

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetDir = "\(outputDir)/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in sizes {
    let img = render(CGFloat(px))
    savePNG(img, to: "\(iconsetDir)/\(name)")
}

print("Iconset written to \(iconsetDir)")
print("Convert with: iconutil -c icns \(iconsetDir) -o \(outputDir)/AppIcon.icns")
