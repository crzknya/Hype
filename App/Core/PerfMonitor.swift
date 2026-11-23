import Foundation
import QuartzCore
import Darwin

/// Lightweight in-app performance monitor (no Xcode needed): CPU used by the app (100% = one core),
/// memory footprint, thermal state, frame rate and a few work counters. Runs only while shown.
@MainActor
@Observable
final class PerfMonitor {
    static let shared = PerfMonitor()

    var cpu = 0.0
    var memoryMB = 0.0
    var thermal = ProcessInfo.ThermalState.nominal
    var fps = 0
    var chartDrawsPerSec = 0
    var messagesPerSec = 0

    @ObservationIgnored private var users = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private let target = DisplayLinkTarget()
    /// Counters bumped from hot paths on the main thread (read and reset once a second).
    nonisolated(unsafe) static var frames = 0
    nonisolated(unsafe) static var chartDraws = 0
    nonisolated(unsafe) static var messages = 0

    func start() {
        users += 1
        guard users == 1 else { return }
        let l = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick))
        l.add(to: .main, forMode: .common)
        link = l
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.sample()
            }
        }
    }

    func stop() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        loop?.cancel(); loop = nil
        link?.invalidate(); link = nil
    }

    private func sample() {
        cpu = Self.cpuUsage()
        memoryMB = Self.memoryFootprintMB()
        thermal = ProcessInfo.processInfo.thermalState
        fps = Self.frames; Self.frames = 0
        chartDrawsPerSec = Self.chartDraws; Self.chartDraws = 0
        messagesPerSec = Self.messages; Self.messages = 0
    }

    var thermalTitle: String {
        switch thermal {
        case .nominal: return L("normal")
        case .fair: return L("warm")
        case .serious: return L("hot")
        case .critical: return L("critical")
        @unknown default: return "?"
        }
    }

    /// Sum of the app's non-idle thread CPU usage, in percent of one core.
    static func cpuUsage() -> Double {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)),
                          vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for i in 0..<Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if kr == KERN_SUCCESS && (info.flags & TH_FLAGS_IDLE) == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return total
    }

    /// Physical memory footprint (what iOS counts against the app), in MB.
    static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

/// CADisplayLink needs an NSObject target.
final class DisplayLinkTarget: NSObject {
    @objc func tick() { PerfMonitor.frames += 1 }
}
