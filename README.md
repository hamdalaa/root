# Root

A native macOS download manager. Paste a link from YouTube, Instagram, TikTok, X, SoundCloud and many more sites, and Root saves the video or audio. It also handles direct file downloads and torrents, catches downloads from your browser, and includes a small set of Mac Care tools (memory, storage, cleanup, uninstaller, login items).

Root is built with SwiftUI. It uses [yt-dlp](https://github.com/yt-dlp/yt-dlp) for media sites, [ffmpeg](https://ffmpeg.org) for merging and converting, and [aria2](https://aria2.github.io) for segmented and torrent downloads. It was inspired by [Parabolic](https://github.com/NickvisionApps/Parabolic).

## Requirements

- macOS 26 or later
- A Mac with Apple Silicon (M1 or newer)
- ffmpeg, for merging video and audio: `brew install ffmpeg`

Root downloads and updates yt-dlp by itself. aria2 is bundled in the app.

## Install

1. Download `Root.zip` from the [latest release](https://github.com/hamdalaa/root/releases/latest).
2. Unzip it and drag `Root.app` into `/Applications`.
3. The app is not notarized by Apple, so macOS blocks it the first time. Run this once in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Root.app
   ```

   Or open Root, then go to System Settings › Privacy & Security and click **Open Anyway**.

## Build from source

You only need the Xcode Command Line Tools (`xcode-select --install`).

```sh
./scripts/bundle.sh     # builds dist/Root.app
./scripts/test.sh       # runs the test suite
```

## Browser extension

Root ships an unpacked Chrome/Brave/Edge and Firefox extension inside the app (`Root.app/Contents/Resources/Extension`). Root installs the native-messaging host automatically when it starts. In Root, open Settings › Browser to find the extension folder, then load it in your browser as an unpacked extension.

## License

Root is free software under the GNU General Public License v3.0. See [LICENSE](LICENSE).

Third-party parts:

- `vendor/aria2c` is aria2 1.37.0, built from the unmodified [upstream source](https://github.com/aria2/aria2/releases/tag/release-1.37.0) with AppleTLS. aria2 is GPL-2.0-or-later.
- Platform logos come from [Simple Icons](https://simpleicons.org) (CC0). The brands belong to their owners.
- yt-dlp (Unlicense) and ffmpeg (LGPL/GPL) are downloaded or installed separately and are not part of this repository.

Only download content you have the right to download.
