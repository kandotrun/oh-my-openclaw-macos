import Foundation

/// The metadata request uses only this paired device's token at a fixed Gateway
/// route. Image bytes use a short-lived ticket; neither credential is persisted.
enum GatewayInboundMediaLoader {
    static let metadataLimit = 64 * 1024
    static let imageLimit = 12 * 1024 * 1024
    typealias Fetch = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

    static func load(_ reference: InboundMediaReference, session: ChatSession, endpoint: URL, deviceToken: String, access: (any CloudflareAccessCredential)? = nil) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let http = URLSession(configuration: configuration, delegate: InboundMediaRedirectRefusal(), delegateQueue: nil)
        defer { http.invalidateAndCancel() }
        do {
            return try await load(reference, session: session, endpoint: endpoint, deviceToken: deviceToken, access: access) { request, limit in
                let (bytes, response) = try await http.bytes(for: request)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw unavailable() }
                guard response.expectedContentLength <= Int64(limit) else { throw tooLarge() }
                var data = Data()
                if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
                for try await byte in bytes {
                    guard data.count < limit else { throw tooLarge() }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return (data, response)
            }
        } catch is CancellationError { throw CancellationError() }
        catch let failure as GatewayFailure { throw failure }
        catch { throw unavailable() }
    }

    /// Injectable bounded transport keeps the credential and route contract testable.
    static func load(_ reference: InboundMediaReference, session: ChatSession, endpoint: URL, deviceToken: String, access: (any CloudflareAccessCredential)? = nil, fetch: Fetch) async throws -> Data {
        let metadataRequest = try metadataRequest(reference, session: session, endpoint: endpoint, deviceToken: deviceToken, access: access)
        let (metadataData, metadataResponse) = try await fetch(metadataRequest, metadataLimit)
        try Task.checkCancellation()
        guard metadataResponse.statusCode == 200, metadataResponse.mimeType?.lowercased() == "application/json" else { throw unavailable() }
        guard metadataData.count <= metadataLimit else { throw tooLarge() }
        guard let metadata = try? JSONDecoder().decode(JSONValue.self, from: metadataData),
              metadata["available"].boolValue == true,
              metadata["mimeType"].stringValue?.lowercased().hasPrefix("image/") == true,
              let ticket = metadata["mediaTicket"].stringValue, validHeaderValue(ticket),
              let expiry = metadata["mediaTicketExpiresAt"].stringValue,
              let date = ticketExpiry(expiry), date > Date() else { throw unavailable() }
        if let size = metadata["sizeBytes"].intValue, size < 0 || size > imageLimit { throw tooLarge() }
        let request = try bytesRequest(reference, session: session, endpoint: endpoint, mediaTicket: ticket, access: access)
        let (data, response) = try await fetch(request, imageLimit)
        try Task.checkCancellation()
        guard response.statusCode == 200, response.mimeType?.lowercased().hasPrefix("image/") == true, !data.isEmpty else { throw unavailable() }
        guard data.count <= imageLimit else { throw tooLarge() }
        return data
    }

    static func metadataRequest(_ reference: InboundMediaReference, session: ChatSession, endpoint: URL, deviceToken: String, access: (any CloudflareAccessCredential)? = nil) throws -> URLRequest {
        guard validHeaderValue(deviceToken) else { throw unavailable() }
        var request = try request(reference, session: session, endpoint: endpoint, access: access, extra: [URLQueryItem(name: "meta", value: "1")])
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + deviceToken, forHTTPHeaderField: "Authorization")
        return request
    }

    static func bytesRequest(_ reference: InboundMediaReference, session: ChatSession, endpoint: URL, mediaTicket: String, access: (any CloudflareAccessCredential)? = nil) throws -> URLRequest {
        guard validHeaderValue(mediaTicket) else { throw unavailable() }
        var request = try request(reference, session: session, endpoint: endpoint, access: access, extra: [
            URLQueryItem(name: "mediaTicket", value: mediaTicket),
            URLQueryItem(name: "variant", value: "thumbnail"),
            URLQueryItem(name: "width", value: "960"),
        ])
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        return request
    }

    private static func request(_ reference: InboundMediaReference, session: ChatSession, endpoint: URL, access: (any CloudflareAccessCredential)?, extra: [URLQueryItem]) throws -> URLRequest {
        guard InboundMediaReference(source: reference.source, messageID: reference.messageID) != nil,
              !session.key.isEmpty, !session.agentID.isEmpty,
              let physicalID = session.sessionID, !physicalID.isEmpty else { throw unavailable() }
        let validated = try GatewayEndpoint.parse(endpoint.absoluteString)
        guard var parts = URLComponents(url: validated, resolvingAgainstBaseURL: false) else { throw unavailable() }
        parts.scheme = parts.scheme == "wss" ? "https" : "http"
        var prefix = parts.percentEncodedPath
        while prefix.hasSuffix("/") { prefix.removeLast() }
        let encoded = prefix.lowercased()
        guard !encoded.contains("%2f"), !encoded.contains("%5c"), !encoded.contains("%2e"), !prefix.contains("\\"),
              !parts.path.split(separator: "/").contains("..") else { throw unavailable() }
        parts.percentEncodedPath = prefix + "/__openclaw__/assistant-media"
        parts.queryItems = [
            URLQueryItem(name: "source", value: reference.source),
            URLQueryItem(name: "sessionKey", value: session.key),
            URLQueryItem(name: "agentId", value: session.agentID),
            URLQueryItem(name: "messageId", value: reference.messageID),
        ] + extra
        guard let url = parts.url else { throw unavailable() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        access?.apply(to: &request)
        return request
    }

    private static func validHeaderValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func ticketExpiry(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func unavailable() -> GatewayFailure {
        GatewayFailure(code: "ATTACHMENT_UNAVAILABLE", message: "画像を取得できません。接続を確認して、もう一度開いてください。")
    }
    private static func tooLarge() -> GatewayFailure {
        GatewayFailure(code: "ATTACHMENT_TOO_LARGE", message: "この画像は表示できるサイズを超えています。Gateway の画面で確認してください。")
    }
}

final class InboundMediaRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
