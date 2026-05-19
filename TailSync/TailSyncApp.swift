import SwiftUI

@main
struct TailSyncApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var transferStore = TransferStore(
        photoLibrary: PhotoLibraryClient(),
        uploader: TailscaleUploader()
    )

    init() {
        if ProcessInfo.processInfo.arguments.contains("--taildrop-smoke-test") {
            Task {
                await TaildropSmokeTest.run()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: transferStore)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        transferStore.beginBackgroundContinuation()
                    }
                }
        }
    }
}
