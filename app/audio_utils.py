"""音频处理工具模块

提供音频配置加载和重采样等通用功能，供 IBus 和 Fcitx5 共享使用。
"""
from __future__ import annotations

import json
import logging
import re
from pathlib import Path
from typing import Any

import numpy as np

logger = logging.getLogger(__name__)

# 目标采样率（ASR 模型需要）
SAMPLE_RATE = 16000
# 默认原生采样率
DEFAULT_NATIVE_SAMPLE_RATE = 44100
DEFAULT_INPUT_CHANNEL = 0
BACKEND_AUDIO_CONFIG_FILE = Path.home() / ".config" / "vocotype" / "fcitx5-backend.json"
LEGACY_AUDIO_CONFIG_FILE = Path.home() / ".config" / "vocotype" / "audio.conf"

_HW_SUFFIX_RE = re.compile(r"\s*\(hw:\d+,\d+\)\s*$", re.IGNORECASE)
_USB_ID_RE = re.compile(r"0x[0-9a-f]+:0x[0-9a-f]+", re.IGNORECASE)


def load_audio_config() -> tuple[int | str | None, int]:
    """从配置文件加载音频设备配置

    Returns:
        (device, sample_rate): 设备（可能为 None、整数 ID 或字符串名称）和采样率
    """
    device, sample_rate, _ = load_audio_input_config()
    return device, sample_rate


def load_audio_input_config(
    backend_config_path: str | Path | None = None,
) -> tuple[int | str | None, int, int]:
    """加载音频输入配置，优先读取前端后端共用的 JSON 配置，回退 legacy audio.conf。"""
    backend_config = _load_backend_audio_config(backend_config_path)
    if backend_config is not None:
        return backend_config

    return _load_legacy_audio_config()


def _load_backend_audio_config(
    backend_config_path: str | Path | None,
) -> tuple[int | str | None, int, int] | None:
    config_file = (
        Path(backend_config_path).expanduser()
        if backend_config_path is not None
        else BACKEND_AUDIO_CONFIG_FILE
    )
    if not config_file.exists():
        return None

    try:
        decoded = json.loads(config_file.read_text(encoding="utf-8"))
    except Exception as exc:
        logger.warning("读取后端音频配置失败: %s", exc)
        return None

    if not isinstance(decoded, dict):
        logger.warning("后端配置格式非法，忽略音频设置: %s", config_file)
        return None

    audio_cfg = _string_dynamic_map(decoded.get("audio"))
    if not audio_cfg:
        return None

    device = _normalize_configured_device(audio_cfg.get("device"))
    sample_rate = _coerce_positive_int(
        audio_cfg.get("sample_rate"),
        DEFAULT_NATIVE_SAMPLE_RATE,
    )
    input_channel = _coerce_non_negative_int(
        audio_cfg.get("input_channel"),
        DEFAULT_INPUT_CHANNEL,
    )
    logger.info(
        "从后端配置加载: 设备=%s, 采样率=%d, 输入通道=%d",
        device,
        sample_rate,
        input_channel,
    )
    return device, sample_rate, input_channel


def _load_legacy_audio_config() -> tuple[int | str | None, int, int]:
    if not LEGACY_AUDIO_CONFIG_FILE.exists():
        logger.warning("音频配置文件不存在: %s，使用默认设备", LEGACY_AUDIO_CONFIG_FILE)
        return None, DEFAULT_NATIVE_SAMPLE_RATE, DEFAULT_INPUT_CHANNEL

    try:
        import configparser

        config = configparser.ConfigParser()
        config.read(LEGACY_AUDIO_CONFIG_FILE)

        # 优先使用 device_name（更稳定），回退到 device_id（向后兼容）
        device_name = config.get("audio", "device_name", fallback=None)
        device = device_name or config.getint("audio", "device_id", fallback=None)
        sample_rate = config.getint(
            "audio",
            "sample_rate",
            fallback=DEFAULT_NATIVE_SAMPLE_RATE,
        )
        input_channel = config.getint(
            "audio",
            "input_channel",
            fallback=DEFAULT_INPUT_CHANNEL,
        )
        logger.info(
            "从 legacy 音频配置加载: 设备=%s, 采样率=%d, 输入通道=%d",
            device,
            sample_rate,
            input_channel,
        )
        return device, sample_rate, max(input_channel, 0)
    except Exception as exc:
        logger.warning("读取音频配置失败: %s，使用默认设备", exc)
        return None, DEFAULT_NATIVE_SAMPLE_RATE, DEFAULT_INPUT_CHANNEL


def _string_dynamic_map(value: Any) -> dict[str, Any]:
    if isinstance(value, dict):
        return {str(key): entry for key, entry in value.items()}
    return {}


def _normalize_configured_device(value: Any) -> int | str | None:
    if value is None:
        return None
    if isinstance(value, int):
        return value
    text = str(value).strip()
    if not text:
        return None
    if text.isdigit():
        return int(text)
    return text


def _coerce_positive_int(value: Any, default: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return default
    return number if number > 0 else default


def _coerce_non_negative_int(value: Any, default: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        return default
    return number if number >= 0 else default


def _normalize_device_name(name: str) -> str:
    compact = " ".join(name.split()).strip().lower()
    return _HW_SUFFIX_RE.sub("", compact)


def _extract_usb_id(name: str) -> str | None:
    match = _USB_ID_RE.search(name)
    if not match:
        return None
    return match.group(0).lower()


def list_input_devices(sd: Any) -> list[dict[str, Any]]:
    """枚举所有可录音输入设备及其通道能力。"""
    try:
        devices = sd.query_devices()
    except Exception as exc:
        logger.warning("查询输入设备列表失败: %s", exc)
        return []

    results: list[dict[str, Any]] = []
    for idx, raw in enumerate(devices):
        info = raw if isinstance(raw, dict) else dict(raw)
        max_input_channels = _coerce_non_negative_int(
            info.get("max_input_channels"),
            0,
        )
        if max_input_channels <= 0:
            continue
        results.append(
            {
                "id": idx,
                "name": str(info.get("name", "")),
                "max_input_channels": max_input_channels,
                "default_sample_rate": _coerce_positive_int(
                    info.get("default_samplerate"),
                    DEFAULT_NATIVE_SAMPLE_RATE,
                ),
            }
        )
    return results


def resolve_input_channel(input_channel: int | None, max_input_channels: int) -> int:
    """将请求的输入通道裁剪到设备能力范围内。"""
    if max_input_channels <= 0:
        return DEFAULT_INPUT_CHANNEL

    if input_channel is None:
        return DEFAULT_INPUT_CHANNEL

    try:
        channel = int(input_channel)
    except (TypeError, ValueError):
        return DEFAULT_INPUT_CHANNEL

    if channel < 0:
        return DEFAULT_INPUT_CHANNEL
    if channel >= max_input_channels:
        return max_input_channels - 1
    return channel


def resolve_input_device(sd: Any, device: int | str | None) -> int | str | None:
    """解析输入设备，支持 USB 设备重插后的稳定匹配。"""
    configured = device
    if isinstance(configured, str) and configured.isdigit():
        configured = int(configured)

    if configured is not None:
        try:
            info = sd.query_devices(configured)
            if info.get("max_input_channels", 0) > 0:
                return configured
            logger.warning("设备 %s 无输入通道，尝试重新匹配输入设备", configured)
        except Exception as exc:
            logger.warning("查询设备 %s 失败: %s，尝试重新匹配", configured, exc)

    try:
        devices = sd.query_devices()
    except Exception as exc:
        logger.warning("查询输入设备列表失败: %s", exc)
        return None

    input_devices: list[tuple[int, dict[str, Any]]] = []
    for idx, info in enumerate(devices):
        if info.get("max_input_channels", 0) > 0:
            input_devices.append((idx, info))

    if isinstance(configured, str):
        # 优先完整名称匹配，再做去 hw:x,y 后缀的稳定匹配。
        for idx, info in input_devices:
            name = str(info.get("name", ""))
            if name == configured:
                logger.info("按名称匹配输入设备 #%s (%s)", idx, name)
                return idx

        wanted = _normalize_device_name(configured)
        for idx, info in input_devices:
            name = str(info.get("name", ""))
            if _normalize_device_name(name) == wanted:
                logger.info("按稳定名称匹配输入设备 #%s (%s)", idx, name)
                return idx

        usb_id = _extract_usb_id(configured)
        if usb_id:
            for idx, info in input_devices:
                name = str(info.get("name", ""))
                if usb_id in name.lower():
                    logger.info("按 USB ID 匹配输入设备 #%s (%s)", idx, name)
                    return idx

    if input_devices:
        idx, info = input_devices[0]
        logger.info("回退至输入设备 #%s (%s)", idx, info.get("name", "unknown"))
        return idx

    return None


def resample_audio(audio: np.ndarray, orig_sr: int, target_sr: int) -> np.ndarray:
    """重采样音频到目标采样率

    Args:
        audio: 原始音频数据
        orig_sr: 原始采样率
        target_sr: 目标采样率

    Returns:
        重采样后的音频数据
    """
    if orig_sr == target_sr:
        return audio
    duration = len(audio) / orig_sr
    target_length = int(duration * target_sr)
    indices = np.linspace(0, len(audio) - 1, target_length)
    return np.interp(indices, np.arange(len(audio)), audio.astype(np.float32)).astype(np.int16)
