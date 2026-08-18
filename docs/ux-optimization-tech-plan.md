# MeloNX UX 优化 — 技术实施计划（技术总监评审）

> 版本：v1.0 · 日期：2026-08-18
> 评审对象：[docs/ux-design-optimization.md](./ux-design-optimization.md)
> 评审结论：**整体方向合理，27 项中 19 项为低风险局部改动，8 项涉及结构性改动需拆解。核心路径优化（JIT 诊断、导入反馈）收益明确，建议按子系统分 4 个阶段推进。**

---

## 1. 总体评估

### 1.1 合理性判断

| 评估维度 | 结论 |
|---------|------|
| 目标合理性 | ✅ 聚焦"导入 → 启动 → 游玩"核心路径，与项目最大痛点（JIT 拦截）一致 |
| 方案可行性 | ✅ 所有优化项在现有 SwiftUI + C# 架构内可实现，无需引入新架构 |
| 风险可控性 | ⚠️ 8 项涉及跨模块/跨语言/数据驱动重构，必须拆解分阶段，禁止大爆炸式合并 |
| 与已完成工作衔接 | ✅ 13 项操作反馈修复是本次优化的地基（弹窗、验证、超时均已就位） |

### 1.2 技术影响分级

#### A 级：纯 UI 局部改动（19 项，单文件内完成）

M1 M2 M3 · S1 S2 S3 S4 S6 · L1 L4 · G2 · E1 E2 E3 E4 E5 · T1 T2

- 特征：不改数据流、不改跨模块接口、不碰 C# 侧
- 策略：小 PR 直接做，无需特殊评审

#### B 级：结构性改动（8 项，需拆解设计）

| ID | 项 | 影响面 | 跨语言 |
|----|-----|--------|--------|
| G1 | JIT 前置诊断面板 | IsJITEnabled + JITPopover + LaunchGameHandler 三处联动 | 否 |
| L6 | 导入进度 HUD | FileImporter + ImportHandler 数据流重构 | 否 |
| G3 | Loading 阶段细分 | LoadingOverlayView + C# 侧新增回调 | **是** |
| G4 | Loading 可取消 | 模拟器启动生命周期（Runner/stop 时序） | 否 |
| G5 | 启动前置验证 | 需 C# 侧导出 keys 校验接口 | **是** |
| T3 | 设置搜索 | SettingsView 1500 行硬编码 → 数据驱动重构 | 否 |
| — | 弹窗统一 | 全 App `showAlert` 迁移至 SwiftUI | 否 |
| L2 | JIT 状态胶囊（含诊断面板复用） | 依赖 G1 的诊断结构体 | 依赖 G1 |

---

## 2. 结构性改动拆解

### 2.1 G1：JIT 前置诊断面板（P0）

**现状**：`isJITEnabled()` 返回 Bool → `enableJIT()` 静默尝试 → `startGame()` 中 guard 拦截弹通用文案。

**目标**：点击游戏即诊断，弹面板给出**具体原因 + 可执行动作**。

**拆解步骤**：

```
Step 1  [IsJITEnabled.swift]
        定义 JITDiagnosis 枚举结构：
        struct JITDiagnosis {
            enum Status { enabled, notDebugged, entitlementMissing,
                           dualmappedFailed, unsupportedOS, memoryTestFailed }
            let status: Status
            let detail: String      // 用户可读原因
            let action: JITAction   // .openStikDebug / .openGuide / .none
        }
        diagnoseJIT() -> JITDiagnosis 取代 isJITEnabled() -> Bool
        保留 isJITEnabled() 作为 diagnoseJIT().status == .enabled 的兼容壳

Step 2  [JITPopover.swift]
        扩展为 JITDiagnosticSheet：按 status 渲染对应
        图标 / 原因文本 / 主按钮（打开 StikDebug / 查看教程）/ 次按钮（忽略并继续）

Step 3  [LaunchGameHandler.swift]
        点击游戏入口（GameCardView/GameRowView 的 currentGame 赋值处）
        统一走 handler.prepareLaunch(game)：
          - ignoreJIT 开关开启 → 直接启动
          - 否则 diagnoseJIT()，非 enabled → 弹诊断面板（面板内再决定启动/放弃）
        startGame() 中 guard 改为调用诊断面板（兜底路径）

Step 4  兼容回归：
        Ryujinx.init 中 checkForJIT() 改调 diagnoseJIT
        shouldCheckJIT / shouldShowPopover 计算属性同步迁移
```

**验收标准**：4 种失败场景（未调试/无 entitlement/dualmapped 失败/内存测试失败）各自显示正确原因与动作；JIT 正常时路径与现状无差异。

**风险**：`isJITEnabled()` 被多处调用（Ryujinx.init、GamesListView overlay、LaunchGameHandler 多处计算属性），Step 1 必须保留兼容壳，逐个迁移。

---

### 2.2 L6：导入进度 HUD

**现状**：`handleAddingGame` 在主线程同步 `copyItem`，大 ROM 复制期间 UI 冻结。

**拆解（两阶段，先轻后重）**：

```
阶段 A（本迭代，低成本兜底）：
  - copyItem 前弹全屏半透明 HUD："正在导入 xxx.nsp…"（不确定进度转圈）
  - copyItem 移入 DispatchQueue.global(qos: .userInitiated)
  - 完成/失败回主线程弹结果
  - 收益：UI 不再冻结，用户可见"正在导入"状态

阶段 B（后续，真实进度）：
  - FileImporterManager.importFiles 签名扩展进度回调：
    importFiles(types:allowMultiple:onProgress:completion:)
  - 用 FileManager.copyItem 不支持进度，改为
    InputStream/OutputStream 分块拷贝（4MB 块），按字节数回调
  - HUD 升级为 ProgressView(value:)
```

**验收标准**：阶段 A 后导入 10GB 文件 UI 不冻结且可见加载状态；阶段 B 后显示百分比。

**风险**：安全作用域（security-scoped resource）必须在后台线程保持访问——`startAccessingSecurityScopedResource()` 与拷贝必须在同一线程或 scope 传递正确，这是 iOS 上最容易踩的坑。

---

### 2.3 G3：Loading 阶段细分（跨语言）

**现状**：C# 侧只有 `ProgressWithPTCorShaderCache` 一个回调（JSON: type/current/total）。

**拆解**：

```
Step 1  [C# 侧 Ryujinx.Headless.SDL2]
        定位 ProgressWithPTCorShaderCache 回调注册点
        新增 "LoadingStage" 回调：JSON {"stage": "ptc|shader|firstframe|boot"}
        阶段切换时机：PTC 加载开始/结束、shader 编译开始/结束、首帧渲染

Step 2  [Swift LoadingOverlayView.swift]
        RegisterCallback("LoadingStage") 更新 loadingType 文本：
          ptc → "加载翻译缓存…"
          shader → "编译着色器…"
          firstframe → "等待首帧…"

Step 3  保持向后兼容：C# 侧未升级时 Swift 降级为现有行为（无阶段文本）
```

**验收标准**：loading 期间可见阶段切换；旧 C# 二进制 + 新 Swift 不崩溃。

**风险**：C# 改动需要重编 `Ryujinx.Headless.SDL2.dylib`（NativeAOT 编译时长可观），且 iOS 构建链路验证依赖真机/模拟器签名。建议与 C# 侧其他改动（G5）合并一次编译验证。

---

### 2.4 G5：启动前置验证（跨语言）

**现状**：keys/firmware 无效时在 `ryujinx.start()` 内崩溃，靠日志正则提取归因（`extractExceptionInfo`），用户感知为"崩溃弹窗"。

**拆解**：

```
Step 1  [Swift 侧先行，零 C# 改动]：
        LaunchGameHandler.prepareLaunch 中：
          - checkIfKeysImported()（已有）
          - fetchFirmwareVersion() != "0"（已有）
          - 缺失时直接弹精准提示并阻断启动
        收益：覆盖 80% 案例（缺失场景），当天可交付

Step 2  [C# 侧增强，可选]：
        新增导出 SN_validate_environment() -> C 字符串 JSON：
        {keys_ok, firmware_ok, keys_version, detail}
        用于"文件存在但内容无效"场景（坏 keys、损坏固件）
        此步骤需要 C# 侧解析 keys 头 + 固件版本比对，
        工作量中，收益针对边缘场景，排 P2 阶段
```

**验收标准**：Step 1 后缺 keys/固件场景不再进入崩溃路径；Step 2 后坏文件场景被精准拦截。

---

### 2.5 T3：设置搜索（数据驱动重构）

**现状**：`SettingsView.swift` 1519 行，硬编码 ViewBuilder 渲染各 section。

**拆解**：

```
Step 1  抽象 SettingItem 数据模型（不动视觉）：
        struct SettingItem: Identifiable {
            let id: String
            let title: String
            let icon: String
            let group: String          // 分组名
            let keywords: [String]     // 搜索关键词（含术语别名）
        }

Step 2  建立 SettingsCatalog：集中注册全部设置项元数据
        （此步为纯增量，不影响现有渲染）

Step 3  逐 section 迁移：
        每迁移一个 section，其渲染改为由 catalog 数据驱动，
        其余 section 保持原样。用 3~5 个 PR 完成全量迁移

Step 4  接入搜索：
        Searchable modifier + catalog 关键词匹配 → 过滤显示
```

**验收标准**：每个迁移 PR 独立可合且视觉零变化；全量迁移后搜索可用。

**风险**：大文件逐步迁移容易烂尾，必须按 Step 3 的小 PR 节奏，禁止一次性重写 1500 行。

---

### 2.6 弹窗统一（SwiftUI Alert 收敛）

**现状**：`showAlert`（UIKit UIAlertController）+ SwiftUI `.alert` 混用。

**拆解**：

```
Step 1  新建 AlertRouter（ObservableObject 单例）：
        @Published var currentAlert: AppAlert?
        AppAlert: Identifiable { title, message, buttons }
        根视图（MeloNXApp）挂 .alert(item: $router.currentAlert)

Step 2  兼容层：showAlert() 内部改调 AlertRouter
        （UIKit 实现保留，但仅作 iOS 14/15 降级路径）

Step 3  逐模块迁移：ImportHandler → LaunchGameHandler → SetupView → …
        每模块一个 PR，每步肉眼对比弹窗样式
```

**验收标准**：全 App 弹窗视觉一致；iOS 14/15 降级路径可用。

---

### 2.7 G4：Loading 可取消

**现状**：`startGame()` 一旦触发，`runner.start` 线程内 `mainRyu` 阻塞运行，取消需要完整生命周期支持。

**拆解**：

```
Step 1  调研现有 stop 路径：
        EmulationView.stop() → RyujinxBridge.stopEmulation() → ryujinx.stop()
        确认"启动中"状态下 stop 的时序安全（Runner 线程 join/中断）

Step 2  取消按钮 → 调同一 stop 路径 + 回游戏库：
        LoadingOverlayView 增加 Cancel 按钮，
        action: stopEmulation() + gameHandler.currentGame = nil

Step 3  若启动中 stop 不安全（实测崩溃），
        降级方案：取消按钮隐藏（loading 保持 30s 超时兜底），
        排期 P3 专项治理 Runner 生命周期
```

**验收标准**：取消后回到游戏库且可再次启动；或明确降级为 P3。

**风险**：模拟器初始化中途打断是最容易产生僵尸状态（半初始化 Metal 层、C# 静态状态）的场景，本项为 8 项中**风险最高**，允许降级交付。

---

## 3. 依赖拓扑与实施顺序

```
G1(JIT诊断结构体) ──► L2(胶囊标签复用诊断)
                        │
                        └──► G5.Step2(环境验证，可并行)
A级小项 ──────────────► 随时插入，无依赖
L6.阶段A ────────────► 独立
G3/G5(C#侧) ─────────► 合并为一次 C# 编译验证窗口
T3 ──────────────────► 独立长线任务，多 PR 推进
弹窗统一 ────────────► 优先于新增弹窗类改动（避免新弹窗再用旧 API）
G4 ──────────────────► 独立，允许降级
```

**关键决策**：**弹窗统一必须先做**（Step 1-2 即可），否则后续新增的诊断面板、进度提示又会用旧 `showAlert`，债台越垒越高。

---

## 4. 分阶段计划

### 阶段 0：地基（1~2 天）
| 任务 | 内容 | 产出 |
|------|------|------|
| 弹窗统一 Step 1-2 | AlertRouter + showAlert 兼容壳 | 新弹窗入口就位 |
| 语义色定义 | Theme.swift：主操作/成功/警告/危险 | 后续 UI 用色基准 |

### 阶段 1：核心路径闭环（3~5 天）
| 任务 | 内容 | 验收 |
|------|------|------|
| G1 全量 | JIT 诊断三件套（Step 1-4） | 4 种失败场景正确归因 |
| L2 | JIT 状态胶囊（复用 G1 结构体） | 游戏库可见 JIT 状态 |
| L6 阶段 A | 后台拷贝 + 不确定进度 HUD | 大文件导入不冻结 |
| G5 Step 1 | 缺失 keys/固件前置阻断 | 缺失场景不崩溃 |
| A 级速赢 | E2 退出措辞、S1 动画跳过、L1 空状态 CTA | 合并 1~2 个 PR |

### 阶段 2：体验打磨（1 周）
| 任务 | 内容 | 验收 |
|------|------|------|
| G3 | C# 侧 LoadingStage 回调 + Swift 阶段文本 | 阶段切换可见 |
| G5 Step 2 | C# 侧 SN_validate_environment（与 G3 合并编译验证） | 坏文件精准拦截 |
| L6 阶段 B | 分块拷贝 + 真实进度 | 百分比显示 |
| E1/E3 | 悬浮球 + 暂停标识 | 游戏内可用性提升 |
| A 级余项 | M1 M2 S2 S3 S5 L4 G2 E4 E5 T1 T2 | 分批小 PR |

### 阶段 3：长线治理（2~3 周，可与阶段 2 并行）
| 任务 | 内容 | 验收 |
|------|------|------|
| T3 | 设置数据驱动重构（5+ 个小 PR） | 搜索可用、视觉零变化 |
| G4 | Loading 取消（允许降级） | 取消安全或明确定级 P3 |
| 弹窗统一 Step 3 | 全模块迁移完成 | 旧 API 仅剩兼容层 |
| M3 S4 S6 L5 L3 | 剩余 P2/P3 项 | 排期消化 |

---

## 5. 测试策略

| 层 | 内容 | 工具 |
|----|------|------|
| 单测 | JITDiagnosis 状态机（模拟 4 种失败）、SettingItem 搜索匹配 | XCTest |
| 快照 | 关键视图（诊断面板、HUD、空状态）深/浅色 × iPhone/iPad | SnapshotTesting |
| 真机 | JIT 启用/未启用双场景回归（必须真机，模拟器无 JIT） | TestFlight + 真机清单 |
| C# 侧 | G3/G5 新导出接口冒烟（iOS 编译 + 模拟器跑通） | xc-compile.sh + 模拟器 |
| 回归清单 | 导入/固件/启动/退出 4 条主路径手测清单 | 每阶段发布前过一遍 |

**特别提示**：JIT 相关改动无法在模拟器验证（无 JIT 环境），必须纳入真机测试窗口，阶段 1 发布前预留真机验证时间。

---

## 6. 风险与回滚

| 风险 | 等级 | 缓解 |
|------|------|------|
| G4 中途取消产生僵尸状态 | 高 | 允许降级 P3；取消按钮仅当 stop 时序验证安全后上线 |
| C# 侧回调改动破坏 iOS 构建链 | 中 | G3+G5 合并一次编译窗口；保留 Swift 降级路径 |
| T3 大文件重构烂尾 | 中 | 强制小 PR 节奏（每 PR 迁移 ≤2 sections），视觉零变化为合入门槛 |
| 弹窗统一期间样式回退 | 中 | 先做 Router+兼容层，模块迁移与旧版对照 |
| 安全作用域跨线程失效（L6） | 中 | 拷贝与 scope 同线程；阶段 A 加真机验证 |
| JIT 诊断误判（dualmapped/entitlement 组合） | 中 | 诊断状态机单测覆盖；真机双场景回归 |

**回滚原则**：所有 B 级改动以独立 PR 合入，任一 PR 出问题可单点 revert，不污染其他优化项。

---

## 7. 资源评估

| 阶段 | 工作量 | 前置 |
|------|--------|------|
| 阶段 0 | 1~2 人日 | 无 |
| 阶段 1 | 5~8 人日 | 阶段 0 |
| 阶段 2 | 6~10 人日（含 C# 编译验证） | 阶段 1；C# 侧与 iOS 侧可并行 |
| 阶段 3 | 8~15 人日（可并行进行） | 无硬依赖 |

**总计约 20~35 人日**，建议单人主责 + 阶段 3 可拆给第二人并行。
