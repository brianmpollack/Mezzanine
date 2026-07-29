//
//  MezzanineApp.swift
//  Mezzanine
//
//  Created by Brian Pollack on 7/24/26.
//

import SwiftUI

@main
struct MezzanineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Everything lives in the status item and its panel, so there are no
        // scenes here. Settings{} keeps SwiftUI happy without opening a window.
        Settings {
            EmptyView()
        }
    }
}
