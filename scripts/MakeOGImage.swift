// Generates the Open Graph preview image for parfait.to (site/og-image.png).
// Mirrors the drawing/writing approach in scripts/MakeIcon.swift.
// Run: swift scripts/MakeOGImage.swift <appIconPath> <outdir>
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func srgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

// Same palette as HTMLExporter.swift's --page/--ink/--muted and the
// .parfait-bar four-stop stripe (#FFF9F2, #F2A93B, #E0396B, #5A6ACF).
let page = srgb(255, 249, 242)      // #FFF9F2
let stripeCream = srgb(255, 249, 242)
let stripeHoney = srgb(242, 169, 59)  // #F2A93B
let stripeRaspberry = srgb(224, 57, 107) // #E0396B
let stripePeriwinkle = srgb(90, 106, 207) // #5A6ACF
let ink = srgb(67, 50, 43)          // #43322B
let mutedOnPage = srgb(67, 50, 43, 0.62) // rgba(67,50,43,.62), matches --muted

let width = 1200
let height = 630
let stripeHeight: CGFloat = 14

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    return ctx
}

func writePNG(_ ctx: CGContext, to url: URL) {
    guard let img = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fputs("cannot create \(url.path)\n", stderr); exit(1) }
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { fputs("cannot write \(url.path)\n", stderr); exit(1) }
}

/// System rounded font (same family used across the app's HTML export:
/// ui-rounded / SF Pro Rounded), via AppKit's rounded font-descriptor design.
func roundedFont(size: CGFloat, weight: NSFont.Weight) -> CTFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let descriptor = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    let font = NSFont(descriptor: descriptor, size: size) ?? base
    return font as CTFont
}

struct Line {
    let ctLine: CTLine
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
}

func makeLine(_ text: String, font: CTFont, color: CGColor) -> Line {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
    ]
    let attrStr = NSAttributedString(string: text, attributes: attrs)
    let ctLine = CTLineCreateWithAttributedString(attrStr)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let w = CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading)
    return Line(ctLine: ctLine, width: CGFloat(w), ascent: ascent, descent: descent)
}

func drawCentered(_ ctx: CGContext, _ line: Line, centerX: CGFloat, baselineY: CGFloat) {
    ctx.textPosition = CGPoint(x: centerX - line.width / 2, y: baselineY)
    CTLineDraw(line.ctLine, ctx)
}

func drawOGImage(appIconURL: URL, to outURL: URL) {
    let ctx = makeContext(width, height)

    // Background.
    ctx.setFillColor(page)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Layered-stripe band along the top edge — four equal hard-edged bands,
    // matching HTMLExporter's .parfait-bar hard-stop gradient exactly.
    let bandWidth = CGFloat(width) / 4
    let stripeY = CGFloat(height) - stripeHeight
    for (i, color) in [stripeCream, stripeHoney, stripeRaspberry, stripePeriwinkle].enumerated() {
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: CGFloat(i) * bandWidth, y: stripeY, width: bandWidth, height: stripeHeight))
    }

    // App icon, loaded from Resources/AppIcon-1024.png.
    guard let src = CGImageSourceCreateWithURL(appIconURL as CFURL, nil),
          let iconImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { fputs("cannot load \(appIconURL.path)\n", stderr); exit(1) }
    let iconSize: CGFloat = 220

    // Wordmark + tagline lines, measured before layout so the whole block
    // (icon + wordmark + tagline) can be centered as one unit.
    let wordmarkFont = roundedFont(size: 96, weight: .bold)
    let taglineFont = roundedFont(size: 28, weight: .medium)
    let wordmark = makeLine("Parfait", font: wordmarkFont, color: ink)
    let tagline = makeLine("Layered meeting notes. Perfectly local.", font: taglineFont, color: mutedOnPage)

    let gapIconToWordmark: CGFloat = 32
    let gapWordmarkToTagline: CGFloat = 18
    let blockHeight = iconSize + gapIconToWordmark + (wordmark.ascent + wordmark.descent)
        + gapWordmarkToTagline + (tagline.ascent + tagline.descent)

    let usableHeight = CGFloat(height) - stripeHeight
    let topMargin = max(40, (usableHeight - blockHeight) / 2)
    let blockTopOffset = stripeHeight + topMargin // distance from canvas top (y = height) to top of block

    let centerX = CGFloat(width) / 2

    // Icon: top-anchored at blockTopOffset, centered horizontally.
    let iconTopY = CGFloat(height) - blockTopOffset
    let iconRect = CGRect(x: centerX - iconSize / 2, y: iconTopY - iconSize, width: iconSize, height: iconSize)
    ctx.draw(iconImage, in: iconRect)

    // Wordmark, centered, directly below the icon.
    let wordmarkTopOffset = blockTopOffset + iconSize + gapIconToWordmark
    let wordmarkBaselineY = CGFloat(height) - wordmarkTopOffset - wordmark.ascent
    drawCentered(ctx, wordmark, centerX: centerX, baselineY: wordmarkBaselineY)

    // Tagline, centered, directly below the wordmark.
    let taglineTopOffset = wordmarkTopOffset + wordmark.ascent + wordmark.descent + gapWordmarkToTagline
    let taglineBaselineY = CGFloat(height) - taglineTopOffset - tagline.ascent
    drawCentered(ctx, tagline, centerX: centerX, baselineY: taglineBaselineY)

    writePNG(ctx, to: outURL)
}

// MARK: - Driver

let args = CommandLine.arguments
guard args.count == 3 else {
    fputs("usage: swift MakeOGImage.swift <appIconPath> <outdir>\n", stderr)
    exit(1)
}
let appIconURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

drawOGImage(appIconURL: appIconURL, to: outDir.appendingPathComponent("og-image.png"))
print("wrote og-image.png to \(outDir.path)")
