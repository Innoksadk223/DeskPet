# DeskPet — macOS 桌面桌宠（月薪猫 🐱）

macOS 桌面漂浮桌宠（Swift/AppKit 纯代码，无 storyboard/xib）。后台驱动 **Hermes 双 Agent**：
主 Agent 快速对话 + 任务派发协作协议；任务 Agent 后台执行（文件/终端/搜索全工具）。
语音三件套：唤醒词（本地 sherpa KWS）+ 持续聆听 + 语音播报（Edge/豆包/系统）+ 听写识别（本地/豆包流式）。

> **📘 交接指引（AI 接手必读）**：完整架构与机制见项目根 `ARCHITECTURE.md`（双轨协议/播报串行化/修复决策/排查指南）。
>
> **🚫 铁律（不可违背）**：
> - **Hermes 本体与 serve（`~/.hermes/hermes-agent/`）绝不修改**——桌宠只做客户端适配
> - 分发 .app/DMG 不含任何 key（build-app.sh 强制剥离；本地 key 仅存 history/config/ 600 权限）
> - `history/config/` 清理绝不碰；`history/data/` 可清理
> - 每次改动：自测基准全绿闸门 + 可回滚备份；敏感操作先确认

## 功能总览

- **桌宠动画**：7 状态帧动画（idle/wave/run/failed/review/jump/waiting），7 形象，透明置顶不抢焦点、可拖拽
- **双 Agent 对话/任务**：主会话闲聊 + `<task>` 协议派发任务给任务 Agent，进度/调整/取消全程协作，完成回填口语报告
- **语音播报**：Edge（默认）/ 豆包 TTS（seed-tts-2.0）/ 系统语音，播报方式单选（当前生效一个），失败自动降级 + ⚠️ 可见提示
- **听写识别**：本地 Apple 听写 / 豆包流式 ASR（云端更准）；豆包路径 VAD 静默跳过省额度
- **唤醒词**：本地 sherpa 中文 KWS（默认「嘿猫猫」），灵敏度三档，归一化 + 心跳自愈 + 定期 reset
- **持续聆听**：免唤醒直接对话，说话即打断播报；退出词退出（默认「晚安」，可多词）
- **会话管理**：主会话常驻 + 历史归档（上限 50）+ 任务会话（LRU 20）；删除级联、清空确认
- **菜单区块化**：右键/菜单栏一致分组——对话 / 会话 / 历史 / 偏好 / 设置 / 系统

## 快速开始

```bash
# 方式一：DMG 安装（分发/更新）
open DeskPet-<版本>.dmg        # 双击 → 拖 DeskPet.app 到 Applications；未验证提示时右键→打开

# 方式二：源码构建运行
cd ~/Downloads/项目-助手/DeskPet
双击「启动桌宠.command」          # 推荐：增量构建 → 组装 DeskPet.app → 启动（首次授权麦克风/语音识别）
# 或手动：
./build-app.sh && open DeskPet.app   # 打包运行（语音权限依赖 bundle）
swift run DeskPet                    # 开发模式
```

重新打包 DMG：`../build-dmg.sh [版本号]`（项目根，默认 0.3.0，产物 DeskPet-<版本>.dmg）。

## 工程结构

```
DeskPet/
├── Package.swift                  # SwiftPM 可执行目标（macOS 11+）
├── Sources/DeskPet/
│   ├── main.swift                 # 入口：单实例锁（history/data/deskpet.lock）+ Edit 菜单注入 + 自测分发
│   ├── AppDelegate.swift          # 组装：窗口/菜单/桥接/会话/设置动作
│   ├── HermesBridge.swift         # 双 Agent 桥接：会话管理 + 双轨输出 + 任务协作协议（标记解析）
│   ├── HermesClient.swift         # Hermes WebSocket JSON-RPC 客户端
│   ├── CommandRouter.swift        # 触发词路由（36 条规则，history/config/commands.json）
│   ├── ListeningCoordinator.swift # 持续聆听 + 退出词拦截
│   ├── WakeController.swift       # 本地 sherpa 唤醒（归一化/心跳自愈/定期 reset）
│   ├── SpeechOutputManager.swift  # 播报链（Edge→系统→豆包→…），单选当前生效
│   ├── EdgeTTSProvider.swift      # Edge 语音（复用 Hermes venv edge-tts；缓存 history/data/tts-cache/）
│   ├── DuoyunSpeechProvider.swift # 豆包 TTS（seed-tts-2.0；Base URL + Key 可配）
│   ├── SpeechInputController.swift# 听写（本地 SFSpeech / 豆包流式 + ASRVAD 静默跳过）
│   ├── DuoyunASRProvider.swift    # 豆包 ASR 客户端（帧协议/gzip/重连；asrURL/asrApiKey 可配）
│   ├── DeskPetConfig.swift        # 配置读写（history/config/deskpet-config.json；Codable 兼容迁移）
│   ├── SessionIndex.swift         # 会话索引（history/data/session-index.json）
│   ├── TranscriptStore.swift      # 转录落档 + 定期清理（history/data/transcripts-*.jsonl）
│   ├── SettingsMenuFactory.swift  # 设置子菜单公共工厂（右键/菜单栏共用）
│   └── …（PetView/PetPanel/PetSprite/PetSpec/BubblePanel/HistoryPanel/AboutPanel/InputPanel/StatusItem 等）
├── config/                        # 出厂兜底（首次运行迁移到 history/config/；bundle 打包副本兜底）
├── Pets/<id>/                     # 素材（pet.json + spritesheet.webp）
├── history/                       # 运行数据（分目录，随项目可移植）
│   ├── config/                    # 配置：deskpet-config.json / personas.json / commands.json / voice-services.json / prompts/voice.json
│   └── data/                      # 数据/临时：session-index.json / transcripts-*.jsonl / tts-cache/ / deskpet.lock / *.bak
├── build-app.sh                   # 打包（含敏感字段强制剥离）
├── 启动桌宠.command                # 双击启动器（构建+启动）
└── README.md / 指令手册.md
```

项目根：`build-dmg.sh`（DMG 打包）+ `ARCHITECTURE.md`（架构与机制交接）+ `HANDOFF.md`（历史交接，已弃用）

## 配置说明（history/config/）

| 文件 | 内容 | 修改方式 |
|------|------|---------|
| `deskpet-config.json` | 全部设置（见下表） | 设置菜单（推荐）或直接编辑 |
| `personas.json` | 人设（2 个：月薪猫/卖萌小可爱） | 设置 ▸ 人设 ▸ 直接编辑人设文件… |
| `commands.json` | 触发词规则（36 条） | 直接编辑（重启生效） |
| `voice-services.json` | 语音服务清单（删除服务入口） | 设置 ▸ 语音服务管理… |
| `prompts/voice.json` | 语音交互提示词（输入侧宽容理解 / 输出侧口语播报轨） | 设置 ▸ 人设 ▸ 高级：直接编辑语音提示词文件… |

`deskpet-config.json` 关键字段：

| 字段 | 说明 |
|------|------|
| `petID` | 当前人设 id（形象=外观在人设菜单旁独立选择） |
| `wakePhrase` / `wakeThreshold` | 唤醒词 / 灵敏度（0.15/0.25/0.4） |
| `listenMode` / `listenExitPhrases` / `listenSilenceTimeout` | 持续聆听 / 退出词（多词，逗号分隔）/ 静默分段时长 |
| `edgeVoice` | Edge 音色（默认晓晓；9 个实测可用） |
| `duoyunApiKey` / `duoyunBaseURL` / `duoyunVoiceType` / `duoyunResourceId` | 豆包 TTS Key/自定义端点/音色/资源 |
| `asrProvider` / `asrApiKey` / `asrURL` | 识别来源（local/duoyun）/ 识别 Key（空=复用语音 Key）/ 识别端点（空=默认豆包 plan 端点） |
| `transcriptRetentionDays` | 转录保留天数（默认 7） |

> 配置优先级：history/config/ 优先（持久化写入点）→ bundle/项目 config/ 出厂兜底。首启自动迁移（已存在不覆盖）。

## 双 Agent 协作协议（内部标记，用户无感）

| 标记 | 含义 |
|------|------|
| `<task>…` | 主 Agent 派发任务 → 任务 Agent 执行 |
| `<task_status/>` | 查询任务进度（写回主会话） |
| `<task_steer>…` | 任务执行中追加调整 |
| `<task_cancel/>` | 取消任务 |

任务完成 → 任务 Agent 回填主 Agent → 口语化报告（气泡 + 播报）。router 触发词（「执行任务：…」「任务：…」等）直接派发不经过 LLM。

## 安全说明

- **key 只存本机**：豆包 TTS/ASR Key 仅存在于 `history/config/deskpet-config.json`（本机文件，仅当前用户可读）
- **打包强制剥离**：`build-app.sh` 拷贝 config 进 bundle 前强制清空敏感字段（duoyunApiKey/asrApiKey + 字段名 key/token/secret 模式兜底）——**分发 .app / DeskPet.dmg 永不携带 key**
- 源 `config/` 与 bundle 兜底副本默认均为空 key

## 开发自测

```bash
swift build
.build/debug/DeskPet --self-test-router      # 触发词路由 41/41
.build/debug/DeskPet --self-test-tts         # 分句 5/5
.build/debug/DeskPet --self-test-edge        # Edge 合成+缓存 4/4
.build/debug/DeskPet --self-test-transcript  # 转录落档 5/5
.build/debug/DeskPet --self-test-markers     # 双轨标记协议 17/17
.build/debug/DeskPet --self-test-vad         # ASR VAD 8/8
.build/debug/DeskPet --self-test-duoyun-asr <16k-wav>   # 豆包 ASR 全链路（需配 key）
.build/debug/DeskPet --self-test-duoyun      # 豆包 TTS
.build/debug/DeskPet --self-test-speech      # 语音权限
HERMES_DASHBOARD_SESSION_TOKEN=<token> .build/debug/DeskPet --self-test-hermes   # Hermes 客户端
HERMES_DASHBOARD_SESSION_TOKEN=<token> .build/debug/DeskPet --self-test-bridge   # 转发层
```

## 日志与排查

- 日志：`~/Library/Logs/DeskPet/deskpet.log`（NSLog + 文件双写，5MB 轮转保留 2 份）
- 事件链路：`[EVT] message.delta/complete sid=… text=…`（DEBUG 级，主回复/任务事件排查）
- serve 输出：`[serve]` 前缀（serve 端错误落盘，不再丢弃）
- serve 侧模型调用：`~/.hermes/logs/agent.log`（含 response_len/tool 调用）
- 唤醒/识别/播报/桥接各环节失败均有日志 + 气泡 ⚠️ 提示（不静默）
- serve 重启后桌宠自动重连；服务不可用有可见提示

## 状态与已知问题（2026-08-13）

- 版本 0.3.0；形象 8 个；人设 3 条；唤醒词「猫猫」阈值 0.15；ASR 豆包流式；豆包声线 Vivi（seed-tts-2.0）
- 主 Agent 双轨协议（spoken 口语概要 1/5~1/10 + formal 完整正文）——模型不遵守时有全文兜底
- 持续聆听默认关闭（P0 已修复：静默不误提交 / TTS 回声闸门 / 退出不重启）；阈值 2 字/0.5 置信待实机校准
- F1 外部阻塞：Hermes config.yaml 注入 reasoning_effort: max，部分渠道（函数工具+reasoning_effort）400——需 Hermes 配置侧处理（用户已确认暂不改）
- 待办：真人语音复核唤醒链路 / B4 检测器 CPU 优化 / U13-U15 UX P2 项 / 日志轮转实机验证

## 常见坑（血泪教训）

- serve 重启丢会话（4007 重建是**设计**）；create/resume 超时 ≠ 传输失效（勿加回自愈触发）
- readabilityHandler 必须 EOF 取消注册（防烧核）；serve 输出管道必须有读者
- build-app.sh 会剥离 key（别在打包后查 key）
- 终端跑 Swift WS 探针需 `env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY`（否则走 7890 代理连本地 WS 失败）
- 用户要求一切以当前对话优先——改动前确认，敏感操作先问
