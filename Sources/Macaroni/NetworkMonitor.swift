import Foundation
import Darwin

/// Live network throughput, read straight from the kernel's per-interface byte
/// counters — the same numbers `netstat -ib` prints.
///
/// No permissions, no probing, no traffic of its own: it asks sysctl for the
/// cumulative byte totals once a second and divides the difference by the time
/// elapsed. Costs microseconds per tick.
final class NetworkMonitor {

    /// Bytes per second, refreshed every tick.
    private(set) var downloadRate: Double = 0
    private(set) var uploadRate: Double = 0

    /// Moved since Macaroni launched.
    private(set) var sessionReceived: UInt64 = 0
    private(set) var sessionSent: UInt64 = 0

    /// The busiest physical interface — what you're actually using.
    private(set) var interfaceName: String = "—"

    var onUpdate: (() -> Void)?

    private var lastReceived: UInt64?
    private var lastSent: UInt64?
    private var lastSampleTime: CFAbsoluteTime?
    private var baselineReceived: UInt64?
    private var baselineSent: UInt64?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        sample()
        // .common mode so it keeps ticking while the panel is open and while
        // menus are tracking — the menu bar readout must never freeze.
        let newTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Sampling

    private func sample() {
        guard let counters = Self.readCounters() else { return }
        let now = CFAbsoluteTimeGetCurrent()

        if baselineReceived == nil {
            baselineReceived = counters.received
            baselineSent = counters.sent
        }
        sessionReceived = counters.received &- (baselineReceived ?? counters.received)
        sessionSent = counters.sent &- (baselineSent ?? counters.sent)

        if let previousReceived = lastReceived,
           let previousSent = lastSent,
           let previousTime = lastSampleTime {
            let elapsed = now - previousTime
            if elapsed > 0.05 {
                // Counters only climb; a drop means an interface reset or came
                // and went, so treat it as zero rather than a huge spike.
                let deltaIn = counters.received >= previousReceived ? counters.received - previousReceived : 0
                let deltaOut = counters.sent >= previousSent ? counters.sent - previousSent : 0
                downloadRate = Double(deltaIn) / elapsed
                uploadRate = Double(deltaOut) / elapsed
            }
        }

        lastReceived = counters.received
        lastSent = counters.sent
        lastSampleTime = now
        if !counters.busiestInterface.isEmpty {
            interfaceName = counters.busiestInterface
        }

        onUpdate?()
    }

    private struct Counters {
        let received: UInt64
        let sent: UInt64
        let busiestInterface: String
    }

    /// Walks the kernel's interface list and sums the physical ones.
    ///
    /// NET_RT_IFLIST2 hands back `if_data64`, so the counters are 64-bit and
    /// won't wrap the way the old 32-bit ones did on a busy link.
    private static func readCounters() -> Counters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        var busiestName = ""
        var busiestBytes: UInt64 = 0

        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0

            while offset + MemoryLayout<if_msghdr>.size <= length {
                let messagePointer = base.advanced(by: offset)
                let header = messagePointer.assumingMemoryBound(to: if_msghdr.self).pointee
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }

                guard Int32(header.ifm_type) == RTM_IFINFO2 else { continue }
                guard offset + MemoryLayout<if_msghdr2>.size <= length else { continue }

                let info = messagePointer.assumingMemoryBound(to: if_msghdr2.self).pointee

                // The interface name lives in the sockaddr_dl right after the header.
                let linkPointer = messagePointer
                    .advanced(by: MemoryLayout<if_msghdr2>.size)
                    .assumingMemoryBound(to: sockaddr_dl.self)
                let name = interfaceName(from: linkPointer)
                guard isPhysical(name) else { continue }

                let received = info.ifm_data.ifi_ibytes
                let sent = info.ifm_data.ifi_obytes
                totalIn &+= received
                totalOut &+= sent

                if received &+ sent > busiestBytes {
                    busiestBytes = received &+ sent
                    busiestName = name
                }
            }
        }

        return Counters(received: totalIn, sent: totalOut, busiestInterface: busiestName)
    }

    private static func interfaceName(from pointer: UnsafePointer<sockaddr_dl>) -> String {
        let nameLength = Int(pointer.pointee.sdl_nlen)
        guard nameLength > 0 else { return "" }
        return withUnsafePointer(to: pointer.pointee.sdl_data) { dataPointer in
            dataPointer.withMemoryRebound(to: UInt8.self, capacity: nameLength) { bytes in
                String(decoding: UnsafeBufferPointer(start: bytes, count: nameLength), as: UTF8.self)
            }
        }
    }

    /// Only real Wi-Fi/Ethernet links count.
    ///
    /// Loopback would count local traffic, Apple's virtual interfaces (AWDL for
    /// AirDrop, bridges, Thunderbolt bridges) would double-count, and including
    /// VPN tunnels (`utun`) counts the same packets twice — once tunnelled and
    /// once on the wire.
    private static func isPhysical(_ name: String) -> Bool {
        guard name.hasPrefix("en") else { return false }
        return true
    }

    // MARK: - Formatting

    /// Compact, fixed-ish width so the menu bar item doesn't jitter as numbers
    /// change: "0 KB/s", "986 KB/s", "12.4 MB/s".
    static func formatRate(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value < 1_024 {
            return "\(Int(value)) B/s"
        }
        let kilobytes = value / 1_024
        if kilobytes < 1_000 {
            return "\(Int(kilobytes.rounded())) KB/s"
        }
        let megabytes = kilobytes / 1_024
        if megabytes < 100 {
            return String(format: "%.1f MB/s", megabytes)
        }
        return "\(Int(megabytes.rounded())) MB/s"
    }

    static func formatTotal(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
