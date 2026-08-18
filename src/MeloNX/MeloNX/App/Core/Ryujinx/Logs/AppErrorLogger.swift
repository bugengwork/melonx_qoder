//
//  AppErrorLogger.swift
//  MeloNX
//
//  Created by Codex on 18/08/2026.
//
//  Swift 侧结构化错误日志：
//  - 带时间戳 / 模块标签 / 文件行号，写入 Documents/Logs/ 持久化文件
//  - 与 LogCapture（捕获 stdout/stderr 的 C# 日志）互补
//  - 原则：所有被吞掉的错误必须落盘，可追溯可排查
//

import Foundation

enum AppLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

final class AppErrorLogger {
    static let shared = AppErrorLogger()

    private let fileManager = FileManager.default
    private let logQueue = DispatchQueue(label: "com.melonx.errorlogger", qos: .utility)
    private var currentLogFileURL: URL?
    private let maxLogFileSize: UInt64 = 2 * 1024 * 1024 // 2MB 轮转

    private init() {
        prepareLogDirectory()
        currentLogFileURL = todayLogFileURL()
        info(tag: "AppErrorLogger", message: "Logger initialized. App version \(appVersion)")
    }

    // MARK: - Public API

    func debug(tag: String, message: String, file: String = #file, line: Int = #line) {
        write(level: .debug, tag: tag, message: message, file: file, line: line)
    }

    func info(tag: String, message: String, file: String = #file, line: Int = #line) {
        write(level: .info, tag: tag, message: message, file: file, line: line)
    }

    func warning(tag: String, message: String, file: String = #file, line: Int = #line) {
        write(level: .warning, tag: tag, message: message, file: file, line: line)
    }

    /// 记录错误：必须同时反馈到用户（UI 弹窗）与日志落盘
    /// - Parameters:
    ///   - tag: 模块标签，如 "ImportHandler"
    ///   - message: 用户可读错误信息
    ///   - underlyingError: 底层错误（可选，用于完整堆栈追溯）
    ///   - notifyUser: 是否弹窗通知用户（默认 true，错误必须有反馈）
    func error(
        tag: String,
        message: String,
        underlyingError: Error? = nil,
        notifyUser: Bool = true,
        file: String = #file,
        line: Int = #line
    ) {
        var fullMessage = message
        if let underlyingError {
            fullMessage += " | Underlying: \(underlyingError)"
        }
        write(level: .error, tag: tag, message: fullMessage, file: file, line: line)

        if notifyUser {
            AlertRouter.shared.present(
                AppAlert.error(title: "Error", message: message)
            )
        }
    }

    // MARK: - File Handling

    private func prepareLogDirectory() {
        let logDir = logsDirectoryURL
        do {
            try fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
        } catch {
            // 目录创建失败不应崩溃，降级为仅控制台输出
            NSLog("[AppErrorLogger] Failed to create log directory: \(error)")
        }
    }

    private var logsDirectoryURL: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return documents.appendingPathComponent("Logs", isDirectory: true)
    }

    private func todayLogFileURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let name = "app-\(formatter.string(from: Date())).log"
        return logsDirectoryURL.appendingPathComponent(name)
    }

    private func write(
        level: AppLogLevel,
        tag: String,
        message: String,
        file: String,
        line: Int
    ) {
        let fileName = (file as NSString).lastPathComponent
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let entry = "[\(timestamp)] [\(level.rawValue)] [\(tag)] \(fileName):\(line) - \(message)\n"

        // 同步写控制台（NSLog 便于 Xcode 控制台/Console.app 检索）
        NSLog("[MeloNX][\(level.rawValue)][\(tag)] \(fileName):\(line) - \(message)")

        logQueue.async { [weak self] in
            guard let self else { return }
            self.rotateIfNeeded()
            guard let url = self.currentLogFileURL else { return }

            do {
                if self.fileManager.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    handle.seekToEndOfFile()
                    if let data = entry.data(using: .utf8) {
                        handle.write(data)
                    }
                } else {
                    try entry.data(using: .utf8)?.write(to: url)
                }
            } catch {
                NSLog("[AppErrorLogger] Failed to write log: \(error)")
            }
        }
    }

    /// 日志文件超过 2MB 时轮转为带序号的旧文件
    private func rotateIfNeeded() {
        guard let url = currentLogFileURL else { return }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0

        guard size > maxLogFileSize else { return }

        let rotatedURL = url.deletingPathExtension()
            .appendingPathExtension("old.log")
        try? fileManager.removeItem(at: rotatedURL)
        try? fileManager.moveItem(at: url, to: rotatedURL)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// 最近日志文件列表（供"查看日志"入口使用）
    func recentLogFiles(limit: Int = 10) -> [URL] {
        let logDir = logsDirectoryURL
        guard let contents = try? fileManager.contentsOfDirectory(
            at: logDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "log" }
            .sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return date1 > date2
            }
            .prefix(limit)
            .map { $0 }
    }
}
