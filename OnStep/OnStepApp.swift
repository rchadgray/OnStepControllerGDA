import SwiftUI

// App entry point. Xcode requires exactly one @main struct.
// ContentView is the root of the entire UI — it creates the shared
// OnStepManager, BluetoothManager, and LocationManager objects and
// injects them into the SwiftUI environment for all child views to use.
@main
struct OnStepApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
