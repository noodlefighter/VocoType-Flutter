#!/bin/bash
# VoCoType Flutter Frontend 安装脚本
#
# 用法: install-flutter_vocotype.sh [--device <id>] [--sample-rate <rate>] [--skip-audio] [--skip-build]
#   --device <id>         指定音频设备 ID，跳过交互式配置
#   --sample-rate <rate>  指定采样率（默认 44100）
#   --skip-audio          跳过音频配置
#   --skip-build          跳过 Flutter 构建（使用已有 build 产物）

set -e

SKIP_AUDIO=false
SKIP_BUILD=false
AUDIO_DEVICE=""
SAMPLE_RATE="44100"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-audio)
            SKIP_AUDIO=true
            shift
            ;;
        --skip-build)
            SKIP_BUILD=true
            shift
            ;;
        --device)
            AUDIO_DEVICE="$2"
            shift 2
            ;;
        --sample-rate)
            SAMPLE_RATE="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

PROJECT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
SCRIPT_DIR="$PROJECT_DIR/scripts"
FRONTEND_SOURCE_DIR="$PROJECT_DIR/flutter_vocotype"
FRONTEND_INSTALL_DIR="$HOME/.local/share/vocotype-flutter_vocotype"
BACKEND_INSTALL_DIR="$FRONTEND_INSTALL_DIR/backend_runtime"

PYTHON_MIN_MINOR=11
PYTHON_MAX_MINOR=12
DEFAULT_UV_PYTHON="3.12"

detect_system_python() {
    for py in python3.12 python3.11 python3; do
        if command -v "$py" &>/dev/null; then
            py_version=$("$py" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
            major=$(echo "$py_version" | cut -d. -f1)
            minor=$(echo "$py_version" | cut -d. -f2)
            if [ "$major" -eq 3 ] && [ "$minor" -ge "$PYTHON_MIN_MINOR" ] && [ "$minor" -le "$PYTHON_MAX_MINOR" ]; then
                echo "$py"
                return 0
            fi
        fi
    done
    return 1
}

print_python_help() {
    echo ""
    echo "原因: VoCoType 使用 onnxruntime 运行语音识别模型，"
    echo "      而 onnxruntime 官方尚未支持 Python 3.13+。"
    echo "      参考: https://github.com/microsoft/onnxruntime/issues/21292"
    echo ""
    echo "解决方案："
    echo ""
    echo "  【推荐】安装 uv（自动管理 Python 版本和虚拟环境）："
    echo "    curl -LsSf https://astral.sh/uv/install.sh | sh"
    echo "    然后重新打开终端，再运行本脚本"
    echo ""
    echo "  或手动安装 Python 3.12："
    echo "    Fedora:       sudo dnf install python3.12"
    echo "    Ubuntu 22.04: sudo apt install python3.12 python3.12-venv"
    echo "    Debian 13:    官方源无 3.12，建议使用 uv"
    echo "    Arch:         sudo pacman -S python312"
}

echo "=== VoCoType Flutter Frontend 安装 ==="
echo "项目目录: $PROJECT_DIR"
echo "Flutter 前端目录: $FRONTEND_SOURCE_DIR"
echo "后端安装目录: $BACKEND_INSTALL_DIR"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. 检查源码目录
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo "[1/7] 检查项目目录..."
if [ ! -d "$FRONTEND_SOURCE_DIR" ]; then
    echo "错误: 未找到 Flutter 前端目录: $FRONTEND_SOURCE_DIR"
    exit 1
fi
if [ ! -f "$PROJECT_DIR/backend/backend_server.py" ]; then
    echo "错误: 未找到后端服务: $PROJECT_DIR/backend/backend_server.py"
    exit 1
fi
echo "✓ 源码目录检查通过"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. 检查 Flutter 与构建依赖
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[2/7] 检查 Flutter 与构建依赖..."
if ! command -v flutter &>/dev/null; then
    echo "错误: 未检测到 Flutter"
    echo "请先安装 Flutter SDK: https://docs.flutter.dev/get-started/install/linux/desktop"
    exit 1
fi

missing_deps=()
for dep in cmake pkg-config ninja; do
    if ! command -v "$dep" &>/dev/null; then
        missing_deps+=("$dep")
    fi
done

if [ ${#missing_deps[@]} -gt 0 ]; then
    echo "错误: 缺少 Flutter Linux 构建依赖: ${missing_deps[*]}"
    echo ""
    echo "安装命令参考:"
    echo "  Debian/Ubuntu: sudo apt install cmake ninja-build pkg-config libgtk-3-dev"
    echo "  Fedora:        sudo dnf install cmake ninja-build pkgconf-pkg-config gtk3-devel"
    echo "  Arch:          sudo pacman -S cmake ninja pkgconf gtk3"
    exit 1
fi

flutter config --enable-linux-desktop >/dev/null 2>&1 || true

if ! command -v xdotool &>/dev/null && ! command -v wtype &>/dev/null; then
    echo "⚠️  未检测到 xdotool/wtype，识别后自动输入文本可能失败"
fi
if ! command -v xclip &>/dev/null; then
    echo "⚠️  未检测到 xclip，Shift+Insert 粘贴路径可能不可用"
fi

echo "✓ Flutter 环境检查通过"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. 安装 Python 后端文件
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[3/7] 安装 Python 后端文件..."
mkdir -p "$BACKEND_INSTALL_DIR"
cp -r "$PROJECT_DIR/app" "$BACKEND_INSTALL_DIR/"
cp -r "$PROJECT_DIR/backend" "$BACKEND_INSTALL_DIR/"
cp "$PROJECT_DIR/vocotype_version.py" "$BACKEND_INSTALL_DIR/"
echo "✓ 后端文件已安装"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. 配置 Python 环境
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[4/7] 配置 Python 环境..."

if command -v uv &>/dev/null; then
    PYTHON_CMD="$DEFAULT_UV_PYTHON"
    echo "检测到 uv，使用 uv 管理 Python: $PYTHON_CMD"
else
    PYTHON_CMD=$(detect_system_python) || {
        echo "错误: 需要 Python 3.11-3.12"
        print_python_help
        exit 1
    }
    echo "检测到兼容的 Python: $PYTHON_CMD"
fi

if [ ! -d "$BACKEND_INSTALL_DIR/.venv" ]; then
    if command -v uv &>/dev/null; then
        echo "使用 uv 创建虚拟环境..."
        uv venv --python "$PYTHON_CMD" "$BACKEND_INSTALL_DIR/.venv"
    else
        echo "使用 venv 创建虚拟环境..."
        "$PYTHON_CMD" -m venv "$BACKEND_INSTALL_DIR/.venv"
    fi
fi

VENV_PYTHON="$BACKEND_INSTALL_DIR/.venv/bin/python"
if command -v uv &>/dev/null; then
    echo "使用 uv 安装依赖..."
    cd "$PROJECT_DIR"
    uv pip install -r requirements.txt --python "$VENV_PYTHON"
    uv pip install -e ".[full]" --python "$VENV_PYTHON"
else
    echo "使用 pip 安装依赖..."
    "$VENV_PYTHON" -m pip install --upgrade pip
    "$VENV_PYTHON" -m pip install -r "$PROJECT_DIR/requirements.txt"
    cd "$PROJECT_DIR"
    "$VENV_PYTHON" -m pip install -e ".[full]"
fi

echo "✓ Python 环境已配置"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 5. 音频设备配置
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[5/7] 配置音频设备..."

if [ -n "$AUDIO_DEVICE" ]; then
    echo "使用指定的音频设备: $AUDIO_DEVICE (采样率: $SAMPLE_RATE)"
    mkdir -p "$HOME/.config/vocotype"
    cat > "$HOME/.config/vocotype/audio.conf" << __VOCOTYPE_AUDIO_EOF__
[audio]
device_id = $AUDIO_DEVICE
sample_rate = $SAMPLE_RATE
__VOCOTYPE_AUDIO_EOF__
    echo "✓ 音频配置已保存"
elif [ "$SKIP_AUDIO" = true ]; then
    echo "跳过音频配置（使用 --skip-audio）"
    echo "请稍后运行以下命令配置音频："
    echo "  $VENV_PYTHON $SCRIPT_DIR/setup-audio.py"
else
    if ! "$VENV_PYTHON" "$SCRIPT_DIR/setup-audio.py"; then
        echo ""
        echo "⚠️  音频配置未完成。"
        echo "请稍后运行以下命令重新配置："
        echo "  $VENV_PYTHON $SCRIPT_DIR/setup-audio.py"
        echo ""
        read -r -p "是否继续安装？ [y/N] " -n 1 REPLY
        echo
        if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
            echo "安装已取消"
            exit 1
        fi
    fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6. 构建并安装 Flutter 前端
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[6/7] 构建并安装 Flutter 前端..."
cd "$FRONTEND_SOURCE_DIR"
flutter pub get

if [ "$SKIP_BUILD" = false ]; then
    flutter build linux --release
else
    echo "使用现有 build 产物（--skip-build）"
fi

BUNDLE_DIR="$FRONTEND_SOURCE_DIR/build/linux/x64/release/bundle"
if [ ! -x "$BUNDLE_DIR/vocotype_flutter" ]; then
    echo "错误: 未找到 Flutter 构建产物: $BUNDLE_DIR/vocotype_flutter"
    echo "请去掉 --skip-build 或检查 flutter build 输出"
    exit 1
fi

mkdir -p "$FRONTEND_INSTALL_DIR"
rm -rf "$FRONTEND_INSTALL_DIR/app"
cp -r "$BUNDLE_DIR" "$FRONTEND_INSTALL_DIR/app"

cat > "$HOME/.local/bin/vocotype-flutter" << '__VOCOTYPE_FLUTTER_LAUNCHER_EOF__'
#!/bin/bash
export VOCOTYPE_BACKEND_RUNTIME="$HOME/.local/share/vocotype-flutter_vocotype/backend_runtime"
exec "$HOME/.local/share/vocotype-flutter_vocotype/app/vocotype_flutter" "$@"
__VOCOTYPE_FLUTTER_LAUNCHER_EOF__
chmod +x "$HOME/.local/bin/vocotype-flutter"

mkdir -p "$HOME/.local/share/applications"
cat > "$HOME/.local/share/applications/vocotype-flutter.desktop" << __VOCOTYPE_DESKTOP_EOF__
[Desktop Entry]
Type=Application
Name=VoCoType Flutter
Comment=VoCoType Flutter Frontend
Exec=$HOME/.local/bin/vocotype-flutter
TryExec=$HOME/.local/bin/vocotype-flutter
Icon=audio-input-microphone
Terminal=false
Categories=Utility;
StartupNotify=true
__VOCOTYPE_DESKTOP_EOF__

if command -v desktop-file-validate >/dev/null 2>&1; then
    if ! desktop-file-validate "$HOME/.local/share/applications/vocotype-flutter.desktop"; then
        echo "⚠️  生成的 desktop 文件未通过校验，请检查:"
        echo "   $HOME/.local/share/applications/vocotype-flutter.desktop"
    fi
fi

echo "✓ Flutter 前端已安装"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 7. 完成
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ VoCoType Flutter Frontend 安装完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📝 接下来的步骤："
echo ""
echo "1. 启动 Flutter 前端："
echo "   vocotype-flutter"
echo ""
echo "2. 使用方式："
echo "   - 按住 F2 说话，松开后识别"
echo "   - 识别文本将自动输入到当前焦点窗口"
echo "   - 后端由 Flutter 自动拉起与停止（无需 systemd）"
echo ""
echo "3. 可选：设置文本输入后端"
echo "   export VOCOTYPE_TYPE_BACKEND=auto   # auto | xdotool | wtype | shift_insert"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
