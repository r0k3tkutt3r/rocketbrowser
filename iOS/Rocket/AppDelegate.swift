import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Incognito stores orphaned by the app being killed with private tabs open.
        IncognitoSession.purgeLeftoverStores()
        return true
    }
}

/// Named in Info.plist's scene manifest.
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?
    private let browser = BrowserViewController()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = browser
        window.makeKeyAndVisible()
        self.window = window

        ContentBlocker.shared.applyToAllWebViews = { [weak browser] in
            browser?.reapplyContentRules()
        }
        // Tabs open once the rule lists are compiled (a cache lookup after the first
        // launch), so the first page is never loaded unblocked. Unlike the Mac, tabs
        // always come back: iOS ends a backgrounded app on its own, and losing every
        // tab to that would read as a crash, not as a launch preference.
        ContentBlocker.shared.prepare { [browser] in
            browser.restoreSession()
        }
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        browser.setMediaSuspended(false)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        browser.currentTab?.resumeActiveTiming()
        SuggestionEngine.shared.retrainIfDue { [browser] trained in
            if trained { browser.reloadNewTabPages() }
        }
    }

    func sceneWillResignActive(_ scene: UIScene) {
        browser.currentTab?.pauseActiveTiming()
    }

    /// The last moment the app is sure to run: iOS may end it any time after this.
    func sceneDidEnterBackground(_ scene: UIScene) {
        browser.setMediaSuspended(true)
        HistoryStore.shared.flush()
        // No tabs means the saved session has not been restored yet; writing now
        // would replace it with nothing.
        guard !browser.tabs.isEmpty else { return }
        SessionStore.shared.flush { browser.sessionSnapshot() }
    }
}
