//
//  Theme.swift
//  MeloNX
//
//  Created by Codex on 18/08/2026.
//
//  语义色定义：全 App 统一用色基准。
//  主操作=蓝、成功=绿、警告=橙、危险=红。
//  禁止在业务代码中直接硬编码颜色值。
//

import SwiftUI

enum AppTheme {
    /// 主操作色（导入、启动、确认）
    static var accent: Color { .blue }

    /// 成功状态（导入完成、检查通过）
    static var success: Color { .green }

    /// 警告状态（缺 Keys/固件、JIT 未启用、低内存）
    static var warning: Color { .orange }

    /// 危险操作（删除、清除缓存、退出）
    static var danger: Color { .red }

    /// 不可用/禁用状态
    static var disabled: Color { .gray }

    /// 半透明遮罩（HUD、loading 背景）
    static var overlayBackground: Color { Color.black.opacity(0.6) }

    /// 卡片表面色（浅色模式）
    static var cardSurfaceLight: Color { Color.white }

    /// 卡片表面色（深色模式）
    static var cardSurfaceDark: Color { Color(.systemGray6) }

    /// 根据配色方案返回卡片表面色
    static func cardSurface(in colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? cardSurfaceDark : cardSurfaceLight
    }

    /// 状态色：按布尔状态取成功/警告色
    static func status(_ isOK: Bool) -> Color {
        isOK ? success : warning
    }

    /// 热区最小尺寸（iOS HIG 44pt）
    static let minTouchTarget: CGFloat = 44

    /// 转场动效（0.25s easeOut）
    static let transitionAnimation: Animation = .easeOut(duration: 0.25)

    /// 庆祝动效（0.5s spring）
    static let celebrationAnimation: Animation = .spring(response: 0.5, dampingFraction: 0.7)
}
