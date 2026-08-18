import XCTest
import Compression
@testable import DSHShellCore

final class SessionStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-session-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(
        workspace: String,
        id: String,
        title: String?,
        cwd: String,
        createdAt: Date
    ) throws {
        let dir = root.appendingPathComponent(workspace, isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var lines = [String]()
        lines.append(#"{"type":"session","version":0,"id":"\#(id)","createdAt":"\#(ISO8601DateFormatter().string(from: createdAt))","cwd":"\#(cwd)","delegationDepth":0,"agentPreset":"standard"}"#)
        lines.append(#"{"type":"event","seq":1,"time":0,"source":"user","event":{"type":"user/input"}}"#)
        if let title {
            lines.append(#"{"type":"session/title","version":0,"time":1,"data":{"title":"\#(title)"}}"#)
        }
        let jsonl = lines.joined(separator: "\n")
        let compressed = Self.zstdCompress(Data(jsonl.utf8))
        try compressed.write(to: dir.appendingPathComponent("session.jsonl.zstd"))
    }

    func testListSessionsParsesHeaderAndTitle() throws {
        try makeSession(
            workspace: "my-project",
            id: "session-aaa",
            title: "Chat about the refactor",
            cwd: "/Users/test/my-project",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try makeSession(
            workspace: "other",
            id: "session-bbb",
            title: nil,
            cwd: "/Users/test/other",
            createdAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let store = SessionStore(rootURL: root)
        let sessions = store.listSessions()
        XCTAssertEqual(sessions.count, 2)

        let aaa = sessions.first { $0.id == "session-aaa" }
        XCTAssertNotNil(aaa)
        XCTAssertEqual(aaa?.title, "Chat about the refactor")
        XCTAssertEqual(aaa?.workspace, "/Users/test/my-project")
        XCTAssertEqual(aaa?.directoryURL.lastPathComponent, "session-aaa")

        let bbb = sessions.first { $0.id == "session-bbb" }
        XCTAssertNotNil(bbb)
        XCTAssertNil(bbb?.title)
    }

    func testListSessionsNewestFirst() throws {
        try makeSession(
            workspace: "w", id: "session-old", title: nil,
            cwd: "/x", createdAt: Date(timeIntervalSince1970: 1_000)
        )
        try makeSession(
            workspace: "w", id: "session-new", title: nil,
            cwd: "/x", createdAt: Date(timeIntervalSince1970: 2_000)
        )

        // newline padding so the newest session has a later mtime
        let sessions = SessionStore(rootURL: root).listSessions()
        XCTAssertEqual(sessions.first?.id, "session-new")
    }

    func testIgnoresNonSessionDirectories() throws {
        try makeSession(
            workspace: "w", id: "session-only", title: nil,
            cwd: "/x", createdAt: Date()
        )
        let stray = root.appendingPathComponent("w/stray", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)

        let sessions = SessionStore(rootURL: root).listSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "session-only")
    }

    func testZstdRoundTrip() throws {
        let original = Data("hello dsh session transcript\nsecond line\n".utf8)
        let compressed = Self.zstdCompress(original)
        let decoded = SessionStore.zstdDecompress(compressed)
        XCTAssertEqual(decoded, original)
    }

    private static func zstdCompress(_ data: Data) -> Data {
        // COMPRESSION_ZSTD = 0x700 (named constants not in SDK's Swift overlay)
        let capacity = compression_encode_scratch_buffer_size(compression_algorithm(rawValue: 0x700))
        var scratch = Data(count: capacity)
        var output = Data(count: data.count + 1024)
        let outputCapacity = output.count
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { src in
                scratch.withUnsafeMutableBytes { scr in
                    compression_encode_buffer(
                        out.bindMemory(to: UInt8.self).baseAddress!,
                        outputCapacity,
                        src.bindMemory(to: UInt8.self).baseAddress!,
                        data.count,
                        scr.bindMemory(to: UInt8.self).baseAddress!,
                        compression_algorithm(rawValue: 0x700)
                    )
                }
            }
        }
        return Data(output.prefix(written))
    }
}