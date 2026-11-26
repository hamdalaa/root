import SwiftUI

/// Built-in presets (read-only) plus user presets with add / edit / delete and a default marker.
struct PresetsSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    @State private var editing: SettingsPresetDraft?
    @State private var pendingDelete: DownloadPreset?

    var body: some View {
        Form {
            Section {
                ForEach(DownloadPreset.builtIn) { preset in
                    PresetRow(preset: preset, isDefault: isDefault(preset), isEditable: false,
                              onSetDefault: { setDefault(preset) })
                }
            } header: {
                Text("Built-in")
            }

            Section {
                if settings.prefs.customPresets.isEmpty {
                    Text("Save your favourite format, quality and subtitle choices as a one-tap preset.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Tokens.space1)
                } else {
                    ForEach(settings.prefs.customPresets) { preset in
                        PresetRow(preset: preset, isDefault: isDefault(preset), isEditable: true,
                                  onSetDefault: { setDefault(preset) },
                                  onEdit: { editing = SettingsPresetDraft(preset: preset, isNew: false) },
                                  onDelete: { pendingDelete = preset })
                    }
                }
                Button {
                    editing = SettingsPresetDraft(preset: DownloadPreset(name: "", symbol: SettingsPresetEditor.symbols[0], fileType: .mp4), isNew: true)
                } label: {
                    Label("Add Preset…", systemImage: "plus")
                }
            } header: {
                Text("Custom")
            } footer: {
                SettingsFooter("The default preset is used for quick downloads from the toolbar, menu bar, clipboard and Services menu.")
            }
        }
        .sheet(item: $editing) { draft in
            SettingsPresetEditor(draft: draft, onSave: save)
        }
        .confirmationDialog("Delete \"\(pendingDelete?.name ?? "")\"?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { preset in
            Button("Delete Preset", role: .destructive) { delete(preset) }
        }
    }

    private func isDefault(_ preset: DownloadPreset) -> Bool { settings.prefs.defaultPreset.id == preset.id }

    private func setDefault(_ preset: DownloadPreset) { settings.setPref(\.defaultPresetID, preset.id) }

    private func save(_ draft: SettingsPresetDraft) {
        var preset = draft.preset
        preset.name = preset.name.trimmingCharacters(in: .whitespaces)
        let existing = settings.prefs.customPresets
        settings.setPref(\.customPresets, existing.contains { $0.id == preset.id }
            ? existing.map { $0.id == preset.id ? preset : $0 }
            : existing + [preset])
    }

    private func delete(_ preset: DownloadPreset) {
        var prefs = settings.prefs
        prefs.customPresets = prefs.customPresets.filter { $0.id != preset.id }
        if prefs.defaultPresetID == preset.id { prefs.defaultPresetID = DownloadPreset.builtIn.first?.id }
        // Platforms that used the deleted preset fall back to their default.
        prefs.platformPresets = prefs.platformPresets.filter { $0.value != preset.id }
        if prefs != settings.prefs { settings.prefs = prefs }
        pendingDelete = nil
    }
}

private struct PresetRow: View {
    var preset: DownloadPreset
    var isDefault: Bool
    var isEditable: Bool
    var onSetDefault: () -> Void
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Tokens.space3) {
            Image(systemName: preset.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.parabolicAccent)
                .frame(width: 28, height: 28)
                .background(Color.parabolicAccent.opacity(0.12), in: .rect(cornerRadius: Tokens.radiusControl))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(preset.name).font(.system(size: 13))
                    if isDefault {
                        Text("Default")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.parabolicAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.parabolicAccent.opacity(0.12), in: .capsule)
                    }
                }
                Text(preset.settingsSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: Tokens.space1) {
                if !isDefault {
                    Button("Set as Default", action: onSetDefault)
                }
                if isEditable {
                    Button("Edit", action: onEdit)
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                        .help("Delete preset")
                        .accessibilityLabel("Delete \(preset.name)")
                }
            }
            .buttonStyle(.borderless)
            .opacity(isHovered ? 1 : 0)
        }
        .contentShape(.rect)
        .onHover { hovering in withAnimation(Tokens.quick) { isHovered = hovering } }
        .onTapGesture(count: 2) { if isEditable { onEdit() } }
        .contextMenu {
            Button("Set as Default", action: onSetDefault).disabled(isDefault)
            if isEditable {
                Button("Edit…", action: onEdit)
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Set as default", onSetDefault)
    }
}

extension DownloadPreset {
    /// "MP4 · 1080p · EN, AR subtitles · split chapters"
    var settingsSummary: String {
        var parts = [fileType.label]
        if fileType.isAudio {
            parts.append(audioQuality.label)
        } else {
            parts.append(videoQuality.label)
        }
        if !subtitleLanguages.isEmpty {
            parts.append(subtitleLanguages.map { $0.uppercased() }.joined(separator: ", ") + " subtitles")
        }
        if splitChapters { parts.append("split chapters") }
        return parts.joined(separator: " · ")
    }
}
