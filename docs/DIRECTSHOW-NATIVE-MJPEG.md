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

## Build evidence

### OBS 33.0.1 — successful

- Branch: [`obs-33.0.1-build`](https://github.com/westkerberos/ChatGPT/tree/obs-33.0.1-build).
- Workflow: [#43638792702](https://github.com/westkerberos/ChatGPT/actions/runs/43638792702).
- Result: patch applied, markers verified, CMake configured, `win-dshow` built, DLL/PDB/SHA-256 uploaded.
- Artifact is a temporary GitHub Actions artifact, not a supported release and not a binary for OBS 33.0.3.

### OBS 33.0.3 — patch applied, build blocked by runner dependency

- Branch: [`obs-33.0.3-native-mjpeg`](https://github.com/westkerberos/ChatGPT/tree/obs-33.0.3-native-mjpeg).
- Commit: `561d3e30f14b5444cb04edaf5d6c77f29c743903`.
- Workflow: [#45856617485](https://github.com/westkerberos/ChatGPT/actions/runs/45856617485).
- Patch dry-run/application, source-marker validation and CMake configure completed successfully.
- Build then failed while compiling OBS's DirectShow/virtual-camera dependency because the GitHub Windows runner did not have Visual C++ ATL headers `atlcomcli.h` and `atlstr.h`.
- This does **not** establish a source incompatibility with OBS 33.0.3. It also does not establish a successful DLL build. No OBS 33.0.3 DShow DLL has been produced yet.

Next CI task: add the required Visual Studio ATL component to the runner image (or use a runner/image that already includes it), rerun the target, then verify the actual `win-dshow.dll` output and SHA-256.

## Code review risk before production

The current patch calls `device.Start()` before `NativeMjpegRecorder::Start()` in `DShowInput::Activate`. Encoded-frame callbacks may therefore begin while recorder setup is still mutating the format context, stream pointers and header state. `Active()`, `Write()` and `WriteAudio()` use a mutex, but `Start()` does not hold it over initialization. This is a plausible data race from source inspection, not a reproduced crash. Fix start ordering/locking and run concurrent callback/deactivate tests before production use.

Additional tests: non-ASCII Windows paths, source hide/show, deactivation/reactivation, stop while callbacks are running, long recordings, MOV integrity and audio/video synchronization.

## Rules

- Never install the OBS 33.0.1 DLL into OBS 33.0.3 and call it compatible.
- Never replace the complete OBS installation with this one module; install only the validated DLL in the appropriate OBS 33 plugin folder.
- Build against the exact OBS tag and toolchain in the workflow, and publish SHA-256 with each DLL.
- Update the [complete WEST Gaming streaming stack document](https://github.com/westkerberos/obs-vertical-canvas/blob/feature/tiktok-native-ebc-combined/docs/WEST-GAMING-STREAMING-STACK.md) whenever this module changes.
