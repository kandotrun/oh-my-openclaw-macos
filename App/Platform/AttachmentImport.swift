import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns picked, dropped, or pasted content into attachment bytes the Gateway accepts.
enum AttachmentImport {
    struct Loaded: Sendable, Equatable {
        let data: Data
        let fileName: String
        let mimeType: String
    }

    enum Failure: LocalizedError, Equatable {
        case tooLarge, invalidImage, unreadable
        var errorDescription: String? {
            switch self {
            case .tooLarge: "ファイルが大きすぎます。小さいファイルを選んでください。"
            case .invalidImage: "この画像を読み込めませんでした。別の画像を選んでください。"
            case .unreadable: "ファイルを読み込めませんでした。アクセス権を確認してください。"
            }
        }
    }

    static let fileLimit = 25 * 1024 * 1024
    static let imageLimit = 6 * 1024 * 1024
    private static let maxPixelSize = 2048

    /// PNG and JPEG within the limit keep their bytes, so screenshots stay sharp.
    /// Other formats and oversized images become a JPEG of at most 2048 pixels.
    static func image(data: Data, fileName: String, limit: Int = imageLimit) throws -> Loaded {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source).map({ UTType($0 as String) }) ?? nil else {
            throw Failure.invalidImage
        }
        if data.count <= limit, type == .png || type == .jpeg, let mime = type.preferredMIMEType {
            return Loaded(data: data, fileName: fileName, mimeType: mime)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else { throw Failure.invalidImage }
        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.invalidImage }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalidImage }
        guard jpeg.length <= limit else { throw Failure.tooLarge }
        let base = (fileName as NSString).deletingPathExtension
        return Loaded(data: jpeg as Data, fileName: (base.isEmpty ? "Image" : base) + ".jpg", mimeType: "image/jpeg")
    }

    /// Reads a user-selected file. Images go through `image` so they fit the Gateway's limits.
    static func file(url: URL, limit: Int = fileLimit, imageLimit: Int = imageLimit) throws -> Loaded {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard let values, values.isRegularFile != false else { throw Failure.unreadable }
        guard let size = values.fileSize, size <= limit else { throw Failure.tooLarge }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Failure.unreadable }
        guard data.count <= limit else { throw Failure.tooLarge }
        let type = UTType(filenameExtension: url.pathExtension)
        // Decodable images must fit the image limit; formats ImageIO cannot read, such as SVG, travel as plain files.
        if let type, type.conforms(to: .image), let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 {
            return try image(data: data, fileName: url.lastPathComponent, limit: imageLimit)
        }
        return Loaded(data: data, fileName: url.lastPathComponent, mimeType: type?.preferredMIMEType ?? "application/octet-stream")
    }
}
