import Foundation

/// 精灵几何与状态映射。
/// MUST 与 Hermes `~/.hermes/hermes-agent/agent/pet/constants.py` 保持一致；
/// 修改规格时必须同步两边（行序、别名、几何禁止臆测）。
enum PetSpec {
    /// 帧几何（像素）—— constants.py FRAME_W / FRAME_H
    static let frameW = 192
    static let frameH = 208
    /// 旧版 8 行 atlas 的兼容帧数——constants.py FRAMES_PER_STATE
    static let framesPerState = 6
    /// 单个状态完整循环时长（毫秒）—— constants.py LOOP_MS
    static let loopMS: Double = 1100
    /// 默认显示缩放—— constants.py DEFAULT_SCALE
    static let defaultScale: Double = 0.33

    /// 标准 8 列 × 9 行 atlas 行序（top → bottom）—— constants.py CODEX_STATE_ROWS
    static let codexStateRows = [
        "idle", "running-right", "running-left", "waving", "jumping",
        "failed", "waiting", "running", "review",
    ]
    /// 旧版 8 行 atlas 行序（top → bottom）——constants.py LEGACY_STATE_ROWS
    static let legacyStateRows = [
        "idle", "wave", "run", "failed", "review", "jump", "extra1", "extra2",
    ]

    /// constants.py `state_rows_for_grid`：行数 ≥ 9 用 Codex，否则 Legacy。
    static func rows(forRowCount rowCount: Int) -> [String] {
        rowCount >= codexStateRows.count ? codexStateRows : legacyStateRows
    }

    /// 根据状态与 atlas 形状决定实际裁剪帧数。
    /// 新版按标准行帧数，旧版（包括方向状态回退到 run 行）统一兼容 6 帧；
    /// 列数不足时由此处截到素材实际可用范围。
    static func frameCount(for state: PetState, columns: Int, rowCount: Int) -> Int {
        guard columns > 0, rowCount > 0 else { return 0 }
        let requested = rowCount >= codexStateRows.count ? state.standardFrameCount : framesPerState
        return min(columns, requested)
    }
}

/// 活动状态：7 个 Hermes 业务态 + 2 个可显式切换的 atlas 方向态。
/// allCases 按标准 9 行素材顺序排列；事件状态机仍只发出原 7 个业务态。
enum PetState: String, CaseIterable {
    case idle = "idle"
    case runningRight = "running-right"
    case runningLeft = "running-left"
    case wave
    case jump
    case failed
    case waiting
    case run
    case review

    /// 标准 9 行 atlas 中该状态的帧数。
    var standardFrameCount: Int {
        switch self {
        case .idle, .waiting, .run, .review: return 6
        case .runningRight, .runningLeft, .failed: return 8
        case .wave: return 4
        case .jump: return 5
        }
    }

    var displayName: String {
        switch self {
        case .idle: return "空闲"
        case .runningRight: return "向右奔跑"
        case .runningLeft: return "向左奔跑"
        case .wave: return "挥手"
        case .jump: return "跳跃"
        case .failed: return "失败"
        case .waiting: return "等待"
        case .run: return "奔跑"
        case .review: return "审查"
        }
    }

    /// 行名别名（降序偏好）——新版方向行优先，旧版方向态回退到 run/running 行。
    var aliases: [String] {
        switch self {
        case .idle: return ["idle"]
        case .runningRight: return ["running-right", "run", "running"]
        case .runningLeft: return ["running-left", "run", "running"]
        case .wave: return ["wave", "waving"]
        case .jump: return ["jump", "jumping"]
        case .failed: return ["failed"]
        case .waiting: return ["waiting"]
        case .run: return ["run", "running"]
        case .review: return ["review"]
        }
    }

    /// 复刻 constants.py `state_row_index`：按别名在行表中查找，
    /// 未命中回退到 idle 行（0）。方向状态在 legacy atlas 中因此命中 run 行，
    /// 而不是错误取 idle；extra1/extra2 仍只是未定义占位行。
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
