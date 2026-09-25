import XCTest
@testable import StatusTrioCore

final class AudioTapBufferProcessorTests: XCTestCase {
    func testRealtimeProcessorCanRunOffMainActor() async {
        let expectation = expectation(description: "realtime processor completes off the main actor")

        DispatchQueue.global(qos: .userInitiated).async {
            var samples: [Float] = [0.25, -0.5, 1.0, -1.0]
            samples.withUnsafeMutableBufferPointer {
                AudioTapRealtimeProcessor.applyGain(2, to: $0)
            }
            XCTAssertEqual(samples, [0.5, -1.0, 2.0, -2.0])
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testGainIsClampedAndMuteProducesSilence() {
        XCTAssertEqual(AudioTapBufferProcessor.gain(volume: 2, muted: false), 2)
        XCTAssertEqual(AudioTapBufferProcessor.gain(volume: 8, muted: false), 4)
        XCTAssertEqual(AudioTapBufferProcessor.gain(volume: 2, muted: true), 0)
    }

    func testApplyGainProcessesFloatSamplesWithoutChangingCount() {
        var samples: [Float] = [0.25, -0.5, 0.75]

        samples.withUnsafeMutableBufferPointer {
            AudioTapBufferProcessor.applyGain(2, to: $0)
        }

        XCTAssertEqual(samples, [0.5, -1, 1.5])
    }
}
