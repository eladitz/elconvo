// Image formats ImageIO can't write, done here so the App Store build needs no ImageMagick:
// Radiance HDR (RGBE), EPS (AppKit's PostScript) and WBMP (1-bit wireless bitmap).

import AppKit

enum ImageWriters {
    static func write(_ png: URL, as id: String, to out: URL) throws {
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ConvertError("Couldn't read the image.") }
        switch id {
        case "hdr": try hdr(image).write(to: out)
        case "wbmp": try wbmp(image).write(to: out)
        case "eps":
            // AppKit views belong to the main thread; conversions may run elsewhere.
            let data = Thread.isMainThread ? MainActor.assumeIsolated { eps(image) }
                : DispatchQueue.main.sync { MainActor.assumeIsolated { eps(image) } }
            try data.write(to: out)
        default: throw ConvertError("Elconvo can't write .\(id) here.")
        }
    }

    /// RGBA pixels, drawn into a known layout.
    private static func pixels<T: Numeric>(_ image: CGImage, _ type: T.Type, space: CGColorSpace, bits: Int, info: UInt32) -> [T] {
        let w = image.width, h = image.height
        var buffer = [T](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: bits, bytesPerRow: w * 4 * bits / 8,
                                space: space, bitmapInfo: info)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buffer
    }

    /// Radiance HDR: a text header, then each pixel as a shared exponent plus three mantissas, in linear light.
    static func hdr(_ image: CGImage) -> Data {
        let w = image.width, h = image.height
        let floats = pixels(image, Float.self, space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, bits: 32,
                            info: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        var data = Data("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y \(h) +X \(w)\n".utf8)
        data.reserveCapacity(data.count + w * h * 4)
        for i in stride(from: 0, to: floats.count, by: 4) {
            let a = max(floats[i + 3], 1e-6)
            let r = max(0, floats[i] / a), g = max(0, floats[i + 1] / a), b = max(0, floats[i + 2] / a)
            let biggest = max(r, g, b)
            if biggest < 1e-32 { data.append(contentsOf: [0, 0, 0, 0]); continue }
            let e = frexp(biggest).1
            let scale = Float(sign: .plus, exponent: -e, significand: 1) * 256
            data.append(contentsOf: [UInt8(min(255, r * scale)), UInt8(min(255, g * scale)), UInt8(min(255, b * scale)), UInt8(e + 128)])
        }
        return data
    }

    /// WBMP type 0: black and white, one bit a pixel, light pixels white.
    static func wbmp(_ image: CGImage) -> Data {
        let w = image.width, h = image.height
        let rgba = pixels(image, UInt8.self, space: CGColorSpace(name: CGColorSpace.sRGB)!, bits: 8,
                          info: CGImageAlphaInfo.premultipliedLast.rawValue)
        func multibyte(_ n: Int) -> [UInt8] {   // 7 bits per byte, high bit = more follows
            var bytes = [UInt8(n & 0x7F)]
            var rest = n >> 7
            while rest > 0 { bytes.insert(UInt8(0x80 | (rest & 0x7F)), at: 0); rest >>= 7 }
            return bytes
        }
        var data = Data([0, 0] + multibyte(w) + multibyte(h))
        let rowBytes = (w + 7) / 8
        for y in 0..<h {
            var row = [UInt8](repeating: 0, count: rowBytes)
            for x in 0..<w {
                let i = (y * w + x) * 4
                // Over white, as the transparent parts would print.
                let a = Int(rgba[i + 3]), light = (Int(rgba[i]) * 299 + Int(rgba[i + 1]) * 587 + Int(rgba[i + 2]) * 114) / 1000 + (255 - a)
                if light >= 128 { row[x / 8] |= UInt8(0x80 >> (x % 8)) }
            }
            data.append(contentsOf: row)
        }
        return data
    }

    /// EPS through AppKit, which writes PostScript with the picture inside.
    @MainActor
    static func eps(_ image: CGImage) -> Data {
        let size = NSSize(width: image.width, height: image.height)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.imageScaling = .scaleAxesIndependently
        view.image = NSImage(cgImage: image, size: size)
        return view.dataWithEPS(inside: view.bounds)
    }
}
