# DeskPet 开发者文档

macOS 桌面漂浮桌宠（Swift/AppKit 纯代码，无 storyboard/xib）。后台驱动 **Hermes 双 Agent**：主 Agent 对话 + 任务派发协作协议；任务 Agent 后台执行（文件/终端/搜索全工具）。语音三件套：唤醒词（本地 sherpa KWS）+ 持续聆听 + 语音播报（Edge/豆包/系统）+ 听写识别（本地/豆包流式）。

> **用户文档**（安装/使用/FAQ）见根目录 `README.md` 与 `指令手册.md`；**架构与机制**见项目根 `../ARCHITECTURE.md`。

## 开发环境

```bash
cd ~/Downloads/项目-助手/DeskPet
swift build                     # debug 构建
./build-app.sh                  # 打包 DeskPet.app（含敏感字段强制剥离）
../build-dmg.sh [版本号]        # 打包 DMG（项目根脚本，产物在项目根）
swift run DeskPet               # 开发模式
```

## 工程结构

```
DeskPet/
├── Package.swift                  # SwiftPM 可执行目标（macOS 11+）
├── Sources/DeskPet/
│   ├── main.swift                 # 入口：单实例锁（history/data/deskpet.lock）+ Edit 菜单注入 + 自测分发
│   ├── AppDelegate.swift          # 组装：窗口/菜单/桥接/会话/设置动作（胶水层）
│   ├── HermesBridge.swift         # 双 Agent 桥接：会话管理 + 双轨输出 + 任务协作协议（标记解析）
│   ├── HermesClient.swift         # Hermes WebSocket JSON-RPC 客户端
│   ├── CommandRouter.swift        # 触发词路由（36 条规则，history/config/commands.json）
│   ├── ListeningCoordinator.swift # 持续聆听 + 退出词拦截
│   ├── WakeController.swift       # 本地 sherpa 唤醒（归一化/心跳自愈/定期 reset）
│   ├── SpeechOutputManager.swift  # 播报链（豆包→Edge→系统，串行化 + 优先级 + 说话即打断）
│   ├── EdgeTTSProvider.swift      # Edge 语音（复用 Hermes venv edge-tts；缓存 history/data/tts-cache/）
│   ├── DuoyunSpeechProvider.swift # 豆包 TTS（seed-tts-2.0；Base URL + Key 可配）
│   ├── SpeechInputController.swift# 听写（本地 SFSpeech / 豆包流式 + ASRVAD 静默跳过 + P0 提交闸门）
│   ├── DuoyunASRProvider.swift    # 豆包 ASR 客户端（帧协议/gzip/重连；asrURL/asrApiKey 可配）
│   ├── DeskPetConfig.swift        # 配置读写（history/config/deskpet-config.json；Codable 兼容迁移）
│   ├── SessionIndex.swift         # 会话索引（history/data/session-index.json）
│   ├── TranscriptStore.swift      # 转录落档 + 定期清理（history/data/transcripts-*.jsonl）
│   ├── SettingsMenuFactory.swift  # 设置子菜单公共工厂（右键/菜单栏共用）
│   └── …（PetView/PetPanel/PetSprite/PetSpec/BubblePanel/HistoryPanel/AboutPanel/InputPanel/StatusItem 等）
├── config/                        # 出厂兜底（空 key；首次运行迁移到 history/config/）
├── Pets/<id>/                     # 素材（pet.json + spritesheet.webp）
├── history/                       # 运行数据（不入库）
│   ├── config/                    # 配置：deskpet-config.json / personas.json / commands.json / voice-services.json / prompts/voice.json
│   └── data/                      # 数据/临时：session-index.json / transcripts-*.jsonl / tts-cache/ / deskpet.lock / *.bak
├── build-app.sh                   # 打包（含敏感字段强制剥离）
├── 启动桌宠.command                # 双击启动器（构建+启动）
└── README.md / 指令手册.md
```

## 配置说明（history/config/）

| 文件 | 内容 | 修改方式 |
|------|------|---------|
| `deskpet-config.json` | 全部设置（见下表） | 设置菜单（推荐）或直接编辑 |
| `personas.json` | 人设（月薪猫/卖萌小可爱等） | 设置 ▸ 人设 ▸ 直接编辑人设文件… |
| `commands.json` | 触发词规则（36 条） | 直接编辑（重启生效） |
| `voice-services.json` | 语音服务清单 | 设置 ▸ 语音服务管理… |
| `prompts/voice.json` | 语音交互提示词 | 设置 ▸ 人设 ▸ 高级：直接编辑语音提示词文件… |

`deskpet-config.json` 关键字段：

| 字段 | 说明 |
|------|------|
| `petID` | 当前人设 id（形象=外观独立选择） |
| `wakePhrase` / `wakeThreshold` | 唤醒词 / 灵敏度（0.15/0.25/0.4） |
| `listenMode` / `listenExitPhrases` / `listenSilenceTimeout` | 持续聆听 / 退出词（多词逗号分隔）/ 静默分段时长 |
| `edgeVoice` | Edge 音色（默认晓晓；9 个实测可用） |
| `duoyunApiKey` / `duoyunBaseURL` / `duoyunVoiceType` / `duoyunResourceId` | 豆包 TTS Key/端点/音色/资源 |
| `asrProvider` / `asrApiKey` / `asrURL` | 识别来源（local/duoyun）/ Key（空=复用语音 Key）/ 端点 |
| `transcriptRetentionDays` | 转录保留天数（默认 7） |

> 配置优先级：history/config/（持久化写入点）→ bundle/项目 config/ 出厂兜底。首启自动迁移（已存在不覆盖）。

## 双 Agent 协作协议（内部标记，用户无感）

| 标记 | 含义 |
|------|------|
| `<task>…` | 主 Agent 派发任务 → 任务 Agent 执行 |
| `<task_status/>` | 查询任务进度（写回主会话） |
| `<task_steer>…` | 任务执行中追加调整 |
| `<task_cancel/>` | 取消任务 |

任务完成 → 任务 Agent 回填主 Agent → 口语化报告（气泡 + 播报）。router 触发词（「执行任务：…」等）直接派发不经过 LLM。双轨输出协议（`<spoken>` 口语概要 + `<formal>` 完整正文）详见 `../ARCHITECTURE.md` §3。

## 安全说明

- **key 只存本机**：豆包 TTS/ASR Key 仅存在于 `history/config/deskpet-config.json`（本机文件，仅当前用户可读）
- **打包强制剥离**：`build-app.sh` 拷贝 config 进 bundle 前强制清空敏感字段——**分发 .app / DMG 永不携带 key**
- 源 `config/` 与 bundle 兜底副本默认均为空 key

## 开发自测（每次改动后必跑——硬闸门）

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
- 事件链路：`[EVT] message.delta/complete sid=… text=…`（DEBUG 级）；serve 输出：`[serve]` 前缀
- serve 侧模型调用：`~/.hermes/logs/agent.log`（含 response_len/tool 调用）
- 排查主回复为空：①[EVT] 是否收到 delta/complete ②agent.log 模型是否输出 ③「主回复兜底」日志

## 状态与已知问题（2026-08-13）

- 版本 0.3.0；形象 8 个；人设 3 条；唤醒词「猫猫」阈值 0.15；ASR 豆包流式；豆包声线 Vivi（seed-tts-2.0）
- 主 Agent 双轨协议（spoken 1/5~1/10 + formal）——模型不遵守时有全文兜底
- 持续聆听默认关闭（P0 已修复：静默不误提交 / TTS 回声闸门 / 退出不重启）；阈值 2 字/0.5 置信待实机校准
- F1 外部阻塞：Hermes config.yaml 注入 reasoning_effort: max，部分渠道（函数工具+reasoning_effort）400——需 Hermes 配置侧处理（用户已确认暂不改）
- 待办：真人语音复核唤醒链路 / B4 检测器 CPU 优化 / U13-U15 UX P2 项 / 日志轮转实机验证

## 常见坑（血泪教训）

- serve 重启丢会话（4007 重建是**设计**）；create/resume 超时 ≠ 传输失效（勿加回自愈触发）
- readabilityHandler 必须 EOF 取消注册（防烧核）；serve 输出管道必须有读者
- build-app.sh 会剥离 key（别在打包后查 key）
- 终端跑 Swift WS 探针需 `env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY`（否则走 7890 代理连本地 WS 失败）
- 用户要求一切以当前对话优先——改动前确认，敏感操作先问
