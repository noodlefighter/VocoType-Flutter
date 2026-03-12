#!/usr/bin/env python3
"""音频采集脚本

此脚本被 C++ Addon 通过 subprocess 调用，负责录制音频。

工作流程：
1. C++ Addon 启动此脚本，传入参数
2. 脚本开始录音
3. 脚本输出临时音频文件路径到 stdout
4. C++ Addon 读取路径，将其发送到 Backend 进行识别
"""
from __future__ import annotations

import sys
import argparse
import tempfile
import threading
import logging
import time
from pathlib import Path

import numpy as np
import sounddevice as sd

# 添加项目根目录到 path
PROJECT_ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from app.audio_utils import (
    load_audio_input_config,
    resample_audio,
    resolve_input_device,
    resolve_input_channel,
    SAMPLE_RATE,
)
from app.wave_writer import write_wav

logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')
logger = logging.getLogger(__name__)

MIN_TRANSCRIBE_DURATION_SECONDS = 0.3


class AudioRecorder:
    """音频录制器（可复用）"""

    def __init__(
        self,
        device: int | str | None,
        sample_rate: int,
        input_channel: int = 0,
    ):
        self.device = device
        self.sample_rate = sample_rate
        self.input_channel = max(int(input_channel), 0)
        self.audio_frames: list[np.ndarray] = []
        self.stream: sd.InputStream | None = None
        self.active_sample_rate: int | None = None
        self.active_input_channel: int = 0
        self.active_device: int | str | None = None
        self._state_lock = threading.Lock()
        self._recording = False
        self._record_started_at: float | None = None
        self._first_frame_logged = False

    def matches_config(
        self,
        device: int | str | None,
        sample_rate: int,
        input_channel: int,
    ) -> bool:
        return (
            self.device == device
            and self.sample_rate == sample_rate
            and self.input_channel == max(int(input_channel), 0)
        )

    def _resolve_input_device(self):
        """选择可用的输入设备"""
        return resolve_input_device(sd, self.device)

    def _resolve_input_channel(self, device) -> int:
        try:
            info = sd.query_devices(device if device is not None else None, kind="input")
        except Exception as exc:
            logger.warning("查询设备通道信息失败: %s，回退到通道 1", exc)
            return 0

        max_input_channels = int(info.get("max_input_channels", 0) or 0)
        selected_channel = resolve_input_channel(self.input_channel, max_input_channels)
        if selected_channel != self.input_channel:
            logger.warning(
                "请求的输入通道 %s 超出设备能力（最大 %s），回退到通道 %s",
                self.input_channel + 1,
                max_input_channels,
                selected_channel + 1,
            )
        return selected_channel

    def _resolve_sample_rate(self, device, preferred, input_channel):
        """选择可用采样率"""
        required_channels = input_channel + 1
        if preferred:
            try:
                sd.check_input_settings(
                    device=device,
                    samplerate=preferred,
                    channels=required_channels,
                    dtype="int16",
                )
                return preferred
            except Exception:
                pass

        try:
            info = sd.query_devices(device if device is not None else None, kind="input")
            default_sr = int(info.get("default_samplerate", 0)) if info else 0
            if default_sr:
                sd.check_input_settings(
                    device=device,
                    samplerate=default_sr,
                    channels=required_channels,
                    dtype="int16",
                )
                return default_sr
        except Exception:
            pass

        return preferred or SAMPLE_RATE

    def prepare(self) -> None:
        """预热输入流，避免首轮录音时重新打开设备。"""
        if self.stream is not None and getattr(self.stream, "active", False):
            return
        if self.stream is not None:
            self.cleanup()

        device = self._resolve_input_device()
        input_channel = self._resolve_input_channel(device)
        sample_rate = self._resolve_sample_rate(device, self.sample_rate, input_channel)
        self.active_device = device
        self.active_sample_rate = sample_rate
        self.active_input_channel = input_channel

        logger.info(
            "使用设备: %s, 采样率: %d Hz, 输入通道: %d",
            device,
            sample_rate,
            input_channel + 1,
        )

        block_ms = 20
        block_size = int(sample_rate * block_ms / 1000)

        def audio_callback(indata, frame_count, time_info, status):
            if status:
                logger.warning("音频状态: %s", status)
            with self._state_lock:
                if not self._recording:
                    return
                if indata.ndim > 1:
                    frame = indata[:, self.active_input_channel].copy()
                else:
                    frame = indata.copy().reshape(-1)
                self.audio_frames.append(frame)
                if not self._first_frame_logged and self._record_started_at is not None:
                    startup_ms = (time.perf_counter() - self._record_started_at) * 1000
                    self._first_frame_logged = True
                    logger.info("首帧到达，录音启动延迟: %.1f ms", startup_ms)

        self.stream = sd.InputStream(
            samplerate=sample_rate,
            blocksize=block_size,
            device=device,
            channels=input_channel + 1,
            dtype='int16',
            callback=audio_callback,
        )
        self.stream.start()
        logger.info("音频输入流已预热")

    def start(self) -> None:
        """开始录音（非阻塞）"""
        self.prepare()

        with self._state_lock:
            self.audio_frames.clear()
            self._recording = True
            self._record_started_at = time.perf_counter()
            self._first_frame_logged = False

        logger.info("开始录音...")

    def stop(self) -> Path | None:
        """停止录音并写入临时文件"""
        if self.stream is None or self.active_sample_rate is None:
            return None

        with self._state_lock:
            if not self._recording:
                return None
            self._recording = False
            self._record_started_at = None
            self._first_frame_logged = False
            frames = self.audio_frames
            self.audio_frames = []

        logger.info("录音完成，共 %d 帧", len(frames))

        if not frames:
            logger.error("没有录制到音频数据")
            return None

        sample_rate = self.active_sample_rate
        audio_data = np.concatenate(frames).flatten()
        audio_duration = len(audio_data) / sample_rate
        logger.info("录音时长: %.2f 秒", audio_duration)

        if audio_duration < MIN_TRANSCRIBE_DURATION_SECONDS:
            logger.warning(
                "录音时长过短（< %.1f 秒），可能无法识别",
                MIN_TRANSCRIBE_DURATION_SECONDS,
            )

        audio_16k = resample_audio(audio_data, sample_rate, SAMPLE_RATE)

        temp_file = tempfile.NamedTemporaryFile(suffix='.wav', delete=False)
        temp_path = Path(temp_file.name)
        temp_file.close()

        write_wav(temp_path, audio_16k.tobytes(), SAMPLE_RATE)
        logger.info("已保存到: %s", temp_path)

        return temp_path

    def cleanup(self) -> None:
        """关闭预热中的输入流。"""
        with self._state_lock:
            self._recording = False
            self._record_started_at = None
            self._first_frame_logged = False
            self.audio_frames.clear()

        stream = self.stream
        self.stream = None
        self.active_device = None
        self.active_sample_rate = None
        self.active_input_channel = 0
        if stream is None:
            return

        try:
            stream.stop()
        except Exception:
            pass
        try:
            stream.close()
        except Exception:
            pass

    def record(self, duration: float | None = None) -> Path:
        """录制音频（阻塞）"""
        self.start()

        if duration:
            time.sleep(duration)
        else:
            sys.stdin.read()

        path = self.stop()
        if path is None:
            raise RuntimeError("没有录制到音频数据")
        return path


def main():
    parser = argparse.ArgumentParser(description='VoCoType Audio Recorder')
    parser.add_argument(
        '--loop',
        action='store_true',
        help='Listen for START/STOP commands on stdin'
    )
    parser.add_argument(
        '--duration',
        type=float,
        help='Recording duration in seconds (default: wait for stdin)'
    )
    parser.add_argument(
        '--device',
        type=str,
        help='Audio device name or ID'
    )
    parser.add_argument(
        '--sample-rate',
        type=int,
        default=44100,
        help='Sample rate (default: 44100)'
    )
    parser.add_argument(
        '--input-channel',
        type=int,
        help='Input channel index, zero-based'
    )
    args = parser.parse_args()

    # 加载配置
    configured_device, configured_sr, configured_channel = load_audio_input_config()
    device = args.device if args.device is not None else configured_device
    if isinstance(device, str) and device.isdigit():
        device = int(device)
    sample_rate = args.sample_rate if args.sample_rate != 44100 else configured_sr
    input_channel = configured_channel if args.input_channel is None else args.input_channel

    # 录音
    if args.loop:
        recorder: AudioRecorder | None = None
        try:
            for line in sys.stdin:
                cmd = line.strip().upper()
                if not cmd:
                    continue
                if cmd == "START":
                    if recorder is None:
                        recorder = AudioRecorder(device, sample_rate, input_channel)
                    recorder.start()
                elif cmd == "STOP":
                    if recorder is None:
                        print("", flush=True)
                        continue
                    audio_path = recorder.stop()
                    print("" if audio_path is None else audio_path, flush=True)
                elif cmd == "QUIT":
                    if recorder is not None:
                        recorder.cleanup()
                    break
        except KeyboardInterrupt:
            logger.info("录音被中断")
            sys.exit(1)
        except Exception as exc:
            logger.error("录音失败: %s", exc)
            import traceback
            traceback.print_exc()
            sys.exit(1)
        return

    recorder = AudioRecorder(device, sample_rate, input_channel)
    try:
        audio_path = recorder.record(duration=args.duration)
        print(audio_path, flush=True)
    except KeyboardInterrupt:
        logger.info("录音被中断")
        sys.exit(1)
    except Exception as exc:
        logger.error("录音失败: %s", exc)
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == '__main__':
    main()
