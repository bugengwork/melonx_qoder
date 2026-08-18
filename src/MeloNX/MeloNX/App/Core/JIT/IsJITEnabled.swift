//
//  IsJITEnabled.swift
//  MeloNX
//
//  Created by Stossy11 on 10/02/2025.
//

import Foundation

@_silgen_name("csops")
func csops(pid: Int32, ops: Int32, useraddr: UnsafeMutableRawPointer?, usersize: Int32) -> Int32

// MARK: - JIT 诊断结构体（G1）

/// JIT 诊断结果：替代布尔返回值，给出具体失败原因与可执行建议。
struct JITDiagnosis {
    enum Status: String {
        case enabled
        case notDebugged
        case dualmappedFailed
        case memoryTestFailed
        case unknown
    }

    let status: Status
    /// 用户可读的原因说明
    let detail: String
    /// 用户可执行的下一步建议
    let suggestion: String
    /// 是否允许用户“忽略并继续”（继续会大概率崩溃）
    let canProceedAnyway: Bool

    static let enabled = JITDiagnosis(
        status: .enabled,
        detail: "JIT is enabled and working correctly.",
        suggestion: "",
        canProceedAnyway: true
    )

    static func failure(_ status: Status, detail: String, suggestion: String, canProceedAnyway: Bool = true) -> JITDiagnosis {
        JITDiagnosis(status: status, detail: detail, suggestion: suggestion, canProceedAnyway: canProceedAnyway)
    }

    var isEnabled: Bool { status == .enabled }

    var statusIcon: String {
        switch status {
        case .enabled: return "checkmark.circle.fill"
        case .notDebugged: return "hammer.circle"
        case .dualmappedFailed: return "rectangle.split.2x1"
        case .memoryTestFailed: return "memorychip"
        case .unknown: return "questionmark.circle"
        }
    }
}

extension JITDiagnosis: Identifiable {
    var id: String { status.rawValue }
}

/// JIT 诊断：分析失败原因，返回具体状态与建议。
/// - Note: 保留原 isJITEnabled 的副作用（dualmapped 初始化 + succeededJIT 赋值）。
func diagnoseJIT() -> JITDiagnosis {
    // 1. 有 dynamic-codesigning entitlement（付费开发者 / TrollStore）
    if checkAppEntitlement("dynamic-codesigning") {
        if allocateTest() {
            return .enabled
        }
        AppErrorLogger.shared.warning(tag: "JIT", message: "Entitlement present but memory exec test failed")
        return .failure(
            .memoryTestFailed,
            detail: "Your app has JIT entitlement, but the system refused to execute generated code.",
            suggestion: "Restart the app. If the problem persists, reinstall the app.",
            canProceedAnyway: false
        )
    }

    // 2. 无 entitlement：依赖调试器（StikDebug/Xcode） + dualmapped
    //    dualmapped 已在 App 启动（initializeEmulatorRuntime）/游戏启动（configureEnvironmentVariables）时初始化，
    //    这里只读结果，避免 0.5s 轮询高频重复 mmap。
    let debugged = checkDebugged()

    if #available(iOS 19, *) {
        if debugged && LaunchGameHandler.succeededJIT {
            return .enabled
        }

        if !debugged {
            return .failure(
                .notDebugged,
                detail: "JIT is not enabled. MeloNX must be launched with a JIT debugger (StikDebug) to run games.",
                suggestion: "Open StikDebug, select MeloNX, and enable JIT. Then return here.",
                canProceedAnyway: false
            )
        }

        // debugged 但 dualmapped 失败
        AppErrorLogger.shared.warning(tag: "JIT", message: "Debugged but dual-mapped JIT init failed")
        return .failure(
            .dualmappedFailed,
            detail: "JIT debugging is active, but dual-mapped memory setup failed.",
            suggestion: "Re-enable JIT through StikDebug and try again.",
            canProceedAnyway: false
        )
    } else {
        // iOS 15~18 路径
        if debugged && allocateTest() {
            return .enabled
        }

        if !debugged {
            return .failure(
                .notDebugged,
                detail: "JIT is not enabled. MeloNX must be launched with a JIT debugger to run games.",
                suggestion: "Open StikDebug (or your preferred JIT enabler), select MeloNX, and enable JIT. Then return here.",
                canProceedAnyway: false
            )
        }

        return .failure(
            .memoryTestFailed,
            detail: "JIT debugging is active, but the system refused to execute generated code.",
            suggestion: "Re-enable JIT through StikDebug and try again.",
            canProceedAnyway: false
        )
    }
}

/// 兼容壳：旧调用点继续可用（内部走诊断路径）
func isJITEnabled() -> Bool {
    diagnoseJIT().isEnabled
}

func checkDebugged() -> Bool {
    var flags: Int = 0
    if checkAppEntitlement("dynamic-codesigning") {
        return true
    }
    return csops(pid: getpid(), ops: 0, useraddr: &flags, usersize: Int32(MemoryLayout.size(ofValue: flags))) == 0 && (flags & Int(CS_DEBUGGED)) != 0
}

func checkMemoryPermissions(at address: UnsafeRawPointer) -> Bool {
    var region: vm_address_t = vm_address_t(UInt(bitPattern: address))
    var regionSize: vm_size_t = 0
    var info = vm_region_basic_info_64()
    var infoCount = mach_msg_type_number_t(MemoryLayout<vm_region_basic_info_64>.size / MemoryLayout<integer_t>.size)
    var objectName: mach_port_t = UInt32(MACH_PORT_NULL)
    
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
            vm_region_64(mach_task_self_, &region, &regionSize, VM_REGION_BASIC_INFO_64, $0, &infoCount, &objectName)
        }
    }
    
    if result != KERN_SUCCESS {
        // print("Failed to reach \(address)")
        return false
    }
    
    return info.protection & VM_PROT_EXECUTE != 0
}
func allocateTest() -> Bool {
    let pageSize = sysconf(_SC_PAGESIZE)
    let code: [UInt32] = [0x52800540, 0xD65F03C0]
    
    guard let jitMemory = mmap(nil, pageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), jitMemory != MAP_FAILED else {
        return false
    }
    
    defer {
        munmap(jitMemory, pageSize)
    }
    
    
    memcpy(jitMemory, code, code.count)
    
    _ = mprotect(jitMemory, pageSize, PROT_READ | PROT_EXEC)
    
    let checkMem = checkMemoryPermissions(at: jitMemory)
    
    return checkMem
}

// thank you nikki (nythepegasus)
extension FileManager {
    func filePath(atPath path: String, withLength length: Int) -> String? {
        guard let file = try? contentsOfDirectory(atPath: path).filter({ $0.count == length }).first else { return nil }
        return "\(path)/\(file)"
    }
}

func notnil(_ condition: Any?) -> Bool {
    if let _ = condition {
        return false
    } else {
        return true
    }
}

public extension ProcessInfo {
    var hasTXM: Bool {
        { if let boot = FileManager.default.filePath(atPath: "/System/Volumes/Preboot", withLength: 36), let file = FileManager.default.filePath(atPath: "\(boot)/boot", withLength: 96) { return access("\(file)/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", F_OK) == 0 } else { return (FileManager.default.filePath(atPath: "/private/preboot", withLength: 96).map { access("\($0)/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", F_OK) == 0 }) ?? false } }()
    }
}

