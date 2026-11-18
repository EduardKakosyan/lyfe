import LyfeKit
import UIKit
import UserNotifications

/// Owns the app's model, receives the device token Apple issues for
/// notifications, and answers the morning weigh-in prompt. The backend
/// decides what is sent; this says where to send it and takes the replies.
///
/// The model lives here rather than in a SwiftUI view, because a weight
/// typed into the prompt on the lock screen launches lyfe in the background
/// with no screen at all, and the reply still has to reach the model.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel.live(
        deviceName: UIDevice.current.name,
        // Set per machine in Local.xcconfig, so the address is not in the
        // repository and does not have to be typed on the phone.
        defaultServerAddress: Bundle.main.object(forInfoDictionaryKey: "LyfeDefaultServer") as? String ?? "",
        ownerCheck: AppDelegate.ownerCheck
    )

    /// Face ID each time lyfe is opened. A development build launched to
    /// run by itself (LYFE_DEBUG_BREATH_RUN, or LYFE_DEBUG_UNLOCKED) is not
    /// stopped by it, and LYFE_DEBUG_LOCKED replaces Face ID with a fixed
    /// answer.
    private static var ownerCheck: any OwnerCheck {
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if environment["LYFE_DEBUG_BREATH_RUN"] != nil || environment["LYFE_DEBUG_UNLOCKED"] != nil {
                return NoOwnerCheck()
            }
            if let locked = environment["LYFE_DEBUG_LOCKED"] {
                return StubbedOwnerCheck(passes: locked == "open")
            }
        #endif
        return DeviceOwnerCheck()
    }

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        // Both before launching finishes, or a reply that launched the app
        // would not be handed over.
        center.delegate = self
        center.setNotificationCategories([Self.weighInCategory])
        return true
    }

    /// The morning prompt gets a field to type the weight into. It needs
    /// no unlock and does not open lyfe, so it is the one thing that works
    /// without Face ID: a weight can be added from the lock screen, and
    /// nothing can be read there.
    static let weighInCategory = UNNotificationCategory(
        identifier: WeighInPrompt.category,
        actions: [
            UNTextInputNotificationAction(
                identifier: WeighInPrompt.replyAction, title: "Type weight", options: [],
                textInputButtonTitle: "Save", textInputPlaceholder: "Weight, like 181.4")
        ],
        intentIdentifiers: [], options: [])

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await model.setPushToken(token) }
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

    /// The owner answered a notification. For the weigh-in prompt that is
    /// either a weight typed into it, which is stored and sent before this
    /// returns, or a tap on the prompt itself, which opens the weight entry.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.content.categoryIdentifier == WeighInPrompt.category else { return }
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        let tapped = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        await answerWeighIn(typed: typed, tapped: tapped)
    }

    @MainActor
    private func answerWeighIn(typed: String?, tapped: Bool) async {
        if let typed {
            let outcome = await model.recordWeight(typed)
            if let again = WeightText.retry(after: outcome, typed: typed, unit: model.weightUnit) {
                await askAgain(title: again.title, body: again.body)
            }
        } else if tapped {
            model.openWeighIn()
        }
    }

    /// A reply that was not a weight is asked for again at once, with the
    /// same field, rather than lost without a word.
    private func askAgain(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = WeighInPrompt.category
        let request = UNNotificationRequest(identifier: "weigh-in-again", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

#if DEBUG
    /// A check with a fixed answer, for trying the lock in the simulator
    /// without its Face ID panel: LYFE_DEBUG_LOCKED keeps lyfe locked,
    /// LYFE_DEBUG_LOCKED=open lets it open each time.
    private struct StubbedOwnerCheck: OwnerCheck {
        var passes: Bool
        var isAvailable: Bool { true }
        func confirm(reason: String) async -> Bool { passes }
    }
#endif

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
