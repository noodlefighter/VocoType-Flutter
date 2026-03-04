#!/usr/bin/env python3
"""Fcitx 5 Python 后端服务（语音 + Rime）

此服务作为独立进程运行，通过 Unix Socket 接收来自 C++ Addon 的请求，
提供语音识别和 Rime 拼音输入功能。
"""
from __future__ import annotations

import sys
import os
import json
import socket
import logging
import signal
import stat
import threading
from pathlib import Path
from dataclasses import asdict, dataclass

# 添加项目根目录到 path
PROJECT_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from app.config import DEFAULT_CONFIG, ensure_logging_dir, load_config
from app.funasr_server import FunASRServer
from app.logging_config import setup_logging
from backend.rime_handler import RimeHandler
from backend.audio_recorder import AudioRecorder
from app.audio_utils import load_audio_config

logger = logging.getLogger(__name__)

SOCKET_PATH = "/tmp/vocotype-fcitx5.sock"
MAX_REQUEST_BYTES = 1024 * 1024
REQUEST_TIMEOUT_S = 2.0
DEFAULT_CONFIG_PATH = "~/.config/vocotype/fcitx5-backend.json"


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
    config_path = os.environ.get("VOCOTYPE_FCITX5_CONFIG", DEFAULT_CONFIG_PATH)
    expanded_path = os.path.expanduser(config_path)
    if not os.path.exists(expanded_path):
        return dict(DEFAULT_CONFIG), expanded_path

    try:
        return load_config(expanded_path), expanded_path
    except Exception as exc:
        print(f"Failed to load config {expanded_path}: {exc}", file=sys.stderr)
        return dict(DEFAULT_CONFIG), expanded_path


def configure_logging(config: dict, debug: bool) -> None:
    """Configure logging with optional file output."""
    logging_cfg = config.get("logging", {})
    level = "DEBUG" if debug else logging_cfg.get("level", "INFO")
    write_file = bool(logging_cfg.get("file", False))
    log_dir = ensure_logging_dir(config) if write_file else None
    setup_logging(level=level, log_dir=log_dir)


class Fcitx5Backend:
    """Fcitx 5 Python 后端服务

    职责：
    1. 接收语音识别请求，调用 FunASRServer
    2. 接收 Rime 按键请求，调用 RimeHandler
    3. 通过 IPC 返回结果给 C++ Addon
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
        self._audio_device, self._audio_sample_rate = load_audio_config()
        if isinstance(self._audio_device, str) and self._audio_device.isdigit():
            self._audio_device = int(self._audio_device)

        # 注册信号处理
        signal.signal(signal.SIGTERM, self._signal_handler)
        signal.signal(signal.SIGINT, self._signal_handler)

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

        logger.info("Fcitx5 Backend 已启动，监听: %s", SOCKET_PATH)

        try:
            while self.running:
                try:
                    conn, _ = sock.accept()
                    threading.Thread(
                        target=self.handle_client,
                        args=(conn,),
                        daemon=True,
                        name="Fcitx5BackendClient",
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
            logger.info("Fcitx5 Backend 已停止")

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
                    response = result

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
            }

        if cmd == "shutdown":
            self.running = False
            return {"ok": True}

        return {"ok": False, "error": f"unknown_cmd:{cmd}"}

    def _start_recording(self) -> dict:
        with self._record_lock:
            if self._recording:
                return {"ok": True, "recording": True}

            recorder = AudioRecorder(
                device=self._audio_device,
                sample_rate=self._audio_sample_rate,
            )
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
            self._recorder = None
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
            text=str(asr_result.get("text", "")).strip() if asr_result.get("success") else "",
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
        try:
            self.asr_server.cleanup()
            self.rime_handler.cleanup()
        except Exception as exc:
            logger.error("清理资源失败: %s", exc)


def main():
    """主入口"""
    global SOCKET_PATH
    import argparse

    parser = argparse.ArgumentParser(
        description='VoCoType Fcitx5 Backend Server'
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

    backend = Fcitx5Backend()
    try:
        backend.run()
    except KeyboardInterrupt:
        logger.info("收到 Ctrl+C，退出...")
    finally:
        backend.cleanup()


if __name__ == '__main__':
    main()
