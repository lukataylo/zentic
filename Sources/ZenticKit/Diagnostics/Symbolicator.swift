import Foundation
import MachO

/// Names a code address from a report, when the binary it points into is
/// loaded in this process right now — the same build of Zentic, and the
/// system libraries of this macOS.
///
/// Reports from MetricKit carry only "binary UUID + offset". Matching by UUID
/// means a report from a different build is left as offsets rather than given
/// plausible wrong names; the offsets stay in the report for the developer.
public enum Symbolicator {
    /// "Browser.close(_:) + 120", or nil when the binary is not loaded or
    /// has no symbol there.
    public static func symbol(binaryUUID: String, offset: UInt64) -> String? {
        guard let uuid = UUID(uuidString: binaryUUID), let header = loadedImage(uuid) else { return nil }
        let address = UnsafeRawPointer(header).advanced(by: Int(offset))
        var info = Dl_info()
        guard dladdr(address, &info) != 0, let name = info.dli_sname, let start = info.dli_saddr else {
            return nil
        }
        let distance = address - UnsafeRawPointer(start)
        return "\(demangle(String(cString: name))) + \(distance)"
    }

    /// The mach header of the loaded image with this UUID, if any. Images
    /// load and unload, so this is looked up per report rather than cached.
    static func loadedImage(_ uuid: UUID) -> UnsafePointer<mach_header>? {
        for index in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(index) else { continue }
            if imageUUID(header) == uuid { return header }
        }
        return nil
    }

    static func imageUUID(_ header: UnsafePointer<mach_header>) -> UUID? {
        // Every loaded image is 64-bit on the Macs Zentic runs on.
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == LC_UUID {
                let bytes = command.load(as: uuid_command.self).uuid
                return UUID(uuid: bytes)
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        return nil
    }

    /// Swift symbols are mangled ("$s6Zentic7BrowserC5closeyyAA3TabCF");
    /// the runtime that mangled them can read them back.
    static func demangle(_ name: String) -> String {
        guard name.hasPrefix("$s") || name.hasPrefix("_$s") else { return name }
        return name.withCString { pointer in
            guard let demangled = swift_demangle(pointer, strlen(pointer), nil, nil, 0) else { return name }
            defer { free(demangled) }
            return String(cString: demangled)
        }
    }
}

@_silgen_name("swift_demangle")
private func swift_demangle(
    _ mangledName: UnsafePointer<CChar>, _ mangledNameLength: Int,
    _ outputBuffer: UnsafeMutablePointer<CChar>?, _ outputBufferSize: UnsafeMutablePointer<Int>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<CChar>?
