import CryptoKit
import Foundation

/// Minimal AWS Signature V4 implementation for Cloudflare R2's S3-compatible API.
/// R2 uses region "auto" and service "s3".
struct SigV4Signer: Sendable {
    let accessKeyId: String
    let secretAccessKey: String
    let region = "auto"
    let service = "s3"

    static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    // MARK: - Header-signed request (used for list calls)

    func sign(_ request: inout URLRequest) {
        guard let url = request.url, let host = url.host else { return }
        let (amzDate, dateStamp) = Self.timestamps(Date())
        let payloadHash = Self.emptyPayloadHash
        let method = request.httpMethod ?? "GET"
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host

        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        let headers: [(String, String)] = [
            ("host", hostHeader),
            ("x-amz-content-sha256", payloadHash),
            ("x-amz-date", amzDate),
        ]
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalHeaders = headers.map { "\($0.0):\($0.1.trimmingCharacters(in: .whitespaces))\n" }.joined()

        let canonicalRequest = [
            method,
            Self.canonicalURI(url),
            Self.canonicalQuery(url),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let signature = signature(canonicalRequest: canonicalRequest, amzDate: amzDate, dateStamp: dateStamp, scope: scope)
        let auth = "AWS4-HMAC-SHA256 Credential=\(accessKeyId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(auth, forHTTPHeaderField: "Authorization")
    }

    // MARK: - Presigned URL (used by AVPlayer / thumbnail generator)

    /// Returns a query-string-authenticated URL. `expires` is clamped to 1s...7 days (S3 maximum).
    func presign(url: URL, expires: TimeInterval) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = url.host else { return url }
        let (amzDate, dateStamp) = Self.timestamps(Date())
        let scope = "\(dateStamp)/\(region)/\(service)/aws4_request"
        let expiresSeconds = Int(min(max(expires, 1), 604_800))
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host

        var items = comps.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "X-Amz-Algorithm", value: "AWS4-HMAC-SHA256"),
            URLQueryItem(name: "X-Amz-Credential", value: "\(accessKeyId)/\(scope)"),
            URLQueryItem(name: "X-Amz-Date", value: amzDate),
            URLQueryItem(name: "X-Amz-Expires", value: String(expiresSeconds)),
            URLQueryItem(name: "X-Amz-SignedHeaders", value: "host"),
        ])
        let query = Self.canonicalQuery(items)

        let canonicalRequest = [
            "GET",
            Self.canonicalURI(url),
            query,
            "host:\(hostHeader)\n",
            "host",
            "UNSIGNED-PAYLOAD",
        ].joined(separator: "\n")

        let signature = signature(canonicalRequest: canonicalRequest, amzDate: amzDate, dateStamp: dateStamp, scope: scope)
        // Build the final URL using our own encoding so the server sees exactly what we signed.
        comps.percentEncodedQuery = query + "&X-Amz-Signature=" + signature
        return comps.url ?? url
    }

    // MARK: - Internals

    private func signature(canonicalRequest: String, amzDate: String, dateStamp: String, scope: String) -> String {
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(secretAccessKey)".utf8))
        for part in [dateStamp, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let sig = HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key)
        return Data(sig).hexString
    }

    static func sha256Hex(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hexString
    }

    static func timestamps(_ date: Date) -> (amzDate: String, dateStamp: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amz = f.string(from: date)
        return (amz, String(amz.prefix(8)))
    }

    /// RFC 3986 unreserved characters — the only ones SigV4 leaves unencoded.
    static let unreserved: CharacterSet = {
        var s = CharacterSet()
        s.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s
    }()

    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }

    /// Path is already percent-encoded by the client (each segment via `encode`); S3 does not double-encode.
    static func canonicalURI(_ url: URL) -> String {
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = comps?.percentEncodedPath ?? "/"
        return path.isEmpty ? "/" : path
    }

    static func canonicalQuery(_ url: URL) -> String {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return "" }
        return canonicalQuery(items)
    }

    static func canonicalQuery(_ items: [URLQueryItem]) -> String {
        items.map { (encode($0.name), encode($0.value ?? "")) }
            .sorted(by: <)
            .map { $0.0 + "=" + $0.1 }
            .joined(separator: "&")
    }
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
