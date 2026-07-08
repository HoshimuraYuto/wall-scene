import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
// Top-level code in main.swift is treated as nonisolated by the type system, but at runtime it
// always runs synchronously on the main thread (before the RunLoop starts). This assertion aligns
// the code with the actual isolation assumption; it does not change threading/timing
MainActor.assumeIsolated {
  app.delegate = delegate
}
app.setActivationPolicy(.accessory)
app.run()
