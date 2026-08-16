# DeskPet 架构与机制（AI 交接文档）

> 更新时间：2026-08-16（v9：音频设备切换稳定窗口重建/任务派发可见收口/任务失联看门狗；v10：三分控制中断/幽灵任务槽修复；v11：双 Agent 异步细节加固——详见 §12 双 Agent 异步模型与 §8 批次记录；v12：专属执行工作区 workspace 绑定——主/任务会话显式 cwd=~/.deskpet/hermes/workspace；v13：专属 SOUL install-dedicated-soul——profile 根安装独立真实 SOUL.md；v14：补齐 0.6 数据归属、隔离边界与升级理念——见 §1.1–§1.3）
> 本文件是 AI 接手本项目的首要阅读文档：先读本文件 → 再读 HANDOFF.md（铁律/历史/排查）。
> 配套人工可读版：`.pi/artifacts/deskpet.html`

## 0. 项目速览

- **定位：Hermes Agent（`hermes-agent`）的官方桌面语音伴侣 GUI**——面向已安装 Hermes 的用户（不是独立产品；无 Hermes 无法工作）
- macOS 菜单栏桌宠（SwiftPM，无 Xcode 方案），`swift build` + `./build-app.sh` 打包
- Hermes 提供大脑（双 Agent 会话与工具），DeskPet 提供桌面形象 + 语音交互（唤醒/听写/TTS 播报）+ 桌宠体验
- 大脑 = Hermes serve（`~/.hermes/hermes-agent/venv/bin/hermes serve`），**本体不可改**，DeskPet 只做客户端适配
- serve 端口：9119（用户原服务）被占时自启 9120/9121；token 持久化在 UserDefaults（`DeskPetServeToken`，.app 版域为 `com.deskpet.app`，debug 版域为 `DeskPet`）
- 日志：`~/Library/Logs/DeskPet/deskpet.log`（5MB 轮转保留 2 份）；serve 端日志 `~/.hermes/logs/agent.log`
- 会话索引：`~/Library/Application Support/DeskPet/`（.app 版）；项目 `history/data/`（debug 版）
- **v5 历史存储隔离**：新主/任务会话建在 Hermes named profile `deskpet-app`（真实目录 `~/.deskpet/hermes`，由 `~/.hermes/profiles/deskpet-app` 符号链接接入；`config/.env/auth/skills` 只链接不复制；v13 起 `SOUL.md` 改为 DeskPet 独立真实文件）；旧索引缺 profile 视为 legacy——保留可查看删除，升级后旧当前自动归档、新会话立即用 deskpet-app
- **v12 专属执行工作区（deskpet-workspace）**：主/任务会话 `session.create` 均显式传 `cwd=~/.deskpet/hermes/workspace`（DeskPetHermesProfile.workspace 单一事实来源；HermesClient.createSession 可选 cwd 参数，仅 DeskPet 调用传值）——任务 Agent 默认文件/终端操作在专属工作区进行，不再落到启动时所在的用户项目目录；Hermes 本体/主 profile/全局文件零修改
- **v13 专属 SOUL（install-dedicated-soul）**：profile 根安装独立真实 `~/.deskpet/hermes/SOUL.md`（身份=个人数字管家；只定义身份/目标/职责/固定边界）——口气由 personas、语音格式由 voice prompts 提供，三层互不重复注入；不再链接主 SOUL，主 SOUL 零读写；升级不覆盖既有专属文件，Agent 不自行更新

## 1. 三层架构与文件映射

```
① 语音层                      ② AI Agent 层                 ③ 展示/交互层
WakeController.swift          HermesClient.swift             PetView.swift（动画/右键菜单）
SpeechInputController.swift   HermesBridge.swift（核心）      BubblePanel.swift（气泡）
DuoyunASRProvider.swift       ServeManager.swift             StatusItemController.swift（菜单栏）
SpeechOutputManager.swift     SessionIndex.swift             SettingsMenuFactory.swift
DuoyunSpeechProvider.swift    CommandRouter.swift            InputPanelController.swift
EdgeTTSProvider.swift         AppDelegate.swift（胶水层）      DeskPetConfig.swift
DeskPetHermesProfile.swift    HermesClient.swift             DeskPetState.swift
```

- **AppDelegate** 是胶水：接线 ①↔②↔③，`showBubble`/`feedback` 是唯一气泡/反馈入口，NSWindow 操作主线程收口
- **HermesBridge** 是核心：状态机（idle/waiting/run/review/failed）、事件处理、双轨解析、任务标记协议、结果归档

### 1.1 0.6 数据归属与隔离边界

```text
Hermes 本体（只依赖，不修改）
~/.hermes/hermes-agent/

DeskPet named profile（会话运行状态）
~/.deskpet/hermes/
├── state.db                # 主 Agent + 任务 Agent 的完整消息/会话
├── SOUL.md                 # DeskPet 独立身份：个人数字管家
├── workspace/              # 主/任务会话显式 cwd；任务默认文件落点
├── logs/cache/bin/...      # Hermes 在该 profile 下生成的运行数据
└── config/.env/auth/skills # 指向主 profile 的复用链接，不复制内容

项目内 DeskPet 数据（App 自己维护）
DeskPet/history/
├── config/                 # personas、voice prompts、commands、DeskPet 设置
└── data/session-index.json # 会话 ID、任务归属与完成状态索引；不是聊天正文
```

边界含义：

- **完整聊天正文**属于 Hermes profile，存于 `~/.deskpet/hermes/state.db`；项目内 `session-index.json` 只是可移植索引，不重复保存消息正文。
- **任务产物**默认属于 `workspace/`，与会话数据库分离；清聊天历史不应顺带删除工作文件，清工作区也不应破坏会话索引。
- **SOUL**属于 DeskPet profile 的稳定身份；**persona**负责具体宠物的口气/性格；**voice prompts**负责语音输入容错与播报格式。三者职责不重叠。
- `workspace/` 是**默认工作目录隔离**，不是操作系统权限沙箱。任务 Agent 在用户明确授权并给出绝对路径时仍可能访问其他位置；不可逆、敏感、付费或外发操作仍必须经过确认。

### 1.2 设计理念

1. **DeskPet 适配，不侵入 Hermes**：只使用 Hermes 已有的 named profile、`session.create.cwd`、会话 API 和提示词加载机制；不修改 `~/.hermes/hermes-agent/**`，不替用户改全局 `terminal.cwd`。
2. **显式路径优于进程环境**：会话创建必须显式传 workspace cwd，不依赖 App 从 Finder、终端或其他项目目录启动时碰巧继承的当前目录。
3. **状态、工作文件、身份分层**：`state.db` 管对话，`workspace/` 管产物，`SOUL.md` 管稳定职责，persona/voice 管体验。任何一层的清理或升级不应隐式覆盖另一层。
4. **用户所有权优先**：首次安装只创建缺失文件；既有专属 SOUL 永不自动覆盖，Agent 不自行改写；仅识别并迁移 DeskPet 旧版创建的主 SOUL 链接，未知链接直接报冲突。
5. **安全迁移、可回退历史**：workspace 切换用 seed 版本门槛新建当前会话，旧会话只归档不迁移正文、不删除；迁移失败必须可见，禁止静默回退用户项目目录。
6. **单一事实来源**：profile 根和 workspace 统一由 `DeskPetHermesProfile` 定义；会话 cwd、SOUL 安装、测试与文档都引用同一位置，避免多套路径漂移。
7. **主快、任务稳**：主 Agent 保持对话与控制权，任务 Agent 在单槽 FIFO 中执行；两者共享身份与 cwd，但不共享职责，任务运行不阻塞主对话。
8. **可观察而不伪成功**：目录创建、链接冲突、远端中断、任务启动与事件缺失都有明确状态/日志/用户反馈；不能验证时报告限制，不把推断当完成。

### 1.3 安装、升级与会话生效顺序

```text
DeskPet 启动
→ ensure ~/.deskpet/hermes 与 named-profile 接入链接
→ 创建并校验 workspace/（失败即停止会话创建，不回退）
→ 安装 SOUL：缺失则从 App 模板创建；旧主链接则只替换链接；普通文件保留
→ 复用 config/.env/auth/skills 链接
→ 检查 mainSeedVersion
   ├─ 旧版本会话：归档保留，不 resume
   └─ 当前版本会话：正常 resume
→ 新建主会话与常驻任务会话时显式传同一 cwd
```

- 新 SOUL 和新 cwd 在**新建/重新构建 Agent 会话**后生效；不能假设修改磁盘文件会重写已经在内存中的模型上下文。
- 0.6 使用 `mainSeedVersion = 4` 作为 workspace 切换门槛：旧历史仍能查看/删除，新当前会话绑定专属工作区。
- 发布验证必须同时检查：最终 App 二进制、workspace 类型/边界、SOUL 是否为普通文件、主 SOUL/全局配置 mtime 未变、旧历史仍在。

## 2. 对话主流程（v3）

```
用户说话 → 唤醒词(本地KWS) → 听写(ASR+静默2s分段) → routeUserInput
  ├─ 本地指令路由(CommandRouter)：取消/状态查询/静音/新开对话等 → 即时执行（零延迟零失真）
  ├─ 指令路由命中派发触发词（帮我查/打开/搜索…，及 v4 高置信 regex：帮我/请帮我+执行·运行·
  │  文件/代码/脚本/命令/目录/项目/文档类操作）→ 直接 startTask（不经主 Agent；regex 全量原文直传）
  └─ 主会话：chat() 原文提交（人设/协议已在 seed，不再前缀注入） → prompt.submit
     → Hermes 主 Agent 回复
     → message.delta 流式 → mainBuffer
     → message.complete → （delta 缺失时用 complete.payload.text 兜底）
     → 主回复解析（见 §3）→ 气泡(showBubble) + 播报(speak)
     → [耗时] 日志：用户消息→主回复完成秒数（v3 新增，端到端延迟可观测）
```

## 3. 双轨协议与任务直报（v3）

**注入（一次性，seed v3）**：人设 + 双轨格式 + 精简标记协议在主会话创建时注入 seed（`mainSessionSeed`）；
用户消息不再前缀注入（旧机制 token 线性膨胀已移除）。切人设 = `applyPersonaChange` 单次提交变更消息
（主 Agent 用新人设打招呼确认，正常显示+播报）；彻底生效可新开对话（新 seed 按新 petID 生成）。
seed 版本号存 SessionIndex（`mainSeedVersion`，当前 4）——版本不符的旧会话不 resume、直接新建（v12：3→4 为 workspace 绑定门槛——旧 cwd 会话归档保留，新建绑定工作区的会话；后续 restart 正常 resume）。

**解析**（`HermesBridge.parseDualTrack`）：
1. 提取 `<spoken>…</spoken>` 与 `<formal>…</formal>`
2. 有 spoken → `(spoken, formal)`；仅 formal → `(spoken, formal)`
3. **都空（主 Agent 不遵守协议）→ 全文兜底 `(全文, 全文)`**——有回复必播报必显示，不丢

**消费**（`AppDelegate.onMainMessage`）：
- 气泡：**formal 优先**（折叠 2 行 + 点击展开滚动阅读；长气泡截断文案）
- 播报：**只念 spoken，formal 绝不生成语音**；spoken>200 字才截断（"更多内容请看气泡"）
- 空回复：不弹气泡不播报；用户轮给「刚才那句我没接住，再说一遍？」
- **非用户轮（归档 ack/人设变更确认）：不播报**——剥 `<ok/>` 后为空则完全静默，非空仅显示气泡（防丢信息）

## 4. 播报机制（SpeechOutputManager）

- provider 链：豆包 TTS → Edge TTS → 系统语音（`speechChain` 配置，失败自动降级）
- **优先级**：high（主回复/反馈）立即打断；low（任务完成/进度）入队，当前播完推进
- **串行合成（2026-08-13 修复）**：high 多句逐句——只提交第 1 句，播放完成回调推进下一句（`pendingHigh` 队列）——杜绝多句并发合成完成顺序乱导致交叉/乱序
- **打断语义**：新 high → stop（停当前播放 + 清 pendingHigh + 作废在途合成 generation+1 + 清低优队列）→ 播新内容——**最终结果优先，中间播报全部丢弃**
- **说话即打断**：用户开口 → stop（低优队列保留，2s 后空闲推进）；`recordingGuard` 防录音中插播
- **任务播报抢占**：`cancelTaskSpeech(newTag)`——新任务派发清空低优队列，旧任务 tag 播报丢弃
- P0-2：`onSpeakingChange` 通知播报状态（持续聆听采集闸门用）

## 5. 语音闭环防护（P0，2026-08-13）

| 缺陷 | 修复 |
|---|---|
| 静默误提交（"嗯"） | 提交闸门：`<2 字 \|\| 平均置信 <0.5` 丢弃（常量 `minSegmentLength`/`minSegmentConfidence`，可调） |
| TTS 回声自回灌 | 播报开始暂停采集（`pausedForTTS`，不发 onStateChange 零抖动），播完恢复；提交闸门 `isSpeaking` 双保险 |
| 退出后自动重启识别 | 提交后 `guard self.continuousMode`（退出聆听后绝不重启） |

持续聆听默认关闭（验证后再评估默认开启）。

## 6. 任务协作流程（v3：直报 + 归档）

```
主 Agent 回复含 <task>…</task> 标记 / 本地触发词命中 → parseTaskMarkers 剥离 → startTask
→ 常驻任务会话（种子注入一次，跨任务复用；同一时间只执行一个 turn；新任务排队 ≤5）
→ 任务 Agent 执行（工具/搜索/终端；默认工作目录 = 专属工作区 `~/.deskpet/hermes/workspace`，v12 绑定）
→ message.complete → 下一主线程调度机会 → 双轨解析（v4：不再固定 1.5s 静默窗口）
→ 【直报】isFinal：气泡显示 formal 全文 + 语音直接播 spoken（任务 Agent 亲自浓缩的精简版，
  零二次转述、零回填等待；>150 字截断护栏）
→ 【归档】archiveTaskResult：formal 全文写回主会话存档（主 Agent 只回 <ok/>，客户端剥掉不显示
  不播报；追问任务细节时主 Agent 有全量上下文）
→ 空结果按失败处理（不报"任务完成"）
```

- 标记协议（v3 减法后）：`<task>`（派发）/ `<task_steer>`（追加指令）+ `<spoken>/<formal>`（双轨）+ `<ok/>`（归档 ack）；
  **`<task_status>`/`<task_cancel>` 已从 seed 删除**——状态查询/取消由本地路由即时执行（解析代码保留作防御：status 仅剥离、cancel 仍执行）
- 归档机制：防抖 5s 多任务合并为一条提交（旧版覆盖 bug 已修）；失败仅记日志不重试（丢档只影响追问细节，无用户可见影响）
- 任务队列：最多排队 5 个；新任务不打断当前 turn，显式停止时当前任务与等待队列一起清空
- 打断：`interruptTask() -> TaskInterruptOutcome`（inactive/stopped/stoppedUnconfirmed/cancelledDuringStart）——
  本地收口始终完成（远端 RPC 失败如实标记 stoppedUnconfirmed）；启动中取消走 cancelledDuringStart；详见 §12
- 打断后：明确「任务已停止，不会再有结果了」/「已本地停止但远端未确认」

## 7. serve 生命周期与自愈

- 复用"自己的"serve（token 握手通过）→ 否则自启（9119→9120→9121）
- 自愈触发：未连接 / 发送失败 / 接收中断 / 健康检查失败；**RPC 超时不再直接触发**（假超时已修——仅 pending 判超时）
- 防抖 60s / 防风暴 1h 最多 3 次
- serve 重启丢会话（4007）→ resume 失败自动重建；`handleServeReconnected` resume 钩子防断链死循环
- 手动重连成功 → 「✅ 已重新连接助手服务」（仅手动路径，冷启动不打扰）

## 8. 关键修复决策记录（v3 批次 2026-08-14）

| 问题 | 根因 | 修复 |
|---|---|---|
| 任务汇报延迟+失真 | 任务 spoken 被丢弃、回填 spoken 截断 1200 字→主 Agent 二次转述（两次浓缩，主 Agent 无执行上下文） | **直报**：isFinal 直接播任务 spoken；**归档**：formal 全文写回主会话，主 Agent 只回 <ok/> |
| 5s 防抖窗口内两任务完成，前者回填丢失 | pendingBackfill 单值覆盖 | 归档改数组追加，flush 合并为一条提交 |
| 回填链路复杂（退避重试×2/tag 抢占/过渡气泡） | 归档失败被视为需重试的用户可见错误 | 失败仅 log 不重试（丢档无用户可见影响）；整条 WriteBackRetry/tag 抢占/过渡气泡链删除 |
| 每条消息前缀注入人设+协议 | 旧版为热切换妥协，token 线性膨胀 | 人设/协议进 seed 一次性注入；切人设单次变更消息；seed 版本不符自动新建会话 |
| 协议 8 种标记认知负荷高 | 历史兼容堆积（dispatch/steer 旧格式、status/cancel 写回） | 减到 4+ok：status/cancel 本地路由即时执行；dispatch/steer 不再教学（解析保留防御） |
| 状态查询绕整圈（LLM→写回→再转述，秒级延迟） | 主 Agent 输出 <task_status/> → 系统查状态写回 → 主 Agent 转述 | 本地路由直答（还在工作吗/任务状态/任务进度）零延迟 |
| 端到端延迟不可观测 | 无计时 | [耗时] 日志：用户消息→主回复完成秒数（排队场景记最新一次） |

### v4 批次（状态同步 state-sync-fix，摘要）

| 问题 | 根因 | 修复 |
|---|---|---|
| 状态错位：任务完成但主回复仍生成时立绘提前 idle；队列衔接时提前休息 | debounceIdle guard 只查 activeTask，未覆盖 mainTurnActive/taskSlotOccupied | guard 覆盖真实忙态（任务运行 / 主 turn 打开 / 任务槽占用），不加延时 |
| 任务结束后立绘卡 run 不回落 | tool.start/tool.generating 非任务 else 无条件 setState(.run)——setState 取消 idleTimer 后无人再安排回退 | 只允许可归属的活跃生命周期驱动 run（任务 turn 未关 / 主 turn 活跃）；无归属/迟到事件忽略 + debug 日志 |
| 任务 message.complete 缺 session_id 时 activeTask 永久残留（卡忙/队列卡死） | 任务分支 require sid 解包，nil 时事件整体忽略 | activeTask 存在且 turn 未关、主 turn 未打开时安全消歧为当前任务（warn 日志）；主 turn 活跃时归主（不丢主回复） |

### v5 批次（历史存储隔离 history-storage-fix，摘要）

| 问题 | 根因 | 修复 |
|---|---|---|
| 会话/状态与用户主 profile 混存（~/.hermes），清历史会碰主环境 | 无 profile 隔离 | Hermes named profile `deskpet-app`：真实目录 ~/.deskpet/hermes，由 ~/.hermes/profiles/deskpet-app 符号链接接入；create/resume/delete 按记录 profile 路由；缺失 config/.env/auth/SOUL/skills 只建指向既有项的符号链接（不复制凭证）；冲突不覆盖报错 |
| 升级后旧会话与新旧混存 | 索引无 profile 概念 | 索引记录加 profile（nil=legacy）；legacy 可解码、归档、不删除；升级后旧当前自动归档，新会话立即用 deskpet-app |
| 远端删除失败但本地索引已清（假清空） | 清空先清索引后删远端 | 远端成功才移除索引；失败保留可重试；单主删除失败任务索引保留（removeMain keepTaskIDs）；清空成功路径清运行态含 pendingArchives/backfillWorkItem/turnTracker |

### v6 批次（fresh-install 加固，摘要）

| 问题 | 根因 | 修复 |
|---|---|---|
| 全新用户/空 HOME 场景接入链接创建失败（~/.hermes/profiles 不存在） | ensure 未递归创建父目录；真实目录创建失败 try? 静默 | H1：递归创建并验证 ~/.hermes/profiles；真实目录失败抛 directory 不静默 |
| ensure 失败后无法重试（ensured 提前置位） | ensured=true 在成功前设置 | H2：全部成功才置 ensured=true；失败后用户修复可重试 |
| 后端静默降级默认 DB（请求 deskpet-app 却写入默认 profile） | serve 端 profile 解析失败时 _response_profile_name 回退 launch profile 名 | M3：主/任务会话 create 后均校验 info.profile_name==deskpet-app 且 desktop_contract>=6（当前已验证门槛）；校验失败各自关闭/删除刚建会话、释放创建权、legacy 索引保留、报 Hermes 版本不兼容 |
| 错误提示不可行动 | 单一连接失败文案 | M1：ProfileError 区分 conflict/directory/backendIncompatible，AppDelegate 给可行动中文反馈（含重试入口） |
| 历史查询不按 profile 路由 | history 无 profile 参数 | M2：HermesClient.history(profile:)，主/任务历史查询按记录 profile 路由 |
| 无目录归属标记；第二实例可双写 | 无 ownership 标记；单实例锁失败仅 warn 继续 | M4：~/.deskpet/hermes 写入不含隐私 ownership/version 标记（既有正确链接补标记，其他预置目录不接管）；main.swift 锁失败即退出阻止初始化 |
| Developer ID 公证 / Intel universal / Finder 卸载交互 | 发布流程项 | 明确保留为发布限制（本任务不处理） |

### v7 批次（唤醒词热生效 wake-reload-fix，摘要）

| 问题 | 根因 | 修复 |
|---|---|---|
| 设置唤醒词后不热生效（listening 才重启） | setWakePhrase 仅 currentState == .listening 时 stop+start | 决策提取为纯函数 wakeReloadAction(for:)：listening/arming/disabled → .reloadNow（stop 幂等，disabled 从失效恢复监听）；detected → .reloadAfterResume |
| arming（start 中）时新词不生效 | start() guard 只认 disabled，arming 时 stop+start 顺序被 guard 挡住 | reloadNow 统一 stop()（置 disabled）→ start()（guard 通过），arming 也立即重启 |
| disabled（检测器失效/未启动）时设置词不恢复 | 旧逻辑仅 listening 分支 | reloadNow 覆盖 disabled：stop 幂等 + start 重新 locate/spawn（新词随 spawn 参数生效） |
| detected（听写中）设词后 resume 不换词（旧词残留） | resume 只恢复采集不重启子进程 | pendingReload 标记；resume 2s 防抖回调内消费 → stop+start（不打断已结束听写）；start() 清零作废 |
| 状态分支无法离线验证 | 决策内嵌 UI 路径 | 纯函数 wakeReloadAction + pendingReload 钩子，tester 可离线断言四态分支（不触音频） |
| 既有行为 | — | 异常退出自动重启（30s 防抖）、heartbeat 卡死重启、采集暂停/恢复、start() guard 语义均保留 |

### v8 批次（ASR 分段修复 asr-segmentation-fix，摘要）

| 问题 | 根因 | 修复 |
|---|---|---|
| 两句话任务只收到后半句（三途径用户实测） | 豆包路径无本地分段（服务端端点 1~2s 切碎 + didSubmitFinal 一次性守卫丢弃后续 final）；Apple 服务器模式同样自动端点；on-device 静默计时与 final/partial 时序竞态 | 统一 SpeechSegmenter 分段状态机（三 ASR 途径同一入口）：静音 1s 分句标记不提交、静音 listenSilenceTimeout（默认 2.0s，可调）提交累积、分句窗口内新内容合并 |
| 服务端 final 立即提交/被一次性守卫丢弃 | didSubmitFinal 布尔守卫 | 段级 submitted 去重 + final 只更新累积（utteranceUpdate 幂等收尾 / restart 后 utteranceStart 拼接合并），提交由本地 1s/2s 计时统一驱动；服务器模式 final 与豆包同构（仅累积+续听，唤醒听写在 2s 静默后才结束） |
| 合并窗口计时漂移（final 到达晚于实际停说，从到达起算 2s 会提前/延迟提交） | 端点检测静音 ~1s 后 final 才到达 | 服务端 final 到达即分句边界已过（立即 boundaryMarked=true）；豆包路径 VAD 语音活动重置 1s/2s 计时（提交相对实际停说时刻）；服务器模式新 request partial 到达重置（语音活动近似） |
| 竞态窗口（partial 延迟、2s 提交与 final 先后） | 提交时机分散在 final/error/静默多路径 | 提交收敛到 handleSilenceCommit（计时）与 finish（收尾）两点，submitted 去重；stop/error/final 均走 finish |
| 阈值不可调/不统一 | 固定 2s/3s 常量 | 提交阈值接 config.listenSilenceTimeout（默认 2.0s，clamp 1.0...5.0）；分句 1s 常量；持续/唤醒/手动统一 |
| 语义回归风险 | — | 唤醒听写提交后结束、持续聆听提交后重启、TTS 回声防护（isSpeaking 提交闸门）、VAD 静音过滤、未开口 10s/60s 超时全部保留 |
| 无法离线验证 | 状态机内嵌 UI/音频路径 | SpeechSegmenter 纯值类型 + runSelfTest（23 断言挂 --self-test-vad 入口，合成输入不触音频） |
| 续听 restart 抹除已累积前半句 | startRecording/startDuoyunRecording 无条件 segmentState.reset | 服务端 final 续听走 preserveSegment 路径（restart 跳过 reset 与 L2 补交，累积/boundary/submitted 保留）；新会话（用户停止后新录音/唤醒结束）仍完整 reset |
| 续听时刻 L2 补交提前提交 | startRecording 的 L2 补交在 restart 时也触发 | 补交仅限用户停止后快速连说（!preserveSegment）；服务端 final 续听不补交，保护合并窗口 |
| 豆包唤醒单句在续听后丢失 | restart 清空累积 | preserveSegment 保留累积——无续说时本地 2s 计时（相对 final 到达，VAD 重置辅助）正常提交单句 |

### v9 批次（音频设备切换重建 + 任务生命周期收口，摘要）

| 问题 | 根因 | 修复 |
|---|---|---|
| 蓝牙/默认设备切换后采集失效 | 配置变化风暴中立即重建，过渡期格式无效即死；重建丢未提交段；TTS 暂停遗留旧计时器 | 0.6s 稳定窗口防抖重建（preserveSegment 段保留 + epoch/引擎身份守卫 + 有界重试 + 失败可见非假开启）；resume/resumeCapture 恢复同样重试；启动失败清理孤儿检测器进程 |
| 任务已接收却无下文 | 标记路径 try? 吞错；complete 丢失后 activeTask/槽/UI 永久卡住 | startTask/dispatchTask 不抛错、全部失败 onTaskFailed 可见收口；600s 任务失联看门狗（事件重排、收口取消） |

### v10 批次（三分控制中断 split-interrupt-commands + 幽灵任务槽 fix-ghost-task-queue，摘要）

| 问题 | 根因 | 修复 |
|---|---|---|
| 中断语义单一，无法只停主回复/只停任务 | 仅有 task-only interrupt | 三分控制：中断任务（task-only）/停止回答（main-only：finalizeMainInterrupt 关 mainTurnActive/清 buffer/消费在途 tracker/迟到 complete+error 抑制/flush 聊天队列）/全部停止（两侧独立收口）；触发词 prefix 语义不误伤否定句 |
| 幽灵任务排队（旧任务已取消/启动失败，新任务被误报「当前任务还在执行」长期排队） | reserveTaskSlot 置位后启动盲区（activeTask 未创建）：取消/清队/出队三路径均可留残留槽或被误释放 | StartingTask(token) 启动生命周期登记 + taskSlotPhase 判定 + 幽灵槽自愈直接启动 + 出队即登记 + 锁内 token 转换（迟到创建拦截）+ interruptTask 本地收口不依赖远端（stoppedUnconfirmed 如实提示）+ ensureTaskSession 竞争等待显式 3s 上限 + 排队文案区分「正在启动/正在执行」 |

### v11 批次（双 Agent 异步细节加固 harden-dual-agent-async，摘要）

| 问题 | 根因 | 修复 |
|---|---|---|
| 服务端 queued 的归档 backfill 身份丢失（<ok/> 被当用户回复展示）或提前登记污染在途用户 turn | 仅非 queued 提交登记 tracker；queued 归档记录先于在途用户 turn 的 complete 被消费 | R3：四个提交点（chat/flushChatQueue/applyPersonaChange/archiveTaskResult）成功提交即按序登记（含 queued），tracker 成为提交顺序的精确 FIFO |
| 缺 sid complete 在并发边界误归任务（提前收口真实任务）或误归主（丢主回复） | 仅凭 mainTurnActive 消歧 | R4：`nilSidCompleteBelongsToTask` 纯函数按显式在途证据（主 turn 活跃/主 tracker 在途/主侧刚完成 3s 窗口）消歧；主侧刚完成窗口内迟到/重复 complete 忽略（任务侧看门狗兜底） |
| R1 双 runTaskNow / R2 启动中取消 | 由 v10 StartingTask/token 闭环 | 仅补组合回归断言（dual-agent 段） |

### v12 批次（专属执行工作区 deskpet-workspace，摘要）

| 问题 | 根因 | 修复 |
|---|---|---|
| 任务 Agent 默认文件/终端操作落在启动时所在目录（如用户项目目录 `/Users/uzxzander/Downloads/项目-助手`），与用户工作文件混放 | 会话创建未指定工作目录，serve 按 launch cwd 回退 | **DeskPet-only cwd 覆盖**：`DeskPetHermesProfile.workspace`（realHome `~/.deskpet/hermes` 下固定 `workspace/` 子目录）为单一事实来源；`ensure()` 幂等创建并校验（是目录 + 标准化后位于 realHome 内，失败抛可见 directory 错误，不回退当前目录/主 terminal.cwd）；主/任务 `session.create` 均显式传 `cwd=workspace.path`（HermesClient.createSession 新增可选 cwd 参数，默认 nil 不带 cwd 键——其他调用者行为不变；serve 端 methods_session.py 原生支持 cwd） |
| 升级后旧 cwd 当前会话继续作为新当前（文件操作仍落旧目录） | 会话无 cwd 绑定标识 | 最小版本门槛：`mainSeedVersion` 3→4——旧（未绑定 cwd）会话不 resume（`shouldResumeMainSession` 纯函数：seed 一致且有 profile 才 resume），旧当前由 setMain 自动归档（历史保留可查看/删除，**不迁移正文**），新建绑定 workspace 的主会话；后续 restart seed 一致 → 正常 resume 新会话 |
| 主 Agent 仍是纯对话协调者 | 无 | 主/任务会话均绑定 workspace cwd（主 Agent 无工具，其 cwd 仅一致性）；seed v4 注入工作目录说明，任务 Agent 种子明确「文件/终端操作默认在此专属工作区进行」 |
| 工作区边界不可验证 | 无离线断言 | HistoryStorageSelfTest：workspace 创建/校验/占用失败可见/修复重试/幂等；HermesBridgeSelfTest：`createSessionParams`（cwd 键构造）与 `shouldResumeMainSession`（门槛）纯逻辑回归；**Hermes 源码/`~/.hermes/config.yaml`/SOUL/凭证/skills 等全局文件零修改** |

### v13 批次（专属 SOUL install-dedicated-soul，摘要）

| 问题 | 根因 | 修复 |
|---|---|---|
| DeskPet 会话加载主 profile 的 SOUL（~/.hermes/SOUL.md），身份/行为随主环境变化且清历史时可能受影响 | profile 复用链接把 SOUL.md 指向主文件 | **内容分层**：专属 SOUL 只定义身份（个人数字管家）/目标/职责/固定边界；口气由 personas（personas.json）、语音格式由 voice prompts（prompts/voice.json）提供——三者不重复注入 |
| 升级/安装时如何放置专属 SOUL | 无模板与安装机制 | 模板 `DeskPet/config/SOUL.md`（build-app.sh 复制到 App Resources/config）；运行时首次 `ensure()` 经 ProjectPaths 定位模板，原子创建 profile 根真实文件（.atomic） |
| 旧版本遗留 SOUL → ~/.hermes/SOUL.md 链接 | 复用链接历史遗留 | `soulAction` 纯函数决策：缺失→createFromTemplate；明确指向主 SOUL 的链接→只删链接本体后创建专属文件（主 SOUL 不读不复制不改，内容/mtime 不变）；普通文件→keepExisting 永久保留；其他链接→conflict 不接管 |
| 应用升级/重启会覆盖用户专属 SOUL 吗 | 无保留策略 | 不覆盖：既有普通文件永久保留，Agent 不自行更新此文件；模板缺失时跳过安装（绝不删而不建） |
| workspace 出现第二份 SOUL 重复注入 identity | 无边界约定 | workspace/ 只作 cwd 上下文，不创建 SOUL；主/任务会话经同一 HERMES_HOME（deskpet-app）加载同一专属 SOUL |
| 迁移/保留/冲突不可验证 | 无离线断言 | HistoryStorageSelfTest（临时 HOME）：缺失创建（内容==模板）、旧主链接替换（主 SOUL 内容/mtime 不变）、普通文件保留、其他链接冲突、幂等、soulAction 四分支纯函数；**Hermes 本体/主 profile 零修改** |

### 历史批次（2026-08-13，摘要）

| 问题 | 根因 | 修复 |
|---|---|---|
| 自愈锁死烧额度 | RPC 成功返回后遗留超时定时器制造假超时 | 仅 pending 判超时；RPC 超时≠传输失效 |
| 空结果任务报"完成" | 完成判定不检查结果空 | 空结果按失败处理 |
| 空闲误报"已打断" | interruptTask 无条件成功 | 返回 Bool + 菜单置灰 |
| 主回复永远空 | ①serve 对 resume 会话的 delta 偶发不到达 ②主 Agent 不输出双轨标记 | ①complete.text 兜底 ②parseDualTrack 全文兜底 |
| 播报交叉/乱序 | 多句并发合成完成顺序乱 | 逐句串行 + 打断清干净 |
| 历史无反馈/长气泡/气泡不消失/唤醒态不一致/serve 错误不可见/事件链路不可见 | 见 git 历史 | 均已修（详见 git log） |

## 9. 可观测性与排查指南

- 播报链路：`播报：N 句（high）` → `豆包 TTS 合成成功：N 字节` → （串行推进）
- 事件链路：`[EVT] message.delta sid=… text=…`（排查主回复/任务事件用）
- serve 侧：`~/.hermes/logs/agent.log`（模型调用/工具/turn 结束，含 response_len）
- 排查主回复为空：①看 [EVT] 是否收到 delta/complete ②看 agent.log 模型是否输出 ③看「主回复兜底」日志是否触发
- 环境坑：终端跑 Swift WS 探针需 `env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY`（否则走 7890 代理连本地 WS 失败）

## 10. 已知限制与下一步

- F1（外部阻塞）：Hermes `config.yaml` 注入 `agent/delegation.reasoning_effort: max`，某些渠道模型（函数工具+reasoning_effort）400——DeskPet 侧无法控制，需 Hermes 配置侧决策（用户已确认暂不改）
- 主 Agent 双轨遵守度：模型行为，不遵守时有全文兜底（体验不丢，仅 TTS token 变多）
- 持续聆听默认关闭；阈值（2 字/0.5 置信）待实机校准（`minSegmentLength`/`minSegmentConfidence` 常量）
- v3 待验证：[耗时] 日志积累后决定是否进一步优化首字延迟（ASR 静默 2s 分段/Hermes 思考等级）
- P2 体验项：本地设置触发云 TTS、开始新对话无确认、形象与性格联动不透明、声线列表重复、冷启动无就绪反馈、AX 状态不可靠、空输入可发送——未处理
- `~/.deskpet/hermes/workspace` 只是默认 cwd，不是 macOS 沙箱；如未来要求强制禁止访问目录外路径，应使用独立进程/容器/系统权限，而不是继续堆提示词判断
- 专属 SOUL 在新 Agent 构建时读取；运行中直接编辑文件不会可靠热更新当前会话，需新开对话或重启会话

## 11. 构建与验证命令

```bash
cd DeskPet
swiftc -parse Sources/DeskPet/<file>.swift     # 单文件语法检查
swift build                                     # debug 构建
./build-app.sh                                  # 打包 DeskPet.app（剥离敏感字段）
swift run DeskPet --self-test-tts               # 播报分句自测
swift run DeskPet --self-test-router            # 指令路由 60/60（三分控制/触发词/误伤反例）
swift run DeskPet --self-test-markers           # 标记协议 + state-sync + task-slot + dual-agent + ux-details + workspace 绑定纯逻辑
swift run DeskPet --self-test-wake              # 唤醒决策 17/17（零音频触碰）
swift run DeskPet --self-test-vad               # 静音分段 8/8 + segmenter 23/23
swift run DeskPet --self-test-asr-seg           # ASR 分段回归 10/10
swift run DeskPet --self-test-history-storage   # 历史存储隔离回归（workspace + 专属 SOUL 生命周期：缺失创建/旧链接替换/保留/冲突/幂等）
```

**验收指标**（deskpet-hv）：丢弃告警 10min ≤2 条 + 30min 归零；桌宠 CPU 待机 ≤1%（当前 0.2-0.4%）；内存 2h 不增长；serve 自愈 kill → ≤30s 恢复 + 对话提交成功；唤醒误触发 0.25/0.4 档必须 0。

## 12. 双 Agent 异步模型（harden-dual-agent-async：细节加固，非架构重做）

> 本节记录**当前实现的事实模型**（2026-08-16 验证态）：主 Agent 快速响应与控制任务 Agent、任务单槽 FIFO 独立运行、完成后直报用户并异步归档。本批次只收口异步细节竞态，未改功能主体、队列策略与产品语义。

### 12.1 两链路时序（独立并行）

```
主链路（用户 ↔ 主 Agent）：
  用户消息 → chat() → 主会话 streaming → message.delta/complete → 气泡+播报
  ├─ 主 turn 忙碌时本地 pendingChatQueue（≤5，FIFO）排队，complete 后 flush
  └─ 服务端竞态 busy → queued 直入服务端队列（R3：同样登记 turn tracker，身份保序）
任务链路（主 Agent 控制 ↔ 任务 Agent，单槽 FIFO）：
  派发（<task> 标记 / 本地触发词 / 强制派发）→ reserveTaskSlot（starting 生命周期+token）
  → ensureTaskSession（常驻会话，创建竞争等待 ≤3s×2）→ submit → activeTask（看门狗武装）
  → 任务 turn 独立 streaming → complete → 直报（spoken 播报 + formal 气泡）→ 归档回填主会话
  └─ 新任务排队 pendingTasks（≤5）；出队即登记 starting（无盲区）；完成后 startNextQueuedTask
两链并行：主 Agent 回复不等待任务完成；任务运行不阻塞用户对话（播报低优队列+tag 抢占）
```

### 12.2 控制权矩阵（三分控制）

| 指令 | 主 Agent | 任务 Agent（activeTask+队列） | 反馈 |
|---|---|---|---|
| 中断任务/停止任务/取消任务/停一下（菜单同义） | 不动 | 停 activeTask + 清 pendingTasks + 取消播报/看门狗（常驻会话保留） | 已停止 / 当前没有运行的任务 / 已本地停止但远端未确认 / 启动中已取消 |
| 停止回答 | 停当前回复：关 mainTurnActive、清 buffer、消费在途 tracker、迟到 complete/error 抑制、flush 聊天队列 | 不动 | 已停止回答 / 主 Agent 当前没有在回答 / 失败 |
| 全部停止 | 同停止回答 | 同中断任务 | 两侧独立结果如实拼接（任一侧 inactive 不伪报） |

### 12.3 状态/队列不变量（七项）

1. **单任务槽**：任何时刻至多一个合法 starting/running 任务；`taskSlotPhase(occupied,hasActive,hasStarting)` 唯一判定相位（free/running/starting/ghost）。
2. **无盲区启动**：reserveTaskSlot 与出队（startNextQueuedTask）都立即登记 `StartingTask(token)`；starting→active 转换与中断分支在同一 `taskLifecycleLock` 内互斥，token 校验（`startTransitionShouldProceed`）保证至多一个 runTaskNow 转换成功、迟到创建被拦截。
3. **幽灵自愈**：occupied=true 且无 active/starting（ghost）→ 新派发直接自愈启动（不误排队），中断时自愈释放+清队列。
4. **取消意图优先**：interruptTask 本地收口不依赖远端 RPC（失败 → stoppedUnconfirmed 如实提示）；activeTask/pendingTasks/槽/看门狗/播报/未提交归档有界清理；迟到事件由 activeTask 清空 + 3s 失败抑制 + token 失效三重拦截。
5. **主 tracker FIFO**：每次成功提交（含服务端 queued）都按提交顺序登记 turn kind（user/backfill）；complete 时按序消费——归档 `.backfill` 身份全程保持，迟到 `<ok/>` 不展示不播报，不污染后续用户 turn。
6. **主/任务队列独立**：pendingChatQueue（≤5）与 pendingTasks（≤5）各自 FIFO；归档回填不占任务槽、不阻塞主回复；任务启动失败/看门狗收口后继续队列。
7. **状态收口幂等**：任务完成/失败/中断/看门狗/接管失效各自独立收口（activeTask 清空 + 记录标记 + startNextQueuedTask）；迟到 complete/error 不再驱动状态。

### 12.4 事件归属与缺 sid 消歧（R4）

- 带 sid 事件按会话精确归属（主/任务）；迟到事件由 `turnClosed`/`isComplete`/`activeTask` 清空拦截。
- 缺 sid complete 按**显式在途证据**消歧（`nilSidCompleteBelongsToTask` 纯函数）：主 turn 活跃 / 主 tracker 在途（含服务端 queued 记录）/ 主侧刚完成窗口（3s，`lastMainCompleteAt`）任一为真 → 归主；仅任务 turn 未关且主侧无在途证据 → 归任务。主侧刚完成窗口内到达的缺 sid complete 视为主侧迟到/重复而忽略（不重发、不误关任务 turn；窗口为有界启发，真实缺 sid 任务 complete 由此被忽略时由 600s 看门狗兜底可见收口）。
- 任务工具事件只允许可归属活跃生命周期驱动 run；主 turn 关闭后的迟到 tool 事件不恢复 run。

### 12.5 归档回填（R3）

- 任务完成/失败 → formal 全文（或失败原因）写回主会话存档；防抖 5s 合并、失败仅日志不重试。
- 提交点统一：`chat`/`flushChatQueue`/`applyPersonaChange`/`archiveTaskResult` 在成功提交（含服务端 queued）后立即登记 tracker（.backfill/.user）——服务端 queued 的归档在服务端 FIFO 中位于在途用户 turn 之后，客户端 tracker 同序消费，`<ok/>` 永远按归档轮处理。
- 主会话忙（4009）→ 归档入 pendingChatQueue（带 .backfill 身份），flush 链接管。

### 12.6 超时/重连边界

| 边界 | 机制 |
|---|---|
| 任务会话创建竞争 | ensureTaskSession 轮询等待显式 ≤3s×2（50ms 间隔），不依赖无限 while；createSession RPC 本身保持 HermesClient 30s 超时（不误杀健康冷启动） |
| 任务失联 | 600s 零事件看门狗 → 可见失败收口 + 释放槽 + 继续队列（任何任务事件重排） |
| serve 重启 | 传输失效 → ServeManager 重启（防抖 60s/防风暴 1h×3，任务运行中避让）；重连成功 → resume 主会话（清 buffer/重置 tracker 残留）+ 任务会话恢复或按失败收口 |
| 主中断迟到事件 | mainTurnSuppressed 抑制 complete/error；下一 message.start 解除 |
| 打断后失败抑制 | 3s 窗口内同任务迟到 error 不播报失败 |

### 12.7 离线验证矩阵

| 自测入口 | 覆盖 |
|---|---|
| --self-test-router 60/60 | 三分控制触发词/误伤反例/既有 52 条 |
| --self-test-markers 39/39 | 标记解析 + 无主会话派发可见收口 + task-slot 16 项（幽灵相位/token/中断分支/取消失败本地收口）+ dual-agent 17 项（R1 组合/R3 tracker FIFO/R4 消歧真值表） |
| state-sync 19/19（同入口） | 忙态 guard/工具事件归属/缺 sid 主侧收口/S5 主中断抑制 |
| --self-test-wake 17/17 | 唤醒四态热生效 + 配置变化重建决策（零音频触碰） |
| --self-test-vad 8/8 + segmenter 23/23 | 静音分段/三途径合并语义 |
| --self-test-asr-seg 10/10 | 分段状态机回归 |
| --self-test-tts 5/5 / history-storage | 分句/历史隔离 |

> 无法离线覆盖（真实网络/硬件）：启动窗口真实 RPC 并发时序、服务端 queued 的真实事件流（R3 四提交点）、缺 sid 完整事件链（R4 启发窗口）、真实 session.interrupt、蓝牙设备切换、600s 看门狗到期。均未建大型 mock；决策逻辑已由纯函数离线覆盖。
