import Foundation

/// 精灵几何与状态映射。
/// MUST 与 Hermes `~/.hermes/hermes-agent/agent/pet/constants.py` 保持一致；
/// 修改规格时必须同步两边（行序、别名、几何禁止臆测）。
enum PetSpec {
    /// 帧几何（像素）—— constants.py FRAME_W / FRAME_H
    static let frameW = 192
    static let frameH = 208
    /// 每个动画状态消耗的帧数—— constants.py FRAMES_PER_STATE
    static let framesPerState = 6
    /// 单个状态完整循环时长（毫秒）—— constants.py LOOP_MS
    static let loopMS: Double = 1100
    /// 默认显示缩放—— constants.py DEFAULT_SCALE
    static let defaultScale: Double = 0.33

    /// 当前 Petdex/Codex 9 行 atlas 行序（top → bottom）—— constants.py CODEX_STATE_ROWS
    static let codexStateRows = [
        "idle", "running-right", "running-left", "waving", "jumping",
        "failed", "waiting", "running", "review",
    ]
    /// 旧版 8 行 atlas 行序（top → bottom）—— constants.py LEGACY_STATE_ROWS
    static let legacyStateRows = [
        "idle", "wave", "run", "failed", "review", "jump", "extra1", "extra2",
    ]

    /// constants.py `state_rows_for_grid`：行数 ≥ 9 用 Codex，否则 Legacy
    static func rows(forRowCount rowCount: Int) -> [String] {
        rowCount >= codexStateRows.count ? codexStateRows : legacyStateRows
    }
}

/// 活动状态。注意：PetState 枚举实为 7 态（constants.py），
/// 菜单/状态机均以此为准；8 行/9 行 atlas 的行映射差异由 rowIndex 消化。
enum PetState: String, CaseIterable {
    case idle
    case wave
    case run
    case failed
    case review
    case jump
    case waiting

    var displayName: String {
        switch self {
        case .idle: return "空闲"
        case .wave: return "挥手"
        case .run: return "奔跑"
        case .failed: return "失败"
        case .review: return "审查"
        case .jump: return "跳跃"
        case .waiting: return "等待"
        }
    }

    /// 行名别名（降序偏好）—— constants.py STATE_ALIASES
    var aliases: [String] {
        switch self {
        case .idle: return ["idle"]
        case .wave: return ["wave", "waving"]
        case .jump: return ["jump", "jumping"]
        case .run: return ["run", "running"]
        case .failed: return ["failed"]
        case .review: return ["review"]
        case .waiting: return ["waiting"]
        }
    }

    /// 复刻 constants.py `state_row_index`：按别名在行表中查找，
    /// 未命中回退到 idle 行（0）。禁止臆测行号。
    func rowIndex(rowCount: Int) -> Int {
        let rows = PetSpec.rows(forRowCount: rowCount)
        for name in aliases {
            if let i = rows.firstIndex(of: name) { return i }
        }
        return 0
    }
}

extension PetState {
    /// 循环顺序的下一状态（菜单与 AppDelegate 共用，消除重复逻辑）
    var next: PetState {
        let all = PetState.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }
}
