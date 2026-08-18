//
//  ImportHandler.swift
//  MeloNX
//
//  Created by Stossy11 on 10/11/2025.
//

import Combine
import Foundation

/// L6: 导入进度状态（单例，供 HUD 监听）
final class ImportState: ObservableObject {
    static let shared = ImportState()

    @Published var isImporting = false
    /// nil = 不确定进度（准备阶段）
    @Published var progress: Double? = nil
    @Published var fileName: String = ""
}

class ImportHandler {
    static public func handleRunningGame(result: Result<[URL], Error>, gameHandler: LaunchGameHandler) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                showAlert(title: "Failed to Open Game", message: "No file selected.", actions:
                    [(title: "OK", style: .default, handler: nil)]
                )
                return
            }
            
            _ = url.startAccessingSecurityScopedResource()
            
            do {
                let handle = try FileHandle(forReadingFrom: url)
                let fileExtension = (url.pathExtension as NSString)
                
                let gameInfo = RyujinxBridge.getGameInfo(arg0: handle.fileDescriptor, arg1: fileExtension)
                
                let game = Game.convertGameInfoToGame(gameInfo: gameInfo, url: url)
                
                Task { @MainActor in
                    gameHandler.currentGame = game
                }
            } catch {
                showAlert(title: "Failed to Open Game", message: error.localizedDescription, actions:
                    [(title: "OK", style: .default, handler: nil)]
                )
            }
            
        case .failure(let err):
            showAlert(title: "Failed to Open Game", message: err.localizedDescription, actions:
                [(title: "OK", style: .default, handler: nil)]
            )
        }
    }
    
    static public func handleAddingGame(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                showAlert(title: "Failed to import", message: "No file selected.", actions:
                    [(title: "Cancel", style: .cancel, handler: nil)]
                )
                return
            }

            if !GameFileType.isSupported(fileExtension: url.pathExtension) {
                AppErrorLogger.shared.warning(
                    tag: "Import",
                    message: "Unsupported file extension rejected: .\(url.pathExtension)"
                )
                showAlert(title: "Failed to import", message: "Unsupported file extension: .\(url.pathExtension)", actions:
                    [
                        (title: "Cancel", style: .cancel, handler: nil)
                    ]
                )
                return
            }

            let keepAccess = url.startAccessingSecurityScopedResource()

            let fileManager = FileManager.default
            let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
            let romsDirectory = documentsDirectory.appendingPathComponent("roms")

            if !fileManager.fileExists(atPath: romsDirectory.path) {
                do {
                    try fileManager.createDirectory(at: romsDirectory, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    if keepAccess { url.stopAccessingSecurityScopedResource() }
                    AppErrorLogger.shared.error(tag: "Import", message: "Failed to create roms directory.", underlyingError: error)
                    return
                }
            }

            let destinationURL = romsDirectory.appendingPathComponent(url.lastPathComponent)

            // 如果文件已存在，询问是否覆盖（后台拷贝 + 进度 HUD）
            if fileManager.fileExists(atPath: destinationURL.path) {
                showAlert(title: "File Already Exists", message: "\"\(url.lastPathComponent)\" already exists in your library. Overwrite?",
                          actions: [
                              (title: "Cancel", style: .cancel, handler: {
                                  if keepAccess { url.stopAccessingSecurityScopedResource() }
                              }),
                              (title: "Overwrite", style: .destructive, handler: {
                                  performImport(from: url, to: destinationURL, keepAccess: keepAccess)
                              })
                          ]
                )
                return
            }

            performImport(from: url, to: destinationURL, keepAccess: keepAccess)

        case .failure(let err):
            showAlert(title: "Failed to import", message: err.localizedDescription, actions:
                [(title: "Cancel", style: .cancel, handler: nil)]
            )
        }
    }

    // MARK: - L6 后台拷贝 + 进度

    /// 后台执行拷贝：流式读写以支持进度，结束后刷新游戏库并提示结果。
    private static func performImport(from url: URL, to destinationURL: URL, keepAccess: Bool) {
        Task.detached(priority: .userInitiated) {
            await MainActor.run {
                ImportState.shared.isImporting = true
                ImportState.shared.fileName = url.lastPathComponent
                ImportState.shared.progress = nil
            }

            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try? FileManager.default.removeItem(at: destinationURL)
                }
                try copyFileWithProgress(from: url, to: destinationURL)

                await MainActor.run {
                    if keepAccess { url.stopAccessingSecurityScopedResource() }
                    Ryujinx.shared.games = Ryujinx.shared.loadGames()
                    ImportState.shared.isImporting = false
                    ImportState.shared.progress = nil
                    showAlert(title: "Import Successful", message: "\(url.lastPathComponent) has been added to your library.", actions:
                        [(title: "OK", style: .default, handler: nil)]
                    )
                }
            } catch {
                await MainActor.run {
                    if keepAccess { url.stopAccessingSecurityScopedResource() }
                    ImportState.shared.isImporting = false
                    ImportState.shared.progress = nil
                    // 清理可能残留的半成品文件
                    try? FileManager.default.removeItem(at: destinationURL)
                    AppErrorLogger.shared.error(
                        tag: "Import",
                        message: "Failed to import \(url.lastPathComponent).",
                        underlyingError: error
                    )
                }
            }
        }
    }

    /// 流式拷贝（8MB 分块），每块更新主线程进度。
    private static func copyFileWithProgress(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        let totalBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        guard totalBytes > 0 else {
            // 空/未知大小文件：直接拷贝
            try fileManager.copyItem(at: source, to: destination)
            return
        }

        let chunkSize = 8 * 1024 * 1024

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }

        fileManager.createFile(atPath: destination.path, contents: nil, attributes: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var copied: Int64 = 0
        while true {
            guard let data = try input.read(upToCount: chunkSize), !data.isEmpty else { break }
            try output.write(contentsOf: data)
            copied += Int64(data.count)

            let fraction = min(Double(copied) / Double(totalBytes), 1.0)
            DispatchQueue.main.async {
                ImportState.shared.progress = fraction
            }
        }
    }
    
    static public func handleFirmwareImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let url):
            guard let url = url.first else {
                showAlert(title: "Installing Firmware Failed", message: "No file selected.", actions:
                    [(title: "Cancel", style: .cancel, handler: nil)]
                )
                return
            }
            
            do {
                let fun = url.startAccessingSecurityScopedResource()
                let path = url.path
                    
                let (string, isErr) = RyujinxBridge.installFirmware(at: path)
                
                if fun {
                    url.stopAccessingSecurityScopedResource()
                }
                
                if isErr {
                    showAlert(title: "Installing Firmware Failed", message: string, actions:
                                [
                                    (title: "Cancel", style: .cancel, handler: nil)
                                ]
                    )
                } else {
                    Ryujinx.shared.firmwareversion = string
                    showAlert(title: "Firmware Installed", message: "Firmware version \(string) has been installed successfully.", actions:
                        [(title: "OK", style: .default, handler: nil)]
                    )
                }
            }
        case .failure(let error):
            showAlert(title: "Installing Firmware Failed", message: error.localizedDescription, actions:
                        [
                            (title: "Cancel", style: .cancel, handler: nil)
                        ]
            )
        }
    }
    
}
