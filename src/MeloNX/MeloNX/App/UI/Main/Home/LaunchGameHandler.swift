//
//  LaunchGameHandler.swift
//  MeloNX
//
//  Created by Stossy11 on 10/11/2025.
//

import Combine
import Foundation
import SwiftUI

class LaunchGameHandler: ObservableObject {
    @Published var currentGame: Game? = nil
    @Published var profileSelected = false
    @Published var showApp: Bool = true
    @Published var isPortrait: Bool = true
    @Published var jitDiagnosis: JITDiagnosis? = nil
    @AppStorage("gametorun") var gametorun: String = ""
    @AppStorage("gametorun-date") var gametorunDate: String = ""
    
    static var succeededJIT: Bool = true
    /// 模拟界面（fullScreenCover）是否已呈现：AlertRouter 路由弹窗到游戏内渲染器
    static var isEmulationActive = false
    
    private static let jitEntitlement = "com.apple.developer.kernel.increased-memory-limit"
    
    private let ryujinx = Ryujinx.shared
    private let nativeSettings = NativeSettingsManager.shared
    private let settingsManager = SettingsManager.shared
    private let persettings = PerGameSettingsManager.shared
    private let controllerManager = ControllerManager.shared
    
    private var config: Ryujinx.Arguments {
        settingsManager.config
    }
    
    private var hasJITEntitlement: Bool {
        ProcessInfo.processInfo.isiOSAppOnMac ? true : checkAppEntitlement(Self.jitEntitlement)
    }
    
    var isGameReady: Bool {
        currentGame != nil
            && (nativeSettings.ignoreJIT.value ? true : ryujinx.jitenabled)
            && (nativeSettings.showProfileonGame.value ? profileSelected : true)
    }
    
    var shouldLaunchGame: Bool {
        isGameReady && hasJITEntitlement
    }
    
    var shouldShowEntitlement: Bool {
        isGameReady && !hasJITEntitlement
    }
    
    var shouldShowPopover: Bool {
        currentGame != nil
            && ryujinx.jitenabled
            && !profileSelected
            && nativeSettings.showProfileonGame.value
            && hasJITEntitlement
    }
    
    var shouldCheckJIT: Bool {
        currentGame != nil
            && !ryujinx.jitenabled
            && !(nativeSettings.ignoreJIT.value as Bool)
            && hasJITEntitlement
    }
    
    
    
    func enableJIT() {
        ryujinx.checkForJIT()
        print("Has TXM? \(ProcessInfo.processInfo.hasTXM)")
        
        if !ryujinx.jitenabled {
            if nativeSettings.useTrollStore.value {
                gametorunDate = "\(Date().timeIntervalSince1970)"
                gametorun = currentGame?.titleId ?? ""
                askForJIT()
            } else if nativeSettings.stikJIT.value {
                gametorunDate = "\(Date().timeIntervalSince1970)"
                gametorun = currentGame?.titleId ?? ""
                enableJITStik()
            } else {
                showAlert(title: "JIT Required", message: "JIT is not enabled. Please use StikDebug or enable JIT through your preferred method to run games.", actions:
                    [(title: "OK", style: .default, handler: nil)]
                )
            }
        }
    }
    
    func startGame() {
        // G1: 前置 JIT 诊断（ignoreJIT 用户跳过检查）
        if !nativeSettings.ignoreJIT.value {
            let diagnosis = diagnoseJIT()
            guard diagnosis.isEnabled else {
                AppErrorLogger.shared.warning(
                    tag: "Launch",
                    message: "Launch blocked by JIT diagnosis: \(diagnosis.status.rawValue)"
                )
                gametorunDate = "\(Date().timeIntervalSince1970)"
                gametorun = currentGame?.titleId ?? ""
                jitDiagnosis = diagnosis
                return
            }
        }

        // G5: 缺失 keys/固件前置阻断
        let hasKeys = ryujinx.checkIfKeysImported()
        let firmwareVersion = ryujinx.fetchFirmwareVersion()
        let hasFirmware = (firmwareVersion == "" ? "0" : firmwareVersion) != "0"
        guard hasKeys && hasFirmware else {
            AppErrorLogger.shared.warning(
                tag: "Launch",
                message: "Launch blocked: missing \(hasKeys ? "" : "keys") \(hasFirmware ? "" : "firmware")"
            )
            showAlert(title: "Cannot Start Game", message: "Encryption keys and firmware are required to run games. Please complete setup first.", actions:
                [
                    (title: "Cancel", style: .cancel, handler: nil),
                    (title: "Setup", style: .default, handler: {
                        UserDefaults.standard.set(false, forKey: "hasbeenfinished")
                    })
                ]
            )
            return
        }

        enableJIT()
        
        // 如果 JIT 仍未启用，阻止启动
        guard ryujinx.jitenabled || nativeSettings.ignoreJIT.value else {
            showAlert(title: "Cannot Start Game", message: "JIT is required to run games. Please enable JIT and try again.", actions:
                [(title: "OK", style: .default, handler: nil)]
            )
            return
        }
        
        MusicSelectorView.stopMusic()
        nativeSettings.isVirtualController.value = controllerManager.hasVirtualController()
        MetalView.createView()
        
        guard let currentGame else { return }
        
        persettings.loadSettings()
        
        var config = persettings.config[currentGame.titleId] ?? self.config
        
        controllerManager.registerControllerTypeForMatchingControllers()
        config.gamepath = currentGame.fileURL.path
        config.inputids = Array(Set(controllerManager.selectedControllers))
        
        if config.inputids.isEmpty {
            config.inputids.append("0")
        }
        
        print(config.inputids)
        configureEnvironmentVariables()
        
        do {
            try ryujinx.start(with: config)
        } catch {
            print("Failed to start game '\(currentGame.titleId)': \(error)")
            showAlert(title: "Failed to Start Game", message: "\(currentGame.titleName) could not be started.\n\(error.localizedDescription)", actions:
                [(title: "OK", style: .default, handler: nil)]
            )
        }
    }
    
    // MARK: - G1 JIT 诊断面板动作

    /// 诊断面板"重试 / 打开 JIT 渠道"：重新诊断，成功则继续启动，失败则尝试跳转 JIT 渠道
    func retryJITLaunch() {
        let diagnosis = diagnoseJIT()

        if diagnosis.isEnabled {
            jitDiagnosis = nil
            ryujinx.checkForJIT()
            startGame()
            return
        }

        jitDiagnosis = diagnosis

        // 仍有可用跳转渠道时尝试跳转（面板保持显示，返回后自动继续）
        if nativeSettings.useTrollStore.value || nativeSettings.stikJIT.value {
            gametorunDate = "\(Date().timeIntervalSince1970)"
            gametorun = currentGame?.titleId ?? ""

            if nativeSettings.useTrollStore.value {
                askForJIT()
            } else {
                enableJITStik()
            }
        }
    }

    /// 诊断面板"取消"：关闭面板，不启动游戏
    func dismissJITDiagnosis() {
        jitDiagnosis = nil
    }

    private func configureEnvironmentVariables() {
        let useDualMappedJIT: Bool
        if #available(iOS 19, *) {
            useDualMappedJIT = nativeSettings.setting(forKey: "DUAL_MAPPED_JIT", default: true).value
        } else {
            useDualMappedJIT = nativeSettings.setting(forKey: "DUAL_MAPPED_JIT", default: false).value
        }
        
        if useDualMappedJIT {
            setenv("DUAL_MAPPED_JIT", "1", 1)
            Self.succeededJIT = RyujinxBridge.initialize_dualmapped()
        } else {
            setenv("DUAL_MAPPED_JIT", "0", 1)
        }
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "1", 1)
            return
        }
        
        let supportsArgumentBuffersTier2 = device.argumentBuffersSupport.rawValue >= MTLArgumentBuffersTier.tier2.rawValue
        setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", supportsArgumentBuffersTier2 ? "1" : "0", 1)
    }
}
