import Foundation
import Testing
@testable import Translator_Everywhere

@Suite("RegionCapturer cancel detection")
struct RegionCapturerTests {

    @Test("Returns the URL when the capture writes a file")
    func returnsURLWhenFileWritten() async throws {
        // Simulate a completed capture: the runner writes a PNG-ish file.
        let capturer = RegionCapturer { destination in
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: destination)
        }

        let url = try await capturer.captureRegion()

        #expect(url != nil)
        if let url {
            #expect(FileManager.default.fileExists(atPath: url.path))
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test("Returns nil when the user cancels (no file written)")
    func returnsNilOnCancel() async throws {
        // Simulate Esc: screencapture exits but writes nothing.
        let capturer = RegionCapturer { _ in
            // no file written
        }

        let url = try await capturer.captureRegion()

        #expect(url == nil)
    }

    // NOTE: the real interactive `screencapture -i -x` path cannot be exercised
    // headlessly (it needs a user drag + screen-recording permission), so only
    // the cancel-vs-success *detection* (file presence) is unit-tested here.
}
