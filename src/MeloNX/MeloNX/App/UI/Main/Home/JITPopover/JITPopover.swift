//
//  JITPopover.swift
//  MeloNX
//
//  Created by Stossy11 on 10/11/2025.
//

import SwiftUI

// MARK: - JIT 诊断面板（G1）

/// JIT 诊断面板：根据 diagnoseJIT() 的结果展示具体原因 + 可执行动作。
struct JITDiagnosticView: View {
    let diagnosis: JITDiagnosis
    let onRetry: () -> Void
    let onProceedAnyway: (() -> Void)?
    let onCancel: () -> Void

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 20) {
            // 状态图标
            Image(systemName: diagnosis.statusIcon)
                .font(.system(size: 52))
                .foregroundColor(AppTheme.status(diagnosis.isEnabled))
                .padding(.top, 10)

            VStack(spacing: 8) {
                Text(titleText)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)

                Text(diagnosis.detail)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !diagnosis.suggestion.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundColor(AppTheme.warning)
                        .font(.system(size: 16))

                    Text(diagnosis.suggestion)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray6).opacity(0.5))
                )
            }

            // 动作区
            VStack(spacing: 10) {
                Button(action: onRetry) {
                    Text(retryButtonTitle)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)

                if let onProceedAnyway = onProceedAnyway, diagnosis.canProceedAnyway {
                    Button(action: onProceedAnyway) {
                        Text("Proceed Anyway")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(AppTheme.warning)
                }

                Button(action: onCancel) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 24)
        }
        .padding(24)
        .frame(maxWidth: 400)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.1), radius: 20, x: 0, y: 10)
        )
    }

    private var titleText: String {
        switch diagnosis.status {
        case .enabled:
            return "JIT Enabled"
        case .notDebugged:
            return "JIT Not Enabled"
        case .dualmappedFailed:
            return "JIT Setup Failed"
        case .memoryTestFailed:
            return "JIT Blocked"
        case .unknown:
            return "JIT Status Unknown"
        }
    }

    private var retryButtonTitle: String {
        switch diagnosis.status {
        case .notDebugged:
            return "Open JIT Enabler"
        default:
            return "Retry"
        }
    }
}

// MARK: - 旧 JIT 等待弹窗（保留，供等待重试场景使用）

struct JITPopover: View {
    var onJITEnabled: () -> Void
    @Environment(\.presentationMode) var presentationMode
    @EnvironmentObject var gameHandler: LaunchGameHandler
    
    @State private var isJIT: Bool = false
    @State private var pulseAnimation: Bool = false
    
    var body: some View {
        VStack(spacing: 20) {
            // cool animation :3
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 100, height: 100)
                    .scaleEffect(pulseAnimation ? 1.2 : 1.0)
                    .opacity(pulseAnimation ? 0 : 1)
                    .animation(
                        Animation.easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: false),
                        value: pulseAnimation
                    )
                
                Image(systemName: "cpu.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.blue)
            }
            .padding(.top, 10)
            
            VStack(spacing: 8) {
                Text("Waiting for JIT")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                
                Text("Waiting for Just-In-Time compilation...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.blue)
                        .font(.system(size: 16))
                    
                    Text("JIT compilation enables MeloNX to achieve maximum performance by dynamically translating and executing code on the fly.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 16))
                    
                    Text("This process is required for the emulator to function properly.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray6))
            )
        }
        .padding(24)
        .frame(maxWidth: 400)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.1), radius: 20, x: 0, y: 10)
        )
        .onAppear {
            pulseAnimation = true
            
            gameHandler.enableJIT()
            
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
                isJIT = isJITEnabled()
                
                if isJIT {
                    timer.invalidate()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        presentationMode.wrappedValue.dismiss()
                    }
                    onJITEnabled()
                    Ryujinx.shared.checkForJIT()
                }
            }
        }
    }
}
