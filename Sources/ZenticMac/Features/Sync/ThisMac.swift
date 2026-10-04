import CryptoKit
import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration
import ZenticKit

/// How this Mac introduces itself to the user's other Macs.
enum ThisMac {
    /// The name from System Settings › General › Sharing, read each time so a
    /// rename shows up on the next send. Not `Host.current()`, which can wait
    /// on the network.
    static var name: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }

    /// A Mac with an internal battery is a laptop. The model identifier no
    /// longer says (Apple silicon Macs are all "Mac14,2" and the like).
    static let kind: SyncedDevice.Kind = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return .desktop }
        let hasBattery = sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
        return hasBattery ? .laptop : .desktop
    }()

    /// This Mac's record name. From the hardware, not stored: preferences
    /// copied to a new Mac by Migration Assistant would otherwise give two
    /// Macs one record, each overwriting the other's tabs. Hashed, so the
    /// hardware id itself never leaves the Mac; mixed with the data directory,
    /// so an isolated run is a device of its own.
    static let syncID: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let hardware =
            IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? ""
        let digest = SHA256.hash(data: Data((hardware + "|" + DataDirectory.root.path).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }()
}
