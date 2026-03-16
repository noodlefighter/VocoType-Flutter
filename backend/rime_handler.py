#!/usr/bin/env python3
"""Rime 处理模块

提供 Rime 输入法引擎的按键处理功能。
"""
from __future__ import annotations

import logging
import threading
from pathlib import Path
from typing import Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from pyrime.session import Session as RimeSession

logger = logging.getLogger(__name__)


class RimeHandler:
    """Rime 按键处理器"""

    DEFAULT_RIME_SCHEMA = "luna_pinyin"

    def __init__(self):
        self.session: Optional[RimeSession] = None
        self._api = None
        self._session_id = None
        self.available = self._check_rime_available()
        self._init_lock = threading.Lock()

        if self.available:
            logger.info("Rime 处理器已创建（pyrime 可用）")
        else:
            logger.info("Rime 处理器已创建（pyrime 不可用，仅语音模式）")

    def _check_rime_available(self) -> bool:
        """检查 pyrime 是否可用"""
        try:
            import pyrime
            return True
        except ImportError:
            logger.info("pyrime 未安装，Rime 集成功能将被禁用")
            return False

    def _read_schema_from_yaml(self, user_yaml: Path) -> Optional[str]:
        """从指定 user.yaml 读取用户偏好方案"""
        if not user_yaml.exists():
            return None

        try:
            import yaml
            with open(user_yaml, "r", encoding="utf-8") as f:
                data = yaml.safe_load(f)
            if data:
                if "var" in data and isinstance(data["var"], dict):
                    schema = data["var"].get("previously_selected_schema")
                    if schema:
                        return schema
                schema = data.get("selected_schema")
                if schema:
                    return schema
        except ImportError:
            import re
            try:
                content = user_yaml.read_text(encoding="utf-8")
                for pattern in [
                    r"previously_selected_schema:\s*(\S+)",
                    r"selected_schema:\s*(\S+)",
                ]:
                    match = re.search(pattern, content)
                    if match:
                        return match.group(1)
            except Exception:
                pass
        except Exception as exc:
            logger.warning("读取 user.yaml 失败: %s", exc)

        return None

    def _get_preferred_rime_schema(self, user_data_dir: Path) -> Optional[str]:
        """优先读取 vocotype 的 user.yaml，失败再回退 user_data_dir"""
        vocotype_yaml = Path.home() / ".config" / "vocotype" / "rime" / "user.yaml"
        preferred = self._read_schema_from_yaml(vocotype_yaml)
        if preferred:
            return preferred
        return self._read_schema_from_yaml(user_data_dir / "user.yaml")

    def _read_installation_metadata(self, user_data_dir: Path) -> dict:
        """读取 Rime installation.yaml 中的 distribution 信息"""
        install_file = user_data_dir / "installation.yaml"
        if not install_file.exists():
            return {}

        try:
            import yaml
            data = yaml.safe_load(install_file.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                return {
                    "distribution_name": data.get("distribution_name"),
                    "distribution_code_name": data.get("distribution_code_name"),
                    "distribution_version": data.get("distribution_version"),
                }
        except ImportError:
            result = {}
            for line in install_file.read_text(encoding="utf-8").splitlines():
                if ":" not in line:
                    continue
                key, value = line.split(":", 1)
                key = key.strip()
                if key in {
                    "distribution_name",
                    "distribution_code_name",
                    "distribution_version",
                }:
                    result[key] = value.strip().strip('"').strip("'")
            return result
        except Exception as exc:
            logger.warning("读取 installation.yaml 失败: %s", exc)
        return {}

    def initialize(self) -> bool:
        """初始化 Rime Session（懒加载）

        Returns:
            是否初始化成功
        """
        if self.session is not None:
            return True

        if not self.available:
            return False

        with self._init_lock:
            if self.session is not None:
                return True

            try:
                # 确保日志目录存在
                log_dir = Path.home() / ".local" / "share" / "vocotype" / "rime"
                log_dir.mkdir(parents=True, exist_ok=True)

                from pyrime.api import Traits, API
                from pyrime.session import Session

                vocotype_user_dir = Path.home() / ".config" / "vocotype" / "rime"
                user_data_dir = vocotype_user_dir
                user_data_dir.mkdir(parents=True, exist_ok=True)

                # 查找共享数据目录
                shared_dirs = [
                    Path("/usr/share/rime-data"),
                    Path("/usr/local/share/rime-data"),
                ]
                shared_data_dir = next((d for d in shared_dirs if d.exists()), None)
                if shared_data_dir is None:
                    logger.error("找不到 Rime 共享数据目录")
                    return False

                # 验证至少有一个 default.yaml 可用（用户或系统）
                if not (user_data_dir / "default.yaml").exists() and \
                   not (shared_data_dir / "default.yaml").exists():
                    logger.error("找不到 Rime 配置文件（用户和系统目录都缺少 default.yaml）")
                    return False

                for subdir in ["build", "lua", "cn_dicts", "en_dicts", "opencc", "others"]:
                    link_path = user_data_dir / subdir
                    if link_path.exists() or link_path.is_symlink():
                        continue
                    target_path = shared_data_dir / subdir
                    if target_path.exists():
                        try:
                            link_path.symlink_to(target_path)
                            logger.debug("创建 %s 符号链接: %s -> %s", subdir, link_path, target_path)
                        except OSError as exc:
                            logger.warning("创建 %s 符号链接失败: %s", subdir, exc)

                install_meta = self._read_installation_metadata(user_data_dir)
                distribution_name = install_meta.get("distribution_name") or "VoCoType"
                distribution_code = install_meta.get("distribution_code_name") or "vocotype"
                distribution_version = install_meta.get("distribution_version") or "1.0"
                app_name = "rime.vocotype"

                traits = Traits(
                    shared_data_dir=str(shared_data_dir),
                    user_data_dir=str(user_data_dir),
                    log_dir=str(log_dir),
                    distribution_name=distribution_name,
                    distribution_code_name=distribution_code,
                    distribution_version=distribution_version,
                    app_name=app_name,
                )

                logger.info("Rime traits: shared=%s, user=%s, log=%s",
                           shared_data_dir, user_data_dir, log_dir)
                if install_meta:
                    logger.info("Rime installation metadata: %s", install_meta)

                api = API()
                logger.info("Rime API 创建 (addr=%s)，初始化中...", api.address)
                api.setup(traits)
                api.initialize(traits)
                session_id = api.create_session()
                self._api = api
                self._session_id = session_id
                self.session = Session(traits=traits, api=api, id=session_id)

                # 选择已部署的 schema（避免 get_schema_list 触发潜在崩溃）
                try:
                    schema = self.session.get_current_schema()
                    if isinstance(schema, bytes):
                        try:
                            schema = schema.decode("utf-8")
                        except UnicodeDecodeError:
                            schema = schema.decode("gbk", errors="ignore")
                    logger.info("Rime Session 已创建，schema: %s", schema)
                except Exception as exc:
                    logger.warning("获取当前schema失败: %s，使用默认值", exc)
                    schema = None

                preferred_schema = self._get_preferred_rime_schema(user_data_dir)
                if preferred_schema:
                    try:
                        logger.info("尝试使用用户配置的方案: %s", preferred_schema)
                        self.session.select_schema(preferred_schema)
                    except Exception as exc:
                        logger.warning("选择用户方案失败: %s", exc)
                elif schema in (None, "", ".default"):
                    try:
                        logger.info("使用默认方案: %s", self.DEFAULT_RIME_SCHEMA)
                        self.session.select_schema(self.DEFAULT_RIME_SCHEMA)
                    except Exception as exc:
                        logger.warning("选择默认方案失败: %s", exc)

                try:
                    logger.info("当前 schema: %s", self.session.get_current_schema())
                except Exception:
                    pass

                try:
                    if hasattr(self.session, "set_option"):
                        self.session.set_option("ascii_mode", False)
                        logger.info("已关闭 ascii_mode")
                except Exception as exc:
                    logger.warning("设置 ascii_mode 失败: %s", exc)
                return True

            except Exception as exc:
                logger.error("初始化 Rime Session 失败: %s", exc)
                import traceback
                traceback.print_exc()
                return False

    def process_key(self, keyval: int, mask: int) -> dict:
        """处理按键事件

        Args:
            keyval: X11 keysym 值
            mask: Rime modifier mask (0=shift, 1=lock, 2=ctrl, 3=alt)

        Returns:
            {
                "handled": bool,           # 是否被 Rime 处理
                "commit": str,             # 提交的文本（如果有）
                "preedit": {               # 预编辑信息（如果有）
                    "text": str,
                    "cursor_pos": int
                },
                "candidates": [            # 候选词列表（如果有）
                    {"text": str, "comment": str}
                ],
                "highlighted_index": int,  # 高亮的候选词索引
                "page_size": int          # 每页候选词数
            }
        """
        logger.info("process_key: keyval=%d, mask=%d, available=%s, session=%s",
                    keyval, mask, self.available, self.session is not None)

        if not self.available:
            logger.warning("Rime not available (pyrime not installed)")
            return {"handled": False}

        if not self.initialize():
            logger.warning("Rime initialization failed")
            return {"handled": False}

        try:
            # 处理按键
            handled = self.session.process_key(keyval, mask)

            result = {"handled": handled}

            # 检查提交文本
            commit = self.session.get_commit()
            if commit and commit.text:
                result["commit"] = commit.text
                logger.info("Rime 提交文本: %s", commit.text)

            # 获取上下文
            context = self.session.get_context()
            if context:
                # 预编辑文本
                preedit_text = context.composition.preedit or ""
                if preedit_text:
                    result["preedit"] = {
                        "text": preedit_text,
                        "cursor_pos": context.composition.cursor_pos
                    }

                # 候选词
                menu = context.menu
                if menu.candidates:
                    result["candidates"] = [
                        {
                            "text": c.text,
                            "comment": c.comment or ""
                        }
                        for c in menu.candidates
                    ]
                    result["highlighted_index"] = menu.highlighted_candidate_index
                    result["page_size"] = menu.page_size

            logger.info(
                "Rime 状态: handled=%s, preedit=%s, candidates=%s, commit=%s",
                handled,
                bool(result.get("preedit")),
                len(result.get("candidates", [])),
                bool(result.get("commit")),
            )

            return result

        except Exception as exc:
            logger.error("Rime 处理按键失败: %s", exc)
            import traceback
            traceback.print_exc()
            return {"handled": False}

    def reset(self):
        """重置 Rime 状态（清除组合）"""
        if self.session:
            try:
                self.session.clear_composition()
                logger.debug("Rime 状态已重置")
            except Exception as exc:
                logger.warning("重置 Rime 状态失败: %s", exc)

    def cleanup(self):
        """清理资源"""
        if self.session:
            try:
                if self._api and self._session_id is not None:
                    self._api.destroy_session(self._session_id)
                self.session = None
                self._api = None
                self._session_id = None
                logger.info("Rime Handler 已清理")
            except Exception as exc:
                logger.warning("清理 Rime Handler 失败: %s", exc)
