import Foundation
import IOKit.ps

/// Monitors conditions where we should conserve power (battery power, Low Power Mode, thermal
/// pressure).
@MainActor
final class PowerMonitor {
  /// true = we should conserve power. Called only when the value changes.
  var onChange: ((Bool) -> Void)?
  private(set) var isConstrained: Bool

  private var timer: Timer?
  private var observerTokens: [NSObjectProtocol] = []

  init() {
    isConstrained = PowerMonitor.evaluate()

    let powerStateToken = NotificationCenter.default.addObserver(
      forName: NSNotification.Name.NSProcessInfoPowerStateDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.reevaluate() }
    }
    let thermalToken = NotificationCenter.default.addObserver(
      forName: ProcessInfo.thermalStateDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.reevaluate() }
    }
    observerTokens = [powerStateToken, thermalToken]

    // Detect switches to/from battery power by re-evaluating every 20 seconds; this is
    // prototype-quality.
    let pollTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in self?.reevaluate() }
    }
    RunLoop.main.add(pollTimer, forMode: .common)
    timer = pollTimer
  }

  deinit {
    timer?.invalidate()
    for token in observerTokens {
      NotificationCenter.default.removeObserver(token)
    }
  }

  private func reevaluate() {
    let newValue = PowerMonitor.evaluate()
    guard newValue != isConstrained else { return }
    isConstrained = newValue
    onChange?(newValue)
  }

  private static func evaluate() -> Bool {
    isOnBatteryPower() || ProcessInfo.processInfo.isLowPowerModeEnabled || isThermallyConstrained()
  }

  private static func isThermallyConstrained() -> Bool {
    ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
  }

  private static func isOnBatteryPower() -> Bool {
    guard let snapshotUnmanaged = IOPSCopyPowerSourcesInfo() else { return false }
    let snapshot = snapshotUnmanaged.takeRetainedValue()
    guard let typeUnmanaged = IOPSGetProvidingPowerSourceType(snapshot) else { return false }
    let type = typeUnmanaged.takeUnretainedValue() as String
    return type == (kIOPSBatteryPowerValue as String)
  }
}
