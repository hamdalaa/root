import Foundation

/// Sites with a yt-dlp search extractor.
enum SearchSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case youtube, soundcloud, bilibili, niconico

    var id: String { rawValue }
    var prefix: String {
        switch self {
        case .youtube: "ytsearch"
        case .soundcloud: "scsearch"
        case .bilibili: "bilisearch"
        case .niconico: "nicosearch"
        }
    }
    var platform: Platform {
        switch self {
        case .youtube: .youtube
        case .soundcloud: .soundcloud
        case .bilibili: .bilibili
        case .niconico: .niconico
        }
    }
}
