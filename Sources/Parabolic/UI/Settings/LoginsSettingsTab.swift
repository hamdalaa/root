import SwiftUI

/// Saved site logins. Names and usernames live in preferences; passwords live in the Keychain.
struct LoginsSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    @State private var editing: CredentialDraft?
    @State private var pendingDelete: Credential?

    var body: some View {
        Form {
            Section {
                if settings.prefs.credentials.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "person.badge.key")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No saved logins")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Add a login for sites that need an account,\nor a password for protected videos.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Tokens.space4)
                    .accessibilityElement(children: .combine)
                } else {
                    ForEach(settings.prefs.credentials) { credential in
                        CredentialRow(credential: credential,
                                      onEdit: { editing = CredentialDraft(editing: credential) },
                                      onDelete: { pendingDelete = credential })
                    }
                }
                Button {
                    editing = CredentialDraft()
                } label: {
                    Label("Add Login…", systemImage: "plus")
                }
            } header: {
                Text("Saved logins")
            } footer: {
                SettingsFooter("Passwords are stored in your login keychain. Leave the username empty to save a video password (for a password-protected video).")
            }
        }
        .sheet(item: $editing) { draft in
            CredentialEditor(draft: draft, onSave: save)
        }
        .confirmationDialog("Delete \"\(pendingDelete?.name ?? "")\"?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { credential in
            Button("Delete Login", role: .destructive) { delete(credential) }
        } message: { _ in
            Text("The password is removed from your keychain.")
        }
    }

    private func save(_ draft: CredentialDraft) {
        let credential = Credential(id: draft.id, name: draft.name.trimmingCharacters(in: .whitespaces),
                                    username: draft.username.trimmingCharacters(in: .whitespaces))
        let existing = settings.prefs.credentials
        settings.setPref(\.credentials, existing.contains { $0.id == draft.id }
            ? existing.map { $0.id == draft.id ? credential : $0 }
            : existing + [credential])
        if draft.passwordChanged {
            Keychain.setPassword(draft.password, for: draft.id)
        }
    }

    private func delete(_ credential: Credential) {
        Keychain.deletePassword(for: credential.id)
        settings.setPref(\.credentials, settings.prefs.credentials.filter { $0.id != credential.id })
        pendingDelete = nil
    }
}

private struct CredentialRow: View {
    var credential: Credential
    var onEdit: () -> Void
    var onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Tokens.space3) {
            Image(systemName: credential.username.isEmpty ? "lock.rectangle" : "person.crop.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.parabolicAccent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(credential.name).font(.system(size: 13))
                Text(credential.username.isEmpty ? "Video password" : credential.username)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: Tokens.space1) {
                Button("Edit", action: onEdit)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .help("Delete login")
                .accessibilityLabel("Delete \(credential.name)")
            }
            .buttonStyle(.borderless)
            .opacity(isHovered ? 1 : 0.55)
        }
        .contentShape(.rect)
        .onHover { hovering in withAnimation(Tokens.quick) { isHovered = hovering } }
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit…", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Edit", onEdit)
        .accessibilityAction(named: "Delete", onDelete)
    }
}

private struct CredentialDraft: Identifiable {
    var id = UUID()
    var name = ""
    var username = ""
    var password = ""
    var isNew = true
    var passwordChanged = false

    init() {}

    init(editing credential: Credential) {
        id = credential.id
        name = credential.name
        username = credential.username
        password = Keychain.password(for: credential.id) ?? ""
        isNew = false
    }
}

private struct CredentialEditor: View {
    @State var draft: CredentialDraft
    var onSave: (CredentialDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool { !draft.name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. Instagram"))
                    TextField("Username", text: $draft.username, prompt: Text("Optional"))
                        .autocorrectionDisabled()
                        .textContentType(.username)
                    SecureField("Password", text: Binding(
                        get: { draft.password },
                        set: { draft.password = $0; draft.passwordChanged = true }))
                        .textContentType(.password)
                } header: {
                    Text(draft.isNew ? "New login" : "Edit login")
                } footer: {
                    SettingsFooter("Leave the username empty for a video password.")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Add" : "Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding([.horizontal, .bottom], Tokens.space5)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
