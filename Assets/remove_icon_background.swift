import AppKit
import CoreGraphics
import Foundation

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let image = NSImage(contentsOf: inputURL),
      let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("无法读取源图")
}

let width = source.width
let height = source.height
let bytesPerPixel = 4
let bytesPerRow = width * bytesPerPixel
var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let context = CGContext(
    data: &pixels,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("无法创建图像上下文")
}

context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

for y in 0..<height {
    for x in 0..<width {
        let index = y * bytesPerRow + x * bytesPerPixel
        let r = Double(pixels[index])
        let g = Double(pixels[index + 1])
        let b = Double(pixels[index + 2])
        let brightness = (r + g + b) / 3.0
        let chroma = max(r, g, b) - min(r, g, b)

        // 只处理接近纯白、低色差的外围底色；阴影和图标内部的暖白色保留。
        let whiteness = min(1.0, max(0.0, (brightness - 236.0) / 17.0))
        let neutral = min(1.0, max(0.0, (12.0 - chroma) / 12.0))
        let edgeDistance = min(min(x, width - 1 - x), min(y, height - 1 - y))
        let edgeWeight = min(1.0, max(0.0, Double(150 - edgeDistance) / 90.0))
        let removal = whiteness * neutral * edgeWeight

        if removal > 0 {
            let alpha = Double(pixels[index + 3]) * (1.0 - removal)
            pixels[index + 3] = UInt8(max(0, min(255, alpha.rounded())))
        }
    }
}

guard let result = context.makeImage() else {
    fatalError("无法生成透明图像")
}
let bitmap = NSBitmapImageRep(cgImage: result)
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("无法编码 PNG")
}
try png.write(to: outputURL)
