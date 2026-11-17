import AppKit

// Qdown deliberately has no storyboard/nib. NSApplication is configured by hand
// so that the app is a plain document-based AppKit application.
//
// The app delegate and all AppKit setup are main-actor isolated; the process
// entry point itself is the main thread, so assume that isolation here. The
// delegate is stored in a global so it stays alive for the whole run loop even
// though NSApplication only keeps a weak reference to it.
let applicationDelegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.delegate = applicationDelegate
    application.setActivationPolicy(.regular)
    application.run()
}
