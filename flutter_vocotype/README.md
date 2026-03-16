# VoCoType Flutter Frontend

Linux desktop frontend for VoCoType. The app talks to a bundled Python backend over `/tmp/vocotype-backend.sock`.

## Install

From repo root:

```bash
bash scripts/install-flutter_vocotype.sh
vocotype-flutter
```

## Run in Development

```bash
cd flutter_vocotype
flutter pub get
flutter run -d linux
```

If the socket is unavailable, the app auto-starts the local backend runtime.

## Behavior

- Hold `F2`: start recording
- Release `F2`: stop recording and transcribe
- Recognized text is injected into the current focused app
- `去除句号` writes `~/.config/vocotype/backend.json`

## Text Input Backend

- UI options: `Auto`, `Xdotool`, `Wtype`, `Shift+Insert Paste`
- `Auto` tries `Shift+Insert Paste` first, then falls back to `Wtype` on Wayland and `Xdotool` elsewhere

```bash
export VOCOTYPE_TYPE_BACKEND=auto  # auto | xdotool | wtype | shift_insert
```
