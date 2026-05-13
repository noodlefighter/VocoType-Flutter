#!/usr/bin/env python3
"""VoCoType Python 后端服务（语音 + Rime）."""
from __future__ import annotations

import sys
import os
import json
import copy
import re
import socket
import logging
import signal
import stat
import threading
from pathlib import Path
from dataclasses import asdict, dataclass

import sounddevice as sd

# 添加项目根目录到 path
PROJECT_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from app.config import DEFAULT_CONFIG, ensure_logging_dir, load_config
from app.funasr_server import FunASRServer
from app.logging_config import setup_logging
from backend.rime_handler import RimeHandler
from backend.audio_recorder import AudioRecorder
from app.audio_utils import (
    DEFAULT_INPUT_CHANNEL,
    DEFAULT_NATIVE_SAMPLE_RATE,
    list_input_devices,
    load_audio_input_config,
    resolve_input_channel,
    resolve_input_device,
)

logger = logging.getLogger(__name__)

SOCKET_PATH = "/tmp/vocotype-backend.sock"
MAX_REQUEST_BYTES = 1024 * 1024
REQUEST_TIMEOUT_S = 2.0
DEFAULT_CONFIG_PATH = "~/.config/vocotype/backend.json"
DEVICE_WATCH_INTERVAL_S = 5.0


@dataclass
class ResultEnvelope:
    seq: int
    text: str
    raw_text: str
    duration: float
    inference_latency: float
    confidence: float
    error: str | None = None


def load_backend_config() -> tuple[dict, str]:
    """Load backend config from user config file if present."""
    config_path = os.environ.get("VOCOTYPE_BACKEND_CONFIG", DEFAULT_CONFIG_PATH)
    expanded_path = os.path.expanduser(config_path)
    if not os.path.exists(expanded_path):
        return copy.deepcopy(DEFAULT_CONFIG), expanded_path

    try:
        return load_config(expanded_path), expanded_path
    except Exception as exc:
        print(f"Failed to load config {expanded_path}: {exc}", file=sys.stderr)
        return copy.deepcopy(DEFAULT_CONFIG), expanded_path


def configure_logging(config: dict, debug: bool) -> None:
    """Configure logging with optional file output."""
    logging_cfg = config.get("logging", {})
    level = "DEBUG" if debug else logging_cfg.get("level", "INFO")
    write_file = bool(logging_cfg.get("file", False))
    log_dir = ensure_logging_dir(config) if write_file else None
    setup_logging(level=level, log_dir=log_dir)


class VocotypeBackend:
    """VoCoType Python 后端服务

    职责：
    1. 接收语音识别请求，调用 FunASRServer
    2. 接收 Rime 按键请求，调用 RimeHandler
    3. 通过 IPC 返回结果给前端
    """

    def __init__(self):
        # 语音识别服务
        logger.info("正在初始化 FunASR 服务器...")
        self.asr_server = FunASRServer()
        asr_result = self.asr_server.initialize()
        if not asr_result['success']:
            logger.error("FunASR 初始化失败: %s", asr_result.get('error'))
            sys.exit(1)
        logger.info("FunASR 服务器初始化成功")

        # Rime 处理器
        self.rime_handler = RimeHandler()
        if self.rime_handler.available:
            logger.info("Rime 集成已启用")
        else:
            logger.info("Rime 集成未启用（纯语音模式）")

        # 标记运行状态
        self.running = True
        self._asr_lock = threading.Lock()
        self._rime_lock = threading.Lock()
        self._record_lock = threading.Lock()
        self._recorder: AudioRecorder | None = None
        self._recording = False
        self._result_seq = 0
        self._last_result: ResultEnvelope | None = None
        self._config_lock = threading.Lock()
        self._config_path = os.path.expanduser(
            os.environ.get("VOCOTYPE_BACKEND_CONFIG", DEFAULT_CONFIG_PATH)
        )
        self._config_mtime: float | None = None
        self._runtime_config = copy.deepcopy(DEFAULT_CONFIG)
        self._audio_device: int | str | None = None
        self._audio_sample_rate = DEFAULT_NATIVE_SAMPLE_RATE
        self._audio_input_channel = DEFAULT_INPUT_CHANNEL
        self._audio_device_signature: tuple[tuple[int, str, int, int], ...] | None = None
        self._device_watch_stop = threading.Event()
        self._device_watch_thread = threading.Thread(
            target=self._device_watch_loop,
            daemon=True,
            name="VocotypeAudioDeviceWatch",
        )
        self._reload_audio_input_config()
        self._warmup_recorder()
        self._device_watch_thread.start()

        # 注册信号处理
        signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)

    def _reload_runtime_config_if_needed(self) -> dict:
        """Reload backend config on file change and fallback to defaults on error."""
        with self._config_lock:
            try:
                st = os.stat(self._config_path)
            except FileNotFoundError:
                self._config_mtime = None
                self._runtime_config = copy.deepcopy(DEFAULT_CONFIG)
                return self._runtime_config
            except OSError as exc:
                logger.warning("读取配置文件状态失败，回退默认配置: %s", exc)
                self._config_mtime = None
                self._runtime_config = copy.deepcopy(DEFAULT_CONFIG)
                return self._runtime_config

            if self._config_mtime == st.st_mtime:
                return self._runtime_config

            try:
                self._runtime_config = load_config(self._config_path)
                self._config_mtime = st.st_mtime
                logger.info("配置已重载: %s", self._config_path)
            except Exception as exc:
                logger.warning("加载配置失败，回退默认配置: %s", exc)
                self._runtime_config = copy.deepcopy(DEFAULT_CONFIG)
                self._config_mtime = st.st_mtime

            return self._runtime_config

    def _postprocess_output_text(self, text: str) -> str:
        config = self._reload_runtime_config_if_needed()
        output_cfg = config.get("output", {})
        if not bool(output_cfg.get("remove_period", False)):
            return text
        return re.sub(r"[。.]+$", "", text)

    def _reload_audio_input_config(self) -> None:
        device, sample_rate, input_channel = load_audio_input_config(self._config_path)
        self._audio_device = device
        self._audio_sample_rate = sample_rate
        self._audio_input_channel = input_channel

    def _reset_audio_backend_locked(self) -> None:
        """重建 sounddevice/PortAudio 状态，确保重新枚举热插拔设备。"""
        recorder = self._recorder
        if recorder is not None:
            recorder.cleanup()
            self._recorder = None

        try:
            sd._terminate()
        except Exception as exc:
            logger.warning("终止音频后端失败: %s", exc)

        try:
            sd._initialize()
        except Exception as exc:
            logger.warning("重建音频后端失败: %s", exc)

    def _audio_device_snapshot_locked(self) -> tuple[tuple[int, str, int, int], ...]:
        snapshot = tuple(
            (
                int(item.get("id", 0) or 0),
                str(item.get("name", "")),
                int(item.get("max_input_channels", 0) or 0),
                int(item.get("default_sample_rate", 0) or 0),
            )
            for item in list_input_devices(sd)
        )
        return snapshot

    def _refresh_audio_devices_locked(self) -> bool:
        """重建音频后端并在设备变化时更新内部状态。"""
        if self._recording:
            return False

        previous_signature = self._audio_device_signature
        self._reload_audio_input_config()
        self._reset_audio_backend_locked()

        current_signature = self._audio_device_snapshot_locked()
        self._audio_device_signature = current_signature

        if previous_signature == current_signature:
            return False

        recorder = self._ensure_recorder_locked()
        try:
            recorder.prepare()
        except Exception as exc:
            logger.warning("刷新音频设备预热失败: %s", exc)
        return True

    def _device_watch_loop(self) -> None:
        while not self._device_watch_stop.wait(DEVICE_WATCH_INTERVAL_S):
            try:
                with self._record_lock:
                    changed = self._refresh_audio_devices_locked()
                if changed:
                    logger.info("检测到音频设备变化，已刷新设备状态")
            except Exception as exc:
                logger.warning("音频设备监测失败: %s", exc)

    def _build_recorder(self) -> AudioRecorder:
        return AudioRecorder(
            device=self._audio_device,
            sample_rate=self._audio_sample_rate,
            input_channel=self._audio_input_channel,
        )

    def _ensure_recorder_locked(self) -> AudioRecorder:
        recorder = self._recorder
        if recorder is not None and recorder.matches_config(
            self._audio_device,
            self._audio_sample_rate,
            self._audio_input_channel,
        ):
            return recorder

        if recorder is not None:
            recorder.cleanup()

        recorder = self._build_recorder()
        self._recorder = recorder
        return recorder

    def _warmup_recorder(self) -> None:
        with self._record_lock:
            if self._recording:
                return
            recorder = self._ensure_recorder_locked()
        try:
            recorder.prepare()
        except Exception as exc:
            logger.warning("音频输入流预热失败: %s", exc)

    def _current_audio_input_state(self) -> dict:
        state = {
            "device": self._audio_device,
            "sample_rate": self._audio_sample_rate,
            "input_channel": self._audio_input_channel,
        }
        resolved_device = resolve_input_device(sd, self._audio_device)
        state["resolved_device"] = resolved_device

        try:
            info = sd.query_devices(
                resolved_device if resolved_device is not None else None,
                kind="input",
            )
        except Exception as exc:
            state["resolution_error"] = str(exc)
            return state

        max_input_channels = int(info.get("max_input_channels", 0) or 0)
        state.update(
            {
                "resolved_device_name": str(info.get("name", "")),
                "max_input_channels": max_input_channels,
                "default_sample_rate": int(info.get("default_samplerate", 0) or 0),
                "resolved_input_channel": resolve_input_channel(
                    self._audio_input_channel,
                    max_input_channels,
                ),
            }
        )
        return state

    def _list_audio_inputs(self) -> dict:
        with self._record_lock:
            if not self._recording:
                self._refresh_audio_devices_locked()
        return {
            "ok": True,
            "devices": list_input_devices(sd),
            "current": self._current_audio_input_state(),
            "recording": self._recording,
        }

    def _set_audio_input(self, request: dict) -> dict:
        device = request.get("device")
        if isinstance(device, str):
            device = device.strip() or None
            if device and device.isdigit():
                device = int(device)
        elif device is not None and not isinstance(device, int):
            device = str(device)

        try:
            sample_rate = int(request.get("sample_rate", self._audio_sample_rate))
        except (TypeError, ValueError):
            return {"ok": False, "error": "invalid_sample_rate"}
        if sample_rate <= 0:
            return {"ok": False, "error": "invalid_sample_rate"}

        try:
            input_channel = int(request.get("input_channel", self._audio_input_channel))
        except (TypeError, ValueError):
            return {"ok": False, "error": "invalid_input_channel"}
        if input_channel < 0:
            return {"ok": False, "error": "invalid_input_channel"}

        available_devices = list_input_devices(sd)
        if device is not None:
            matched = False
            for candidate in available_devices:
                if isinstance(device, int) and candidate.get("id") == device:
                    matched = True
                    break
                if isinstance(device, str) and candidate.get("name") == device:
                    matched = True
                    break
            if not matched:
                return {"ok": False, "error": "device_unavailable"}

        resolved_device = resolve_input_device(sd, device)
        try:
            info = sd.query_devices(
                resolved_device if resolved_device is not None else None,
                kind="input",
            )
        except Exception as exc:
            return {"ok": False, "error": f"device_query_failed: {exc}"}

        max_input_channels = int(info.get("max_input_channels", 0) or 0)
        if max_input_channels <= 0:
            return {"ok": False, "error": "no_input_channels"}

        resolved_input_channel = resolve_input_channel(input_channel, max_input_channels)
        if resolved_input_channel != input_channel:
            return {
                "ok": False,
                "error": f"invalid_input_channel:{input_channel}",
                "max_input_channels": max_input_channels,
            }

        self._audio_device = device
        self._audio_sample_rate = sample_rate
        self._audio_input_channel = resolved_input_channel
        if not self._recording:
            self._warmup_recorder()
        state = self._current_audio_input_state()
        return {
            "ok": True,
            "applied_now": not self._recording,
            "recording": self._recording,
            "current": state,
        }

    def _apply_asr_postprocess(self, asr_result: dict) -> dict:
        if not asr_result.get("success"):
            return asr_result

        response = dict(asr_result)
        response["text"] = self._postprocess_output_text(str(response.get("text", "")))
        return response

    def _cleanup_socket_path(self, path: str) -> None:
        """安全删除旧 socket 文件（避免误删普通文件）"""
        if not os.path.exists(path):
            return

        try:
            st = os.lstat(path)
        except OSError as exc:
            logger.warning("检查旧 socket 失败: %s", exc)
            return

        if stat.S_ISSOCK(st.st_mode) or stat.S_ISLNK(st.st_mode):
            try:
                os.remove(path)
                logger.info("已移除旧 socket: %s", path)
            except OSError as exc:
                logger.warning("移除旧 socket 失败: %s", exc)
        else:
            raise RuntimeError(f"socket 路径已存在且不是 socket: {path}")

    def _signal_handler(self, signum, frame):
        """信号处理器"""
        logger.info("收到信号 %d，准备退出...", signum)
        self.running = False

    def run(self):
        """运行 IPC 服务器"""
        # 删除旧的 socket 文件
        self._cleanup_socket_path(SOCKET_PATH)

        # 创建 Unix Socket
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(SOCKET_PATH)
        os.chmod(SOCKET_PATH, 0o600)
        sock.listen(5)
        sock.settimeout(1.0)  # 设置超时以便处理信号

        logger.info("VoCoType Backend 已启动，监听: %s", SOCKET_PATH)

        try:
            while self.running:
                try:
                    conn, _ = sock.accept()
                    threading.Thread(
                        target=self.handle_client,
                        args=(conn,),
                        daemon=True,
                        name="VocotypeBackendClient",
                    ).start()
                except socket.timeout:
                    continue
                except Exception as exc:
                    if self.running:
                        logger.error("接受连接失败: %s", exc)
        finally:
            sock.close()
            try:
                self._cleanup_socket_path(SOCKET_PATH)
            except RuntimeError as exc:
                logger.warning("清理 socket 失败: %s", exc)
            logger.info("VoCoType Backend 已停止")

    def handle_client(self, conn: socket.socket):
        """处理客户端请求

        IPC 协议：
        - 请求格式：JSON 字符串
        - 响应格式：JSON 字符串

        请求类型：
        1. transcribe: 语音识别
           {"type": "transcribe", "audio_path": "/tmp/xxx.wav"}
           -> {"success": true, "text": "识别结果"}

        2. key_event: Rime 按键处理
           {"type": "key_event", "keyval": 97, "mask": 0}
           -> {"handled": true, "commit": "...", "preedit": {...}, ...}

        3. reset: 重置 Rime 状态
           {"type": "reset"}
           -> {"success": true}

        4. ping: 健康检查
           {"type": "ping"}
           -> {"pong": true}
        """
        try:
            conn.settimeout(REQUEST_TIMEOUT_S)
            # 接收请求（读到 EOF）
            chunks = []
            total_bytes = 0
            while True:
                chunk = conn.recv(8192)
                if not chunk:
                    break
                chunks.append(chunk)
                total_bytes += len(chunk)
                if total_bytes > MAX_REQUEST_BYTES:
                    response_str = json.dumps({"error": "Request too large"}, ensure_ascii=False)
                    conn.sendall(response_str.encode('utf-8'))
                    return
                if b"\n" in chunk:
                    break
            if not chunks:
                return
            data = b''.join(chunks).decode('utf-8').strip()
            if "\n" in data:
                data = data.splitlines()[0].strip()

            request = json.loads(data)
            cmd = request.get('cmd')
            req_type = request.get('type')

            logger.debug("收到请求: cmd=%s type=%s", cmd, req_type)

            # 处理请求
            if cmd is not None:
                response = self._dispatch_frontend_cmd(request)
            elif req_type == 'transcribe':
                # 语音识别
                audio_path = request.get('audio_path')
                if not audio_path:
                    response = {"success": False, "error": "缺少 audio_path 参数"}
                else:
                    with self._asr_lock:
                        result = self.asr_server.transcribe_audio(audio_path)
                    response = self._apply_asr_postprocess(result)

            elif req_type == 'key_event':
                # Rime 按键处理
                keyval = request.get('keyval')
                mask = request.get('mask', 0)
                if keyval is None:
                    response = {"handled": False, "error": "缺少 keyval 参数"}
                else:
                    with self._rime_lock:
                        result = self.rime_handler.process_key(keyval, mask)
                    response = result

            elif req_type == 'reset':
                # 重置 Rime
                with self._rime_lock:
                    self.rime_handler.reset()
                response = {"success": True}

            elif req_type == 'ping':
                # 健康检查
                response = {"pong": True}

            else:
                response = {"error": f"未知的请求类型: {req_type}"}

            # 发送响应
            response_str = json.dumps(response, ensure_ascii=False)
            conn.sendall(response_str.encode('utf-8'))

            logger.debug("已发送响应: %d 字节", len(response_str))

        except json.JSONDecodeError as exc:
            logger.error("JSON 解析失败: %s", exc)
            try:
                error_response = json.dumps({"error": "Invalid JSON"})
                conn.sendall(error_response.encode('utf-8'))
            except Exception:
                pass

        except socket.timeout:
            logger.warning("IPC 请求读取超时")
            try:
                error_response = json.dumps({"error": "Request timeout"})
                conn.sendall(error_response.encode('utf-8'))
            except Exception:
                pass

        except Exception as exc:
            logger.error("处理请求失败: %s", exc)
            import traceback
            traceback.print_exc()
            try:
                error_response = json.dumps({"error": str(exc)})
                conn.sendall(error_response.encode('utf-8'))
            except Exception:
                pass

        finally:
            conn.close()

    def _dispatch_frontend_cmd(self, request: dict) -> dict:
        cmd = str(request.get("cmd", "")).strip().lower()

        if cmd == "ping":
            return {"ok": True, "type": "pong"}

        if cmd == "start":
            return self._start_recording()

        if cmd == "stop":
            return self._stop_recording(transcribe=False)

        if cmd == "stop_and_wait":
            return self._stop_recording(transcribe=True)

        if cmd == "status":
            return {
                "ok": True,
                "recording": self._recording,
                "transcribing": False,
                "stats": {"transcription_count": self.asr_server.transcription_count},
                "last_result": asdict(self._last_result) if self._last_result else None,
                "audio": self._current_audio_input_state(),
            }

        if cmd == "list_audio_inputs":
            return self._list_audio_inputs()

        if cmd == "set_audio_input":
            return self._set_audio_input(request)

        if cmd == "shutdown":
            self.running = False
            return {"ok": True}

        return {"ok": False, "error": f"unknown_cmd:{cmd}"}

    def _start_recording(self) -> dict:
        with self._record_lock:
            if self._recording:
                return {"ok": True, "recording": True}

            self._reload_audio_input_config()
            recorder = self._ensure_recorder_locked()
            try:
                recorder.start()
            except Exception as exc:
                return {"ok": False, "error": f"start_failed: {exc}"}

            self._recorder = recorder
            self._recording = True
            return {"ok": True, "recording": True}

    def _stop_recording(self, transcribe: bool) -> dict:
        with self._record_lock:
            recorder = self._recorder
            if recorder is None or not self._recording:
                return {"ok": False, "error": "not_recording"}
            self._recording = False

        try:
            audio_path = recorder.stop()
        except Exception as exc:
            return {"ok": False, "error": f"stop_failed: {exc}"}

        if not transcribe:
            if audio_path:
                try:
                    os.remove(audio_path)
                except OSError:
                    pass
            return {"ok": True, "recording": False}

        if audio_path is None:
            return {"ok": False, "error": "no_audio"}

        try:
            with self._asr_lock:
                asr_result = self.asr_server.transcribe_audio(str(audio_path))
        finally:
            try:
                os.remove(audio_path)
            except OSError:
                pass

        envelope = ResultEnvelope(
            seq=self._result_seq + 1,
            text=self._postprocess_output_text(str(asr_result.get("text", "")).strip())
            if asr_result.get("success")
            else "",
            raw_text=str(asr_result.get("raw_text", "")) if asr_result.get("success") else "",
            duration=float(asr_result.get("duration", 0.0) or 0.0),
            inference_latency=0.0,
            confidence=float(asr_result.get("confidence", 0.0) or 0.0),
            error=None if asr_result.get("success") else str(asr_result.get("error", "transcribe_failed")),
        )
        self._result_seq = envelope.seq
        self._last_result = envelope
        return {"ok": True, "result": asdict(envelope)}

    def cleanup(self):
        """清理资源"""
        logger.info("正在清理资源...")
        self._device_watch_stop.set()
        if self._device_watch_thread.is_alive():
            self._device_watch_thread.join(timeout=2.0)
        try:
            if self._recorder is not None:
                self._recorder.cleanup()
            self.asr_server.cleanup()
            self.rime_handler.cleanup()
        except Exception as exc:
            logger.error("清理资源失败: %s", exc)


def main():
    """主入口"""
    global SOCKET_PATH
    import argparse

    parser = argparse.ArgumentParser(
        description='VoCoType Backend Server'
    )
    parser.add_argument(
        '--socket',
        default=SOCKET_PATH,
        help=f'Unix socket path (default: {SOCKET_PATH})'
    )
    parser.add_argument(
        '--debug',
        action='store_true',
        help='Enable debug logging'
    )
    args = parser.parse_args()

    config, config_path = load_backend_config()
    configure_logging(config, args.debug)
    logger.info("配置文件路径: %s", config_path)

    SOCKET_PATH = args.socket

    backend = VocotypeBackend()
    try:
        backend.run()
    except KeyboardInterrupt:
        logger.info("收到 Ctrl+C，退出...")
    finally:
        backend.cleanup()


if __name__ == '__main__':
    main()
