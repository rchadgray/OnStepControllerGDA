import SwiftUI

// Shared navigation state — lets any view switch the active tab.
// Also owns the star alignment session so SetupView can start it
// and SkyChartView can drive it without passing state through bindings.
@Observable
final class AppState {
    var selectedTab: Int = 0

    // Alignment session state
    var isAligning:              Bool     = false
    var alignmentStarCount:      Int      = 1
    var alignmentNextStar:       Int      = 1
    var alignmentTotalStars:     Int      = 0
    var alignmentUsedStarNames:  [String] = []
    var alignmentCurrentStarName: String  = ""
    var alignmentCurrentRA:      String   = ""
    var alignmentCurrentDec:     String   = ""
    var alignmentShowPanel:      Bool     = false
    var alignmentIsComplete:     Bool     = false

    func endAlignment() {
        isAligning               = false
        alignmentShowPanel       = false
        alignmentIsComplete      = false
        alignmentUsedStarNames   = []
        alignmentCurrentStarName = ""
        alignmentCurrentRA       = ""
        alignmentCurrentDec      = ""
    }
}

// Tab indices
extension AppState {
    static let tabSetup   = 0
    static let tabControl = 1
    static let tabGoTo    = 2
    static let tabSky     = 3
}

struct ContentView: View {
    @StateObject var telescope       = OnStepManager()
    @StateObject var bluetooth       = BluetoothManager()
    @StateObject var locationManager = LocationManager()
    @State var appState = AppState()

    var body: some View {
        TabView(selection: $appState.selectedTab) {
            SetupView()
                .tabItem { Label("Setup",   systemImage: "slider.horizontal.3") }
                .tag(AppState.tabSetup)

            ControlView()
                .tabItem { Label("Control", systemImage: "gamecontroller") }
                .tag(AppState.tabControl)

            GoToView()
                .tabItem { Label("GoTo",    systemImage: "location.north.line") }
                .tag(AppState.tabGoTo)

            SkyChartView()
                .tabItem { Label("Sky",     systemImage: "sparkles") }
                .tag(AppState.tabSky)
        }
        .environmentObject(telescope)
        .environmentObject(bluetooth)
        .environmentObject(locationManager)
        .environment(appState)
        .preferredColorScheme(.dark)
        .tint(.astroRed)
    }
}

#Preview {
    ContentView()
}
