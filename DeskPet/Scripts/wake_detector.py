#!/usr/bin/env python3
"""桌宠本地唤醒检测器（E-W1）：stdin 流式读 16kHz int16 mono PCM，
sherpa-onnx wenetspeech 中文 KWS 检测唤醒词，命中时 stdout 输出一行 JSON。

协议：
- stdin：纯 PCM 二进制（16kHz int16 mono，任意块大小）
- stdout：每命中一次输出 {"event":"detected","phrase":"<唤醒词>"}\n
- 存活心跳：每 5s 输出 {"event":"heartbeat"}\n（唤醒侧据此判定检测器卡死并自动重启）
- 命中后自动 reset 继续检测（暂停检测 = 调用方停止喂 PCM）

心跳/自愈（R2-E7/E9 演进，高压铁证后定稿）：
- 心跳由**独立 daemon 线程**输出（每 5s）——主循环推理慢/卡住不再阻塞心跳，
  桌宠侧不因心跳延迟误判卡死（12:29-12:43 重启循环根因）
- **主循环停滞自杀已移除**（R2-E9 高压铁证：CPU 100% 满时 select 等待中的主循环
  线程被调度饿 30s+（faulthandler 实证卡在 select）→ 停滞误判 → 自杀重启循环）。
  真死锁（decode 卡死占 GIL）→ 心跳线程同样卡死 → 心跳断流 → 桌宠侧 20s 判死
  自动重启兜底（心跳线程高压下实测 5s 稳定——桌宠侧不会误判）
- stdout 写入加锁（心跳线程与主循环 detected 并发写，防行交错）

定期 reset（R2-E8，2026-08-13 用户实测修复）：
- 用户实测：运行几分钟 → stream 长流累积变慢 → 卡死 → 自杀重启循环 → 卡死期唤醒全无效
  （13:34-13:36 日志铁证：丢弃 120s 未消费 → 30s 停滞自杀 → 重启 → 命中短暂恢复 → 再卡死）
- 根因：stream 只在命中时 reset_stream()——长时间无命中时音频持续 accept_waveform 累积
  （zipformer KWS 长流内部状态/缓冲增长 → 推理越来越慢 → 最终卡死）
- 修复：无命中持续 --reset-interval 秒（默认 20s）→ 定期 reset_stream() 清内部状态防累积；
  reset 后唤醒词需重新完整说出（可接受）；命中时同样更新 reset 时间戳
- 保守：num_threads 回 1（2 线程实测可能引入推理问题/更慢——吞吐靠定期 reset 防累积解决）

读限流 keep-latest（R2-E9，高压测试铁证后根治）：
- tester 风暴实测：CPU 高压 → 推理线程被调度饿死（单帧 80ms 音频推理耗时暴增）→ 主循环
  停滞 >30s → 自杀 → 重启循环 → 积压丢弃 2500 块（A 矩阵独立实例同样 ~30s 死亡）
- 修复：主循环 select 就绪后 os.read 读完**全部可用** → 只保留最后 ~1s 音频（32000 字节）
  处理，旧积压丢弃——与桌宠侧 keep-latest 语义一致（丢旧留新，推理负载恒定不追积压）；
  唤醒词在积压段内可能漏——总比卡死完全不可用好（权衡已认可）
- reset 间隔默认 60s → 20s（长流累积窗口收紧）

用法：
  wake_detector.py --model <dir> --keyword <中文唤醒词> [--threshold 0.25] [--reset-interval 20]

依赖：sherpa_onnx + pypinyin（Hermes venv 内已装）。
模型：sherpa-onnx-kws-zipformer-wenetspeech（官方中文 KWS，ppinyin tokenization）。
"""
import argparse
import json
import os
import select
import sys
import threading
import time
import wave
from pathlib import Path

import numpy as np
import sherpa_onnx
from sherpa_onnx import text2token

FRAME = 1280  # 80ms @16kHz（sherpa 推荐 chunk）

# 音量归一化（R-M1，用户反馈「唤醒词不太敏感」——小声/远距离低电平输入检测率低）：
# 逐帧 RMS 增益——低电平放大到目标 RMS（有限幅），静音/正常音量不动。
TARGET_RMS = 0.05    # 目标 RMS（正常说话 0.05-0.3；低于此视为小声 → 增益）
MAX_GAIN = 8.0       # 增益上限（防噪声放大误触发）
SILENCE_RMS = 1e-4   # 静音阈值（低于此不放大——防底噪爆音）


def normalize_gain(seg: np.ndarray) -> np.ndarray:
    """逐帧音量归一化：低电平输入增益放大（小声/远距离可检测）；静音/正常音量原样返回。
    - rms < SILENCE_RMS → 原样（静音帧不放大，防底噪爆音）
    - rms < TARGET_RMS → 增益 min(TARGET_RMS/rms, MAX_GAIN)（上限防噪声放大）
    - rms >= TARGET_RMS → 原样（防失真）
    """
    rms = float(np.sqrt(np.mean(np.square(seg))))
    if rms < SILENCE_RMS or rms >= TARGET_RMS:
        return seg
    gain = min(TARGET_RMS / rms, MAX_GAIN)
    return seg * gain


def self_test_normalize() -> int:
    """归一化自测（--self-test-normalize）：低音量模拟验证（不依赖模型）。"""
    rng = np.random.default_rng(42)
    # 低音量：rms≈0.03（正常语音 ×0.1 水平）→ 应增益到目标 0.05
    low = (rng.standard_normal(FRAME) * 0.03).astype(np.float32)
    out = normalize_gain(low)
    rms_in = float(np.sqrt(np.mean(np.square(low))))
    rms_out = float(np.sqrt(np.mean(np.square(out))))
    assert abs(rms_out - TARGET_RMS) < 0.005, f"低音量增益不达标：{rms_in:.4f} → {rms_out:.4f}（目标 {TARGET_RMS}）"
    print(f"[normalize] 低音量 {rms_in:.4f} → {rms_out:.4f}（增益 {rms_out / rms_in:.1f}x，目标 {TARGET_RMS}）✓")
    # 静音帧不放大（防底噪爆音）
    silent = np.zeros(FRAME, dtype=np.float32)
    assert np.array_equal(normalize_gain(silent), silent), "静音帧被放大"
    print("[normalize] 静音帧不放大 ✓")
    # 正常音量原样（防失真）
    loud = (rng.standard_normal(FRAME) * 0.3).astype(np.float32)
    assert np.array_equal(normalize_gain(loud), loud), "正常音量帧被改动"
    print("[normalize] 正常音量原样 ✓")
    # 增益上限生效（极低电平不超 MAX_GAIN）
    tiny = np.full(FRAME, 0.002, dtype=np.float32)
    out_tiny = normalize_gain(tiny)
    gain = float(out_tiny[0] / 0.002)
    assert gain <= MAX_GAIN + 1e-6, f"增益超上限：{gain:.1f}x"
    print(f"[normalize] 增益上限 {gain:.1f}x ≤ {MAX_GAIN}x ✓")
    return 0

# stdout 线程安全写入锁（心跳线程与主循环 detected 并发写）
STDOUT_LOCK = threading.Lock()


def emit(line: str) -> None:
    """stdout 线程安全写入（心跳线程与主循环 detected 并发——锁防行交错）。"""
    with STDOUT_LOCK:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def heartbeat_loop() -> None:
    """独立心跳线程（daemon）：每 5s 输出 heartbeat——进程存活证明。
    CPU 高压下主循环可能被调度饿（select 等待），心跳线程实测 5s 稳定；
    真死锁（decode 占 GIL 卡死）→ 心跳同样断流 → 桌宠侧 20s 判死自动重启。
    """
    while True:
        time.sleep(5.0)
        emit('{"event":"heartbeat"}')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True, help="模型目录（含 tokens.txt + onnx）")
    ap.add_argument("--keyword", required=True, help="中文唤醒词，如 嘿猫猫")
    ap.add_argument("--threshold", type=float, default=0.25)
    ap.add_argument("--reset-interval", type=float, default=20.0, help="无命中持续多久定期 reset stream（防长流累积卡死）")
    ap.add_argument("--self-test-normalize", action="store_true", help="音量归一化自测（不依赖模型，跑完退出）")
    args = ap.parse_args()

    if args.self_test_normalize:
        return self_test_normalize()

    d = Path(args.model)
    if not (d / "tokens.txt").exists():
        sys.stderr.write(f"wake_detector: 模型缺失 {d}\n")
        return 1

    # 中文唤醒词 → ppinyin token 序列（h ēi m āo m āo）
    toks = text2token([args.keyword], tokens=str(d / "tokens.txt"), tokens_type="ppinyin")
    if not toks or not toks[0]:
        sys.stderr.write(f"wake_detector: 唤醒词编码失败「{args.keyword}」\n")
        return 1
    kw = " ".join(toks[0]) + " @WAKEKEYWORD\n"

    # 非 int8 模型组合（fp32，兼容性最好）
    def pick(pat: str) -> str:
        # E4：显式排除 int8（glob [!8] 挡不住 "int8.onnx" 的 x 字符）
        hits = sorted(p for p in d.glob(pat) if ".int8." not in p.name)
        if not hits:
            raise SystemExit(f"wake_detector: 缺少模型文件 {pat}")
        return str(hits[0])

    # 关键词写临时文件（官方 API：KeywordSpotter 必填 keywords_file）
    import tempfile
    kf = tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False, encoding="utf-8")
    kf.write(kw)
    kf.close()
    # R2-E8：num_threads 回 1（保守——2 线程实测可能引入推理问题/更慢；
    # 长流卡死根因是 stream 状态累积，由定期 reset 解决，不靠多线程）
    kws = sherpa_onnx.KeywordSpotter(
        tokens=str(d / "tokens.txt"),
        encoder=pick("encoder-*[!8].onnx"),
        decoder=pick("decoder-*[!8].onnx"),
        joiner=pick("joiner-*[!8].onnx"),
        keywords_file=kf.name,
        keywords_threshold=args.threshold,
        num_threads=1,
        provider="cpu",
    )
    stream = kws.create_stream()
    sys.stderr.write(f"wake_detector: 就绪，监听「{args.keyword}」（threshold={args.threshold}，reset_interval={args.reset_interval:.0f}s）\n")
    sys.stderr.flush()
    # R2-E9：stdin 非阻塞读（配合 select——读完所有可用后 EAGAIN；keep-latest 截断用）
    os.set_blocking(sys.stdin.fileno(), False)

    # 心跳独立线程（daemon）——主循环推理慢/卡住不阻塞心跳
    threading.Thread(target=heartbeat_loop, daemon=True, name="wake-heartbeat").start()

    buf = b""
    last_reset = time.monotonic()   # R2-E8：定期 reset 时间戳（命中时同样更新）
    dropped_bytes = 0              # R2-E9：keep-latest 丢弃累计（日志节流）
    keep_bytes = 32000             # 保留最后 ~1s 音频（16kHz int16 mono）
    while True:
        # 非阻塞式读（select 1s 超时——保证主循环不被阻塞读卡住）
        rlist, _, _ = select.select([sys.stdin], [], [], 1.0)
        if rlist:
            # R2-E9 keep-latest 读限流（核心）：读完所有可用 → 只保留最后 ~1s 处理，
            # 旧积压丢弃。CPU 高压时推理变慢 → 积压增长；若追着处理会越来越慢直至卡死
            # （tester 风暴铁证：~30s 停滞自杀重启循环）。丢旧留新 → 推理负载恒定，
            # 永远处理最新 1s——唤醒词在积压段内可能漏，但总比卡死完全不可用好。
            while True:
                try:
                    chunk = os.read(sys.stdin.fileno(), 16384)
                except BlockingIOError:
                    break
                if not chunk:  # stdin 关闭 → 退出
                    return 0
                buf += chunk
                if len(buf) > keep_bytes:
                    dropped_bytes += len(buf) - keep_bytes
                    buf = buf[-keep_bytes:]
            if dropped_bytes >= 128000:   # 每累计丢弃 4s 音频打一次日志（节流）
                sys.stderr.write(f"wake_detector: keep-latest 丢弃旧音频 {dropped_bytes // 32000}s（推理跟不上输入，高压场景）\n")
                sys.stderr.flush()
                dropped_bytes = 0
            # 尽量按 FRAME 对齐消费（buf 已被截断为最新 ~1s，处理负载恒定）
            n = (len(buf) // (FRAME * 2)) * FRAME * 2
            if n > 0:
                pcm, buf = buf[:n], buf[n:]
                samples = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
                for i in range(0, len(samples), FRAME):
                    seg = samples[i:i + FRAME]
                    if len(seg) < FRAME:
                        continue
                    # R-M1：逐帧音量归一化——小声/远距离低电平增益放大（静音/正常音量不动）
                    seg = normalize_gain(seg)
                    stream.accept_waveform(16000, seg)
                    while kws.is_ready(stream):
                        kws.decode_stream(stream)
                        r = kws.get_result(stream)
                        if r:
                            emit('{"event":"detected","phrase":"%s"}' % args.keyword)
                            kws.reset_stream(stream)
                            last_reset = time.monotonic()   # 命中：reset 时间戳更新
        # R2-E8：定期 reset——无命中持续 interval 秒 → 重置 stream 清内部状态
        # （zipformer KWS 长流状态/缓冲增长 → 推理越来越慢 → 卡死；reset 后重开，
        # 唤醒词需重新完整说出——可接受；reset 期间音频继续喂）
        now = time.monotonic()
        if now - last_reset >= args.reset_interval:
            kws.reset_stream(stream)
            last_reset = now
            sys.stderr.write(f"wake_detector: 定期 reset（{args.reset_interval:.0f}s 无命中）——清长流状态防累积\n")
            sys.stderr.flush()


if __name__ == "__main__":
    raise SystemExit(main())
