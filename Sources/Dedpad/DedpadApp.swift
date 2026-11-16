import SwiftUI
import DedpadCore

@main
struct DedpadApp: App {
    @StateObject private var library: LibraryModel
    @StateObject private var auth: GoogleAuth
    @StateObject private var backup: DriveBackup
    @AppStorage(AppPrefs.appearance) private var appearance = "system"
    @Environment(\.scenePhase) private var scenePhase

    init() {
        DedFont.registerBundledFonts()
        let library = LibraryModel()
        let auth = GoogleAuth()
        _library = StateObject(wrappedValue: library)
        _auth = StateObject(wrappedValue: auth)
        _backup = StateObject(wrappedValue: DriveBackup(library: library, auth: auth))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(auth)
                .environmentObject(backup)
                .tint(Ded.accent)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .onOpenURL { url in
                    library.importFiles([url])
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { backup.schedule(after: 5) }
            if phase == .background { backup.appWillResignActive() }
        }
    }
}
