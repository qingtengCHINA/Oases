# Notices

Oases Chat for iOS — Copyright (C) 2025–2026 QingTeng Studio.
Licensed under the GNU General Public License, version 3 (see `LICENSE`),
with the App Store statement in `LICENSE.IOS`.

## Built on

- **iSH** — https://github.com/ish-app/ish (ARM64 fork: https://github.com/OpenMinis/ish-arm64).
  GPL-3.0 (later contributions also GPL-2.0), with the App Store statement in
  `vendor/iSH/LICENSE.IOS`. The Linux emulator under Ogent (engineering mode)
  is iSH; `libish`, `libish_emu` and `libfakefs` are linked into the app.
  The vendored copy and its build notes are in `vendor/iSH/`.
- **OpenMinis** — https://github.com/OpenMinis/OpenMinis. GPL-3.0.
  Parts of the agent, model-provider, tool and interface code are ported
  from OpenMinis; files that were ported say so in their header comments.

## Other components

The app's Settings > About > Open Source Licenses page lists every other
component with its full license text; the same texts are in
`OasesChat/Resources/Licenses/` (index: `licenses.json`). In short:
MinisSkills, SwiftAnthropic, SwiftMath (fonts: SIL OFL 1.1 / GUST),
RealTimeCutVADLibrary (with ONNX Runtime, WebRTC audio processing and the
Silero VAD model), libraries.dev kits (ThinkingOrbsKit, BorderBeamKit,
BotAvatarsKit, MetalFxKit), cppjieba, KaTeX, sensory-ui, Cicada, Paper
Shaders (“Powered by Paper Shaders: https://shaders.paper.design”),
expo-backdrop, LobeHub Icons, HyperFrames, swift-cmark.

## Ogent's Linux environment

`OasesChat/Resources/AlpineFakefs/` is an Alpine Linux 3.21 root file system
(257 packages). Its programs run inside the emulator as separate programs;
they are not linked into the app. Each package keeps its own license
(recorded in `data/lib/apk/db/installed`), among them GPL-2.0, GPL-3.0,
LGPL-2.1 and MPL-2.0. Build recipes and sources:
https://gitlab.alpinelinux.org/alpine/aports/-/tree/3.21-stable and
https://dl-cdn.alpinelinux.org/alpine/v3.21/. `scripts/rootfs/` rebuilds the
file system.
