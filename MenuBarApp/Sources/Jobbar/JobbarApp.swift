import SwiftUI
import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if Notifier.hasBundle {
            UNUserNotificationCenter.current().delegate = self
            Notifier.requestAuth()
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct JobbarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = JobStore()

    var body: some Scene {
        MenuBarExtra {
            ContentView(store: store)
        } label: {
            MenuLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuLabel: View {
    @ObservedObject var store: JobStore
    var body: some View {
        if store.labelIsRed {
            Image(nsImage: Self.render(store.labelText, color: .systemRed))
        } else {
            Text(store.labelText)
        }
    }

    /// Menu bar labels are rendered as templates (monochrome); draw a non-template image to get red.
    static func render(_ s: String, color: NSColor) -> NSImage {
        let str = NSAttributedString(string: s, attributes: [.font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: color])
        let size = str.size()
        let img = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)), flipped: false) { r in
            str.draw(in: r); return true
        }
        img.isTemplate = false
        return img
    }
}
