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
import queue
import threading
import logging
from pathlib import Path

import numpy as np
import sounddevice as sd

# 添加项目根目录到 path
PROJECT_ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from app.audio_utils import load_audio_config, resample_audio, SAMPLE_RATE
from app.wave_writer import write_wav

logging.basicConfig(level=logging.INFO, format='%(levelname)s: %(message)s')
logger = logging.getLogger(__name__)


class AudioRecorder:
    """音频录制器（可复用）"""

    def __init__(self, device: int | str | None, sample_rate: int):
        self.device = device
        self.sample_rate = sample_rate
        self.audio_frames: list[np.ndarray] = []
        self.audio_queue: queue.Queue[np.ndarray] = queue.Queue(maxsize=500)
        self.stop_event = threading.Event()
        self.stream: sd.InputStream | None = None
        self.capture_thread: threading.Thread | None = None
        self.active_sample_rate: int | None = None

    def _resolve_input_device(self):
        """选择可用的输入设备"""
        if self.device is not None:
            try:
                info = sd.query_devices(self.device)
                if info.get("max_input_channels", 0) > 0:
                    return self.device
                logger.warning("设备 %s 无输入通道，回退选择输入设备", self.device)
            except Exception as exc:
                logger.warning("查询设备 %s 失败: %s", self.device, exc)

        try:
            devices = sd.query_devices()
            for idx, info in enumerate(devices):
                if info.get("max_input_channels", 0) > 0:
                    logger.info("回退至输入设备 #%s (%s)", idx, info.get("name", "unknown"))
                    return idx
        except Exception as exc:
            logger.warning("查询输入设备列表失败: %s", exc)

        return None

    def _resolve_sample_rate(self, device, preferred):
        """选择可用采样率"""
        if preferred:
            try:
                sd.check_input_settings(
                    device=device,
                    samplerate=preferred,
                    channels=1,
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
                    channels=1,
                    dtype="int16",
                )
                return default_sr
        except Exception:
            pass

        return preferred or SAMPLE_RATE

    def start(self) -> None:
        """开始录音（非阻塞）"""
        if self.stream is not None:
            return

        self.audio_frames.clear()
        while not self.audio_queue.empty():
            try:
                self.audio_queue.get_nowait()
            except queue.Empty:
                break
        self.stop_event.clear()

        device = self._resolve_input_device()
        sample_rate = self._resolve_sample_rate(device, self.sample_rate)
        self.active_sample_rate = sample_rate

        logger.info("使用设备: %s, 采样率: %d Hz", device, sample_rate)

        block_ms = 20
        block_size = int(sample_rate * block_ms / 1000)

        def audio_callback(indata, frame_count, time_info, status):
            if status:
                logger.warning("音频状态: %s", status)
            try:
                self.audio_queue.put_nowait(indata.copy())
            except queue.Full:
                pass

        self.stream = sd.InputStream(
            samplerate=sample_rate,
            blocksize=block_size,
            device=device,
            channels=1,
            dtype='int16',
            callback=audio_callback,
        )
        self.stream.start()

        def capture_loop():
            while not self.stop_event.is_set():
                try:
                    frame = self.audio_queue.get(timeout=0.1)
                    self.audio_frames.append(frame)
                except queue.Empty:
                    continue

        self.capture_thread = threading.Thread(target=capture_loop, daemon=True)
        self.capture_thread.start()
        logger.info("开始录音...")

    def stop(self) -> Path | None:
        """停止录音并写入临时文件"""
        if self.stream is None or self.active_sample_rate is None:
            return None

        self.stop_event.set()
        try:
            self.stream.stop()
            self.stream.close()
        finally:
            self.stream = None

        if self.capture_thread is not None:
            self.capture_thread.join(timeout=1.0)
            self.capture_thread = None

        logger.info("录音完成，共 %d 帧", len(self.audio_frames))

        if not self.audio_frames:
            logger.error("没有录制到音频数据")
            return None

        sample_rate = self.active_sample_rate
        audio_data = np.concatenate(self.audio_frames).flatten()
        audio_duration = len(audio_data) / sample_rate
        logger.info("录音时长: %.2f 秒", audio_duration)

        if audio_duration < 0.3:
            logger.warning("录音时长过短（< 0.3 秒），可能无法识别")

        audio_16k = resample_audio(audio_data, sample_rate, SAMPLE_RATE)

        temp_file = tempfile.NamedTemporaryFile(suffix='.wav', delete=False)
        temp_path = Path(temp_file.name)
        temp_file.close()

        write_wav(temp_path, audio_16k.tobytes(), SAMPLE_RATE)
        logger.info("已保存到: %s", temp_path)

        return temp_path

    def record(self, duration: float | None = None) -> Path:
        """录制音频（阻塞）"""
        self.start()

        if duration:
            self.stop_event.wait(timeout=duration)
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
    args = parser.parse_args()

    # 加载配置
    configured_device, configured_sr = load_audio_config()
    device = args.device if args.device is not None else configured_device
    if isinstance(device, str) and device.isdigit():
        device = int(device)
    sample_rate = args.sample_rate if args.sample_rate != 44100 else configured_sr

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
                        recorder = AudioRecorder(device, sample_rate)
                    recorder.start()
                elif cmd == "STOP":
                    if recorder is None:
                        print("", flush=True)
                        continue
                    audio_path = recorder.stop()
                    recorder = None
                    print("" if audio_path is None else audio_path, flush=True)
                elif cmd == "QUIT":
                    if recorder is not None:
                        recorder.stop()
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

    recorder = AudioRecorder(device, sample_rate)
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
