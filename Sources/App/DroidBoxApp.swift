import SwiftUI
import UIKit

@main
struct DroidBoxApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var session = RemoteSession()

    var body: some View {
        TabView {
            LibraryView(session: session)
                .tabItem { Label("应用", systemImage: "square.stack.3d.up.fill") }

            RemoteConsoleView(session: session)
                .tabItem { Label("远程", systemImage: "display") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .tint(Theme.accent)
        .onAppear { Theme.configureAppearance() }
    }
}

enum Theme {
    static let accent = Color(red: 0.36, green: 0.86, blue: 0.55)
    static let surface = Color(red: 0.09, green: 0.10, blue: 0.12)
    static let card = Color(red: 0.14, green: 0.15, blue: 0.18)

    static func configureAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance

        let navigation = UINavigationBarAppearance()
        navigation.configureWithOpaqueBackground()
        navigation.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1)
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
    }
}
