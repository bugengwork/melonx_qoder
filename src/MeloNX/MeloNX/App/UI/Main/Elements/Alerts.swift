//
//  Alerts.swift
//  MeloNX
//
//  Created by Stossy11 on 04/07/2025.
//
//  showAlert 兼容层：统一路由到 AlertRouter（SwiftUI .alert 渲染）。
//  新代码请直接使用 AlertRouter.shared.present(AppAlert...)。
//

import SwiftUI
import UIKit

func showAlert(_ viewController: UIViewController? = nil,
    title: String?,
    message: String?,
    actions: [(title: String, style: UIAlertAction.Style, handler: (() -> Void)?)]) {

    let appButtons = actions.map { action -> AppAlertButton in
        let role: ButtonRole? = {
            switch action.style {
            case .cancel: return .cancel
            case .destructive: return .destructive
            default: return nil
            }
        }()
        return AppAlertButton(title: action.title, role: role, action: action.handler)
    }

    let alert = AppAlert(
        title: title ?? "Error",
        message: message ?? "Unknown error occurred.",
        buttons: appButtons.isEmpty
            ? [AppAlertButton(title: "OK", role: nil, action: nil)]
            : appButtons
    )

    AlertRouter.shared.present(alert)
}
