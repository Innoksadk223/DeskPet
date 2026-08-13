# DeskPet — macOS 桌面桌宠（月薪猫 🐱）

macOS 菜单栏桌宠：本地语音唤醒（「猫猫」）→ 听写 → **Hermes 双 Agent** 对话/任务 → TTS 播报（Edge/豆包/系统）。Swift/AppKit 纯代码，无第三方依赖。

- **双 Agent**：主 Agent 对话 + `<task>` 协议派发任务给任务 Agent（文件/终端/搜索全工具）
- **语音闭环**：本地 KWS 唤醒 / 持续聆听（TTS 回声闸门 + 静默过滤）/ 播报串行化 + 说话即打断
- **双轨输出**：`<spoken>` 口语概要（朗读，约正式内容 1/5~1/10）`<formal>` 完整正文（气泡，可展开）
- **自愈体系**：Hermes serve 自动启停/重启（防抖/防风暴/健康检查），断线自动恢复

## 快速开始

```bash
# 源码构建运行（推荐）
cd DeskPet
./build-app.sh && open DeskPet.app     # 打包运行（首次授权麦克风/语音识别）

# 开发模式
swift run DeskPet

# 重新打包 DMG（产物 DeskPet-<版本>.dmg，不含任何 key）
./build-dmg.sh [版本号]
```

## 文档导航

| 文档 | 内容 |
|------|------|
| `ARCHITECTURE.md` | **架构与机制全貌**（AI 接手必读）：三层结构、双轨协议、播报机制、修复决策、排查指南 |
| `DeskPet/README.md` | 详细文档：功能总览、配置说明、协作协议、开发自测、日志排查 |
| `DeskPet/指令手册.md` | 用户指令手册 |

## 安全

- Key 只存本机 `DeskPet/history/config/`（已 gitignore，不入库）
- 打包（.app/DMG）强制剥离敏感字段——分发产物零 key

## 许可

私有仓库（作者：Innoksadk223）。
