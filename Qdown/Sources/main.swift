import AppKit

// Qdown deliberately has no storyboard/nib. NSApplication is configured by hand
// so that the app is a plain document-based AppKit application.
let application = NSApplication.shared
let applicationDelegate = AppDelegate()
application.delegate = applicationDelegate
application.setActivationPolicy(.regular)
application.run()
