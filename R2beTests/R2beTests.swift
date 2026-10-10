import AVFoundation
import XCTest
@testable import R2be

// Regression guards for behavior that has broken before or is easy to break when features merge.
// Each test names the user-visible behavior it protects.

// MARK: - Bucket folders

final class FolderPrefixTests: XCTestCase {
    private func creds(_ folder: String?) -> R2Credentials {
        R2Credentials(accountId: "acct", accessKeyId: "k", secretAccessKey: "s", bucket: "b", folder: folder)
    }

    func testNoFolderIndexesWholeBucket() {
        XCTAssertEqual(creds(nil).prefixes, [""])
        XCTAssertEqual(creds("").prefixes, [""])
        XCTAssertEqual(creds(nil).rootPrefix, "")
    }

    func testFoldersParseFromCommasAndNewlinesAndTrimSlashes() {
        XCTAssertEqual(creds("/videos/movies/, shows\nmusic ").prefixes, ["music/", "shows/", "videos/movies/"])
    }

    func testNestedAndDuplicateFoldersAreDropped() {
        XCTAssertEqual(creds("media\nmedia/clips\nmedia").prefixes, ["media/"])
    }

    func testLibraryOpensAtTheSharedFolder() {
        XCTAssertEqual(creds("videos/movies").rootPrefix, "videos/movies/")
        XCTAssertEqual(creds("media/clips\nmedia/movies").rootPrefix, "media/")
        XCTAssertEqual(creds("a/x/b\na/y/b").rootPrefix, "a/")
        XCTAssertEqual(creds("videos\nshows").rootPrefix, "")
    }
}

// MARK: - Saved connections

final class SavedConnectionTests: XCTestCase {
    func testSingleConnectionFromOlderBuildsStillLoads() throws {
        let legacy = #"{"accountId":"a","accessKeyId":"k","secretAccessKey":"s","bucket":"b","jurisdiction":"standard"}"#
        let loaded = KeychainStore.decode(Data(legacy.utf8))
        XCTAssertEqual(loaded.map(\.bucket), ["b"])
        XCTAssertNil(loaded.first?.folder)
    }

    func testMultipleConnectionsRoundTrip() throws {
        let list = [
            R2Credentials(accountId: "a", accessKeyId: "k1", secretAccessKey: "s1", bucket: "one"),
            R2Credentials(accountId: "a", accessKeyId: "k2", secretAccessKey: "s2", bucket: "two", folder: "clips"),
        ]
        let loaded = KeychainStore.decode(try JSONEncoder().encode(list))
        XCTAssertEqual(loaded, list)
    }

    func testJurisdictionEndpoints() {
        var c = R2Credentials(accountId: " acct ", accessKeyId: "k", secretAccessKey: "s", bucket: "b")
        XCTAssertEqual(c.endpoint.absoluteString, "https://acct.r2.cloudflarestorage.com")
        c.jurisdiction = .eu
        XCTAssertEqual(c.endpoint.absoluteString, "https://acct.eu.r2.cloudflarestorage.com")
    }
}

// MARK: - S3 responses

final class S3ParserTests: XCTestCase {
    private let listXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>b</Name><Prefix>shows/</Prefix><Delimiter>/</Delimiter><IsTruncated>true</IsTruncated>
      <Contents><Key>shows/a.mp4</Key><LastModified>2024-05-01T10:00:00.000Z</LastModified><ETag>"abc"</ETag><Size>1234</Size></Contents>
      <CommonPrefixes><Prefix>shows/season 1/</Prefix></CommonPrefixes>
      <CommonPrefixes><Prefix>shows/season 2/</Prefix></CommonPrefixes>
      <NextContinuationToken>tok==</NextContinuationToken>
    </ListBucketResult>
    """

    func testListObjectsPage() throws {
        let page = try XCTUnwrap(ListObjectsParser.parse(Data(listXML.utf8)))
        XCTAssertEqual(page.objects.map(\.key), ["shows/a.mp4"])
        XCTAssertEqual(page.objects.first?.size, 1234)
        XCTAssertEqual(page.objects.first?.etag, "abc")
        XCTAssertNotNil(page.objects.first?.lastModified)
        XCTAssertTrue(page.isTruncated)
        XCTAssertEqual(page.nextContinuationToken, "tok==")
    }

    /// The folder browser lists subfolders through CommonPrefixes; the request's own <Prefix> must not leak in.
    func testSubfoldersComeFromCommonPrefixesOnly() throws {
        let page = try XCTUnwrap(ListObjectsParser.parse(Data(listXML.utf8)))
        XCTAssertEqual(page.commonPrefixes, ["shows/season 1/", "shows/season 2/"])
    }

    func testBucketListAndErrorCode() {
        let buckets = "<ListAllMyBucketsResult><Buckets><Bucket><Name>one</Name></Bucket><Bucket><Name>two</Name></Bucket></Buckets></ListAllMyBucketsResult>"
        XCTAssertEqual(BucketListParser.parse(Data(buckets.utf8)), ["one", "two"])
        XCTAssertEqual(S3ErrorParser.code(in: "<Error><Code>SignatureDoesNotMatch</Code></Error>"), "SignatureDoesNotMatch")
    }
}

// MARK: - Request signing

final class SigningTests: XCTestCase {
    func testCanonicalQuerySortsAndEncodes() {
        let q = SigV4Signer.canonicalQuery([URLQueryItem(name: "b", value: "2"), URLQueryItem(name: "a", value: "x y/~")])
        XCTAssertEqual(q, "a=x%20y%2F~&b=2")
    }

    /// Keys with spaces and symbols must stream; a mis-encoded path fails with SignatureDoesNotMatch.
    func testObjectURLEncodesEachPathSegment() {
        let client = R2Client(credentials: R2Credentials(accountId: "acct", accessKeyId: "k", secretAccessKey: "s", bucket: "b"))
        let url = client.objectURL(bucket: "my-bucket", key: "Shows/My Clip #1.mp4")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
                       "/my-bucket/Shows/My%20Clip%20%231.mp4")
    }

    func testPresignedLinkCarriesSignatureAndClampsLifetime() throws {
        let signer = SigV4Signer(accessKeyId: "AK", secretAccessKey: "SK")
        let url = signer.presign(url: URL(string: "https://acct.r2.cloudflarestorage.com/b/a.mp4")!, expires: 10_000_000)
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("X-Amz-Algorithm"), "AWS4-HMAC-SHA256")
        XCTAssertEqual(value("X-Amz-Expires"), "604800")
        XCTAssertEqual(value("X-Amz-SignedHeaders"), "host")
        let signature = try XCTUnwrap(value("X-Amz-Signature"))
        XCTAssertEqual(signature.count, 64)
        XCTAssertTrue(signature.allSatisfy(\.isHexDigit))
    }
}

// MARK: - Indexing

final class IndexTests: XCTestCase {
    private func object(_ key: String) -> R2Object { R2Object(key: key, size: 1, lastModified: nil, etag: "e") }

    func testIndexKeepsPlayableMediaAndSidecarImagesOnly() {
        let keys = ["a/", "a/.DS_Store", ".hidden/x.mp4", "a/._clip.mp4", "a/clip.mp4", "a/clip.jpg",
                    "b/song.mp3", "c/movie.mkv", "d/notes.txt"]
        let index = LibraryStore.buildIndex(bucket: "b", objects: keys.map(object))
        XCTAssertEqual(index.videos.map(\.key), ["a/clip.mp4", "b/song.mp3"])
        XCTAssertEqual(index.imageKeys, ["a/clip.jpg"])
    }

    /// Related groups a series by its name with numbers and part words taken out, whatever the pattern.
    func testSeriesMatchAcrossNumberingStyles() {
        for name in ["Trip day1", "Trip_Day 02", "trip day10"] { XCTAssertEqual(LibraryStore.seriesStem(name), "trip day") }
        for name in ["Trip-pt1", "Trip part 2", "Trip (4)", "Trip S01E03"] { XCTAssertEqual(LibraryStore.seriesStem(name), "trip") }
        XCTAssertNotEqual(LibraryStore.seriesStem("Alpha 2"), LibraryStore.seriesStem("Beta 2"))
        XCTAssertEqual(LibraryStore.seriesStem("20240101_123456"), "")
    }

    /// Similar names are compared as trigrams, so glued words and abbreviations still match,
    /// and a word every file shares counts for little.
    func testTrigramSimilarity() {
        let titles = ["tripday", "Trip day", "Beach sunset", "Trip highlights", "Trip hilites",
                      "alpha converted", "beta converted", "gamma converted", "alpha converted copy"]
        let index = NameIndex(titles: titles)
        func sim(_ a: Int, _ b: Int) -> Double { NameIndex.cosine(index.vectors[a], index.vectors[b]) }

        XCTAssertGreaterThan(sim(0, 1), 0.4)                    // glued vs spaced (+0.1 in the same folder clears 0.5)
        XCTAssertEqual(sim(0, 2), 0, accuracy: 1e-9)            // nothing in common
        XCTAssertGreaterThan(sim(3, 4), sim(3, 2))              // abbreviation beats unrelated
        XCTAssertGreaterThan(sim(5, 8), sim(5, 6))              // the distinctive word outweighs "converted"
        XCTAssertEqual(sim(1, 1), 1, accuracy: 1e-9)            // vectors are unit length
    }

    func testSearchIgnoresCaseAndSeparators() {
        let item = VideoItem(bucket: "b", key: "Shows/My-Clip_Final.mp4", size: 1, lastModified: nil, etag: "e")
        XCTAssertTrue(SearchMatcher.matches(item, tokens: SearchMatcher.tokens("my clip final")))
        XCTAssertFalse(SearchMatcher.matches(item, tokens: SearchMatcher.tokens("trailer")))
    }
}

// MARK: - Playback

@MainActor
final class PlaybackTests: XCTestCase {
    /// A player with no saved skip settings; they're cleared again when the test ends.
    private func freshPlayer() -> PlayerController {
        let keys = ["skipUnit", "rewindAmount", "forwardAmount"]
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
        addTeardownBlock { keys.forEach(UserDefaults.standard.removeObject(forKey:)) }
        return PlayerController()
    }

    func testSkipDefaultsAreTenBackThirtyForward() {
        let player = freshPlayer()
        XCTAssertEqual(player.skipUnit, .seconds)
        XCTAssertEqual(player.rewindAmount, 10)
        XCTAssertEqual(player.forwardAmount, 30)
        XCTAssertEqual(player.skipLabel(forward: false), "−10s")
        XCTAssertEqual(player.skipSymbol(forward: true), "goforward.30")
    }

    func testSkipLabelsFollowSettings() {
        let player = freshPlayer()
        player.forwardAmount = 7
        XCTAssertEqual(player.skipSymbol(forward: true), "goforward")
        player.skipUnit = .keyframes
        player.rewindAmount = 1
        XCTAssertEqual(player.skipLabel(forward: false), "−1 keyframe")
        XCTAssertEqual(player.skipSymbol(forward: false), "gobackward")
    }
}

// MARK: - Related

/// Repeatable random numbers, so a test sees the same draws every run.
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class RelatedBatchTests: XCTestCase {
    private func videos(_ prefix: String, _ n: Int) -> [VideoItem] {
        (0..<n).map { VideoItem(bucket: "b", key: "\(prefix)\($0).mp4", size: 1, lastModified: nil, etag: "e") }
    }

    private func batch(names: [VideoItem], looks: [VideoItem], fresh: [VideoItem], pinned: VideoItem? = nil,
                       excluding: Set<String> = [], weight: (VideoItem) -> Double = { _ in 1 },
                       seed: UInt64 = 1) -> [VideoItem] {
        var rng = SeededRandom(state: seed)
        return PlayerController.relatedBatch(names: names, looks: looks, fresh: fresh, pinned: pinned,
                                             excluding: excluding, weight: weight, using: &rng)
    }

    /// A batch is 7: 4 by name (the next part first), 1 new upload from elsewhere, 2 look-alikes.
    func testBatchMixAndPinnedNextPart() {
        let next = VideoItem(bucket: "b", key: "next.mp4", size: 1, lastModified: nil, etag: "e")
        let result = batch(names: [next] + videos("n", 20), looks: videos("l", 20), fresh: videos("f", 20), pinned: next)
        XCTAssertEqual(result.count, 7)
        XCTAssertEqual(result.first, next)
        XCTAssertEqual(result.filter { $0.key.hasPrefix("n") || $0 == next }.count, 4)
        XCTAssertEqual(result.filter { $0.key.hasPrefix("f") }.count, 1)
        XCTAssertEqual(result.filter { $0.key.hasPrefix("l") }.count, 2)
        XCTAssertEqual(Set(result.map(\.id)).count, 7)
    }

    /// The same video gets different suggestions on different visits.
    func testBatchesVaryBetweenVisits() {
        let names = videos("n", 30), looks = videos("l", 30), fresh = videos("f", 30)
        let draws = (1...5).map { seed in batch(names: names, looks: looks, fresh: fresh, seed: seed).map(\.id) }
        XCTAssertGreaterThan(Set(draws).count, 1)
    }

    /// Played or already-shown videos are demoted; at weight 0 they're skipped while others remain.
    func testDemotedVideosGiveWayToFreshOnes() {
        let names = videos("n", 20)
        let watched = Set(names.prefix(6).map(\.id))
        for seed in 1...10 {
            let result = batch(names: names, looks: [], fresh: [], weight: { watched.contains($0.id) ? 0 : 1 }, seed: UInt64(seed))
            XCTAssertTrue(result.allSatisfy { !watched.contains($0.id) }, "seed \(seed)")
        }
    }

    /// Show more continues past what's shown, and a dry pool is topped up from the others.
    func testBatchesContinueAndTopUp() {
        let names = videos("n", 3), fresh = videos("f", 10)
        let first = batch(names: names, looks: [], fresh: fresh)
        XCTAssertEqual(first.count, 7)
        XCTAssertEqual(first.filter { $0.key.hasPrefix("n") }.count, 3)
        let second = batch(names: names, looks: [], fresh: fresh, excluding: Set(first.map(\.id)))
        XCTAssertEqual(second.count, 6)
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: second.map(\.id)))
    }
}

// MARK: - Background playback and Picture in Picture

@MainActor
final class BackgroundPlaybackTests: XCTestCase {
    /// Without the audio background mode, iOS stops playback and PiP the moment the app is left.
    func testAudioBackgroundModeIsDeclared() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        XCTAssertTrue(modes.contains("audio"))
    }

    func testAudioSessionIsSetForPlayback() {
        XCTAssertEqual(AVAudioSession.sharedInstance().category, .playback)
    }

    /// Leaving the app mid-video should hand off to PiP without tapping anything.
    func testPictureInPictureStartsAutomatically() throws {
        try XCTSkipUnless(PiPManager.isSupported, "PiP isn't available on this simulator")
        let pip = PiPManager()
        let surface = PlayerLayerView()
        surface.playerLayer.player = AVPlayer()
        pip.register(surface.playerLayer)
        XCTAssertTrue(pip.startsAutomatically)
    }

    /// With the screen locked (no PiP), surfaces let go of the player so audio keeps going, then reattach.
    func testSurfacesDetachForBackgroundAudioAndReattach() {
        let pip = PiPManager()
        let player = AVPlayer()
        let surface = PlayerLayerView()
        surface.playerLayer.player = player
        pip.register(surface.playerLayer)

        pip.detachLayersForBackground()
        XCTAssertNil(surface.playerLayer.player)

        pip.reattachLayers()
        XCTAssertTrue(surface.playerLayer.player === player)
    }
}
