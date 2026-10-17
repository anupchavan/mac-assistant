import AppKit
import SwiftUI
import XCTest
@testable import QuickyApp
@testable import QuickyCore

/// Renders `PanelView` for hand-built scenes into build/scenes/*.png, with no Engine involved.
@MainActor
final class SceneSnapshotTests: XCTestCase {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let out = repo.appending(path: "build/scenes")

    override func setUp() async throws {
        Fonts.register(from: Self.repo.appending(path: "Resources/Fonts"))
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
    }

    func testRendersTheFourSliceOneScenes() throws {
        let ask = "How do I say hello in Hindi?"
        let earlier = ThreadItem(
            id: "t1", ask: "What's the capital of Telangana?",
            steps: [StepRow(text: "Answered", state: .done)],
            answer: "**Hyderabad.** It has been the capital since the state was formed in 2014.",
            error: nil, isLive: false
        )
        let scenes: [(String, PanelScene)] = [
            ("typing", scene(input: .typing(prefill: ""))),
            ("asked", scene(input: .asked(ask), thread: [ThreadItem(
                id: "t2", ask: ask,
                steps: [StepRow(text: "Read your question", state: .done), StepRow(text: "Thinking", state: .active)],
                answer: "", error: nil, isLive: true
            )])),
            ("streaming", scene(input: .asked(ask), thread: [earlier, ThreadItem(
                id: "t2", ask: ask,
                steps: [StepRow(text: "Read your question", state: .done), StepRow(text: "Thinking", state: .done)],
                answer: "Say **नमस्ते** (*namaste*). It works with anyone.\n\nWith friends, `नमस्कार` or just **हाय",
                error: nil, isLive: true
            )], chatPosition: "2 / 3")),
            ("error", scene(input: .asked(ask), thread: [ThreadItem(
                id: "t2", ask: ask,
                steps: [StepRow(text: "Thinking", state: .done)],
                answer: "Say **नमस्ते** (*namaste*). It works",
                error: "Connection lost.", isLive: false
            )], primary: .retry)),
        ]

        for (name, scene) in scenes {
            let url = Self.out.appending(path: "\(name).png")
            try? FileManager.default.removeItem(at: url)
            try render(scene).write(to: url)
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            XCTAssertGreaterThan(size, 0, "\(name).png is empty")
        }
    }

    private func scene(
        input: InputRow, thread: [ThreadItem] = [], primary: FooterAction? = nil, chatPosition: String? = nil
    ) -> PanelScene {
        PanelScene(presence: .panel, input: input, thread: thread,
                   footer: Footer(primary: primary, chatPosition: chatPosition))
    }

    /// Hosts the view offscreen and lets a few run-loop turns pass, so heights measured during layout
    /// (thread content, input row) settle before the bitmap is taken.
    private func render(_ scene: PanelScene) throws -> Data {
        let host = NSHostingView(rootView: Backdrop(scene: scene))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 800),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        for _ in 0..<6 {
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}

/// A dark wallpaper stand-in for the glass to sit on, since an offscreen render has no desktop behind it.
private struct Backdrop: View {
    let scene: PanelScene
    var body: some View {
        PanelView(scene: scene)
            .padding(40)
            .background(LinearGradient(
                colors: [Color(hex: 0x1B2A4A), Color(hex: 0x3A2A55), Color(hex: 0x1E3B44)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ))
    }
}
