# Third-party code and references

This project is licensed under the GNU General Public License v3.0 (see `LICENSE`). It includes, or is built with, the
following work by others. Their licenses are compatible with the GPLv3 and their notices are kept with the code.

## Included in this repository

| Component | Where | License | Use |
|---|---|---|---|
| **Ryujinx** shader translator: `Ryujinx.Graphics.Shader`, `Spv.Generator` and a few `Ryujinx.Common` helpers, from the [Ryujinx-Nextendo](https://github.com/NextendoNetwork/Ryujinx-Nextendo) continuation of Ryujinx (commit `bd50fbf8`) | `third_party/ryujinx-shader/` | MIT, © Ryujinx Team and Contributors (`third_party/ryujinx-shader/LICENSE.txt`) | Translates the game's Maxwell shaders to SPIR-V on the device. This project's changes are in `CHANGES.patch`. |
| **SPIRV-Cross** (vulkan-sdk-1.4.357.0) | `third_party/spirv-cross/` | Apache-2.0, © The Khronos Group and contributors (`third_party/spirv-cross/LICENSE`) | SPIR-V to Metal Shading Language. Unmodified. |
| **Zstandard** decompressor 1.5.6 | `runtime/third_party/zstddeclib.c` | BSD, © Meta Platforms (`runtime/third_party/zstd-LICENSE`) | The game's `.zs` archives. |
| **bcdec** 0.985 | `runtime/third_party/bcdec.h` | MIT or Unlicense, © Sergii Kudlai | BC1-BC7 texture decoding for the launcher's artwork. |

## Used while building (not in this repository)

| Component | License | Use |
|---|---|---|
| **.NET** runtime and NativeAOT compiler | MIT, © .NET Foundation and Contributors | Compiles the shader translator ahead of time into the app (no JIT). The NativeAOT runtime libraries are linked into the app; their notices: the `THIRD-PARTY-NOTICES.TXT` of the `Microsoft.NETCore.App.Runtime.NativeAOT.ios-arm64` package. |
| **astc-encoder** 5.2.0 (`tools/texconv`, optional) | Apache-2.0, © Arm Limited | Converting textures for the optional ASTC RomFS image. |

## Algorithms, formats and behaviour learned from

No code from these projects is included unless listed above; they documented how the Switch works, and parts of this
runtime were written to match them.

| Project | License | What |
|---|---|---|
| [Ryujinx](https://github.com/Ryujinx/Ryujinx) | MIT | Audio renderer state layouts and effect algorithms (`services/audio.c`), applet and software-keyboard structures (`services/applet.c`), the default Mii table (`services/misc.c`, generated from `DefaultMii.cs`), LDN command ids and structures (`services/ldn.c`), IPC message handling (`ipc.c`). |
| [Atmosphère](https://github.com/Atmosphere-NX/Atmosphere) | GPL-2.0 | Kernel synchronization semantics (condition variables, address arbiter) and HIPC details, reimplemented in `kernel.c` / `ipc.c` (no code copied). |
| [yuzu](https://github.com/yuzu-emu/yuzu) | GPL-2.0-or-later | The shared font format (`services/pl.c`). |
| [switchbrew](https://switchbrew.org), [hactool](https://github.com/SciresM/hactool), [libnx](https://github.com/switchbrew/libnx) | various | XCI / NCA / RomFS / NSO formats and key derivation, service interfaces, software keyboard configuration. |
| FXAA 3.11 by Timothy Lottes (NVIDIA) | NVIDIA's FXAA license | The anti-aliasing pass (`gfx_cmd.m`), a Metal rewrite of the FXAA 3.11 quality preset. |
