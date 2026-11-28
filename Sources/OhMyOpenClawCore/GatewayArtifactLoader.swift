import Foundation

extension ChatAttachment {
    /// Keep transcript references, including the nested managed-file envelope.
    /// Image previews may fetch references; documents remain explicit-open.
    public static func parse(block: JSONValue, fallbackID: String) -> ChatAttachment? {
        let type = block["type"].stringValue?.lowercased() ?? ""
        guard ["image", "file", "document", "audio", "video", "attachment"].contains(type) else { return nil }
        let nested = type == "attachment" ? block["attachment"] : .null
        let kind = nested["kind"].stringValue ?? type
        let mime = block["mimeType"].stringValue ?? nested["mimeType"].stringValue ?? block["source"]["media_type"].stringValue ?? (kind == "image" ? "image/*" : "application/octet-stream")
        let name = block["fileName"].stringValue ?? nested["label"].stringValue ?? block["name"].stringValue ?? block["title"].stringValue ?? block["alt"].stringValue ?? (kind == "image" ? "画像" : "添付ファイル")
        let url = block["url"].stringValue ?? nested["url"].stringValue
        let openURL = block["openUrl"].stringValue ?? nested["openUrl"].stringValue
        let artifactID = block["artifactId"].stringValue ?? nested["artifactId"].stringValue ?? managedArtifactID(url: url ?? openURL, isImage: kind == "image" || mime.hasPrefix("image/"))
        let base64 = block["source"]["data"].stringValue ?? block["data"].stringValue ?? nested["data"].stringValue ?? ""
        let data = Data(base64Encoded: base64) ?? Data()
        return ChatAttachment(id: artifactID ?? fallbackID, fileName: name, mimeType: mime, data: data, artifactID: artifactID, url: url, openURL: openURL, sizeBytes: block["sizeBytes"].intValue ?? nested["sizeBytes"].intValue)
    }

    private static func managedArtifactID(url: String?, isImage: Bool) -> String? {
        guard let url, let components = URLComponents(string: url), components.scheme == nil, components.host == nil, components.query == nil, components.fragment == nil else { return nil }
        let segments = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count == 7, Array(segments.prefix(4)) == ["api", "chat", "media", "outgoing"], segments[6] == "full",
              let attachmentID = UUID(uuidString: String(segments[5]))?.uuidString.lowercased() else { return nil }
        return (isImage ? "artifact_managed_image_" : "artifact_managed_media_") + attachmentID
    }
}

/// Loads bytes through the currently authenticated socket. Expiring download URLs
/// stay in this call; reusable Gateway credentials are never forwarded over HTTP.
public enum GatewayArtifactLoader {
    public static let maxImageBytes = 12 * 1024 * 1024
    public static let maxFileBytes = 20 * 1024 * 1024

    public static func load(_ attachment: ChatAttachment, session: ChatSession, service: any GatewayServing, endpoint: URL, access: (any CloudflareAccessCredential)? = nil) async throws -> Data {
        let limit = attachment.mimeType.hasPrefix("image/") ? maxImageBytes : maxFileBytes
        if !attachment.data.isEmpty {
            guard attachment.data.count <= limit else { throw tooLarge() }
            return attachment.data
        }
        if attachment.artifactID == nil, let inbound = attachment.inboundMedia {
            return try await service.loadInboundMedia(inbound, session: session)
        }
        guard let artifactID = attachment.artifactID, !artifactID.isEmpty else {
            if attachment.url == nil && attachment.openURL == nil { return attachment.data }
            throw GatewayFailure(code: "ATTACHMENT_UNAVAILABLE", message: "この添付には安全に取得できる参照がありません。Gateway の画面で確認してください。")
        }
        if let size = attachment.sizeBytes, size > limit { throw tooLarge() }
        var params: [String: JSONValue] = ["sessionKey": .string(session.key), "agentId": .string(session.agentID), "artifactId": .string(artifactID)]
        if attachment.mimeType.hasPrefix("image/") { params["previewWidth"] = .number(1200) }
        let response = try await service.request(method: "artifacts.download", params: .object(params))
        try Task.checkCancellation()
        guard response["artifact"]["id"].stringValue == artifactID else {
            throw GatewayFailure(code: "ATTACHMENT_CHANGED", message: "添付ファイルの参照が変わりました。会話を開き直してください。")
        }
        if response["encoding"].stringValue == "base64", let encoded = response["data"].stringValue {
            guard encoded.utf8.count <= ((limit + 2) / 3) * 4, let data = Data(base64Encoded: encoded), data.count <= limit else { throw tooLarge() }
            return data
        }
        guard let reference = response["url"].stringValue else {
            throw GatewayFailure(code: "ATTACHMENT_UNAVAILABLE", message: "この添付ファイルを取得できません。Gateway の画面で確認してください。")
        }
        let url = try trustedDownloadURL(reference, endpoint: endpoint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        let http = URLSession(configuration: configuration, delegate: ArtifactRedirectRefusal(), delegateQueue: nil)
        defer { http.invalidateAndCancel() }
        let (bytes, urlResponse) = try await http.bytes(for: downloadRequest(url, access: access))
        guard let response = urlResponse as? HTTPURLResponse, response.statusCode == 200 else {
            throw GatewayFailure(code: "ATTACHMENT_DOWNLOAD_FAILED", message: "添付ファイルを取得できません。接続を確認してもう一度開いてください。")
        }
        guard response.expectedContentLength <= Int64(limit) else { throw tooLarge() }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in bytes {
            guard data.count < limit else { throw tooLarge() }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }

    /// A download from a URL that `trustedDownloadURL` placed on the Gateway origin.
    static func downloadRequest(_ url: URL, access: (any CloudflareAccessCredential)?) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        access?.apply(to: &request)
        return request
    }

    /// Only Gateway artifact routes on the configured origin/base path may be read.
    /// Model-authored URLs are not a download authority.
    public static func trustedDownloadURL(_ reference: String, endpoint: URL) throws -> URL {
        guard var base = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              let source = URLComponents(string: reference), source.user == nil, source.password == nil, source.fragment == nil else { throw untrusted() }
        switch base.scheme?.lowercased() {
        case "wss": base.scheme = "https"
        case "ws" where ["127.0.0.1", "::1", "localhost"].contains(base.host?.lowercased() ?? ""): base.scheme = "http"
        default: throw untrusted()
        }
        base.query = nil; base.fragment = nil
        var routed = source
        var encodedPrefix = base.percentEncodedPath
        while encodedPrefix.hasSuffix("/") { encodedPrefix.removeLast() }
        // Authenticated RPCs return Gateway-root routes even behind a reverse proxy.
        // Add the configured deployment prefix only to those known relative routes.
        if !encodedPrefix.isEmpty, source.scheme == nil, source.host == nil,
           source.percentEncodedPath.hasPrefix("/api/artifacts/download/") || source.percentEncodedPath.hasPrefix("/api/chat/media/outgoing/") {
            routed.percentEncodedPath = encodedPrefix + source.percentEncodedPath
        }
        guard base.user == nil, base.password == nil, let origin = base.url,
              !reference.hasPrefix("//"), let routedReference = routed.string,
              let resolved = URL(string: routedReference, relativeTo: origin)?.absoluteURL,
              let target = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              target.user == nil, target.password == nil, target.fragment == nil,
              target.scheme?.lowercased() == base.scheme, target.host?.lowercased() == base.host?.lowercased(),
              effectivePort(target) == effectivePort(base) else { throw untrusted() }
        // Encoded path separators or dot segments could escape a reverse-proxy prefix.
        let encoded = target.percentEncodedPath.lowercased()
        guard !encoded.contains("%2f"), !encoded.contains("%5c"), !encoded.contains("%2e"), !encoded.contains("\\") else { throw untrusted() }
        let path = target.path
        var prefix = base.path
        while prefix.hasSuffix("/") { prefix.removeLast() }
        let relativePath: String
        if prefix.isEmpty { relativePath = path }
        else {
            guard path.hasPrefix(prefix + "/") else { throw untrusted() }
            relativePath = String(path.dropFirst(prefix.count))
        }
        guard relativePath.hasPrefix("/api/artifacts/download/") || relativePath.hasPrefix("/api/chat/media/outgoing/") else { throw untrusted() }
        guard !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { throw untrusted() }
        return resolved
    }

    private static func effectivePort(_ components: URLComponents) -> Int { components.port ?? (components.scheme?.lowercased() == "https" ? 443 : 80) }
    private static func tooLarge() -> GatewayFailure { GatewayFailure(code: "ATTACHMENT_TOO_LARGE", message: "この添付ファイルは表示できるサイズを超えています。Gateway の画面で確認してください。") }
    private static func untrusted() -> GatewayFailure { GatewayFailure(code: "UNTRUSTED_ATTACHMENT_URL", message: "接続先と異なる場所の添付は、このアプリから取得しません。") }
}

private final class ArtifactRedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
