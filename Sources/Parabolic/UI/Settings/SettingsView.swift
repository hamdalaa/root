import SwiftUI

/// Preferences window: one native grouped Form per tab.
struct SettingsView: View {
    private enum Tab: Hashable { case general, platforms, downloads, browser, converter, network, logins, presets, engine, advanced }

    @State private var selection: Tab = .general

    var body: some View {
        TabView(selection: $selection) {
            GeneralSettingsTab()
                .settingsPane(height: 700)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            PlatformsSettingsTab()
                .settingsPane(height: 640)
                .tabItem { Label("Platforms", systemImage: "square.grid.3x3.square") }
                .tag(Tab.platforms)
            DownloadsSettingsTab()
                .settingsPane(height: 680)
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .tag(Tab.downloads)
            BrowserSettingsTab()
                .settingsPane(height: 720)
                .tabItem { Label("Browser", systemImage: "globe") }
                .tag(Tab.browser)
            ConverterSettingsTab()
                .settingsPane(height: 560)
                .tabItem { Label("Converter", systemImage: "wand.and.stars") }
                .tag(Tab.converter)
            NetworkSettingsTab()
                .settingsPane(height: 540)
                .tabItem { Label("Network", systemImage: "network") }
                .tag(Tab.network)
            LoginsSettingsTab()
                .settingsPane(height: 400)
                .tabItem { Label("Logins", systemImage: "key") }
                .tag(Tab.logins)
            PresetsSettingsTab()
                .settingsPane(height: 520)
                .tabItem { Label("Presets", systemImage: "square.stack") }
                .tag(Tab.presets)
            EngineSettingsTab()
                .settingsPane(height: 600)
                .tabItem { Label("yt-dlp", systemImage: "terminal") }
                .tag(Tab.engine)
            AdvancedSettingsTab()
                .settingsPane(height: 600)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
                .tag(Tab.advanced)
        }
    }
}

extension View {
    /// Every pane shares the same width; height varies per tab so short panes don't float in space.
    func settingsPane(height: CGFloat) -> some View {
        formStyle(.grouped)
            .frame(width: 620, height: height)
    }
}
