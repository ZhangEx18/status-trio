import AppKit
import CoreAudio
import SwiftUI

enum AudioInputDeviceIcon {
    static func symbol(name: String?, transport: UInt32?) -> String {
        let name = (name ?? "").lowercased()
        let families = [("iphone", "iphone"), ("ipad", "ipad"),
            ("airpods pro", "airpodspro"), ("airpods max", "airpodsmax"),
            ("airpods", "airpods.gen3"), ("beats", "beats.headphones"),
            ("macbook", "laptopcomputer"), ("studio display", "display"),
            ("pro display xdr", "display")]
        if let match = families.first(where: { name.contains($0.0) }) { return match.1 }
        return transport == kAudioDeviceTransportTypeUSB ? "cable.connector" : "mic"
    }
}

struct AudioInputDeviceIconView: View {
    let device: AudioInputDevice

    var body: some View {
        Group {
            if let url = device.iconURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: AudioInputDeviceIcon.symbol(name: device.name, transport: device.transport))
                    .resizable().scaledToFit()
            }
        }
        .frame(width: 20, height: 20)
    }
}
