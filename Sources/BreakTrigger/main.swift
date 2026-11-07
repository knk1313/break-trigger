import AppKit

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
// Dock に出さず、メニューバーだけに置く
app.setActivationPolicy(.accessory)
app.run()
