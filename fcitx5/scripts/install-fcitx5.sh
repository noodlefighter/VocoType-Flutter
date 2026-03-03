#!/bin/bash
# VoCoType Fcitx 5 安装脚本
#
# 用法: install-fcitx5.sh [--device <id>] [--sample-rate <rate>] [--skip-audio]
#   --device <id>      指定音频设备ID，跳过交互式配置
#   --sample-rate <rate>  指定采样率（默认44100）
#   --skip-audio       跳过音频配置
#
# 历史问题修复记录：
# 1. FCITX_ADDON_DIRS 环境变量 - Fcitx5 默认不搜索 ~/.local/lib64/fcitx5
# 2. 库文件前缀 - 需要创建 libvocotype.so 符号链接
# 3. inputmethod 配置 - 文件扩展名应为 .conf（不是 .conf.in）
# 4. listInputMethods() - C++ 代码必须实现此方法才能被 Fcitx5 发现
# 5. C++20 标准 - Fcitx5 日志宏需要 source_location

set -e

# 解析命令行参数
SKIP_AUDIO=false
AUDIO_DEVICE=""
SAMPLE_RATE="44100"

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-audio)
            SKIP_AUDIO=true
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

PROJECT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
INSTALL_DIR="$HOME/.local/share/vocotype-fcitx5"
SCRIPT_DIR="$PROJECT_DIR/scripts"

echo "=== VoCoType Fcitx 5 语音输入法安装 ==="
echo "项目目录: $PROJECT_DIR"
echo ""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. 检查 Fcitx 5
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo "[1/9] 检查 Fcitx 5..."
if ! command -v fcitx5 &>/dev/null; then
    echo "错误: 未检测到 Fcitx 5"
    echo "请先安装 Fcitx 5:"
    echo "  Debian/Ubuntu: sudo apt install fcitx5 fcitx5-config-qt"
    echo "  Fedora:        sudo dnf install fcitx5 fcitx5-configtool"
    echo "  Arch:          sudo pacman -S fcitx5 fcitx5-configtool"
    exit 1
fi
echo "✓ Fcitx 5 已安装"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. 检查编译依赖
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[2/9] 检查编译依赖..."
missing_deps=()

# 检查 CMake
if ! command -v cmake &>/dev/null; then
    missing_deps+=("cmake")
fi

# 检查 pkg-config
if ! command -v pkg-config &>/dev/null; then
    missing_deps+=("pkg-config")
fi

# 检查 Fcitx 5 开发库（多种检测方式）
fcitx5_found=false
for pkg in Fcitx5Core fcitx5-core Fcitx5Module fcitx5; do
    if pkg-config --exists "$pkg" 2>/dev/null; then
        fcitx5_found=true
        break
    fi
done

if [ "$fcitx5_found" = false ]; then
    for include_dir in /usr/include /usr/local/include; do
        if [ -f "$include_dir/Fcitx5/Core/fcitx/addoninstance.h" ] || \
           [ -f "$include_dir/fcitx5/core/addoninstance.h" ]; then
            fcitx5_found=true
            break
        fi
    done
fi

if [ "$fcitx5_found" = false ]; then
    missing_deps+=("fcitx5-devel (或 libfcitx5-dev)")
fi

# 检查 nlohmann-json
json_found=false
for pkg in nlohmann_json json; do
    if pkg-config --exists "$pkg" 2>/dev/null; then
        json_found=true
        break
    fi
done

if [ "$json_found" = false ]; then
    for include_dir in /usr/include /usr/local/include; do
        if [ -f "$include_dir/nlohmann/json.hpp" ]; then
            json_found=true
            break
        fi
    done
fi

if [ "$json_found" = false ]; then
    missing_deps+=("nlohmann-json-devel (或 nlohmann-json3-dev)")
fi

if [ ${#missing_deps[@]} -gt 0 ]; then
    echo "错误: 缺少以下依赖:"
    for dep in "${missing_deps[@]}"; do
        echo "  - $dep"
    done
    echo ""
    echo "安装命令参考:"
    echo "  Debian/Ubuntu: sudo apt install cmake pkg-config libfcitx5-dev nlohmann-json3-dev"
    echo "  Fedora:        sudo dnf install cmake pkgconfig fcitx5-devel json-devel"
    echo "  Arch:          sudo pacman -S cmake pkgconfig fcitx5 nlohmann-json"
    exit 1
fi
echo "✓ 编译依赖已满足"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. 编译 C++ Addon
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[3/9] 编译 C++ Addon..."
mkdir -p "$PROJECT_DIR/fcitx5/addon/build"
cd "$PROJECT_DIR/fcitx5/addon/build"

cmake .. -DCMAKE_INSTALL_PREFIX="$HOME/.local"
make -j$(nproc)
echo "✓ 编译成功"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. 安装 C++ Addon（多位置 + 符号链接）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[4/9] 安装 C++ Addon..."
make install

# 复制到 lib 目录（某些 Fcitx5 配置可能需要）
mkdir -p "$HOME/.local/lib/fcitx5"
cp "$HOME/.local/lib64/fcitx5/vocotype.so" "$HOME/.local/lib/fcitx5/" 2>/dev/null || \
cp "$PROJECT_DIR/fcitx5/addon/build/vocotype.so" "$HOME/.local/lib/fcitx5/"

# 创建 lib 前缀的符号链接（兼容性）
cd "$HOME/.local/lib64/fcitx5" && ln -sf vocotype.so libvocotype.so 2>/dev/null || true
cd "$HOME/.local/lib/fcitx5" && ln -sf vocotype.so libvocotype.so 2>/dev/null || true

# 安装 Addon 配置文件
mkdir -p "$HOME/.local/share/fcitx5/addon"
mkdir -p "$HOME/.local/share/fcitx5/inputmethod"
cp "$PROJECT_DIR/fcitx5/data/vocotype.conf" "$HOME/.local/share/fcitx5/addon/"

# 注意：inputmethod 配置文件需要 .conf 扩展名（不是 .conf.in）
if [ -f "$PROJECT_DIR/fcitx5/data/vocotype.conf.in" ]; then
    cp "$PROJECT_DIR/fcitx5/data/vocotype.conf.in" "$HOME/.local/share/fcitx5/inputmethod/vocotype.conf"
fi

echo "✓ C++ Addon 已安装"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 5. 设置环境变量（关键：让 Fcitx5 找到用户插件）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[5/9] 配置环境变量..."
mkdir -p "$HOME/.config/environment.d"
cat > "$HOME/.config/environment.d/fcitx5-vocotype.conf" << 'EOF'
FCITX_ADDON_DIRS=$HOME/.local/lib64/fcitx5:$HOME/.local/lib/fcitx5:/usr/lib64/fcitx5:/usr/lib/x86_64-linux-gnu/fcitx5:/usr/lib/fcitx5
EOF
echo "✓ 环境变量已配置"
echo "  注意: 需要重新登录或设置环境变量才能生效"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6. 安装 Python 后端
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[6/9] 安装 Python 后端..."
mkdir -p "$INSTALL_DIR"

# 复制文件
cp -r "$PROJECT_DIR/app" "$INSTALL_DIR/"
cp -r "$PROJECT_DIR/fcitx5/backend" "$INSTALL_DIR/"
cp "$PROJECT_DIR/vocotype_version.py" "$INSTALL_DIR/"

# 创建 __init__.py
touch "$INSTALL_DIR/backend/__init__.py"

echo "✓ Python 后端已安装"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 7. 配置 Python 环境
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[7/9] 配置 Python 环境..."

# 检测可用的 Python 版本（需要 3.11-3.12，onnxruntime 不支持 3.13+）
PYTHON_CMD=""
if command -v uv &>/dev/null; then
    PYTHON_CMD="3.12"
    echo "检测到 uv，使用 uv 管理 Python: $PYTHON_CMD"
else
    for py in python3.12 python3.11 python3; do
        if command -v "$py" &>/dev/null; then
            py_version=$("$py" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
            major=$(echo "$py_version" | cut -d. -f1)
            minor=$(echo "$py_version" | cut -d. -f2)
            if [ "$major" -eq 3 ] && [ "$minor" -ge 11 ] && [ "$minor" -le 12 ]; then
                PYTHON_CMD="$py"
                echo "使用 Python $py_version"
                break
            fi
        fi
    done
fi

if [ -z "$PYTHON_CMD" ]; then
    echo "错误: 需要 Python 3.11-3.12"
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
    echo "    Fedora: sudo dnf install python3.12"
    echo "    Ubuntu: sudo apt install python3.12"
    echo "    Arch:   sudo pacman -S python312"
    exit 1
fi

# 创建虚拟环境
if [ ! -d "$INSTALL_DIR/.venv" ]; then
    if command -v uv &>/dev/null; then
        echo "使用 uv 创建虚拟环境..."
        uv venv --python "$PYTHON_CMD" "$INSTALL_DIR/.venv"
    else
        echo "使用 venv 创建虚拟环境..."
        "$PYTHON_CMD" -m venv "$INSTALL_DIR/.venv"
    fi
fi

# 安装依赖
VENV_PYTHON="$INSTALL_DIR/.venv/bin/python"
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
# 8. Rime 输入方案选择（可选）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[8/9] 配置 Rime 输入方案（可选）"

FCITX_RIME_USER="$HOME/.local/share/fcitx5/rime"
FCITX_RIME_BUILD="$FCITX_RIME_USER/build"
VOCOTYPE_RIME_CONFIG="$HOME/.config/vocotype/rime"

if [ -d "$FCITX_RIME_USER" ]; then
    if [ ! -f "/usr/share/rime-data/default.yaml" ] && [ ! -f "/usr/local/share/rime-data/default.yaml" ]; then
        echo "⚠️  未找到系统 Rime 配置文件，跳过方案选择"
        echo "   Arch: sudo pacman -S rime-data"
    else
        echo ""
        echo "══════════════════════════════════════════"
        echo "   RIME 输入方案配置"
        echo "══════════════════════════════════════════"
        echo ""

        declare -a SCHEMAS=()
        declare -A SCHEMA_NAMES=()

        SCHEMA_NAMES["luna_pinyin"]="朙月拼音"
        SCHEMA_NAMES["luna_pinyin_simp"]="朙月拼音·简化字"
        SCHEMA_NAMES["luna_pinyin_tw"]="朙月拼音·臺灣正體"
        SCHEMA_NAMES["double_pinyin"]="自然码双拼"
        SCHEMA_NAMES["double_pinyin_abc"]="智能ABC双拼"
        SCHEMA_NAMES["double_pinyin_flypy"]="小鹤双拼"
        SCHEMA_NAMES["double_pinyin_mspy"]="微软双拼"
        SCHEMA_NAMES["double_pinyin_pyjj"]="拼音加加双拼"
        SCHEMA_NAMES["rime_ice"]="雾凇拼音"
        SCHEMA_NAMES["wubi86"]="五笔86"
        SCHEMA_NAMES["wubi98"]="五笔98"
        SCHEMA_NAMES["wubi_pinyin"]="五笔拼音混输"
        SCHEMA_NAMES["pinyin_simp"]="袖珍简化字拼音"
        SCHEMA_NAMES["terra_pinyin"]="地球拼音"
        SCHEMA_NAMES["bopomofo"]="注音"
        SCHEMA_NAMES["bopomofo_tw"]="注音·臺灣正體"
        SCHEMA_NAMES["bopomofo_express"]="注音·快打"
        SCHEMA_NAMES["cangjie5"]="仓颉五代"
        SCHEMA_NAMES["cangjie5_express"]="仓颉五代·快打"
        SCHEMA_NAMES["quick5"]="速成"
        SCHEMA_NAMES["stroke"]="五笔画"
        SCHEMA_NAMES["array30"]="行列30"
        SCHEMA_NAMES["combo_pinyin"]="宫保拼音"
        SCHEMA_NAMES["combo_pinyin_kbcon"]="宫保拼音·键盘控"
        SCHEMA_NAMES["combo_pinyin_left"]="宫保拼音·左手"
        SCHEMA_NAMES["stenotype"]="打字速记"
        SCHEMA_NAMES["jyutping"]="粤拼"
        SCHEMA_NAMES["ipa_xsampa"]="国际音标"
        SCHEMA_NAMES["emoji"]="绘文字"
        SCHEMA_NAMES["stroke_simp"]="笔顺·简化字"
        SCHEMA_NAMES["triungkox"]="中古汉语三拼"

        if [ -d "$FCITX_RIME_BUILD" ]; then
            for f in "$FCITX_RIME_BUILD"/*.prism.bin; do
                if [ -f "$f" ]; then
                    schema_id=$(basename "$f" .prism.bin)
                    SCHEMAS+=("$schema_id")
                fi
            done
        fi

        if [ ${#SCHEMAS[@]} -eq 0 ]; then
            echo "⚠️  未检测到已部署的 Rime 输入方案"
            echo ""
            echo "请先运行 fcitx5-rime 完成 Rime 部署："
            echo "  1. 添加 fcitx5-rime 输入法"
            echo "  2. 切换到 fcitx5-rime 并使用一次"
            echo "  3. Rime 会自动部署输入方案"
            echo "  4. 然后重新运行本安装脚本"
        else
            echo "检测到 ${#SCHEMAS[@]} 个已部署的输入方案"
            echo ""

            MENU_SCHEMAS=()
            if [[ " ${SCHEMAS[*]} " =~ " luna_pinyin " ]]; then
                MENU_SCHEMAS+=("luna_pinyin")
            fi
            for s in "${SCHEMAS[@]}"; do
                if [ "$s" != "luna_pinyin" ]; then
                    MENU_SCHEMAS+=("$s")
                fi
            done

            PAGE_SIZE=10
            TOTAL=${#MENU_SCHEMAS[@]}
            PAGE=0
            TOTAL_PAGES=$(( (TOTAL + PAGE_SIZE - 1) / PAGE_SIZE ))

            while true; do
                echo "检测到以下可用输入方案（第 $((PAGE + 1))/$TOTAL_PAGES 页，共 $TOTAL 个）："
                echo ""

                START=$((PAGE * PAGE_SIZE))
                END=$((START + PAGE_SIZE))
                if [ $END -gt $TOTAL ]; then
                    END=$TOTAL
                fi

                for ((i = START; i < END; i++)); do
                    s="${MENU_SCHEMAS[$i]}"
                    display_num=$((i + 1))
                    name="${SCHEMA_NAMES[$s]:-$s}"
                    if [ "$s" = "luna_pinyin" ]; then
                        echo "  [$display_num] $s - $name（推荐，librime 自带）"
                    else
                        echo "  [$display_num] $s - $name"
                    fi
                done

                echo ""
                if [ $TOTAL_PAGES -gt 1 ]; then
                    echo "  [n] 下一页  [p] 上一页"
                fi
                echo "  [0] 使用默认 luna_pinyin"
                echo ""

                read -r -p "请输入方案编号 (默认 1): " SCHEMA_CHOICE

                if [ "$SCHEMA_CHOICE" = "n" ] || [ "$SCHEMA_CHOICE" = "N" ]; then
                    if [ $((PAGE + 1)) -lt $TOTAL_PAGES ]; then
                        PAGE=$((PAGE + 1))
                        echo ""
                        continue
                    else
                        echo "已是最后一页"
                        echo ""
                        continue
                    fi
                elif [ "$SCHEMA_CHOICE" = "p" ] || [ "$SCHEMA_CHOICE" = "P" ]; then
                    if [ $PAGE -gt 0 ]; then
                        PAGE=$((PAGE - 1))
                        echo ""
                        continue
                    else
                        echo "已是第一页"
                        echo ""
                        continue
                    fi
                fi

                if [ -z "$SCHEMA_CHOICE" ] || [ "$SCHEMA_CHOICE" = "1" ]; then
                    SELECTED_SCHEMA="${MENU_SCHEMAS[0]}"
                    break
                elif [ "$SCHEMA_CHOICE" = "0" ]; then
                    SELECTED_SCHEMA="luna_pinyin"
                    break
                elif [[ "$SCHEMA_CHOICE" =~ ^[0-9]+$ ]] && [ "$SCHEMA_CHOICE" -ge 1 ] && [ "$SCHEMA_CHOICE" -le $TOTAL ]; then
                    idx=$((SCHEMA_CHOICE - 1))
                    SELECTED_SCHEMA="${MENU_SCHEMAS[$idx]}"
                    break
                else
                    echo "无效选择，请重新输入"
                    echo ""
                    continue
                fi
            done

            mkdir -p "$VOCOTYPE_RIME_CONFIG"
            cat > "$VOCOTYPE_RIME_CONFIG/user.yaml" << EOF
# VoCoType RIME 用户配置
# 如需更换输入方案，请修改下面的 previously_selected_schema 值
var:
  previously_selected_schema: "$SELECTED_SCHEMA"
EOF

            echo ""
            echo "✓ 已选择输入方案: $SELECTED_SCHEMA"
            echo "  配置文件: $VOCOTYPE_RIME_CONFIG/user.yaml"
            echo "══════════════════════════════════════════"
        fi
    fi
else
    echo "⚠️  未找到 Fcitx5 Rime 目录：$FCITX_RIME_USER"
    echo "   请先安装并启用 fcitx5-rime，然后重新运行安装脚本"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 9. 音频设备配置和 ASR 验收
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "[9/9] 音频设备配置..."

if [ -n "$AUDIO_DEVICE" ]; then
    # 使用命令行指定的设备，直接写入配置
    echo "使用指定的音频设备: $AUDIO_DEVICE (采样率: $SAMPLE_RATE)"
    mkdir -p "$HOME/.config/vocotype"
    cat > "$HOME/.config/vocotype/audio.conf" << EOF
[audio]
device_id = $AUDIO_DEVICE
sample_rate = $SAMPLE_RATE
EOF
    echo "✓ 音频配置已保存"
elif [ "$SKIP_AUDIO" = true ]; then
    # 跳过音频配置
    echo "跳过音频配置（使用 --skip-audio）"
    echo "请稍后运行以下命令配置音频："
    echo "  $VENV_PYTHON $SCRIPT_DIR/setup-audio.py"
else
    # 交互式配置
    echo ""
    echo "现在需要配置您的麦克风设备。"
    echo "这个过程会："
    echo "  - 列出可用的音频输入设备"
    echo "  - 测试录音和播放"
    echo "  - 验证语音识别效果"
    echo ""

    if ! "$VENV_PYTHON" "$SCRIPT_DIR/setup-audio.py"; then
        echo ""
        echo "⚠️  音频配置未完成。"
        echo "请稍后运行以下命令重新配置："
        echo "  $VENV_PYTHON $SCRIPT_DIR/setup-audio.py"
        echo ""
        read -p "是否继续安装？ [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "安装已取消"
            exit 1
        fi
    fi
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 创建后台服务启动器
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "创建后台服务启动器..."
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/vocotype-fcitx5-backend" << 'EOF'
#!/bin/bash
# VoCoType Fcitx5 Backend 服务

INSTALL_DIR="$HOME/.local/share/vocotype-fcitx5"
PYTHON="$INSTALL_DIR/.venv/bin/python"
SERVER_SCRIPT="$INSTALL_DIR/backend/fcitx5_server.py"

# 检查是否已在运行
if pgrep -f "fcitx5_server.py" > /dev/null; then
    echo "VoCoType Fcitx5 Backend 已在运行"
    exit 0
fi

# 启动服务
exec "$PYTHON" "$SERVER_SCRIPT" "$@"
EOF
chmod +x "$HOME/.local/bin/vocotype-fcitx5-backend"

# 创建 systemd 用户服务
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/vocotype-fcitx5-backend.service" << EOF
[Unit]
Description=VoCoType Fcitx5 Backend Service
After=graphical-session.target

[Service]
Type=simple
ExecStart=$HOME/.local/bin/vocotype-fcitx5-backend
ExecStopPost=-/usr/bin/pkill -f "$HOME/.local/share/vocotype-fcitx5/backend/audio_recorder.py"
KillMode=mixed
Restart=on-failure
RestartSec=5s
Environment="PYTHONIOENCODING=UTF-8"

[Install]
WantedBy=default.target
EOF

if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || \
        echo "⚠️  systemctl --user daemon-reload 失败，请手动执行"
fi

echo "✓ 后台服务启动器已创建"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 完成
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ VoCoType Fcitx 5 安装完成！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📝 接下来的步骤："
echo ""
echo "1. 【重要】设置环境变量（选择一种方式）："
echo ""
echo "   方式 A - 重新登录（推荐）"
echo "     注销并重新登录桌面会话"
echo ""
echo "   方式 B - 当前终端临时设置"
echo "     export FCITX_ADDON_DIRS=~/.local/lib64/fcitx5:~/.local/lib/fcitx5:/usr/lib64/fcitx5"
echo ""
echo "2. 启动后台服务："
echo ""
echo "   systemctl --user daemon-reload"
echo "   systemctl --user enable --now vocotype-fcitx5-backend.service"
echo ""
echo "3. 重启 Fcitx 5："
echo "     fcitx5 -r"
echo ""
echo "4. 在 Fcitx 5 配置中添加 VoCoType 输入法："
echo "     fcitx5-configtool"
echo "   （在输入法列表中找到 VoCoType，添加到当前输入法）"
echo ""
echo "5. 使用方法："
echo "   - 按住 F9 说话，松开识别（语音输入）"
echo "   - 正常打字使用 Rime 拼音输入"
echo ""
echo "🎤 享受语音 + 拼音的输入体验！"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
