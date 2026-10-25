import SwiftUI

enum AppTab: String {
    case mirror
    case browser
    case demo
}

enum LaunchOptions {
    /// Açılış sekmesi `-CarMirrorTab demo` gibi bir başlatma argümanıyla seçilebilir.
    static var initialTab: AppTab {
        AppTab(rawValue: UserDefaults.standard.string(forKey: "CarMirrorTab") ?? "") ?? .mirror
    }
}

struct ContentView: View {
    @State private var selectedTab = LaunchOptions.initialTab

    var body: some View {
        TabView(selection: $selectedTab) {
            MirrorControlView()
                .tabItem { Label("Yansıt", systemImage: "rectangle.on.rectangle") }
                .tag(AppTab.mirror)
            BrowserView()
                .tabItem { Label("Tarayıcı", systemImage: "safari") }
                .tag(AppTab.browser)
            DemoView()
                .tabItem { Label("Demo", systemImage: "play.tv") }
                .tag(AppTab.demo)
        }
    }
}
