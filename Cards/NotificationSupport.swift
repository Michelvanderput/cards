import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum NotificationSupport {
    static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional: "Aan"
        case .denied: "Uit voor Cards (zet aan in Instellingen)"
        case .notDetermined: "Nog niet gevraagd"
        @unknown default: "Onbekend"
        }
    }

    static func isAllowed(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional
    }

    /// Opent de systeeminstellingen voor meldingen van deze app.
    static func openSystemSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
        #endif
    }
}
