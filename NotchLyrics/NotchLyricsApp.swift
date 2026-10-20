//
//  NotchLyricsApp.swift
//  NotchLyrics
//
//  Created by Krish Verma on 20/10/26.
//

import SwiftUI

@main
struct NotchLyricsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let nowPlaying = NowPlayingModel()
    private var notchPanelController: NotchPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        nowPlaying.start()

        let controller = NotchPanelController(model: nowPlaying)
        controller.show()
        notchPanelController = controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
