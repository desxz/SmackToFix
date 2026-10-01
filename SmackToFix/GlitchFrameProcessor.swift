import CoreImage
import CoreVideo
import Foundation

/// Bends one captured frame: RGB split, horizontal sync jitter, scanlines, and the occasional roll.
final class GlitchFrameProcessor {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var time: Double = 0

    func process(pixelBuffer: CVPixelBuffer) -> CGImage? {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = source.extent
        guard extent.width > 2, extent.height > 2, extent.isInfinite == false else { return nil }
        time += 1.0 / 30.0
        let split = rgbSplit(source, extent: extent)
        let torn = jitter(split, extent: extent)
        let lined = scanlines(torn, extent: extent)
        let rolled = roll(lined, extent: extent)
        return context.createCGImage(rolled, from: extent)
    }

    private func rgbSplit(_ image: CIImage, extent: CGRect) -> CIImage {
        let shift = CGFloat(4 + 7 * abs(sin(time * 9)))
        let red = channel(image, red: 1, green: 0, blue: 0)
            .transformed(by: CGAffineTransform(translationX: shift, y: 0))
        let green = channel(image, red: 0, green: 1, blue: 0)
        let blue = channel(image, red: 0, green: 0, blue: 1)
            .transformed(by: CGAffineTransform(translationX: -shift, y: 0))
        return red
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: blue])
            .cropped(to: extent)
    }

    private func channel(_ image: CIImage, red: CGFloat, green: CGFloat, blue: CGFloat) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: red, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: green, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: blue, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
    }

    private func jitter(_ image: CIImage, extent: CGRect) -> CIImage {
        guard let map = displacementMap(extent: extent) else { return image }
        let scale = 18 + 46 * abs(sin(time * 5.5))
        return image
            .applyingFilter("CIDisplacementDistortion", parameters: [
                "inputDisplacementImage": map,
                kCIInputScaleKey: scale,
            ])
            .cropped(to: extent)
    }

    private func displacementMap(extent: CGRect) -> CIImage? {
        let bands = 72
        var pixels = [UInt8](repeating: 0, count: bands * 4)
        for index in 0..<bands {
            let wobble = sin(time * 18 + Double(index) * 0.55)
            let tear = sin(time * 7 + Double(index)) > 0.92 ? 1.0 : 0.0
            let centered = wobble * 0.35 + tear * 0.5
            let value = UInt8(clamping: Int((0.5 + centered * 0.5) * 255))
            pixels[index * 4] = value
            pixels[index * 4 + 1] = 128
            pixels[index * 4 + 2] = 128
            pixels[index * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: 1,
            height: bands,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        let scaled = CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(scaleX: extent.width, y: extent.height / CGFloat(bands)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return scaled.cropped(to: extent)
    }

    private func scanlines(_ image: CIImage, extent: CGRect) -> CIImage {
        let stripes = CIFilter(name: "CIStripesGenerator")
        stripes?.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: "inputCenter")
        stripes?.setValue(CIColor(red: 0, green: 0, blue: 0, alpha: 1), forKey: "inputColor0")
        stripes?.setValue(CIColor(red: 1, green: 1, blue: 1, alpha: 1), forKey: "inputColor1")
        stripes?.setValue(1.6, forKey: "inputWidth")
        stripes?.setValue(1.0, forKey: "inputSharpness")
        guard let stripeImage = stripes?.outputImage?.cropped(to: extent) else { return image }
        return stripeImage
            .applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            .cropped(to: extent)
    }

    private func roll(_ image: CIImage, extent: CGRect) -> CIImage {
        guard sin(time * 1.7) > 0.72 else { return image }
        let dy = CGFloat(sin(time * 9)) * extent.height * 0.22
        let shifted = image.transformed(by: CGAffineTransform(translationX: 0, y: dy))
        let sign: CGFloat = dy >= 0 ? -1 : 1
        let wrapped = image.transformed(by: CGAffineTransform(translationX: 0, y: dy + sign * extent.height))
        return shifted.composited(over: wrapped).cropped(to: extent)
    }
}
