import SwiftUI

@main
struct PiVoicePhoneApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environment(\.voiceVisualLevels, model.voiceVisualLevels)
                .onOpenURL { model.handleOpenURL($0) }
                .onAppear { model.presentationVisibilityChanged(scenePhase == .active) }
                .onChange(of: scenePhase) { _, phase in
                    model.presentationVisibilityChanged(phase == .active)
                    if phase == .background { Task { await model.enteredBackground() } }
                    else if phase == .active { model.becameActive() }
                }
        }
    }
}
