import Foundation

/// OasesChat's counterpart of OpenMinis `ISHKernel.shared.refreshDns()`:
/// copies the iOS resolver configuration into the guest's /etc/resolv.conf
/// via `oases_refresh_dns()` (vendor/iSH/runtime/ISHRuntimeInit.m).
///
/// Called once the runtime boots and on every network path change
/// (`NetworkMonitor`), so apk/curl/pip inside iSH resolve through whatever
/// DNS the device is using — Wi-Fi, cellular or a VPN.
final class OasesDnsBridge: @unchecked Sendable {
    static let shared = OasesDnsBridge()
    private init() {}

    /// Returns `true` when resolv.conf is current; `false` before the runtime
    /// has booted (the boot path calls this again) or when the write failed.
    @discardableResult
    func refreshIfAvailable() -> Bool {
        guard ish_runtime_is_ready() != 0 else { return false }
        return oases_refresh_dns() == 0
    }
}
