# Third-Party Notices

This project depends on third-party software and models. Each component is
covered by its own license; consult the upstream project for the authoritative
license text.

Runtime dependencies (from requirements.txt / pyproject.toml):
- sounddevice 0.5.2 - https://github.com/spatialaudio/python-sounddevice
- librosa 0.11.0 - https://github.com/librosa/librosa
- soundfile 0.13.1 - https://github.com/bastibe/python-soundfile
- funasr_onnx 0.4.1 - https://github.com/modelscope/FunASR
- jieba 0.42.1 - https://github.com/fxsjy/jieba
- modelscope 1.30.0 - https://github.com/modelscope/modelscope

Models (downloaded via ModelScope):
- iic/speech_paraformer-large_asr_nat-zh-cn-16k-common-vocab8404-onnx
- iic/speech_fsmn_vad_zh-cn-16k-common-onnx
- iic/punc_ct-transformer_zh-cn-common-vocab272727-onnx

Check the corresponding model cards and licenses on ModelScope before
redistribution or commercial use.
