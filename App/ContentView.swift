import SwiftUI

enum AppTab: String {
    case assistant
    case mirror
    case browser
    case demo
}

enum LaunchOptions {
    /// Açılış sekmesi `-CarMirrorTab demo` gibi bir başlatma argümanıyla seçilebilir.
    static var requestedTab: AppTab? {
        AppTab(rawValue: UserDefaults.standard.string(forKey: "CarMirrorTab") ?? "")
    }

    static var initialTab: AppTab {
        requestedTab ?? (AssistantSettings.shared.startsAtLaunch ? .assistant : .mirror)
    }
}

/// Telefonda hangi sekmenin açık olduğu (CarPlay yansıtması buna göre karar verir).
final class AppTabState {
    static let shared = AppTabState()
    var current: AppTab = LaunchOptions.initialTab
}

struct ContentView: View {
    @State private var selectedTab = LaunchOptions.initialTab

    var body: some View {
        TabView(selection: $selectedTab) {
            AssistantView(surface: .phone, engine: .shared, settings: .shared)
                .tabItem { Label("Asistan", systemImage: "waveform.circle") }
                .tag(AppTab.assistant)
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
        .onAppear { AppTabState.shared.current = selectedTab }
        .onChange(of: selectedTab) { _, tab in
            AppTabState.shared.current = tab
            InAppMirror.shared.tabDidChange(tab)
        }
    }
}
