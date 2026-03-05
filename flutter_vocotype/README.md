# VoCoType Flutter Frontend

Linux desktop frontend for VoCoType fcitx5 backend.

## Install (Recommended)

From repo root:

```bash
bash scripts/install-flutter_vocotype.sh
vocotype-flutter
```

## Run Manually

1. Start Flutter app:

```bash
cd flutter_vocotype
flutter pub get
flutter run -d linux
```

2. The app will auto-start backend if `/tmp/vocotype-fcitx5.sock` is unavailable.

## Behavior

- Hold `F2`: start recording
- Release `F2`: stop + transcribe
- Backend returns ASR result to UI and types text into current focused app
- `去除句号` switch writes `~/.config/vocotype/fcitx5-backend.json` directly

## Text Input Backend

- Configurable in UI: `Auto` / `Xdotool` / `Wtype` / `Shift+Insert Paste`
- `Auto` first tries `Shift+Insert Paste`; if it fails, it falls back to `Wtype` on Wayland and `Xdotool` on non-Wayland sessions
- Optional env override before launch:

```bash
export VOCOTYPE_TYPE_BACKEND=auto   # auto | xdotool | wtype | shift_insert
```
