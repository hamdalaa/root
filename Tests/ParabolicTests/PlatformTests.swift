import AppKit
import SwiftUI
import Testing
@testable import Parabolic

@Suite struct PlatformTests {
    @Test(arguments: [
        ("https://www.youtube.com/watch?v=x", Platform.youtube),
        ("youtu.be/abc", .youtube),
        ("https://music.youtube.com/watch?v=x", .youtube),
        ("https://x.com/a/status/1", .x),
        ("https://twitter.com/a/status/1", .x),
        ("https://vm.tiktok.com/xyz", .tiktok),
        ("https://artist.bandcamp.com/track/a", .bandcamp),
        ("https://podcasts.apple.com/us/podcast/x", .applePodcasts),
        ("https://www.pinterest.co.uk/pin/1", .pinterest),
        ("https://example.com/video", .other),
    ])
    func detectsPlatform(url: String, expected: Platform) {
        #expect(Platform.detect(url: url) == expected)
    }

    @Test func extractorFallback() {
        #expect(Platform.detect(url: "https://cdn.example/x", extractor: "TwitchVod") == .twitch)
        #expect(Platform.detect(url: "https://cdn.example/x", extractor: "Twitter") == .x)
    }

    @Test func everyGlyphParses() {
        for platform in Platform.known {
            let bounds = platform.glyph?.boundingRect ?? .zero
            #expect(bounds.width > 10 && bounds.width <= 24.5, "\(platform) width \(bounds.width)")
            #expect(bounds.height > 5 && bounds.height <= 24.5, "\(platform) height \(bounds.height)")
        }
    }

    @Test func musicPlatformsDefaultToAudio() {
        #expect(Preferences().preset(for: .soundcloud).fileType.isAudio)
        #expect(!Preferences().preset(for: .youtube).fileType.isAudio)
    }

    /// Renders every glyph into a sheet for eyeballing: PB_RENDER=1 ./scripts/test.sh --filter renderSheet
    @MainActor @Test func renderSheet() throws {
        guard ProcessInfo.processInfo.environment["PB_RENDER"] != nil else { return }
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.fixed(64)), count: 9), spacing: 12) {
            ForEach(Platform.allCases) { p in
                VStack { PlatformGlyph(platform: p, size: 36); Text(p.title).font(.system(size: 8)) }
            }
        }.padding(20).background(Color.white).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: grid)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/pb_glyphs.png"))
    }
}

@Suite struct SubscriptionTests {
    @Test(arguments: [
        ("https://www.youtube.com/@jawed", "https://www.youtube.com/@jawed/videos"),
        ("https://www.youtube.com/channel/UC123", "https://www.youtube.com/channel/UC123/videos"),
        ("https://www.youtube.com/@jawed/shorts", "https://www.youtube.com/@jawed/shorts"),
        ("https://www.youtube.com/playlist?list=PL1", "https://www.youtube.com/playlist?list=PL1"),
        ("https://soundcloud.com/forss", "https://soundcloud.com/forss"),
    ])
    func followsVideosTab(input: String, expected: String) {
        #expect(SubscriptionStore.channelFeedURL(input) == expected)
    }
}
