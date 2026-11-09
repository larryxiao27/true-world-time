import SwiftUI
import AppKit

@main struct SettingsRenderCheck {
    @MainActor static func main() throws {
        let model = ProbeModel(startServices: false)
        model.engine.accept(NetworkSample(utc: Date().timeIntervalSince1970, continuous: ContinuousTime.now, roundTrip: 0.01, uncertainty: 0.005, source: "布局预览", stratum: 2))
        model.setWindowVisible(true)
        Thread.sleep(forTimeInterval: 2.1)
        model.tick()
        model.lastMessage = "布局检查：未注册登录项、未进行网络校时"
        let view = ProbeSettingsView(model: model, hideWindow: {}).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Settings rendering failed") }
        try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        model.setWindowVisible(false)
        print("Rendered settings without opening a window or registering a login item.")
    }
}
