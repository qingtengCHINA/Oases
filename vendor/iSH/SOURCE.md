# iSH — source and license

Everything under `vendor/iSH/` comes from, or is built from, **iSH**, a
usermode Linux emulator for iOS:

- Upstream: <https://github.com/ish-app/ish>
- ARM64 fork actually vendored here (adds the native AArch64 guest backend,
  `ISHShellExecutor`, `DebugServer`, Native Offload, bind mounts):
  <https://github.com/OpenMinis/ish-arm64>

The libraries were built from the fork at commit
`d0767aeed678d5bae5d12c7134b324f3a49d961c` (branch `master`, downloaded
2026-06-26; the commit is recorded in the archive's zip comment):
<https://github.com/OpenMinis/ish-arm64/tree/d0767aeed678d5bae5d12c7134b324f3a49d961c>.

Complete corresponding source, kept here so it stays available:

- `source/ish-arm64-d0767aeed678d5bae5d12c7134b324f3a49d961c.zip` — that
  commit's source tree, unmodified.
- `source/build-changes.patch` — the only changes made before building: the
  deployment target (iOS 11 → 15) and the signing team in `app/Project.xcconfig`,
  `iSH.xcodeproj` and `deps/libarchive.xcodeproj`. No source file was changed.

## What is vendored

| Path | Origin |
|---|---|
| `lib/{iphoneos,iphonesimulator}/libish.a`, `libish_emu.a`, `libfakefs.a` | Prebuilt from the fork above (arm64 only) |
| `runtime/`, `include/` | Fork's `app/` bridge sources (`ISHShellExecutor`, `DebugServer`, runtime init), modified for Oases Chat |
| `offloads/`, `support/`, `diagnostics/`, `shared/` | Native Offload bridges derived from the fork, extended for Oases Chat |

## License

iSH is licensed under the GNU General Public License v3 (`COPYING`), with
later contributions also under GPLv2 — see `LICENSE.md`. The additional
permission in `LICENSE.IOS` (no enforcement of conflicts that arise *solely*
from App Store terms) applies only when the GPL is otherwise complied with,
including providing users the complete corresponding source code and the
license text.

The app shows these texts under Settings → 数据与隐私 → 开源许可
(`OasesChat/Resources/Licenses/`). Keep the copies there in sync with this
directory.

Distributing the app with these libraries statically linked has GPL
consequences for the app as a whole; that is a legal decision, not an
engineering one, and is tracked outside this file.
