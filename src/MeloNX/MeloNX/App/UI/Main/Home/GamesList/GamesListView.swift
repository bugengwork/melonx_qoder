//
//  GamesListView.swift
//  MeloNX
//
//  Created by Stossy11 on 10/11/2025.
//

import SwiftUI
import UniformTypeIdentifiers
import GameController

enum ActiveSheet: Identifiable, Equatable{
    case gameInfo(game: Game)
    case perGameSettings(game: Game)
    // needs to be a full screen sheet so commented out
    // case gameController(game: Game)
    case dlc(game: Game)
    case update(game: Game)
    case mods(game: Game)
    case account

    var id: String {
        switch self {
        case .gameInfo(let game),
             .perGameSettings(let game),
             // .gameController(let game),
             .dlc(let game),
             .mods(let game),
             .update(let game):
            return "\(type(of: self))-\(game.id)"
        case .account:
            return "account"
        }
    }
}

func bindingGame(_ game: Binding<Game?>) -> Binding<Bool> {
    Binding(
        get: { game.wrappedValue != nil },
        set: { newValue in
            if !newValue {
                game.wrappedValue = nil
            }
        }
    )
}

extension UTType {
    static let nsp = UTType(exportedAs: "com.nintendo.switch-package")
    static let xci = UTType(exportedAs: "com.nintendo.switch-cartridge")
}

struct GamesListView: View {
    @EnvironmentObject var gameHandler: LaunchGameHandler
    @StateObject var perGameSettings = PerGameSettingsManager.shared
    @StateObject var nativeSettings = NativeSettingsManager.shared
    @State var gameRequirements: [GameRequirements] = []
    @EnvironmentObject var ryujinx: Ryujinx
    @Environment(\.gameNamespace) var namespace
    @State var showingAccounts = false
    @AppStorage("legacyUI") private var legacyUI: Bool = false
    @State var activeSheet: ActiveSheet?
    @State var controllerEditor: Game?
    @State var scrollTo: Game?
    @StateObject var importState = ImportState.shared
    
    @State var previousDpadHandlers: [GCController: GCControllerDirectionPadValueChangedHandler?] = [:]
    @State var previousButtonAHandlers: [GCController: GCControllerButtonValueChangedHandler?] = [:]
    
    
    var firmware: String {
        (ryujinx.fetchFirmwareVersion() == "" ? "0" : ryujinx.fetchFirmwareVersion())
    }
    
    var hasKeys: Bool { ryujinx.checkIfKeysImported() }
    var hasFirmware: Bool { firmware != "0" }
    var needsSetup: Bool { !hasKeys || !hasFirmware }
    
    var controllerEdit: Binding<Bool> {
        bindingGame($controllerEditor)
    }
    
    var games: Binding<[Game]> {
        Binding(
            get: { ryujinx.games },
            set: { ryujinx.games = $0 }
        )
    }
    
    var body: some View {
        iOSNav {
            ScrollView {
                ScrollViewReader { proxy in
                    if needsSetup {
                        setupReminderBanner
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }
                    Group {
                        if ryujinx.games.isEmpty {
                            emptyStateView
                        } else if nativeSettings.cardLayout(CardType.card).value != .list {
                            var columns: [GridItem] {
                                switch nativeSettings.cardLayout(CardType.card).value {
                                case .card, .compactCard: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)]
                                case .compactCardNoBackground: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 16)]
                                case .compactCardSmall: [GridItem(.adaptive(minimum: 105, maximum: 120), spacing: 16)]
                                default: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 16)]
                                }
                            }
                            
                            
                            LazyVGrid(columns: columns, spacing: columns.first?.spacing ?? 16) {
                                ForEach(ryujinx.games) { game in
                                    GameCardView(
                                        game: game,
                                        games: games,
                                        gameRequirements: $gameRequirements,
                                    )
                                    .id(game)
                                    .iOS18MatchedTransitionSource(id: game.fileURL.absoluteString, in: namespace ?? Namespace().wrappedValue)
                                    .contextMenu {
                                        gameContextMenu(for: game)
                                    }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.top)
                        } else {
                            ForEach(ryujinx.games) { game in
                                Section {
                                    GameRowView(
                                        game: game,
                                        selectedGame: $scrollTo,
                                        games: games,
                                        gameRequirements: $gameRequirements
                                    )
                                    .id(game)
                                    .iOS18MatchedTransitionSource(id: game.fileURL.absoluteString, in: namespace ?? Namespace().wrappedValue)
                                    .padding(.horizontal)
                                    .padding(.vertical, 5)
                                    .contextMenu {
                                        gameContextMenu(for: game)
                                    }
                                }
                            }
                            .onAppear() {
                                setupControllerObservers(scrollProxy: proxy)
                            }
                        }
                    }
                }
                
                if nativeSettings.disableLiquidGlass.value, UIDevice.current.userInterfaceIdiom == .phone {
                    Spacer().frame(height: UIScreen.main.bounds.height / 10)
                }
            }
            // .padding(.top)
            .overlay {
                VStack {
                    HStack {
                        Spacer()
                        jitStatusCapsule
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
                    Spacer()
                }
                .offset(x: 0, y: -25)
            }
            .overlay {
                // L6: 导入进度 HUD
                if importState.isImporting {
                    ImportProgressHUD()
                }
            }
            .onAppear() {
                scrollTo = gameHandler.currentGame
            }
            .navigationTitle("Library")
            .toolbar {
                toolbarHandler()
            }
            .fullScreenCover(isPresented: controllerEdit) {
                ControllerView(isEditing: controllerEdit, gameId: controllerEditor?.titleId ?? "")
                    .interactiveDismissDisabled(true)
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .gameInfo(let game):
                    GameInfoSheet(game: game)
                case .perGameSettings(let game):
                    PerGameSettingsView(titleId: game.titleId)
                case .dlc(let game):
                    DLCManagerSheet(game: game)
                case .update(let game):
                    UpdateManagerSheet(game: game)
                case .mods(let game):
                    ModsManagerSheet(game: game)
                case .account:
                    AccountManagerView()
                }
            }
        }
        .onAppear() {
            ryujinx.addGames()
        }
    }
    
    private var emptyStateView: some View {
        Group {
            if #available(iOS 17, *) {
                ContentUnavailableView {
                    Label("No Games Found", systemImage: "square.and.arrow.down")
                } description: {
                    Text("Add legally dumped ROMs to start playing.")
                } actions: {
                    emptyStateAddButton
                }
            } else {
                VStack(spacing: 20) {
                    Spacer()
                    
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 64))
                        .foregroundColor(.secondary)
                    
                    Text("No Games Found")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Add legally dumped ROMs to start playing.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    emptyStateAddButton
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
            }
        }
    }

    /// L1: 空状态主 CTA（与工具栏入口一致；命名避免与 ToolBar 扩展的 addGameButton 冲突）
    private var emptyStateAddButton: some View {
        Button {
            FileImporterManager.shared.importFiles(types: [.nsp, .xci, .item]) { result in
                ImportHandler.handleAddingGame(result: result)
            }
        } label: {
            Text("Add Game")
                .fontWeight(.semibold)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.accent)
    }
    
    // L2: JIT 状态胶囊
    private var jitStatusCapsule: some View {
        Button {
            showJITStatus()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .frame(width: 8, height: 8)
                    .foregroundColor(jitStatus.color)
                Text(jitStatus.text)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }

    private var jitStatus: (color: Color, text: String) {
        if nativeSettings.ignoreJIT.value {
            return (AppTheme.disabled, "JIT Ignored")
        }
        return ryujinx.jitenabled ? (AppTheme.success, "JIT Ready") : (AppTheme.warning, "JIT Off")
    }

    /// L2: 点击胶囊 → 弹详情（enabled）/ 诊断面板（失败）
    private func showJITStatus() {
        let diagnosis = diagnoseJIT()

        if diagnosis.isEnabled {
            ryujinx.checkForJIT()
            AlertRouter.shared.present(
                AppAlert.info(
                    title: "JIT Enabled",
                    message: "Just-In-Time compilation is active. Games will run at full speed."
                )
            )
        } else {
            gameHandler.jitDiagnosis = diagnosis
        }
    }

    private var setupReminderBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.title3)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Setup Incomplete")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                if !hasKeys && !hasFirmware {
                    Text("Keys and firmware are required to run games.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if !hasKeys {
                    Text("Encryption keys are required to run games.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Firmware is required to run games.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button {
                UserDefaults.standard.set(true, forKey: "hasbeenfinished")
            } label: {
                Text("Setup")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(6)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
    

    // L6: 导入进度 HUD
    private struct ImportProgressHUD: View {
        @ObservedObject var state = ImportState.shared

        var body: some View {
            VStack(spacing: 12) {
                if let progress = state.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 220)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.large)
                    Text("Preparing…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text(state.fileName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.2), radius: 16, y: 8)
            )
            .padding()
        }
    }

    private func gameContextMenu(for game: Game) -> some View {
        Group {
            Section {
                Button {
                    gameHandler.currentGame = game
                } label: {
                    Label("Play Now", systemImage: "play.fill")
                }
                
                Button {
                    activeSheet = .gameInfo(game: game)
                } label: {
                    Label("Game Info", systemImage: "info.circle")
                }
                
                Button {
                    activeSheet = .perGameSettings(game: game)
                } label: {
                    Label("\(game.titleName) Settings", systemImage: "gear")
                }
                
                Button {
                    controllerEditor = game
                } label: {
                    Label("Controller Layout", systemImage: "formfitting.gamecontroller")
                }
            }
            
            Section {
                Button {
                    activeSheet = .update(game: game)
                } label: {
                    Label("Update Manager", systemImage: "arrow.up.circle")
                }
                
                Button {
                    activeSheet = .dlc(game: game)
                } label: {
                    Label("DLC Manager", systemImage: "plus.circle")
                }
                
                Button {
                    activeSheet = .mods(game: game)
                } label: {
                    Label("Mod Manager", systemImage: "folder.circle")
                }
            }
            
            Section {
                
                Button(role: .destructive) {
                    Ryujinx.clearShaderCache(game.titleId)
                } label: {
                    Label("Clear Shader Cache", systemImage: "trash")
                }
                
                Button(role: .destructive) {
                    deleteGame(game: game)
                } label: {
                    Label("Delete Game", systemImage: "trash")
                }
            }
        }
    }
    
    private func setupControllerObservers(scrollProxy: ScrollViewProxy) {
        if !GCController.controllers().isEmpty {
            if scrollTo == nil {
                scrollTo = ryujinx.games.first
            }
        }
        
        let dpadHandler: GCControllerDirectionPadValueChangedHandler = { _, _, yValue in
            guard !ryujinx.games.isEmpty else { return }
            
            guard let scrollTo, let index = ryujinx.games.firstIndex(of: scrollTo) else { return }
            let newIndex = yValue == 1.0 ? max(0, index - 1) : yValue == -1.0 ? min(ryujinx.games.count - 1, index + 1) : index
            let game = ryujinx.games[newIndex]
            
            self.scrollTo = game
            scrollProxy.scrollTo(game)
        }

        for controller in GCController.controllers() {
            print("Controller connected: \(controller.vendorName ?? "Unknown")")
            controller.playerIndex = .index1
            
            
            previousDpadHandlers[controller] = controller.extendedGamepad?.dpad.valueChangedHandler
            previousButtonAHandlers[controller] = controller.extendedGamepad?.buttonA.pressedChangedHandler

            controller.microGamepad?.dpad.valueChangedHandler = dpadHandler
            controller.extendedGamepad?.dpad.valueChangedHandler = dpadHandler

            controller.extendedGamepad?.buttonA.pressedChangedHandler = { _, _, pressed in
                if pressed {
                    Task { @MainActor in
                        print("A button pressed")
                        gameHandler.currentGame = scrollTo
                    }
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { _ in
            setupControllerObservers(scrollProxy: scrollProxy)
        }
        
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { notif in
            if let controller = notif.object as? GCController {
                previousDpadHandlers.removeValue(forKey: controller)
            }
            if GCController.controllers().isEmpty {
                scrollTo = nil
            }
        }
    }
    
    private func deleteGame(game: Game) {
        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: game.fileURL)
            Ryujinx.shared.games.removeAll { $0.id == game.id }
            Ryujinx.shared.games = Ryujinx.shared.loadGames()
        } catch {
        }
    }
}
