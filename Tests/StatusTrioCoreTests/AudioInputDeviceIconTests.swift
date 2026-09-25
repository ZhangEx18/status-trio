import CoreAudio
import XCTest
@testable import StatusTrioCore

final class AudioInputDeviceIconTests: XCTestCase {
    func testInputDeviceFamiliesMatchTheirPhysicalDevices() {
        let cases = [("MacBook Air麦克风", "laptopcomputer"),
                     ("“iPhone Zex”的麦克风", "iphone"), ("iPad microphone", "ipad"),
                     ("AirPods Pro", "airpodspro"), ("AirPods Max", "airpodsmax"),
                     ("AirPods", "airpods.gen3"), ("Beats Studio", "beats.headphones"),
                     ("Studio Display", "display"), ("Pro Display XDR", "display")]
        for (name, symbol) in cases {
            XCTAssertEqual(AudioInputDeviceIcon.symbol(name: name, transport: nil), symbol)
        }
        XCTAssertEqual(AudioInputDeviceIcon.symbol(name: "USB Mic", transport: kAudioDeviceTransportTypeUSB), "cable.connector")
        XCTAssertEqual(AudioInputDeviceIcon.symbol(name: nil, transport: nil), "mic")
        XCTAssertEqual(AudioInputDeviceIcon.symbol(name: "IPHONE", transport: kAudioDeviceTransportTypeUSB), "iphone")
    }
}
