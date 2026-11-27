import AppKit

let file = URL(fileURLWithPath: CommandLine.arguments[1])
func bigEndian(_ value: Int) -> Data {
    var word = UInt32(value).bigEndian
    return withUnsafeBytes(of: &word) { Data($0) }
}
var payload = Data()
for (type, pixels) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
                       ("ic08", 256), ("ic09", 512), ("ic10", 1024)] {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: Double(pixels) / 100, y: Double(pixels) / 100)
    func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(red: r, green: g, blue: b, alpha: a)
    }
    let tile = CGPath(roundedRect: CGRect(x: 6, y: 6, width: 88, height: 88), cornerWidth: 20, cornerHeight: 20, transform: nil)
    ctx.addPath(tile)
    ctx.setFillColor(rgb(0.067, 0.09, 0.135))
    ctx.fillPath()
    ctx.addPath(tile)
    ctx.setStrokeColor(rgb(0.35, 0.87, 0.74, 0.55))
    ctx.setLineWidth(2)
    ctx.strokePath()
    if pixels >= 64 {
        ctx.setStrokeColor(rgb(0.35, 0.87, 0.74, 0.15))
        ctx.setLineWidth(0.6)
        for v in stride(from: 21.0, through: 79.0, by: 9.5) {
            ctx.move(to: CGPoint(x: 20, y: v))
            ctx.addLine(to: CGPoint(x: 80, y: v))
            ctx.move(to: CGPoint(x: v, y: 20))
            ctx.addLine(to: CGPoint(x: v, y: 80))
        }
        ctx.strokePath()
    }
    let points = [(20.0, 48.0), (34, 48), (42, 59), (49, 30), (59, 70), (67, 48), (80, 48)]
    ctx.setLineWidth(pixels < 32 ? 5.2 : 4.1)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(rgb(0.38, 0.89, 0.77))
    ctx.move(to: CGPoint(x: points[0].0, y: points[0].1))
    for (x,y) in points.dropFirst() { ctx.addLine(to: CGPoint(x: x, y: y)) }
    ctx.strokePath()
    let png = NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    payload.append(Data(type.utf8))
    payload.append(bigEndian(png.count + 8))
    payload.append(png)
}
let header = Data("icns".utf8) + bigEndian(payload.count + 8)
try (header + payload).write(to: file, options: .atomic)
