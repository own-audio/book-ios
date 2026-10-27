import Foundation
import Testing
import UIKit
@testable import OwnAudioBooks

/// A cover link from a synced record can be stale: own.audio signs image links for a week or
/// two, and builds them for the address the server had when the record was sent. The loader
/// asks for the current link once when the one in hand does not load.
@Suite("Cover loader", .serialized)
struct CoverLoaderTests {
    final class Stub: URLProtocol {
        nonisolated(unsafe) static var answers: [String: Int] = [:]
        override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "covers.test" }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let status = Self.answers[request.url!.path] ?? 404
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if status == 200 {
                let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { ctx in
                    UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
                }
                client?.urlProtocol(self, didLoad: png)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    init() {
        URLProtocol.registerClass(Stub.self)
        Stub.answers = ["/expired": 403, "/current": 200]
    }

    private func id() -> String { "test|" + UUID().uuidString }

    @Test("an expired link is replaced by the current one, once")
    func expiredLinkRecovers() async {
        let loader = CoverLoader()
        let image = await loader.image(
            compositeId: id(), size: 64,
            url: { URL(string: "https://covers.test/expired") },
            fresh: { URL(string: "https://covers.test/current") })
        #expect(image != nil)
    }

    @Test("without a way to ask again, a stale link stays a placeholder")
    func noFreshLink() async {
        let image = await CoverLoader().image(compositeId: id(), size: 64, url: { URL(string: "https://covers.test/expired") })
        #expect(image == nil)
    }

    @Test("a link that loads is not asked about again")
    func goodLinkIsEnough() async {
        actor Counter { var asked = 0; func add() { asked += 1 } }
        let counter = Counter()
        let image = await CoverLoader().image(
            compositeId: id(), size: 64,
            url: { URL(string: "https://covers.test/current") },
            fresh: { await counter.add(); return nil })
        #expect(image != nil)
        #expect(await counter.asked == 0)
    }
}
