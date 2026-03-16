# VoCoType Linux

Linux 离线语音输入桌面版，当前仓库仅保留 `flutter_vocotype` 前端及其运行所需的 Python 后端。

## 快速开始

```bash
bash scripts/install-flutter_vocotype.sh
vocotype-flutter
```

详细说明见 [flutter_vocotype/README.md](flutter_vocotype/README.md)。

## 核心特性

- 本地离线识别，不上传音频
- Flutter 托盘应用，默认热键 `F2`
- 自动拉起 Python 后端并通过 Unix socket 通信
- 可选 Rime 集成
- 支持 `xdotool`、`wtype`、`Shift+Insert` 等文本注入方式

## 仓库结构

```text
.
├── flutter_vocotype/      # Flutter Linux 桌面前端
├── app/                   # 语音识别与音频处理运行时
├── backend/               # Flutter 复用的 Python socket 后端
└── scripts/               # Flutter 安装与音频配置脚本
```

## 环境要求

- Linux
- Flutter SDK（启用 Linux desktop）
- Python 3.11 或 3.12
- `cmake`、`pkg-config`、`ninja`

## 相关文件

- [flutter_vocotype/README.md](flutter_vocotype/README.md)
- [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
- [LICENSE](LICENSE)
