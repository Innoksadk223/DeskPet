# DeskPet 架构与机制（AI 交接文档）

> 更新时间：2026-08-13（含 UX 修复轮 + P0 语音闭环 + 主回复兜底 + 双轨协议 + 播报串行化）
> 本文件是 AI 接手本项目的首要阅读文档：先读本文件 → 再读 HANDOFF.md（铁律/历史/排查）。
> 配套人工可读版：`.pi/artifacts/deskpet.html`

## 0. 项目速览

- macOS 菜单栏桌宠（SwiftPM，无 Xcode 方案），`swift build` + `./build-app.sh` 打包
- 大脑 = Hermes serve（`~/.hermes/hermes-agent/venv/bin/hermes serve`），**本体不可改**，DeskPet 只做客户端适配
- serve 端口：9119（用户原服务）被占时自启 9120/9121；token 持久化在 UserDefaults（`DeskPetServeToken`，.app 版域为 `com.deskpet.app`，debug 版域为 `DeskPet`）
- 日志：`~/Library/Logs/DeskPet/deskpet.log`（5MB 轮转保留 2 份）；serve 端日志 `~/.hermes/logs/agent.log`
- 会话索引：`~/Library/Application Support/DeskPet/`（.app 版）；项目 `history/data/`（debug 版）

## 1. 三层架构与文件映射

```
① 语音层                      ② AI Agent 层                 ③ 展示/交互层
WakeController.swift          HermesClient.swift             PetView.swift（动画/右键菜单）
SpeechInputController.swift   HermesBridge.swift（核心）      BubblePanel.swift（气泡）
DuoyunASRProvider.swift       ServeManager.swift             StatusItemController.swift（菜单栏）
SpeechOutputManager.swift     SessionIndex.swift             SettingsMenuFactory.swift
DuoyunSpeechProvider.swift    CommandRouter.swift            InputPanelController.swift
EdgeTTSProvider.swift         AppDelegate.swift（胶水层）      DeskPetConfig.swift
```

- **AppDelegate** 是胶水：接线 ①↔②↔③，`showBubble`/`feedback` 是唯一气泡/反馈入口，NSWindow 操作主线程收口
- **HermesBridge** 是核心：状态机（idle/waiting/run/review/failed）、事件处理、双轨解析、任务标记协议、回填

## 2. 对话主流程

```
用户说话 → 唤醒词(本地KWS) → 听写(ASR+静默2s分段) → routeUserInput
  ├─ 指令路由(CommandRouter)：本地命令直接执行
  └─ 主会话：personaPrefixed(人设+双轨协议注入) → prompt.submit
     → Hermes 主 Agent 回复
     → message.delta 流式 → mainBuffer
     → message.complete → （delta 缺失时用 complete.payload.text 兜底）
     → 主回复解析（见 §3）→ 气泡(showBubble) + 播报(speak)
```

## 3. 双轨协议（核心机制，2026-08-13 确立）

**注入**（`HermesBridge.personaPrefixed`，每条用户消息前缀，回填/状态写回不注入）：

```
[输出格式] 回复必须使用双轨格式：
<spoken>口语概要（约为 <formal> 正式内容长度的 1/5 到 1/10，将被全文朗读）</spoken>
<formal>完整详细回复（含全部细节，气泡展示）</formal>
```

**解析**（`HermesBridge.parseDualTrack`）：
1. 提取 `<spoken>…</spoken>` 与 `<formal>…</formal>`
2. 有 spoken → `(spoken, formal)`；仅 formal → `(spoken, formal)`
3. **都空（主 Agent 不遵守协议）→ 全文兜底 `(全文, 全文)`**——有回复必播报必显示，不丢

**消费**（`AppDelegate.onMainMessage`）：
- 气泡：**formal 优先**（折叠 2 行 + 点击展开滚动阅读；长气泡截断文案「…（点击展开，共 N 字）」）
- 播报：**只念 spoken，formal 绝不生成语音**（历史：曾兜底念 formal，已移除）；spoken>200 字才截断（"更多内容请看气泡"）
- 空回复：不弹气泡不播报；用户轮给「刚才那句我没接住，再说一遍？」

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

## 6. 任务协作流程

```
主 Agent 回复含 <task>…</task> 标记 → parseTaskMarkers 剥离 → startTask
→ 常驻任务会话（种子注入一次，跨任务复用，上下文是特性）
→ 任务 Agent 执行（工具/搜索/终端）
→ 任务消息（自带 spoken/formal）→ scheduleTaskCompletion（complete + 1.5s 静默窗口）
→ 空结果按失败处理（不报"任务完成"）→ 回填主会话 → 口语化报告（低优播报）
```

- 标记协议：`<task>`（派发）/ `<task_steer>`（追加指令）/ `<task_status>`（状态查询）/ `<task_cancel>`（取消）
- 打断：`interruptTask() -> Bool`——无运行任务返回 false（空闲菜单置灰）
- 打断后：明确「任务已停止，不会再有结果了」，精确取消未提交回填

## 7. serve 生命周期与自愈

- 复用"自己的"serve（token 握手通过）→ 否则自启（9119→9120→9121）
- 自愈触发：未连接 / 发送失败 / 接收中断 / 健康检查失败；**RPC 超时不再直接触发**（假超时已修——仅 pending 判超时）
- 防抖 60s / 防风暴 1h 最多 3 次
- serve 重启丢会话（4007）→ resume 失败自动重建；`handleServeReconnected` resume 钩子防断链死循环
- 手动重连成功 → 「✅ 已重新连接助手服务」（仅手动路径，冷启动不打扰）

## 8. 关键修复决策记录（2026-08-13 批次）

| 问题 | 根因 | 修复 |
|---|---|---|
| 自愈锁死烧额度 | RPC 成功返回后遗留超时定时器制造假超时 | 仅 pending 判超时；RPC 超时≠传输失效 |
| 空结果任务报"完成" | 完成判定不检查结果空 | 空结果按失败处理 |
| 空闲误报"已打断" | interruptTask 无条件成功 | 返回 Bool + 菜单置灰 |
| 主回复永远空 | ①serve 对 resume 会话的 delta 偶发不到达 ②主 Agent 不输出双轨标记 | ①complete.text 兜底 ②parseDualTrack 全文兜底 + 人设双轨协议 |
| 播报交叉/乱序 | 多句并发合成完成顺序乱 | 逐句串行 + 打断清干净 |
| 播报念 formal | spoken<30 字兜底念 formal | 只念 spoken，formal 不生成语音 |
| 历史无反馈 | 两级嵌套菜单静默路径 | 条目直连打开面板 + 15s 超时 |
| 长气泡不可展开 | 展开态无滚动 | 滚动阅读 + 截断提示 + 首击豁免 |
| 气泡不消失 | 展开态豁免 + 长留无超时 | 三档限时：反馈 2s / 过渡 4s / 阅读+错误 5s |
| 唤醒状态不一致 | 冷启动/重连竞态 | 状态变化直接驱动菜单刷新（三态文案） |
| serve 错误不可见 | B5 输出丢弃 | serve 输出落盘（[serve] 前缀） |
| 事件链路不可见 | 无事件日志 | [EVT] type/sid/text（DEBUG 级） |

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
- P2 体验项：本地设置触发云 TTS、开始新对话无确认、形象与性格联动不透明、声线列表重复、冷启动无就绪反馈、AX 状态不可靠、空输入可发送——未处理

## 11. 构建与验证命令

```bash
cd DeskPet
swiftc -parse Sources/DeskPet/<file>.swift     # 单文件语法检查
swift build                                     # debug 构建
./build-app.sh                                  # 打包 DeskPet.app（剥离敏感字段）
swift run DeskPet --self-test-tts               # 播报分句自测 5/5
swift run DeskPet --self-test-router            # 指令路由 41/41
swift run DeskPet --self-test-markers           # 标记协议 17/17
swift run DeskPet --self-test-vad               # 静音分段 8/8
swift run DeskPet --self-test-edge              # Edge 合成+缓存 4/4
swift run DeskPet --self-test-transcript        # 转录落档 5/5
```

**验收指标**（deskpet-hv）：丢弃告警 10min ≤2 条 + 30min 归零；桌宠 CPU 待机 ≤1%（当前 0.2-0.4%）；内存 2h 不增长；serve 自愈 kill → ≤30s 恢复 + 对话提交成功；唤醒误触发 0.25/0.4 档必须 0。
