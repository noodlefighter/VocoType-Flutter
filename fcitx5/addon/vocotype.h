/*
 * VoCoType Fcitx5 Addon
 *
 * 语音 + Rime 拼音输入法
 * - F9: 按住录音，松开识别
 * - 其他键: Rime 拼音输入
 */

#ifndef VOCOTYPE_ADDON_H
#define VOCOTYPE_ADDON_H

#include <fcitx/addoninstance.h>
#include <fcitx/instance.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/inputmethodentry.h>
#include <fcitx/inputcontextproperty.h>
#include <memory>
#include <string>
#include <sys/types.h>
#include <atomic>
#include <vector>

#include "ipc_client.h"

namespace vocotype {

/**
 * VoCoType Addon（同时也是输入法引擎）
 */
class VoCoTypeAddon : public fcitx::InputMethodEngine {
public:
    VoCoTypeAddon(fcitx::Instance* instance);
    ~VoCoTypeAddon();

    // 返回输入法列表（必须实现，否则 Fcitx5 找不到输入法）
    std::vector<fcitx::InputMethodEntry> listInputMethods() override;

    void keyEvent(const fcitx::InputMethodEntry& entry,
                  fcitx::KeyEvent& keyEvent) override;

    void reset(const fcitx::InputMethodEntry& entry,
               fcitx::InputContextEvent& event) override;

    void activate(const fcitx::InputMethodEntry& entry,
                  fcitx::InputContextEvent& event) override;

    void deactivate(const fcitx::InputMethodEntry& entry,
                    fcitx::InputContextEvent& event) override;

private:
    /**
     * F9 按下：开始录音
     */
    void startRecording(fcitx::InputContext* ic);

    /**
     * F9 松开：停止录音并转录
     */
    void stopAndTranscribe(fcitx::InputContext* ic);

    /**
     * 停止录音，可选择是否转录
     */
    void stopRecording(fcitx::InputContext* ic, bool transcribe);

    /**
     * 更新 UI（预编辑、候选词）
     */
    void updateUI(fcitx::InputContext* ic, const RimeUIState& state);

    /**
     * 清除 UI
     */
    void clearUI(fcitx::InputContext* ic);

    /**
     * 提交文本
     */
    void commitText(fcitx::InputContext* ic, const std::string& text);

    /**
     * 显示错误信息
     */
    void showError(fcitx::InputContext* ic, const std::string& error);

    /**
     * 检查是否是输入法切换热键
     */
    bool isIMSwitchHotkey(const fcitx::Key& key) const;

    bool ensureRecorderRunning(fcitx::InputContext* ic);
    bool sendRecorderCommand(const char* command);
    void terminateRecorderProcess();

    fcitx::Instance* instance_;
    std::unique_ptr<IPCClient> ipc_client_;

    // 录音状态
    bool is_recording_ = false;
    pid_t recorder_pid_ = -1;
    int recorder_stdin_fd_ = -1;
    int recorder_stdout_fd_ = -1;
    std::atomic<bool> recorder_busy_{false};

    // Python 脚本路径（安装时配置）
    std::string python_venv_path_;
    std::string recorder_script_path_;
};

} // namespace vocotype

#endif // VOCOTYPE_ADDON_H
