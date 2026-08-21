import Foundation

/// Pet atlas 契约离线自测：只验证状态/行/帧数逻辑，不读取图片、不连接 Hermes。
enum PetAtlasSelfTest {
    static func run() -> Int32 {
        var passed = 0
        var failed = 0

        func check(_ name: String, _ ok: Bool) {
            if ok { passed += 1 } else { failed += 1 }
            print("[pet-atlas] \(ok ? "✓" : "✗") \(name)")
        }

        let expectedStates: [PetState] = [
            .idle, .runningRight, .runningLeft, .wave, .jump,
            .failed, .waiting, .run, .review,
        ]
        let expectedRows = [
            "idle", "running-right", "running-left", "waving", "jumping",
            "failed", "waiting", "running", "review",
        ]
        let expectedFrameCounts = [6, 8, 8, 4, 5, 8, 6, 6, 6]

        check("PetState 含 9 个状态", PetState.allCases.count == 9)
        check("PetState.allCases 为标准行序", PetState.allCases == expectedStates)
        check("标准行名为 9 行契约", PetSpec.rows(forRowCount: 9) == expectedRows)
        check("标准方向 raw value 正确",
              PetState.runningRight.rawValue == "running-right"
                && PetState.runningLeft.rawValue == "running-left")

        let standardRows = expectedStates.map { $0.rowIndex(rowCount: 9) }
        check("新版 9 行状态逐行映射", standardRows == Array(0..<9))
        check("新版标准帧数为 6/8/8/4/5/8/6/6/6",
              expectedStates.map { PetSpec.frameCount(for: $0, columns: 8, rowCount: 9) }
                == expectedFrameCounts)
        check("新版帧数受实际列数上限约束",
              PetSpec.frameCount(for: .runningRight, columns: 4, rowCount: 9) == 4)

        let legacyRows = PetSpec.rows(forRowCount: 8)
        let legacyIndices = expectedStates.map { $0.rowIndex(rowCount: 8) }
        let expectedLegacyIndices = [0, 2, 2, 1, 5, 3, 0, 2, 4]
        check("legacy 行表保留 extra1/extra2 占位",
              legacyRows == PetSpec.legacyStateRows
                && Array(legacyRows.suffix(2)) == ["extra1", "extra2"])
        check("legacy 8 行业务/方向映射正确", legacyIndices == expectedLegacyIndices)
        check("legacy 方向态回退到 run 行而非 idle",
              PetState.runningRight.rowIndex(rowCount: 8) == 2
                && PetState.runningLeft.rowIndex(rowCount: 8) == 2
                && PetState.runningRight.rowIndex(rowCount: 8) != 0
                && PetState.runningLeft.rowIndex(rowCount: 8) != 0)
        check("legacy 所有状态均只取兼容 6 帧",
              expectedStates.map { PetSpec.frameCount(for: $0, columns: 8, rowCount: 8) }
                == Array(repeating: 6, count: expectedStates.count))
        check("空 atlas 形状不产生帧", PetSpec.frameCount(for: .idle, columns: 0, rowCount: 0) == 0)

        print("[pet-atlas] 通过 \(passed)/\(passed + failed)")
        return failed == 0 ? 0 : 1
    }
}
