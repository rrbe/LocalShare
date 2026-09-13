import XCTest
import ImageIO
import AVFoundation
import UniformTypeIdentifiers
@testable import LocalShare

final class ThumbnailTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func file(_ name: String = "image.jpg") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return url
    }

    func testDownsamplingAndOrientation() throws {
        let url = root.appendingPathComponent("中文 100%.jpg")
        let context = CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let store = ThumbnailStore()
        let data = try XCTUnwrap(store.thumbnail(for: url, generation: store.generation))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.height, 512)
        XCTAssertLessThan(image.width, image.height)
        XCTAssertLessThan(data.count, try Data(contentsOf: url).count)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [url.lastPathComponent])
    }

    func testCacheInvalidatesForFileChangesAndClear() throws {
        let url = try file()
        var calls = 0
        let store = ThumbnailStore { _ in calls += 1; return Data([UInt8(calls)]) }
        let generation = store.generation
        XCTAssertEqual(store.thumbnail(for: url, generation: generation), Data([1]))
        XCTAssertEqual(store.thumbnail(for: url, generation: generation), Data([1]))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: url.path)
        XCTAssertEqual(store.thumbnail(for: url, generation: generation), Data([2]))
        store.clear()
        XCTAssertNil(store.thumbnail(for: url, generation: generation))
        XCTAssertEqual(store.thumbnail(for: url, generation: store.generation), Data([3]))
    }

    func testCoalescesConcurrentRequestsAndCachesFailure() throws {
        let url = try file()
        let lock = NSLock()
        var calls = 0
        let store = ThumbnailStore { _ in
            lock.lock(); calls += 1; lock.unlock()
            Thread.sleep(forTimeInterval: 0.03)
            return nil
        }
        DispatchQueue.concurrentPerform(iterations: 12) { _ in
            XCTAssertNil(store.thumbnail(for: url, generation: store.generation))
        }
        XCTAssertEqual(calls, 1)
    }

    func testAtMostTwoGeneratorsAndDiscardStaleResult() throws {
        let urls = try (0..<8).map { try file("\($0).jpg") }
        let lock = NSLock()
        var active = 0, maximum = 0
        let store = ThumbnailStore { _ in
            lock.lock(); active += 1; maximum = max(active, maximum); lock.unlock()
            Thread.sleep(forTimeInterval: 0.03)
            lock.lock(); active -= 1; lock.unlock()
            return Data([1])
        }
        DispatchQueue.concurrentPerform(iterations: urls.count) { i in
            XCTAssertNotNil(store.thumbnail(for: urls[i], generation: store.generation))
        }
        XCTAssertEqual(maximum, 2)

        let entered = DispatchSemaphore(value: 0), finish = DispatchSemaphore(value: 0)
        let stale = ThumbnailStore { _ in entered.signal(); finish.wait(); return Data([1]) }
        let generation = stale.generation
        let done = expectation(description: "stale work discarded")
        DispatchQueue.global().async {
            XCTAssertNil(stale.thumbnail(for: urls[0], generation: generation))
            done.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        stale.clear()
        finish.signal()
        wait(for: [done], timeout: 2)
    }

    func testVideoFrameIsDownsampledAndRotated() async throws {
        let url = root.appendingPathComponent("clip.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360
        ])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 128, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let deadline = Date().addingTimeInterval(5)
        while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard input.isReadyForMoreMediaData else {
            XCTFail("Video writer did not become ready")
            writer.cancelWriting()
            return
        }
        XCTAssertTrue(adaptor.append(buffer, withPresentationTime: .zero))
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let store = ThumbnailStore()
        let data = try XCTUnwrap(store.thumbnail(for: url, generation: store.generation))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.height, 512)
        XCTAssertEqual(image.width, 288)
    }

    func testHTTPAuthenticationShareChangesAndVirtualRoots() async throws {
        let image = root.appendingPathComponent("图片 100% +&#?.png")
        let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let destination = CGImageDestinationCreateWithURL(image as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.png"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let server = FileServer(share: .directory(root), token: "first")
        server.listenAddress = "127.0.0.1"
        let port = try server.start(preferredPorts: [UInt16.random(in: 40000...49000)])
        defer { server.stop() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        func request(_ path: String, token: String = "first") async throws -> (Data, HTTPURLResponse) {
            var url = URLComponents(string: "http://127.0.0.1:\(port)/ls/thumbnail")!
            url.queryItems = [URLQueryItem(name: "path", value: path),
                              URLQueryItem(name: "t", value: token)]
            let (data, response) = try await session.data(from: url.url!)
            return (data, response as! HTTPURLResponse)
        }
        let (data, response) = try await request("/" + image.lastPathComponent)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(response.value(forHTTPHeaderField: "Content-Length"), String(data.count))
        XCTAssertEqual(response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let (_, unauthorized) = try await request("/" + image.lastPathComponent, token: "wrong")
        XCTAssertEqual(unauthorized.statusCode, 403)
        for path in ["/../etc/hosts", "/escape.png", "/missing.png", "/"] {
            let (_, denied) = try await request(path)
            XCTAssertEqual(denied.statusCode, 404, path)
        }
        server.setCredentials(token: "second", accessCode: nil)
        server.share = .multiple([.init(key: "alias.png", url: image, isDir: false)])
        let (_, stale) = try await request("/" + image.lastPathComponent)
        XCTAssertEqual(stale.statusCode, 403)
        let (_, alias) = try await request("/alias.png", token: "second")
        XCTAssertEqual(alias.statusCode, 200)
        let (_, isolated) = try await request("/" + image.lastPathComponent, token: "second")
        XCTAssertEqual(isolated.statusCode, 404)
    }

    func testCorruptImageAndNonMediaReturnNoThumbnail() throws {
        let store = ThumbnailStore()
        XCTAssertNil(store.thumbnail(for: try file(), generation: store.generation))
        XCTAssertNil(store.thumbnail(for: try file("file.txt"), generation: store.generation))
        XCTAssertNil(store.thumbnail(for: root, generation: store.generation))
    }
}
