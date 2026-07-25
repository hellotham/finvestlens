import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// A 1200x630 social card: the brand gradient, the app icon, name and tagline.
// Built here rather than hand-exported so it can be regenerated when the
// wording changes.
let iconURL = URL(fileURLWithPath: CommandLine.arguments[1])
let out = URL(fileURLWithPath: CommandLine.arguments[2])
let W = 1200, H = 630
let Wf = CGFloat(W), Hf = CGFloat(H)

guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                          bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// Background: the icon's violet → mauve → coral gradient, on the diagonal.
let space = CGColorSpaceCreateDeviceRGB()
let colours = [
    CGColor(red: 0.545, green: 0.482, blue: 0.847, alpha: 1),
    CGColor(red: 0.788, green: 0.545, blue: 0.659, alpha: 1),
    CGColor(red: 0.941, green: 0.659, blue: 0.471, alpha: 1),
] as CFArray
guard let gradient = CGGradient(colorsSpace: space, colors: colours,
                                locations: [0, 0.55, 1]) else { exit(1) }
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: H),
                       end: CGPoint(x: W, y: 0), options: [])

// A soft dark panel so the type stays legible over the gradient.
ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 0.82))
let panel = CGPath(roundedRect: CGRect(x: 56, y: 56, width: W - 112, height: H - 112),
                   cornerWidth: 36, cornerHeight: 36, transform: nil)
ctx.addPath(panel)
ctx.fillPath()

// Icon.
if let s = CGImageSourceCreateWithURL(iconURL as CFURL, nil),
   let icon = CGImageSourceCreateImageAtIndex(s, 0, nil) {
    ctx.draw(icon, in: CGRect(x: 112, y: Hf - 112 - 128, width: 128, height: 128))
}

func draw(_ text: String, size: CGFloat, weight: NSFont.Weight,
          x: CGFloat, y: CGFloat, colour: NSColor, maxWidth: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byWordWrapping
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: colour,
        .paragraphStyle: style,
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    let framesetter = CTFramesetterCreateWithAttributedString(s)
    let path = CGPath(rect: CGRect(x: x, y: y - 400, width: maxWidth, height: 400), transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
    CTFrameDraw(frame, ctx)
}

draw("FinvestLens", size: 76, weight: .bold, x: 112, y: Hf - 300,
     colour: .white, maxWidth: Wf - 224)
draw("Double-entry accounting that belongs on a Mac.",
     size: 38, weight: .regular, x: 112, y: Hf - 400,
     colour: NSColor.white.withAlphaComponent(0.82), maxWidth: Wf - 260)
draw("Published by Hello Tham  ·  Free software, GPL v3",
     size: 25, weight: .medium, x: 112, y: 150,
     colour: NSColor.white.withAlphaComponent(0.6), maxWidth: Wf - 224)

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out.lastPathComponent) \(W)x\(H)")
