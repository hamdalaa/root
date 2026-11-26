import Foundation

/// A site yt-dlp can download from, recognised from a URL or extractor name.
enum Platform: String, Codable, CaseIterable, Identifiable, Sendable {
    case youtube
    case instagram
    case tiktok
    case x
    case facebook
    case soundcloud
    case spotify
    case deezer
    case twitch
    case reddit
    case bandcamp
    case dailymotion
    case bilibili
    case pinterest
    case threads
    case bluesky
    case snapchat
    case rumble
    case kick
    case mixcloud
    case applePodcasts
    case tumblr
    case vk
    case niconico
    case telegram
    case odysee
    case patreon
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .youtube: "YouTube"
        case .instagram: "Instagram"
        case .tiktok: "TikTok"
        case .x: "X"
        case .facebook: "Facebook"
        case .soundcloud: "SoundCloud"
        case .spotify: "Spotify"
        case .deezer: "Deezer"
        case .twitch: "Twitch"
        case .reddit: "Reddit"
        case .bandcamp: "Bandcamp"
        case .dailymotion: "Dailymotion"
        case .bilibili: "Bilibili"
        case .pinterest: "Pinterest"
        case .threads: "Threads"
        case .bluesky: "Bluesky"
        case .snapchat: "Snapchat"
        case .rumble: "Rumble"
        case .kick: "Kick"
        case .mixcloud: "Mixcloud"
        case .applePodcasts: "Apple Podcasts"
        case .tumblr: "Tumblr"
        case .vk: "VK"
        case .niconico: "Niconico"
        case .telegram: "Telegram"
        case .odysee: "Odysee"
        case .patreon: "Patreon"
        case .other: "Other Sites"
        }
    }

    /// Brand colour as 0xRRGGBB, or nil for monochrome brands (render in the primary colour).
    var brandHex: UInt32? {
        switch self {
        case .youtube: 0xFF0000
        case .instagram: 0xFF0069
        case .tiktok: nil
        case .x: nil
        case .facebook: 0x0866FF
        case .soundcloud: 0xFF5500
        case .spotify: 0x1ED760
        case .deezer: 0xA238FF
        case .twitch: 0x9146FF
        case .reddit: 0xFF4500
        case .bandcamp: 0x408294
        case .dailymotion: nil
        case .bilibili: 0x00A1D6
        case .pinterest: 0xBD081C
        case .threads: nil
        case .bluesky: 0x1185FE
        case .snapchat: 0xFFFC00
        case .rumble: 0x85C742
        case .kick: 0x53FC19
        case .mixcloud: 0x5000FF
        case .applePodcasts: 0x9933CC
        case .tumblr: 0x36465D
        case .vk: 0x0077FF
        case .niconico: nil
        case .telegram: 0x26A5E4
        case .odysee: 0xEF1970
        case .patreon: nil
        case .other: nil
        }
    }

    /// Music/podcast platforms where audio is the sensible default.
    var prefersAudio: Bool { [.soundcloud, .spotify, .deezer, .bandcamp, .mixcloud, .applePodcasts].contains(self) }

    /// Known platforms only (excludes `.other`).
    static var known: [Platform] { allCases.filter { $0 != .other } }

    private static let hostTable: [(Platform, [String])] = [
        (.youtube, ["youtube.com", "youtu.be", "youtube-nocookie.com"]),
        (.instagram, ["instagram.com", "instagr.am"]),
        (.tiktok, ["tiktok.com"]),
        (.x, ["twitter.com", "x.com"]),
        (.facebook, ["facebook.com", "fb.watch", "fb.com"]),
        (.soundcloud, ["soundcloud.com"]),
        (.spotify, ["open.spotify.com", "spotify.com", "spotify.link"]),
        (.deezer, ["deezer.com", "deezer.page.link", "dzr.page.link"]),
        (.twitch, ["twitch.tv"]),
        (.reddit, ["reddit.com", "redd.it"]),
        (.bandcamp, ["bandcamp.com"]),
        (.dailymotion, ["dailymotion.com", "dai.ly"]),
        (.bilibili, ["bilibili.com", "b23.tv"]),
        (.pinterest, ["pinterest.com", "pin.it"]),
        (.threads, ["threads.net", "threads.com"]),
        (.bluesky, ["bsky.app"]),
        (.snapchat, ["snapchat.com"]),
        (.rumble, ["rumble.com"]),
        (.kick, ["kick.com"]),
        (.mixcloud, ["mixcloud.com"]),
        (.applePodcasts, ["podcasts.apple.com"]),
        (.tumblr, ["tumblr.com"]),
        (.vk, ["vk.com", "vk.ru", "vkvideo.ru"]),
        (.niconico, ["nicovideo.jp", "nico.ms"]),
        (.telegram, ["t.me", "telegram.me"]),
        (.odysee, ["odysee.com"]),
        (.patreon, ["patreon.com"]),
    ]

    /// Recognises the platform from a URL's host (subdomains included, e.g. music.youtube.com, artist.bandcamp.com).
    static func detect(url: String) -> Platform {
        let text = url.contains("://") ? url : "https://" + url
        guard let host = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return .other }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        for (platform, hosts) in hostTable where hosts.contains(where: { bare == $0 || bare.hasSuffix("." + $0) }) {
            return platform
        }
        if bare.contains("pinterest.") { return .pinterest }
        return .other
    }

    /// Falls back to yt-dlp's extractor key (e.g. "Youtube", "TwitchVod", "BandcampAlbum").
    static func detect(url: String, extractor: String?) -> Platform {
        let byHost = detect(url: url)
        guard byHost == .other, let key = extractor?.lowercased() else { return byHost }
        let aliases: [(String, Platform)] = [("twitter", .x)] + known.map { ($0.rawValue.lowercased(), $0) }
        return aliases.first { key.hasPrefix($0.0) }?.1 ?? .other
    }
}
