//
//  SetupView.swift
//  MeloNX
//
//  Created by Stossy11 on 04/03/2025.
//

import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @State private var isImportingKeys = false
    @State private var isImportingFirmware = false
    @State private var showAlert = false
    @State private var showSkipAlert = false
    @State private var alertMessage = ""
    @State private var keysImported = false
    @State private var firmImported = false
    @State private var showMainSetup = false
    @AppStorage("MeloNXAppMode") private var appModeRaw: String = ""
    @AppStorage("skippedSetup") var skippedSetup: Bool = false
    @Binding var isInSetup: Bool
    
    let cool: LocalizedStringKey = "MeloNX has issues with Certificates and should not be used. Official Install Guides is [here](https://melonx.org)"
    
    var body: some View {
        Group {
            if showMainSetup {
                mainBody
            } else {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.blue.opacity(0.1),
                        Color.red.opacity(0.1)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                .overlay {
                    ZStack {
                        IconAnimation(showMainSetup: $showMainSetup)
                    }
                    .overlay(alignment: .bottom) {
                        // S1: 动画可跳过
                        Button {
                            showMainSetup = true
                        } label: {
                            Text("Skip")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                                .foregroundColor(.primary)
                        }
                        .padding(.bottom, 48)
                    }
                }
            }
        }
    }
    
    var mainBody: some View {
        iOSNav {
            ZStack {
                if UIDevice.current.systemName.contains("iPadOS") {
                    iPadSetupView()
                } else {
                    iPhoneSetupView()
                }
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
        .alert(isPresented: $showSkipAlert) {
            Alert(
                title: Text("Skip Setup?"),
                primaryButton: .destructive(Text("Skip")) {
                    Task { @MainActor in
                        skippedSetup = true
                        isInSetup = false
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .onChange(of: isImportingFirmware) { newValue in
            if newValue {
                FileImporterManager.shared.importFiles(types: [.folder, .zip]) { result in
                    handleFirmwareImport(result: result)
                }
                isImportingFirmware = false
            }
        }
        .onChange(of: isImportingKeys) { newValue in
            if newValue {
                FileImporterManager.shared.importFiles(types: [.item], allowMultiple: true) { result in
                    handleKeysImport(result: result)
                }
                isImportingKeys = false
            }
        }
        .onAppear {
            RyujinxBridge.initialize()
            isInSetup = true
            keysImported = Ryujinx.shared.checkIfKeysImported()
            
            let firmware = Ryujinx.shared.fetchFirmwareVersion()
            firmImported = (firmware == "" ? "0" : firmware) != "0"
        }
    }
    
    @ViewBuilder
    private func iPadSetupView() -> some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.blue.opacity(0.1),
                        Color.red.opacity(0.1)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                HStack(spacing: 40) {
                    if geometry.size.width > 800 {
                        VStack(alignment: .center, spacing: 20) {
                            Image(uiImage: UIImage(named: appIcon()) ?? UIImage())
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 200, height: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 40))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 40)
                                        .stroke(
                                            LinearGradient(
                                                gradient: Gradient(colors: [
                                                    .blue.opacity(0.6),
                                                    .red.opacity(0.6)
                                                ]),
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            ),
                                            lineWidth: 2
                                        )
                                )
                                .shadow(color: .black.opacity(0.1), radius: 15, x: 0, y: 6)
                                .onTapGesture {
                                    if MusicSelectorView.isPlaying {
                                        MusicSelectorView.stopMusic()
                                    } else {
                                        let mp3 = MusicSelectorView.getMP3s().first(where: { $0.builtIn })
                                        MusicSelectorView.playMusic(mp3)
                                    }
                                }
                                .onTapGesture(count: 2) {
                                    let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                                    var sharedurl = documentsUrl.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
                                    if ProcessInfo.processInfo.isiOSAppOnMac {
                                        sharedurl = documentsUrl.absoluteString
                                    }
                                    if UIApplication.shared.canOpenURL(URL(string: sharedurl)!) {
                                        UIApplication.shared.open(URL(string: sharedurl)!, options: [:])
                                    }
                                }
                            
                            Text("Welcome to MeloNX")
                                .font(.title)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                                .onTapGesture(count: 2) {
                                    showSkipAlert = true
                                }
                            
                            if shouldAsCopy && !isInLiveContainer.0 {
                                Text(cool)
                                    .font(.callout)
                                    .fontWeight(.bold)
                                    .foregroundColor(.primary)
                                    .multilineTextAlignment(.center)
                            }
                            
                            Text("Set up your Nintendo Switch emulation environment by importing keys and firmware.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding()
                                .onTapGesture {
                                    let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                                    var sharedurl = documentsUrl.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
                                    if ProcessInfo.processInfo.isiOSAppOnMac {
                                        sharedurl = documentsUrl.absoluteString
                                    }
                                    if UIApplication.shared.canOpenURL(URL(string: sharedurl)!) {
                                        UIApplication.shared.open(URL(string: sharedurl)!, options: [:])
                                    }
                                }
                        }
                        .frame(maxWidth: 400)
                    }
                    
                    VStack(spacing: 20) {
                        setupStep(
                            title: "Import Keys",
                            description: "Add your encryption keys",
                            systemImage: "key.fill",
                            isCompleted: keysImported,
                            action: { isImportingKeys = true }
                        )
                        
                        setupStep(
                            title: "Add Firmware",
                            description: "Install Nintendo Switch firmware",
                            systemImage: "square.and.arrow.down",
                            isCompleted: firmImported,
                            isEnabled: keysImported,
                            action: { isImportingFirmware = true }
                        )
                        
                        Button(action: { finishSetup() }) {
                            HStack {
                                Text("Finish Setup")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(
                                firmImported && keysImported
                                    ? Color.blue
                                    : Color.blue.opacity(0.3)
                            )
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(!(firmImported && keysImported))
                    }
                    .frame(maxWidth: 500)
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    @ViewBuilder
    private func iPhoneSetupView() -> some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.blue.opacity(0.1),
                    Color.red.opacity(0.1)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 20) {
                        Image(uiImage: UIImage(named: appIcon()) ?? UIImage())
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24)
                                    .stroke(
                                        LinearGradient(
                                            gradient: Gradient(colors: [
                                                .blue.opacity(0.6),
                                                .red.opacity(0.6)
                                            ]),
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        ),
                                        lineWidth: 2
                                    )
                            )
                            .shadow(color: .black.opacity(0.1), radius: 12, x: 0, y: 4)
                            .padding(.top, 40)
                            .onTapGesture {
                                if MusicSelectorView.isPlaying {
                                    MusicSelectorView.stopMusic()
                                } else {
                                    let mp3 = MusicSelectorView.getMP3s().first(where: { $0.builtIn })
                                    MusicSelectorView.playMusic(mp3)
                                }
                            }
                            .onTapGesture(count: 2) {
                                let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                                var sharedurl = documentsUrl.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
                                if ProcessInfo.processInfo.isiOSAppOnMac {
                                    sharedurl = documentsUrl.absoluteString
                                }
                                if UIApplication.shared.canOpenURL(URL(string: sharedurl)!) {
                                    UIApplication.shared.open(URL(string: sharedurl)!, options: [:])
                                }
                            }
                        
                        Text("Welcome to MeloNX")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                            .padding(.bottom, 20)
                            .onTapGesture(count: 2) {
                                showSkipAlert = true
                            }
                        
                        if shouldAsCopy && !isInLiveContainer.0 {
                            Text(cool)
                                .font(.title2)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                                .padding(.bottom, 20)
                        }

                        Button {
                            appModeRaw = MeloNXAppMode.controller.rawValue
                        } label: {
                            Label("Use this iPhone as Controller", systemImage: "iphone.radiowaves.left.and.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        
                        setupStep(
                            title: "Import Keys",
                            description: "Add your encryption keys",
                            systemImage: "key.fill",
                            isCompleted: keysImported,
                            action: { isImportingKeys = true }
                        )
                        
                        setupStep(
                            title: "Add Firmware",
                            description: "Install Nintendo Switch firmware",
                            systemImage: "square.and.arrow.down",
                            isCompleted: firmImported,
                            isEnabled: keysImported,
                            action: { isImportingFirmware = true }
                        )
                    }
                    .padding()
                }
                
                // Finish Button
                VStack {
                    Button(action: { finishSetup() }) {
                        HStack {
                            Text("Finish Setup")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            firmImported && keysImported
                                ? Color.blue
                                : Color.blue.opacity(0.3)
                        )
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(!(firmImported && keysImported))
                    .padding()
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func setupStep(
        title: String,
        description: String,
        systemImage: String,
        isCompleted: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: systemImage)
                    .foregroundColor(isCompleted ? .green : .blue)
                    .imageScale(.large)
                
                VStack(alignment: .leading) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isCompleted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }
            .padding()
            .background(Color(UIColor.secondarySystemBackground))
            .cornerRadius(12)
        }
        .disabled(!isEnabled || isCompleted)
        .opacity(isEnabled ? 1.0 : 0.5)
    }
    
    private func handleKeysImport(result: Result<[URL], Error>) {
        do {
            let selectedFiles = try result.get()
            
            guard selectedFiles.count == 2 else {
                alertMessage = "Please select exactly 2 key files (prod.keys and title.keys)"
                showAlert = true
                return
            }
            
            // 验证文件名是否是预期的 key 文件
            let fileNames = selectedFiles.map { $0.lastPathComponent.lowercased() }
            let requiredKeys = ["prod.keys", "title.keys"]
            let hasRequiredKeys = requiredKeys.allSatisfy { required in
                fileNames.contains { $0 == required }
            }
            
            guard hasRequiredKeys else {
                alertMessage = "Please select prod.keys and title.keys files"
                showAlert = true
                return
            }
            
            for fileURL in selectedFiles {
                guard fileURL.startAccessingSecurityScopedResource() else {
                    alertMessage = "Permission denied to access file"
                    showAlert = true
                    return
                }
                
                defer {
                    fileURL.stopAccessingSecurityScopedResource()
                }
                
                let destinationURL = URL.documentsDirectory.appendingPathComponent("system").appendingPathComponent(fileURL.lastPathComponent)
                
                try FileManager.default.copyItem(at: fileURL, to: destinationURL)
            }
            
            keysImported = Ryujinx.shared.checkIfKeysImported()
            
            guard keysImported else {
                alertMessage = "Keys import failed. Please ensure you selected valid prod.keys and title.keys files."
                showAlert = true
                return
            }
            
            alertMessage = "Keys imported successfully"
            showAlert = true
            
        } catch {
            alertMessage = "Error importing keys: \(error.localizedDescription)"
            showAlert = true
        }
    }
    
    private func handleFirmwareImport(result: Result<[URL], Error>) {
        do {
            let selectedFiles = try result.get()
            
            guard let fileURL = selectedFiles.first else {
                alertMessage = "No file selected"
                showAlert = true
                return
            }
            
            guard fileURL.startAccessingSecurityScopedResource() else {
                alertMessage = "Permission denied to access file"
                showAlert = true
                return
            }
            
            defer {
                fileURL.stopAccessingSecurityScopedResource()
            }
            
            
            let (string, isErr) = RyujinxBridge.installFirmware(at: fileURL.path)
            
            if isErr {
                alertMessage = string
                showAlert = true
                return
            }
            
            Ryujinx.shared.firmwareversion = string
            firmImported = (Ryujinx.shared.firmwareversion == "" ? "0" : Ryujinx.shared.firmwareversion) != "0"
            
            guard firmImported else {
                alertMessage = "Firmware installation failed. Please check the firmware files."
                showAlert = true
                return
            }
            
            alertMessage = "Firmware installed successfully"
            showAlert = true
            
        } catch {
            alertMessage = "Error importing firmware: \(error.localizedDescription)"
            showAlert = true
        }
    }
    
    private func finishSetup() {
        // 最终验证：确保 keys 和 firmware 仍然有效
        keysImported = Ryujinx.shared.checkIfKeysImported()
        let firmware = Ryujinx.shared.fetchFirmwareVersion()
        firmImported = (firmware == "" ? "0" : firmware) != "0"
        
        guard keysImported && firmImported else {
            alertMessage = "Please complete all setup steps before finishing."
            showAlert = true
            return
        }
        
        isInSetup = false
    }
    
    func appIcon(in bundle: Bundle = .main) -> String {
        guard let icons = bundle.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              
              let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
              
              let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String],
              
              let iconFileName = iconFiles.last else {

            // print("Could not find icons in bundle")
            return ""
        }

        return iconFileName
    }
}
