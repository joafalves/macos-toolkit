import Foundation

/// CPU and GPU energy from IOReport, the private library behind
/// `powermetrics`. Subscribed to only while the power panel is open, or on a
/// Mac without a battery while the power stat is read, and let go of after. (macOS's own frameworks have the library loaded in
/// every app anyway.) Some Macs report CPU energy only to root; there it
/// reads as nothing rather than as zero watts.
final class EnergyReport {
    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                                                           UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDelta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias IntegerValue = @convention(c) (CFDictionary, Int32) -> Int64

    private let library: UnsafeMutableRawPointer
    private let createSamples: CreateSamples
    private let createDelta: CreateDelta
    private let channelName: ChannelString
    private let unitLabel: ChannelString
    private let integerValue: IntegerValue
    private let subscription: OpaquePointer
    private let channels: CFMutableDictionary
    private var last: (sample: CFDictionary, time: TimeInterval)?

    static let path = "/usr/lib/libIOReport.dylib"

    /// Nil where the library or its energy channels aren't there.
    init?() {
        guard let library = dlopen(Self.path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: type) }
        }
        guard let copyChannels = symbol("IOReportCopyChannelsInGroup", CopyChannels.self),
              let createSubscription = symbol("IOReportCreateSubscription", CreateSubscription.self),
              let createSamples = symbol("IOReportCreateSamples", CreateSamples.self),
              let createDelta = symbol("IOReportCreateSamplesDelta", CreateDelta.self),
              let channelName = symbol("IOReportChannelGetChannelName", ChannelString.self),
              let unitLabel = symbol("IOReportChannelGetUnitLabel", ChannelString.self),
              let integerValue = symbol("IOReportSimpleGetIntegerValue", IntegerValue.self),
              let group = copyChannels("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let wanted = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, group) else {
            dlclose(library)
            return nil
        }
        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, wanted, &subscribed, 0, nil),
              let channels = subscribed?.takeRetainedValue() else {
            dlclose(library)
            return nil
        }
        self.library = library
        self.createSamples = createSamples
        self.createDelta = createDelta
        self.channelName = channelName
        self.unitLabel = unitLabel
        self.integerValue = integerValue
        self.subscription = subscription
        self.channels = channels
    }

    deinit {
        // The subscription is a CF object; it goes before the library does.
        Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(subscription)).release()
        last = nil
        dlclose(library)
    }

    /// Watts since the last read; nil the first time, and for what wasn't reported.
    func read() -> (cpu: Double?, gpu: Double?) {
        guard let sample = createSamples(subscription, channels, nil)?.takeRetainedValue() else { return (nil, nil) }
        let now = ProcessInfo.processInfo.systemUptime
        defer { last = (sample, now) }
        guard let last, now - last.time > 0.2,
              let delta = createDelta(last.sample, sample, nil)?.takeRetainedValue() as? [String: Any],
              let list = delta["IOReportChannels"] as? [CFDictionary] else { return (nil, nil) }
        var cpu: Double?, gpu: Double?
        for channel in list {
            guard let name = channelName(channel)?.takeUnretainedValue() as String?,
                  name == "CPU Energy" || name == "GPU Energy" else { continue }
            let joules = Double(integerValue(channel, 0)) * Self.scale(unitLabel(channel)?.takeUnretainedValue() as String?)
            // A channel that reads nothing at all isn't reported to this process.
            guard joules > 0 else { continue }
            if name == "CPU Energy" { cpu = joules / (now - last.time) } else { gpu = joules / (now - last.time) }
        }
        return (cpu, gpu)
    }

    private static func scale(_ unit: String?) -> Double {
        switch unit {
        case "mJ": return 1e-3
        case "uJ", "µJ": return 1e-6
        case "nJ": return 1e-9
        default: return 1
        }
    }
}
