import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let path = "/Users/zt27532/yaosnap/Build/Yaosnap.app"
    let icon = NSWorkspace.shared.icon(forFile: path)
    icon.size = NSSize(width: 256, height: 256)
    guard let tiff = icon.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("no icon")
        return
    }
    try? png.write(to: URL(fileURLWithPath: "/tmp/yaosnap-verify/evidence/bundle-icon.png"))
    print("BUNDLE ICON \(rep.pixelsWide)x\(rep.pixelsHigh)")
}
