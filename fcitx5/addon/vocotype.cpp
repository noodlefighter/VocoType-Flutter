/*
 * VoCoType Fcitx5 Addon Implementation
 */

#include "vocotype.h"
#include <fcitx/addonfactory.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputpanel.h>
#include <fcitx/text.h>
#include <fcitx/candidatelist.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/event.h>
#include <fcitx-utils/eventdispatcher.h>
#include <cstdlib>
#include <cstdio>
#include <cstring>
#include <cerrno>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <signal.h>
#include <thread>
#include <chrono>

namespace {

std::string readRecorderLineFromFd(int fd) {
    if (fd < 0) {
        return {};
    }
    std::string audio_path;
    bool started = false;
    char ch = '\0';
    while (true) {
        ssize_t n = read(fd, &ch, 1);
        if (n == 0) {
            break;
        }
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            return {};
        }
        if (ch == '\n' || ch == '\r') {
            if (!started) {
                continue;
            }
            break;
        }
        started = true;
        audio_path.push_back(ch);
    }
    return audio_path;
}

} // namespace

namespace vocotype {

// F2 键
constexpr int PTT_KEYVAL = FcitxKey_F2;

VoCoTypeAddon::VoCoTypeAddon(fcitx::Instance* instance)
    : instance_(instance),
      ipc_client_(std::make_unique<IPCClient>("/tmp/vocotype-fcitx5.sock")) {

    // 获取安装路径
    const char* home = std::getenv("HOME");
    if (home) {
        python_venv_path_ = std::string(home) + "/.local/share/vocotype-fcitx5/.venv/bin/python";
        recorder_script_path_ = std::string(home) + "/.local/share/vocotype-fcitx5/backend/audio_recorder.py";
    } else {
        FCITX_ERROR() << "HOME environment variable not set";
    }

    FCITX_INFO() << "VoCoType Addon initialized";

    // 测试 Backend 连接
    if (ipc_client_->ping()) {
        FCITX_INFO() << "Backend connection OK";
    } else {
        FCITX_WARN() << "Backend not responding, please ensure fcitx5_server.py is running";
    }
}

VoCoTypeAddon::~VoCoTypeAddon() {
    terminateRecorderProcess();
    FCITX_INFO() << "VoCoType Addon destroyed";
}

std::vector<fcitx::InputMethodEntry> VoCoTypeAddon::listInputMethods() {
    std::vector<fcitx::InputMethodEntry> result;

    auto entry = fcitx::InputMethodEntry("vocotype", "VoCoType", "zh_CN", "vocotype");
    entry.setNativeName("语音输入");
    entry.setIcon("microphone");
    entry.setLabel("🎤");

    result.push_back(std::move(entry));
    return result;
}

void VoCoTypeAddon::keyEvent(const fcitx::InputMethodEntry& entry,
                              fcitx::KeyEvent& keyEvent) {
    auto ic = keyEvent.inputContext();

    // 获取按键信息
    auto key = keyEvent.key();
    int keyval = key.sym();
    bool is_release = keyEvent.isRelease();

    FCITX_DEBUG() << "Key event: keyval=" << keyval
                  << ", release=" << is_release
                  << ", F9=" << PTT_KEYVAL;

    // 处理 F9 键（PTT）
    if (keyval == PTT_KEYVAL) {
        if (is_release) {
            // F9 松开：停止录音并转录
            if (is_recording_) {
                stopAndTranscribe(ic);
            }
        } else {
            // F9 按下：开始录音
            if (!is_recording_) {
                startRecording(ic);
            }
        }
        keyEvent.filterAndAccept();
        return;
    }

    // 其他键：转发给 Rime
    if (!is_release) {
        // 跳过输入法切换热键
        if (isIMSwitchHotkey(key)) {
            return;
        }

        // 构建 Rime modifier mask
        int mask = 0;
        if (key.states() & fcitx::KeyState::Shift) {
            mask |= (1 << 0);  // kShiftMask
        }
        if (key.states() & fcitx::KeyState::CapsLock) {
            mask |= (1 << 1);  // kLockMask
        }
        if (key.states() & fcitx::KeyState::Ctrl) {
            mask |= (1 << 2);  // kControlMask
        }
        if (key.states() & fcitx::KeyState::Alt) {
            mask |= (1 << 3);  // kAltMask
        }

        // 调用 IPC
        try {
            RimeUIState state = ipc_client_->processKey(keyval, mask);

            // 如果有提交文本，先提交
            if (!state.commit_text.empty()) {
                commitText(ic, state.commit_text);
            }

            // 更新 UI
            updateUI(ic, state);

            // 如果被 Rime 处理，则拦截此按键
            if (state.handled) {
                keyEvent.filterAndAccept();
                return;
            }

        } catch (const std::exception& e) {
            FCITX_ERROR() << "Rime key processing failed: " << e.what();
        }
    }
}

void VoCoTypeAddon::reset(const fcitx::InputMethodEntry& entry,
                           fcitx::InputContextEvent& event) {
    auto ic = event.inputContext();
    clearUI(ic);
    ipc_client_->reset();
}

void VoCoTypeAddon::activate(const fcitx::InputMethodEntry& entry,
                              fcitx::InputContextEvent& event) {
    FCITX_DEBUG() << "VoCoType activated";
}

void VoCoTypeAddon::deactivate(const fcitx::InputMethodEntry& entry,
                                fcitx::InputContextEvent& event) {
    auto ic = event.inputContext();
    clearUI(ic);

    // 如果正在录音，停止录音但不转录
    if (is_recording_) {
        stopRecording(ic, false);
    }

    FCITX_DEBUG() << "VoCoType deactivated";
}

void VoCoTypeAddon::startRecording(fcitx::InputContext* ic) {
    if (is_recording_) {
        return;
    }
    if (recorder_busy_.load()) {
        showError(ic, "录音处理中，请稍候");
        return;
    }

    if (python_venv_path_.empty() || recorder_script_path_.empty()) {
        showError(ic, "录音配置无效");
        return;
    }

    if (!ensureRecorderRunning(ic)) {
        return;
    }

    if (!sendRecorderCommand("START\n")) {
        terminateRecorderProcess();
        showError(ic, "启动录音失败");
        return;
    }

    is_recording_ = true;

    // 显示录音状态
    auto& inputPanel = ic->inputPanel();
    fcitx::Text preedit;
    preedit.append("🎤 录音中...");
    inputPanel.setClientPreedit(preedit);
    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);

    FCITX_INFO() << "Recording started";
}

bool VoCoTypeAddon::ensureRecorderRunning(fcitx::InputContext* ic) {
    if (recorder_pid_ > 0 && recorder_stdout_fd_ >= 0 && recorder_stdin_fd_ >= 0) {
        int status = 0;
        pid_t result = waitpid(recorder_pid_, &status, WNOHANG);
        if (result == 0) {
            return true;
        }
        terminateRecorderProcess();
    }

    int stdin_pipe[2];
    int stdout_pipe[2];
    if (pipe(stdin_pipe) != 0) {
        showError(ic, "启动录音失败");
        return false;
    }
    if (pipe(stdout_pipe) != 0) {
        close(stdin_pipe[0]);
        close(stdin_pipe[1]);
        showError(ic, "启动录音失败");
        return false;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(stdin_pipe[0]);
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);
        showError(ic, "启动录音失败");
        return false;
    }

    if (pid == 0) {
        dup2(stdin_pipe[0], STDIN_FILENO);
        dup2(stdout_pipe[1], STDOUT_FILENO);

        close(stdin_pipe[0]);
        close(stdin_pipe[1]);
        close(stdout_pipe[0]);
        close(stdout_pipe[1]);

        execl(python_venv_path_.c_str(),
              python_venv_path_.c_str(),
              recorder_script_path_.c_str(),
              "--loop",
              static_cast<char*>(nullptr));
        _exit(127);
    }

    close(stdin_pipe[0]);
    close(stdout_pipe[1]);

    if (stdout_pipe[0] < 0) {
        close(stdin_pipe[1]);
        kill(pid, SIGTERM);
        waitpid(pid, nullptr, 0);
        showError(ic, "启动录音失败");
        return false;
    }

    recorder_pid_ = pid;
    recorder_stdin_fd_ = stdin_pipe[1];
    recorder_stdout_fd_ = stdout_pipe[0];
    return true;
}

void VoCoTypeAddon::stopAndTranscribe(fcitx::InputContext* ic) {
    stopRecording(ic, true);
}

void VoCoTypeAddon::stopRecording(fcitx::InputContext* ic, bool transcribe) {
    if (!is_recording_) {
        return;
    }

    is_recording_ = false;
    recorder_busy_.store(true);

    if (ic) {
        if (transcribe) {
            auto& inputPanel = ic->inputPanel();
            fcitx::Text preedit;
            preedit.append("⏳ 识别中...");
            inputPanel.setClientPreedit(preedit);
            ic->updatePreedit();
            ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
        } else {
            clearUI(ic);
        }
    }

    int stdin_fd = recorder_stdin_fd_;
    int stdout_fd = recorder_stdout_fd_;

    auto ic_ref =
        ic ? ic->watch() : fcitx::TrackableObjectReference<fcitx::InputContext>();

    std::thread([this, stdin_fd, stdout_fd, transcribe, ic_ref]() mutable {
        if (stdin_fd >= 0) {
            const char* stop_cmd = "STOP\n";
            ssize_t written = write(stdin_fd, stop_cmd, strlen(stop_cmd));
            if (written < 0) {
                recorder_busy_.store(false);
                terminateRecorderProcess();
                if (transcribe) {
                    instance_->eventDispatcher().scheduleWithContext(
                        ic_ref, [this, ic_ref]() {
                            auto* ic_ptr = ic_ref.get();
                            if (ic_ptr) {
                                showError(ic_ptr, "录音失败");
                            }
                        });
                }
                return;
            }
        }

        std::string audio_path = readRecorderLineFromFd(stdout_fd);
        recorder_busy_.store(false);
        if (audio_path.empty()) {
            terminateRecorderProcess();
            if (transcribe) {
                instance_->eventDispatcher().scheduleWithContext(
                    ic_ref, [this, ic_ref]() {
                        auto* ic_ptr = ic_ref.get();
                        if (ic_ptr) {
                            showError(ic_ptr, "录音失败");
                        }
                    });
            }
            return;
        }

        if (!transcribe) {
            std::remove(audio_path.c_str());
            return;
        }

        TranscribeResult result = ipc_client_->transcribeAudio(audio_path);
        std::remove(audio_path.c_str());

        instance_->eventDispatcher().scheduleWithContext(
            ic_ref, [this, ic_ref, result]() {
                auto* ic_ptr = ic_ref.get();
                if (!ic_ptr) {
                    return;
                }
                if (result.success && !result.text.empty()) {
                    commitText(ic_ptr, result.text);
                } else if (!result.success) {
                    showError(ic_ptr,
                              result.error.empty() ? "转录失败" : result.error);
                } else {
                    clearUI(ic_ptr);
                }
            });
    }).detach();

    FCITX_INFO() << "Recording stopped";
}

bool VoCoTypeAddon::sendRecorderCommand(const char* command) {
    if (recorder_stdin_fd_ < 0) {
        return false;
    }
    size_t len = strlen(command);
    ssize_t written = write(recorder_stdin_fd_, command, len);
    return written == static_cast<ssize_t>(len);
}

void VoCoTypeAddon::terminateRecorderProcess() {
    if (recorder_pid_ <= 0 && recorder_stdout_fd_ < 0 && recorder_stdin_fd_ < 0) {
        return;
    }

    if (recorder_stdin_fd_ >= 0) {
        const char* quit_cmd = "QUIT\n";
        write(recorder_stdin_fd_, quit_cmd, strlen(quit_cmd));
        close(recorder_stdin_fd_);
    }
    recorder_stdin_fd_ = -1;

    if (recorder_stdout_fd_ >= 0) {
        close(recorder_stdout_fd_);
        recorder_stdout_fd_ = -1;
    }

    if (recorder_pid_ > 0) {
        int status = 0;
        while (waitpid(recorder_pid_, &status, 0) < 0 && errno == EINTR) {
        }
        recorder_pid_ = -1;
    }
    is_recording_ = false;
    recorder_busy_.store(false);
}

void VoCoTypeAddon::updateUI(fcitx::InputContext* ic, const RimeUIState& state) {
    auto& inputPanel = ic->inputPanel();

    // 更新预编辑
    if (!state.preedit_text.empty()) {
        fcitx::Text preedit;
        preedit.append(state.preedit_text, fcitx::TextFormatFlag::Underline);
        inputPanel.setClientPreedit(preedit);
        // 注意：Fcitx5 的 InputPanel 可能没有直接的 setCursor 方法
        // 光标位置通常通过 preedit 的属性设置
        ic->updatePreedit();
    } else {
        inputPanel.setClientPreedit(fcitx::Text());
        ic->updatePreedit();
    }

    // 更新候选词
    if (!state.candidates.empty()) {
        auto candidateList = std::make_unique<fcitx::CommonCandidateList>();
        candidateList->setPageSize(state.page_size);
        candidateList->setCursorPositionAfterPaging(
            fcitx::CursorPositionAfterPaging::ResetToFirst);

        for (size_t i = 0; i < state.candidates.size(); ++i) {
            const auto& [text, comment] = state.candidates[i];
            fcitx::Text candidate_text;
            candidate_text.append(text);
            if (!comment.empty()) {
                candidate_text.append(" ");
                candidate_text.append(comment);
            }
            candidateList->append<fcitx::DisplayOnlyCandidateWord>(candidate_text);
        }

        int cursor_index = state.highlighted_index;
        if (cursor_index < 0 ||
            cursor_index >= static_cast<int>(state.candidates.size())) {
            cursor_index = 0;
        }
        candidateList->setGlobalCursorIndex(cursor_index);
        inputPanel.setCandidateList(std::move(candidateList));
    } else {
        inputPanel.setCandidateList(nullptr);
    }

    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
}

void VoCoTypeAddon::clearUI(fcitx::InputContext* ic) {
    auto& inputPanel = ic->inputPanel();
    inputPanel.reset();
    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
}

void VoCoTypeAddon::commitText(fcitx::InputContext* ic, const std::string& text) {
    clearUI(ic);
    ic->commitString(text);
    FCITX_INFO() << "Committed text: " << text;
}

void VoCoTypeAddon::showError(fcitx::InputContext* ic, const std::string& error) {
    auto& inputPanel = ic->inputPanel();
    fcitx::Text preedit;
    preedit.append("❌ " + error);
    inputPanel.setClientPreedit(preedit);
    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);

    // 简化：不自动清除，等待用户下次按键
    // 2 秒自动清除在 Fcitx5 中需要更复杂的实现
}

bool VoCoTypeAddon::isIMSwitchHotkey(const fcitx::Key& key) const {
    // 只拦截 Super+Space (输入法切换)，不拦截 Ctrl+Space (中英切换)
    if (key.sym() == FcitxKey_space) {
        if (key.states() & fcitx::KeyState::Super) {
            return true;
        }
    }

    // Ctrl+Shift 或 Alt+Shift
    if (key.sym() == FcitxKey_Shift_L || key.sym() == FcitxKey_Shift_R) {
        if (key.states() & fcitx::KeyState::Ctrl) {
            return true;
        }
        if (key.states() & fcitx::KeyState::Alt) {
            return true;
        }
    }

    return false;
}

} // namespace vocotype

// Fcitx5 插件注册
class VoCoTypeAddonFactory : public fcitx::AddonFactory {
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
        return new vocotype::VoCoTypeAddon(manager->instance());
    }
};

FCITX_ADDON_FACTORY(VoCoTypeAddonFactory);
