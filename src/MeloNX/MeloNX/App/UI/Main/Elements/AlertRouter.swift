//
//  AlertRouter.swift
//  MeloNX
//
//  Created by Codex on 18/08/2026.
//
//  统一弹窗路由：所有应用内弹窗收敛到 SwiftUI .alert 渲染，
//  保证样式一致且避免 UIKit/SwiftUI 混用导致的 present 时序问题。
//

import SwiftUI

/// 弹窗按钮模型
struct AppAlertButton: Identifiable {
    let id = UUID()
    let title: String
    let role: ButtonRole?
    let action: (() -> Void)?

    init(title: String, role: ButtonRole? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.role = role
        self.action = action
    }
}

/// 弹窗模型
struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let buttons: [AppAlertButton]

    /// 便捷构造：单按钮
    static func info(title: String, message: String, buttonTitle: String = "OK") -> AppAlert {
        AppAlert(
            title: title,
            message: message,
            buttons: [AppAlertButton(title: buttonTitle, role: nil, action: nil)]
        )
    }

    /// 便捷构造：错误弹窗（红色语义 + 单按钮）
    static func error(title: String, message: String, buttonTitle: String = "OK") -> AppAlert {
        AppAlert(
            title: title,
            message: message,
            buttons: [AppAlertButton(title: buttonTitle, role: nil, action: nil)]
        )
    }

    /// 便捷构造：确认弹窗（取消 + 确认）
    static func confirm(
        title: String,
        message: String,
        confirmTitle: String,
        confirmRole: ButtonRole = .destructive,
        onConfirm: @escaping () -> Void
    ) -> AppAlert {
        AppAlert(
            title: title,
            message: message,
            buttons: [
                AppAlertButton(title: "Cancel", role: .cancel, action: nil),
                AppAlertButton(title: confirmTitle, role: confirmRole, action: onConfirm),
            ]
        )
    }
}

/// 全局弹窗路由（ObservableObject 单例）
final class AlertRouter: ObservableObject {
    static let shared = AlertRouter()

    /// 普通界面弹窗（根视图渲染）
    @Published var currentAlert: AppAlert?
    /// 游戏内弹窗（fullScreenCover 之上渲染，避免被遮住）
    @Published var gameAlert: AppAlert?

    private init() {}

    /// 展示弹窗。若已有弹窗在显示，新弹窗被丢弃并记日志（避免连续 present 崩溃）。
    func present(_ alert: AppAlert) {
        // 保证在主线程展示
        let block = { [weak self] in
            guard let self else { return }

            // 游戏运行或模拟界面已呈现时，弹窗必须挂在 fullScreenCover 之上
            if Ryujinx.shared.isRunning || LaunchGameHandler.isEmulationActive {
                if self.gameAlert != nil {
                    AppErrorLogger.shared.warning(
                        tag: "AlertRouter",
                        message: "Dropped game alert while another is presented: \(alert.title)"
                    )
                    return
                }
                self.gameAlert = alert
            } else {
                if self.currentAlert != nil {
                    AppErrorLogger.shared.warning(
                        tag: "AlertRouter",
                        message: "Dropped alert while another is presented: \(alert.title)"
                    )
                    return
                }
                self.currentAlert = alert
            }
        }

        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    func dismiss() {
        currentAlert = nil
        gameAlert = nil
    }

    /// 将 AppAlert 模型构造为系统 Alert（渲染器共用）
    static func buildAlert(_ alert: AppAlert) -> Alert {
        switch alert.buttons.count {
        case 0:
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        case 1:
            let button = alert.buttons[0]
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(button.title), action: button.action ?? {})
            )
        case 2:
            let primary = alert.buttons[0]
            let secondary = alert.buttons[1]
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: primary.role == .cancel
                    ? .cancel(Text(primary.title), action: primary.action ?? {})
                    : .default(Text(primary.title), action: primary.action ?? {}),
                secondaryButton: secondary.role == .destructive
                    ? .destructive(Text(secondary.title), action: secondary.action ?? {})
                    : .default(Text(secondary.title), action: secondary.action ?? {})
            )
        default:
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

/// 根视图挂载点：在 App 根部调用一次（普通界面弹窗）
struct AlertRouterModifier: ViewModifier {
    @ObservedObject private var router = AlertRouter.shared

    func body(content: Content) -> some View {
        content
            .alert(item: $router.currentAlert) { alert in
                AlertRouter.buildAlert(alert)
            }
    }
}

/// 游戏内挂载点：在 EmulationContainerView 调用一次（fullScreenCover 之上的弹窗）
struct GameAlertRouterModifier: ViewModifier {
    @ObservedObject private var router = AlertRouter.shared

    func body(content: Content) -> some View {
        content
            .alert(item: $router.gameAlert) { alert in
                AlertRouter.buildAlert(alert)
            }
    }
}

extension View {
    /// 挂载全局弹窗路由（普通界面）
    func alertRouter() -> some View {
        modifier(AlertRouterModifier())
    }

    /// 挂载游戏内弹窗路由（模拟运行界面）
    func gameAlertRouter() -> some View {
        modifier(GameAlertRouterModifier())
    }
}
