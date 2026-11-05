# FFmpegOffload

`FFmpegOffload.{h,m}` routes guest `ffmpeg` execve into a host `FFmpeg.framework`
(`ffmpeg_main`) with stdio forwarding.

## Default (no binary)

If `vendor/frameworks/FFmpeg.framework` is **absent**, the build:

1. Generates `Configuration/OptionalFrameworks.generated.xcconfig` with `OASES_HAVE_FFMPEG = 0`
2. Compiles `ffmpeg_offload_register()` as an empty stub

No link errors. iSH `ffmpeg` falls through to Alpine apk package if installed.

## Enable real offload

1. Build the umbrella framework with OpenMinis' script (long, network + Xcode):

```bash
# from OpenMinis repo
./deps/build_ffmpeg.sh
# copy outputs into OasesChat
mkdir -p ios/vendor/frameworks
cp -R deps/frameworks/*.framework ios/vendor/frameworks/
```

2. Rebuild OasesChat. `scripts/configure_optional_frameworks.sh` (pre-build)
   detects the framework and sets `-DOASES_HAVE_FFMPEG=1` + link flags.

3. Confirm logs: `[optional-frameworks] … (ffmpeg=yes)` and guest `ffmpeg -version`
   hits the native offload.

## Notes

- Framework binaries are **not** committed (size + license packaging).
- Sibling `libavcodec` / `libavformat` / … frameworks next to the umbrella are
  auto-linked when present.
