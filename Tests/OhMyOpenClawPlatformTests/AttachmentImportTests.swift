import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OhMyOpenClawPlatform

/// Encodes a noisy test image so compression cannot make it trivially small.
private func encodedImage(width: Int, height: Int, type: UTType) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    var generator = SystemRandomNumberGenerator()
    for y in stride(from: 0, to: height, by: 16) {
        for x in stride(from: 0, to: width, by: 16) {
            context.setFillColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator), blue: .random(in: 0...1, using: &generator), alpha: 1)
            context.fill(CGRect(x: x, y: y, width: 16, height: 16))
        }
    }
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
    // Like a camera original, lossy fixtures use the highest quality.
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private func pixelSize(_ data: Data) -> (Int, Int)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (width, height)
}

@Test func pngWithinTheLimitKeepsItsBytesForSharpScreenshots() throws {
    let png = try encodedImage(width: 64, height: 64, type: .png)
    let loaded = try AttachmentImport.image(data: png, fileName: "Screenshot.png", limit: 6 * 1024 * 1024)
    #expect(loaded.data == png)
    #expect(loaded.mimeType == "image/png")
    #expect(loaded.fileName == "Screenshot.png")
}

@Test func otherImageFormatsBecomeJPEG() throws {
    let tiff = try encodedImage(width: 64, height: 64, type: .tiff)
    let loaded = try AttachmentImport.image(data: tiff, fileName: "Pasted.tiff", limit: 6 * 1024 * 1024)
    #expect(loaded.mimeType == "image/jpeg")
    #expect(loaded.data.prefix(2) == Data([0xFF, 0xD8]))
    #expect(loaded.fileName == "Pasted.jpg")
}

@Test func oversizedImagesAreDownscaledToFitTheLimit() throws {
    // Downscaling to 2048 px keeps under half the pixels, so the re-encoded JPEG fits.
    let large = try encodedImage(width: 3000, height: 1500, type: .jpeg)
    let limit = large.count * 3 / 4
    let loaded = try AttachmentImport.image(data: large, fileName: "Large.jpg", limit: limit)
    #expect(loaded.mimeType == "image/jpeg")
    #expect(loaded.data.count <= limit)
    let size = try #require(pixelSize(loaded.data))
    #expect(max(size.0, size.1) <= 2048)
}

@Test func undecodableImageDataIsRejected() {
    #expect(throws: AttachmentImport.Failure.invalidImage) {
        try AttachmentImport.image(data: Data("not an image".utf8), fileName: "x.png", limit: 1024)
    }
}

@Test func filesKeepTheirBytesAndGainAMIMEType() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("notes-\(UUID().uuidString).md")
    try Data("# Notes".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let loaded = try AttachmentImport.file(url: url, limit: 1024)
    #expect(loaded.data == Data("# Notes".utf8))
    #expect(loaded.fileName == url.lastPathComponent)
    #expect(loaded.mimeType == "text/markdown")
}

@Test func filesOverTheLimitAreRejected() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("big-\(UUID().uuidString).bin")
    try Data(count: 2048).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: AttachmentImport.Failure.tooLarge) { try AttachmentImport.file(url: url, limit: 1024) }
}

@Test func aRecognizedImageFileThatCannotFitIsRejectedInsteadOfSentRaw() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("photo-\(UUID().uuidString).png")
    try encodedImage(width: 64, height: 64, type: .png).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: AttachmentImport.Failure.tooLarge) { try AttachmentImport.file(url: url, imageLimit: 16) }
}

@Test func anImageTypeImageIOCannotDecodeTravelsAsAFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("logo-\(UUID().uuidString).svg")
    let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>"#.utf8)
    try svg.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let loaded = try AttachmentImport.file(url: url, imageLimit: 16)
    #expect(loaded.data == svg)
    #expect(loaded.mimeType == "image/svg+xml")
}
