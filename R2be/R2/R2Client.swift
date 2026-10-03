import Foundation

struct R2Credentials: Codable, Hashable, Sendable {
    enum Jurisdiction: String, Codable, CaseIterable, Sendable {
        case standard, eu, fedramp
        var label: String {
            switch self {
            case .standard: return "Default"
            case .eu: return "EU"
            case .fedramp: return "FedRAMP"
            }
        }
    }

    var accountId: String
    var accessKeyId: String
    var secretAccessKey: String
    var bucket: String
    var jurisdiction: Jurisdiction = .standard

    /// Only this folder is indexed; nil or empty indexes the whole bucket.
    /// Optional so connections saved before this field existed still decode.
    var folder: String?

    /// `folder` as a list prefix: "dfvl/clips" → "dfvl/clips/", empty → "".
    var rootPrefix: String {
        let f = (folder ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return f.isEmpty ? "" : f + "/"
    }

    var endpoint: URL {
        let id = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        switch jurisdiction {
        case .standard: return URL(string: "https://\(id).r2.cloudflarestorage.com")!
        case .eu: return URL(string: "https://\(id).eu.r2.cloudflarestorage.com")!
        case .fedramp: return URL(string: "https://\(id).fedramp.r2.cloudflarestorage.com")!
        }
    }
}

struct R2Object: Hashable, Codable, Sendable {
    var key: String
    var size: Int64
    var lastModified: Date?
    var etag: String
}

struct ListPage: Sendable {
    var objects: [R2Object] = []
    var isTruncated = false
    var nextContinuationToken: String?
}

enum R2Error: LocalizedError {
    case http(Int, String)
    case badResponse
    case invalidCredentials

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            let s3Code = S3ErrorParser.code(in: body) ?? ""
            switch code {
            case 401, 403:
                return "Access denied (\(code) \(s3Code)). Check the Access Key, Secret and that the token can read this bucket."
            case 404:
                return "Not found (\(s3Code)). Check the bucket name and Account ID."
            default:
                return "R2 returned HTTP \(code) \(s3Code)"
            }
        case .badResponse: return "Unexpected response from R2."
        case .invalidCredentials: return "Fill in Account ID, Access Key ID and Secret."
        }
    }
}

/// Thin S3-compatible client for the handful of R2 calls the app needs. Read-only by design:
/// the app never writes to, moves, or deletes anything in the bucket.
struct R2Client: Sendable {
    let credentials: R2Credentials
    var session: URLSession = .shared

    private var signer: SigV4Signer {
        SigV4Signer(accessKeyId: credentials.accessKeyId.trimmingCharacters(in: .whitespacesAndNewlines),
                    secretAccessKey: credentials.secretAccessKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: URL building

    func objectURL(bucket: String, key: String) -> URL {
        var comps = URLComponents(url: credentials.endpoint, resolvingAgainstBaseURL: false)!
        let encodedKey = key.split(separator: "/", omittingEmptySubsequences: false)
            .map { SigV4Signer.encode(String($0)) }
            .joined(separator: "/")
        comps.percentEncodedPath = "/" + SigV4Signer.encode(bucket) + "/" + encodedKey
        return comps.url!
    }

    private func bucketURL(_ bucket: String?, query: [URLQueryItem]) -> URL {
        var comps = URLComponents(url: credentials.endpoint, resolvingAgainstBaseURL: false)!
        comps.percentEncodedPath = bucket.map { "/" + SigV4Signer.encode($0) } ?? "/"
        if !query.isEmpty { comps.percentEncodedQuery = SigV4Signer.canonicalQuery(query) }
        return comps.url!
    }

    /// Streamable, time-limited URL for AVPlayer. R2 honours Range requests, so seeking works.
    func presignedURL(bucket: String, key: String, expires: TimeInterval = 6 * 3600) -> URL {
        signer.presign(url: objectURL(bucket: bucket, key: key), expires: expires)
    }

    // MARK: Calls

    func listBuckets() async throws -> [String] {
        let data = try await get(bucketURL(nil, query: []))
        return BucketListParser.parse(data)
    }

    func listObjects(bucket: String, prefix: String = "", continuationToken: String? = nil, maxKeys: Int = 1000) async throws -> ListPage {
        var q = [URLQueryItem(name: "list-type", value: "2"),
                 URLQueryItem(name: "max-keys", value: String(maxKeys))]
        if !prefix.isEmpty { q.append(URLQueryItem(name: "prefix", value: prefix)) }
        if let continuationToken { q.append(URLQueryItem(name: "continuation-token", value: continuationToken)) }
        let data = try await get(bucketURL(bucket, query: q))
        guard let page = ListObjectsParser.parse(data) else { throw R2Error.badResponse }
        return page
    }

    private func get(_ url: URL) async throws -> Data {
        guard !credentials.accountId.isEmpty, !credentials.accessKeyId.isEmpty, !credentials.secretAccessKey.isEmpty else {
            throw R2Error.invalidCredentials
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 30
        signer.sign(&req)
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw R2Error.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw R2Error.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
