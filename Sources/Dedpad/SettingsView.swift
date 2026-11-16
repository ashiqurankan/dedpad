import SwiftUI
import UniformTypeIdentifiers
import DedpadCore

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AppPrefs.appearance) private var appearance = "system"
    @AppStorage(AppPrefs.drawingPolicy) private var drawingPolicy = "system"
    @AppStorage(AppPrefs.defaultStyle) private var defaultStyle = PaperStyle.ruled.rawValue
    @AppStorage(AppPrefs.defaultPaperColor) private var defaultPaperColor = DedPalette.paper.hex
    @AppStorage(AppPrefs.defaultPageSize) private var defaultPageSize = PageSizePreset.a4.rawValue
    @AppStorage(AppPrefs.defaultOrientation) private var defaultOrientation = PageOrientation.portrait.rawValue
    @AppStorage(AppPrefs.defaultMode) private var defaultMode = PageMode.fixed.rawValue
    @AppStorage(AppPrefs.defaultPageNumbers) private var defaultPageNumbers = PageNumberPosition.bottomCenter.rawValue

    @State private var share: ShareItem?
    @State private var showRestore = false
    @State private var usage: String = "…"

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        Text("Match system").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }

                Section {
                    Picker("Draw with", selection: $drawingPolicy) {
                        Text("Follow iPad setting").tag("system")
                        Text("Apple Pencil only").tag("pencil")
                        Text("Pencil, stylus or finger").tag("any")
                    }
                } header: {
                    Text("Writing")
                } footer: {
                    Text("“Apple Pencil only” gives palm rejection: fingers scroll and zoom, the Pencil writes. Many third-party styluses act like a finger, so choose “Pencil, stylus or finger” for them. Pressure and tilt are used when the stylus reports them.")
                }

                Section("New notebooks") {
                    Picker("Paper", selection: $defaultStyle) {
                        ForEach(PaperCategory.allCases) { cat in
                            Section(cat.name) {
                                ForEach(PaperStyle.styles(in: cat)) { Text($0.name).tag($0.rawValue) }
                            }
                        }
                    }
                    Picker("Paper colour", selection: $defaultPaperColor) {
                        Text("White").tag(DedPalette.paper.hex)
                        Text("Warm").tag(DedPalette.warmPaper.hex)
                        Text("Sage mist").tag(RGBA(0xEEF1EA).hex)
                        Text("Charcoal").tag(RGBA(0x2B2E29).hex)
                    }
                    Picker("Page size", selection: $defaultPageSize) {
                        ForEach(PageSizePreset.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    Picker("Orientation", selection: $defaultOrientation) {
                        ForEach(PageOrientation.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    Picker("Page mode", selection: $defaultMode) {
                        ForEach(PageMode.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    Picker("Page numbers", selection: $defaultPageNumbers) {
                        ForEach(PageNumberPosition.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                }

                Section {
                    LabeledContent("Notebooks", value: "\(library.notebooks.count)")
                    LabeledContent("Space used", value: usage)
                    LabeledContent("Location", value: "On My iPad › dedpad")
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Everything is saved on this iPad as you write, and works without an internet connection. You can browse the files in the Files app.")
                }

                Section {
                    Button {
                        do { share = ShareItem(urls: [try library.libraryBackupFile()]) }
                        catch { library.show("Backup failed", error.localizedDescription) }
                    } label: {
                        Label("Back up all notebooks…", systemImage: "externaldrive.badge.checkmark")
                    }
                    Button { showRestore = true } label: {
                        Label("Restore from backup…", systemImage: "arrow.counterclockwise")
                    }
                } header: {
                    Text("Backup & restore")
                } footer: {
                    Text("A backup is a single .zip with every notebook, folder and template. Restoring adds missing notebooks and updates older copies; it never deletes anything.")
                }

                DriveBackupSection()

                Section {
                    HStack(spacing: 14) {
                        BrandMark(size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("dedpad").font(DedFont.display(17, .heavy)).tracking(-0.6)
                            Text("by Dedstudio · version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                                .font(DedFont.sans(12)).foregroundStyle(Ded.muted)
                        }
                    }
                    Text("Your notebooks. Your pages. Your way.").font(DedFont.mark(15)).foregroundStyle(Ded.accent)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Ded.bg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .fileImporter(isPresented: $showRestore, allowedContentTypes: [.zip]) { result in
                if case let .success(url) = result { library.restoreLibrary(from: url) }
            }
            .sheet(item: $share) { item in ShareSheet(items: item.urls) }
            .alert(item: $library.alert) { a in
                Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
            }
            .task {
                let bytes = library.store.diskUsage()
                usage = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            }
        }
    }
}


// MARK: - Google Drive backup

struct DriveBackupSection: View {
    @EnvironmentObject private var backup: DriveBackup
    @EnvironmentObject private var auth: GoogleAuth
    @State private var working = false
    @State private var error: String?
    @State private var showConfig = false
    @State private var showRestore = false
    @State private var draft = GoogleConfig()

    var body: some View {
        Section {
            if let account = auth.account {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 30)).foregroundStyle(Ded.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.name.isEmpty ? account.email : account.name).font(DedFont.sans(14, .semibold))
                        if !account.name.isEmpty { Text(account.email).font(DedFont.sans(12)).foregroundStyle(Ded.muted) }
                    }
                }
                LabeledContent("Status", value: statusText)
                if let last = backup.lastBackup {
                    LabeledContent("Last backup", value: last.formatted(.relative(presentation: .named)))
                }
                if case let .error(msg) = backup.status {
                    Text(msg).font(DedFont.sans(12.5)).foregroundStyle(Ded.danger)
                }
                Toggle("Back up automatically", isOn: $backup.automatic)
                Toggle("Only on Wi-Fi", isOn: $backup.wifiOnly)
                Button {
                    Task { await backup.backupNow() }
                } label: { Label("Back up now", systemImage: "arrow.up.circle") }
                    .disabled(isWorking)
                Button { showRestore = true } label: {
                    Label("Restore from Google Drive…", systemImage: "arrow.down.circle")
                }
                .disabled(isWorking)
                Button(role: .destructive) { backup.signOut() } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else if auth.config.isComplete {
                Button {
                    working = true
                    error = nil
                    Task {
                        do {
                            try await auth.signIn()
                            backup.signedIn()
                        } catch {
                            if (error as NSError).domain != "com.apple.AuthenticationServices.WebAuthenticationSession" {
                                self.error = error.localizedDescription
                            }
                        }
                        working = false
                    }
                } label: {
                    HStack {
                        Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                        if working { Spacer(); ProgressView() }
                    }
                }
                .disabled(working)
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.xmark").foregroundStyle(Ded.muted)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Google Drive backup isn't set up").font(DedFont.sans(14, .semibold))
                        Text("This build has no Google sign-in client ID yet.")
                            .font(DedFont.sans(12.5)).foregroundStyle(Ded.muted)
                    }
                }
                Button("Add client ID…") {
                    draft = auth.config
                    showConfig = true
                }
                .font(DedFont.sans(13))
            }
            if let error {
                Text(error).font(DedFont.sans(12.5)).foregroundStyle(Ded.danger)
            }
        } header: {
            Text("Google Drive backup")
        } footer: {
            Text("Keeps a copy of your notebooks in a “dedpad” folder in your own Google Drive, using your Drive storage. dedpad can only see the files it creates there — never the rest of your Drive. Your notebooks stay on this iPad and keep working offline.")
        }
        .sheet(isPresented: $showRestore) {
            DriveRestoreView().environmentObject(backup)
        }
        .sheet(isPresented: $showConfig) {
            NavigationStack {
                Form {
                    Section {
                        TextField("iOS OAuth client ID", text: $draft.iosClientId)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    } footer: {
                        Text("From Google Cloud Console › APIs & Services › Credentials (type: iOS). It ends in .apps.googleusercontent.com.")
                    }
                }
                .navigationTitle("Google sign-in")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showConfig = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            draft.iosClientId = draft.iosClientId.trimmingCharacters(in: .whitespacesAndNewlines)
                            auth.updateConfig(draft)
                            showConfig = false
                        }
                        .disabled(!draft.iosClientId.trimmingCharacters(in: .whitespaces).hasSuffix(".apps.googleusercontent.com"))
                    }
                }
            }
        }
    }

    private var isWorking: Bool {
        if case .working = backup.status { return true }
        return false
    }

    private var statusText: String {
        switch backup.status {
        case .off: return "Off"
        case .idle: return backup.lastBackup == nil ? "Not backed up yet" : "Up to date"
        case let .working(s): return s
        case let .waiting(s): return s
        case .error: return "Backup paused"
        }
    }
}

/// Pick notebooks to bring back from Google Drive.
struct DriveRestoreView: View {
    @EnvironmentObject private var backup: DriveBackup
    @Environment(\.dismiss) private var dismiss
    @State private var items: [DriveBackup.RemoteNotebook] = []
    @State private var selected = Set<UUID>()
    @State private var loading = true
    @State private var error: String?
    @State private var confirm = false

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Looking in Google Drive…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView("Couldn't read the backup", systemImage: "exclamationmark.icloud", description: Text(error))
                } else if items.isEmpty {
                    ContentUnavailableView("No backups yet", systemImage: "externaldrive",
                                           description: Text("Notebooks appear here after they've been backed up."))
                } else {
                    List(items, selection: $selected) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title.isEmpty ? "Untitled" : item.title).font(DedFont.sans(15, .semibold))
                            HStack(spacing: 6) {
                                if let d = item.backedUpAt {
                                    Text("Backed up \(d.formatted(.relative(presentation: .named)))")
                                }
                                Text(item.onThisIPad ? "· On this iPad" : "· Not on this iPad")
                                    .foregroundStyle(item.onThisIPad ? Ded.muted : Ded.accent)
                            }
                            .font(DedFont.sans(12)).foregroundStyle(Ded.muted)
                        }
                        .padding(.vertical, 2)
                    }
                    .environment(\.editMode, .constant(.active))
                }
            }
            .navigationTitle("Restore from Google Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") {
                        if replacing.isEmpty { start() } else { confirm = true }
                    }
                    .disabled(selected.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    if !items.isEmpty {
                        Button(selected.count == items.count ? "Select none" : "Select all") {
                            selected = selected.count == items.count ? [] : Set(items.map(\.id))
                        }
                    }
                }
            }
            .alert("Replace notebooks on this iPad?", isPresented: $confirm) {
                Button("Cancel", role: .cancel) {}
                Button("Replace", role: .destructive) { start() }
            } message: {
                Text("\(replacing.count) of the selected notebooks are already on this iPad. They'll be replaced by the version in Google Drive; changes made here since that backup will be lost.")
            }
            .task { await load() }
        }
    }

    private var replacing: [DriveBackup.RemoteNotebook] {
        items.filter { selected.contains($0.id) && $0.onThisIPad }
    }

    private func load() async {
        do {
            items = try await backup.remoteNotebooks()
            selected = Set(items.filter { !$0.onThisIPad }.map(\.id))
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func start() {
        let chosen = items.filter { selected.contains($0.id) }
        dismiss()
        Task { await backup.restore(chosen) }
    }
}

/// Small status line for the library sidebar.
struct BackupStatusLabel: View {
    @EnvironmentObject private var backup: DriveBackup

    var body: some View {
        switch backup.status {
        case .off:
            Text("Stored on this iPad")
        case .idle:
            if let d = backup.lastBackup {
                Label("Backed up \(d.formatted(.relative(presentation: .named)))", systemImage: "checkmark.icloud")
            } else {
                Label("Not backed up yet", systemImage: "icloud")
            }
        case .working:
            Label("Backing up…", systemImage: "arrow.up.icloud")
        case let .waiting(s):
            Label(s, systemImage: "icloud.slash")
        case .error:
            Label("Backup paused", systemImage: "exclamationmark.icloud")
        }
    }
}
