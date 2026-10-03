import Foundation

/// Generic flat XML walker: records element paths and text so the specific parsers stay tiny.
private final class XMLWalker: NSObject, XMLParserDelegate {
    var onStart: ((String) -> Void)?
    var onEnd: ((String, String) -> Void)?   // element name, trimmed text
    private var text = ""

    func run(_ data: Data) -> Bool {
        let p = XMLParser(data: data)
        p.delegate = self
        return p.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        onStart?(elementName)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        onEnd?(elementName, text.trimmingCharacters(in: .whitespacesAndNewlines))
        text = ""
    }
}

enum S3Date {
    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

enum ListObjectsParser {
    static func parse(_ data: Data) -> ListPage? {
        var page = ListPage()
        var current: R2Object?
        var inPrefixes = false
        let w = XMLWalker()
        w.onStart = { name in
            if name == "Contents" { current = R2Object(key: "", size: 0, lastModified: nil, etag: "") }
            if name == "CommonPrefixes" { inPrefixes = true }
        }
        w.onEnd = { name, text in
            switch name {
            case "Key": current?.key = text
            case "Size": current?.size = Int64(text) ?? 0
            case "LastModified": current?.lastModified = S3Date.parse(text)
            case "ETag": current?.etag = text.replacingOccurrences(of: "\"", with: "")
            case "Contents": if let c = current { page.objects.append(c) }; current = nil
            case "Prefix" where inPrefixes: page.commonPrefixes.append(text)
            case "CommonPrefixes": inPrefixes = false
            case "IsTruncated": page.isTruncated = (text == "true")
            case "NextContinuationToken": page.nextContinuationToken = text
            default: break
            }
        }
        return w.run(data) ? page : nil
    }
}

enum BucketListParser {
    static func parse(_ data: Data) -> [String] {
        var names: [String] = []
        var inBucket = false
        let w = XMLWalker()
        w.onStart = { if $0 == "Bucket" { inBucket = true } }
        w.onEnd = { name, text in
            if name == "Name", inBucket { names.append(text) }
            if name == "Bucket" { inBucket = false }
        }
        _ = w.run(data)
        return names
    }
}

enum S3ErrorParser {
    static func code(in body: String) -> String? {
        var code: String?
        let w = XMLWalker()
        w.onEnd = { name, text in if name == "Code" { code = text } }
        _ = w.run(Data(body.utf8))
        return code
    }
}
