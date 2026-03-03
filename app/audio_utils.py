"""音频处理工具模块

提供音频配置加载和重采样等通用功能，供 IBus 和 Fcitx5 共享使用。
"""
from __future__ import annotations

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

_HW_SUFFIX_RE = re.compile(r"\s*\(hw:\d+,\d+\)\s*$", re.IGNORECASE)
_USB_ID_RE = re.compile(r"0x[0-9a-f]+:0x[0-9a-f]+", re.IGNORECASE)


def load_audio_config() -> tuple[int | str | None, int]:
    """从配置文件加载音频设备配置

    Returns:
        (device, sample_rate): 设备（可能为 None、整数 ID 或字符串名称）和采样率
    """
    config_file = Path.home() / ".config" / "vocotype" / "audio.conf"
    if not config_file.exists():
        logger.warning("音频配置文件不存在: %s，使用默认设备", config_file)
        return None, DEFAULT_NATIVE_SAMPLE_RATE

    try:
        import configparser
        config = configparser.ConfigParser()
        config.read(config_file)

        # 优先使用 device_name（更稳定），回退到 device_id（向后兼容）
        device_name = config.get('audio', 'device_name', fallback=None)
        if device_name:
            sample_rate = config.getint('audio', 'sample_rate', fallback=DEFAULT_NATIVE_SAMPLE_RATE)
            logger.info("从配置加载: 设备=%s, 采样率=%d", device_name, sample_rate)
            return device_name, sample_rate

        device_id = config.getint('audio', 'device_id', fallback=None)
        sample_rate = config.getint('audio', 'sample_rate', fallback=DEFAULT_NATIVE_SAMPLE_RATE)

        logger.info("从配置加载: 设备=%s, 采样率=%d", device_id, sample_rate)
        return device_id, sample_rate
    except Exception as e:
        logger.warning("读取音频配置失败: %s，使用默认设备", e)
        return None, DEFAULT_NATIVE_SAMPLE_RATE


def _normalize_device_name(name: str) -> str:
    compact = " ".join(name.split()).strip().lower()
    return _HW_SUFFIX_RE.sub("", compact)


def _extract_usb_id(name: str) -> str | None:
    match = _USB_ID_RE.search(name)
    if not match:
        return None
    return match.group(0).lower()


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
