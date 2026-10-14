#if DEBUG && os(iOS)
    import Darwin
    import Foundation
    import Libbox

    enum PriorityFailoverMemoryCapture {
        static let phases = ["baseline", "primary", "backup", "all_down", "transitions", "background"]

        static func run(server: LibboxCommandServer, phase: String, seconds: Int) async throws {
            guard phases.contains(phase), (1 ... 3600).contains(seconds) else {
                throw NSError(domain: "PriorityFailoverMemory", code: -1)
            }
            let url = FilePath.cacheDirectory.appendingPathComponent("priority-failover-memory-\(phase).csv")
            try Data("elapsed_seconds,phase,selected,metric,unit,footprint_bytes\n".utf8).write(to: url, options: .atomic)
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            let started = ProcessInfo.processInfo.systemUptime
            for _ in 0 ..< seconds {
                try Task.checkCancellation()
                var error: NSError?
                let json = server.priorityFailoverStatus(&error)
                if let error { throw error }
                let status = try JSONDecoder().decode(PriorityFailoverStatus.self, from: Data(json.utf8))
                let selected = (status.selected ?? "disabled").replacingOccurrences(of: "\"", with: "\"\"")
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                let footprint = try footprintBytes()
                let row = "\(elapsed),\(phase),\"\(selected)\",phys_footprint,bytes,\(footprint)\n"
                try file.write(contentsOf: Data(row.utf8))
                try await Task.sleep(nanoseconds: NSEC_PER_SEC)
            }
            try file.synchronize()
        }

        private static func footprintBytes() throws -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else {
                throw NSError(domain: "PriorityFailoverMemory", code: Int(result))
            }
            return info.phys_footprint
        }
    }
#endif
