import LyfeKit
import UIKit
import UserNotifications

/// Receives the device token Apple issues for notifications and hands it
/// on. The backend decides what is sent; this only says where to send it.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set by the app once its model exists.
    var onDeviceToken: ((String) -> Void)?

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        onDeviceToken?(deviceToken.map { String(format: "%02x", $0) }.joined())
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("lyfe: could not register for notifications: \(error.localizedDescription)")
    }

    /// A prompt that arrives while lyfe is open is still shown.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

/// Asks once for permission to notify, and registers with Apple whenever
/// permission stands. Safe to call on every launch: the system only shows
/// its question the first time.
@MainActor
func enableNotifications(for model: AppModel) async {
    let center = UNUserNotificationCenter.current()
    let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    model.notificationsAllowed = allowed
    if allowed {
        UIApplication.shared.registerForRemoteNotifications()
    }
}
