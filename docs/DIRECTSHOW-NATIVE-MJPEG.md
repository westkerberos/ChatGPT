# WEST Gaming DirectShow native MJPEG recorder

**Component:** OBS Studio Windows module `win-dshow.dll`  
**Target:** OBS Studio 33.0.3, Windows x64  
**Current source branch:** `obs-33.0.3-native-mjpeg`  
**Patch file:** [obs-33.0.0-beta4-native-mjpeg.patch](../obs-33.0.0-beta4-native-mjpeg.patch)

This is a DirectShow modification to OBS Studio itself. It is **not** an Aitum Vertical or Aitum Multistream plugin. Keep its source, build and release process independent from the two Aitum forks.

## Intended behavior

When a configured DirectShow camera source is active, and the user enables native MJPEG recording, the module writes the camera's original MJPEG packets to a MOV file without re-encoding video. The feature activates only when the capture format is MJPEG and the selected frame size is at least 3840×2160.

Configuration fields:
- `native_mjpeg_record`: enable/disable native recording.
- `native_mjpeg_record_dir`: existing output directory.
- `native_mjpeg_audio_source`: OBS audio source to capture (default `Mic/Aux`).

If the audio source is found, the patch adds PCM S16LE stereo audio. If not found, it warns and records video only. The recorder includes timestamp checks, dropped-frame warnings and diagnostic logs.

## OBS 33.0.3 build evidence

- Branch: [`obs-33.0.3-native-mjpeg`](https://github.com/westkerberos/ChatGPT/tree/obs-33.0.3-native-mjpeg).
- Build-tested commit: `f4ef30142ca4fe70fea712b39322fb2fb6c9fdcf`.
- Workflow: [#45898711824](https://github.com/westkerberos/ChatGPT/actions/runs/45898711824).
- Result: patch application, source-marker validation, CMake configuration, `win-dshow` compilation, DLL/PDB collection and artifact upload all succeeded against OBS tag **33.0.3**.
- Artifact: `obs-33.0.3-native-mjpeg-win-dshow`.
- Artifact SHA-256: `06553fda76c1a974e8610a00ac6a41ae6979aabee072ebfc3cc88226d11a3b64`.
- DLL SHA-256: `EBD7B77E9DA422F9A6ED72BC4661C8387E8889D1BCC1D5EFD1BAC2FCF1ECF9AD`.

The patch now serializes recorder initialization with capture callbacks and reports the measured source frame rate. The artifact is a successful OBS 33.0.3 Windows x64 build, not a camera-runtime certification. It still needs an OBS-side test with the actual MJPEG camera mode, audio source, MOV integrity and A/V synchronization before production use.

The earlier OBS 33.0.1 build is historical evidence only; do not install that DLL into OBS 33.0.3.

## Runtime validation still required

- Confirm the camera actually exposes MJPEG at 3840×2160 or higher.
- Test recording with audio source present and absent.
- Test start/stop, source hide/show, deactivation/reactivation and long recordings.
- Check MOV integrity, timestamps, dropped-frame behavior and audio/video synchronization.
- Test output directories containing non-ASCII characters.## Rules

- Never install the OBS 33.0.1 DLL into OBS 33.0.3 and call it compatible.
- Never replace the complete OBS installation with this one module; install only the validated DLL in the appropriate OBS 33 plugin folder.
- Build against the exact OBS tag and toolchain in the workflow, and publish SHA-256 with each DLL.
- Update the [complete WEST Gaming streaming stack document](https://github.com/westkerberos/obs-vertical-canvas/blob/feature/tiktok-native-ebc-combined/docs/WEST-GAMING-STREAMING-STACK.md) whenever this module changes.
