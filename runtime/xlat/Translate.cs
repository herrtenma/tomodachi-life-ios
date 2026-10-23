// On-device shader translation (linked into the app as a NativeAOT static library, no JIT): one Maxwell stage the game
// binds -> SPIR-V + a JSON description of its resources, with Ryujinx's shader translator (third_party/ryujinx-shader).
// SPIRV-Cross (xlat_msl.cpp) then makes MSL, and MslFix.cs adapts that to Metal's limits.
//
// Inputs (captured by runtime/src/shaders.c when the game calls nvnProgramSetShaders):
//   code  0x30-byte NVN header, 0x50-byte SPH, Maxwell code; compute: NVN header magic 0x12345679, no SPH, code at +0x100
//   c1    driver constant buffer 1 (needed for BRX jump tables)
//   ctl   compute only: the GLSLC control section (local size, shared/local memory)
//
// Binding layout (also what MSL slots become, via SPIRV-Cross's decoration bindings):
//   set 0 uniform buffers   binding 0 = Ryujinx support buffer (render scale etc.),
//                           guest cbufs 1, 2, ... in declaration order  -> [[buffer(n)]]
//   set 1 storage buffers   binding = 16, 17, ...                     -> [[buffer(n)]]
//   set 2 textures          binding = 0, 1, ...                       -> [[texture(n)]] + [[sampler(n)]]
//   set 3 images            binding = 24, 25, ...                     -> [[texture(n)]]
// The JSON maps each binding back to the guest resource (cbuf slot, texture handle).
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;

namespace NxXlat
{
    class Accessor : IGpuAccessor
    {
        readonly byte[] _code, _c1, _ctl;
        int _ubo = 1, _ssbo = 16, _tex, _img = 24;   // binding 0 = Ryujinx's support buffer
        public readonly StringBuilder Warnings = new();

        public Accessor(byte[] code, byte[] c1, byte[] ctl) => (_code, _c1, _ctl) = (code, c1, ctl);
        public void Log(string message) => Warnings.AppendLine(message);

        // Compute: GLSLC control section words (+0x708 is the code offset 0x100): +0x748/+0x74C/+0x750 local size,
        // +0x754 shared memory bytes, +0x7F8 local (scratch) memory bytes.
        int Ctl(int offset) => _ctl != null ? BitConverter.ToInt32(_ctl, offset) : throw new InvalidDataException("compute shader without control section");
        public int QueryComputeLocalSizeX() => Ctl(0x748);
        public int QueryComputeLocalSizeY() => Ctl(0x74C);
        public int QueryComputeLocalSizeZ() => Ctl(0x750);
        public int QueryComputeSharedMemorySize() => Ctl(0x754);
        public int QueryComputeLocalMemorySize() => Ctl(0x7F8) != 0 ? Ctl(0x7F8) : 0x1000;

        // Driver cbuf 1 (the program's constants). The decoder reads BRX jump tables from it; without it every BRX
        // target becomes offset 0, which turns into an endless loop on the GPU.
        public uint ConstantBuffer1Read(int offset)
        {
            if (_c1 == null || offset < 0 || offset + 4 > _c1.Length)
                throw new InvalidDataException($"cbuf 1 read at {offset:x} outside the captured data ({_c1?.Length ?? 0} bytes)");
            return BitConverter.ToUInt32(_c1, offset);
        }

        public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize)
        {
            int start = (int)Math.Min(address, (ulong)_code.Length);
            int size = Math.Max(minimumSize, _code.Length - start);
            var buf = new byte[(size + 7) & ~7];
            Array.Copy(_code, start, buf, 0, Math.Min(buf.Length, _code.Length - start));
            var words = new ulong[buf.Length / 8];
            Buffer.BlockCopy(buf, 0, words, 0, buf.Length);
            return words;
        }

        public SetBindingPair CreateConstantBufferBinding(int index) => new(0, _ubo++);
        public SetBindingPair CreateStorageBufferBinding(int index) => new(1, _ssbo++);
        // Cbuf texture arrays (BindlessToArray, length below) take ArraySlots Metal slots: MslFix shrinks them and
        // indexes them through a per-draw map (same constant there).
        public const int ArraySlots = 96;
        public SetBindingPair CreateTextureBinding(int count, bool isBuffer) { var b = new SetBindingPair(2, _tex); _tex += count > 1 ? ArraySlots : count; return b; }
        public SetBindingPair CreateImageBinding(int count, bool isBuffer) { var b = new SetBindingPair(3, _img); _img += count; return b; }
        public int QuerySamplerArrayLengthFromPool() => 1;
        // BindlessToArray: a texture handle loaded from a cbuf with a dynamic offset becomes an array over the cbuf,
        // element i = handle at byte 8i, index clamped to length - 1. The game picks the handle per pixel (material
        // id << 8 + offset), so the array must cover the whole cbuf (64 KB).
        public int QueryTextureArrayLengthFromBuffer(int slot) => 0x10000 / 8;
        public int QueryTextureArrayLengthFromPool() => 1;

        // What Metal (through SPIRV-Cross) can do.
        public bool QueryHostSupportsGeometryShader() => false;
        public bool QueryHostSupportsGeometryShaderPassthrough() => false;
        public bool QueryHostSupportsTransformFeedback() => false;
        public bool QueryTransformFeedbackEnabled() => false;
        public bool QueryHostSupportsViewportMask() => false;
        public bool QueryHostSupportsFragmentShaderInterlock() => false;
        public bool QueryHostSupportsLayerVertexTessellation() => false;
        public bool QueryHostSupportsViewportIndexVertexTessellation() => false;
        public bool QueryHostSupportsDepthClipControl() => false;   // Metal clips z to [0, w]

        // Fixed-function state the translator bakes in. The game sets nvnDeviceSetDepthMode(0) = NEAR_IS_MINUS_W
        // (OpenGL-style -1..1 clip z), so vertex shaders remap z to 0..1 for Metal; nvnDeviceSetWindowOriginMode(1) =
        // upper-left, like Metal.
        public GpuGraphicsState QueryGraphicsState() => new(
            false, InputTopology.Points, false, TessPatchType.Triangles, TessSpacing.EqualSpacing,
            false, false, false,
            true,                                   // depthMode: -1..1
            false, 1f, AlphaTestOp.Always, 0f, default, true, default, false,
            false,                                  // yNegateEnabled
            true,                                   // originUpperLeft
            false);
    }

    public static unsafe class Exports
    {
        static byte[] Copy(byte* p, int n) => p == null || n <= 0 ? null : new ReadOnlySpan<byte>(p, n).ToArray();

        static byte* Alloc(ReadOnlySpan<byte> data, bool terminate)
        {
            byte* p = (byte*)NativeMemory.Alloc((nuint)(data.Length + (terminate ? 1 : 0)));
            data.CopyTo(new Span<byte>(p, data.Length));
            if (terminate) p[data.Length] = 0;
            return p;
        }
        static byte* AllocString(string s) => Alloc(Encoding.UTF8.GetBytes(s), true);

        // Returns 0 and sets *spv / *spvLen / *json (free with nxsh_free), or -1 and sets *err.
        [UnmanagedCallersOnly(EntryPoint = "nxsh_translate")]
        public static int Translate(byte* code, int codeLen, byte* c1, int c1Len, byte* ctl, int ctlLen,
                                    byte** spv, int* spvLen, byte** json, byte** err)
        {
            *spv = null; *json = null; *err = null; *spvLen = 0;
            try
            {
                byte[] codeB = Copy(code, codeLen);
                bool compute = BitConverter.ToUInt32(codeB, 0) == 0x12345679;
                var acc = new Accessor(codeB, Copy(c1, c1Len), Copy(ctl, ctlLen));
                var ctx = Translator.CreateContext(compute ? 0x100UL : 0x30UL, acc,
                    new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, compute ? TranslationFlags.Compute : TranslationFlags.None));
                ShaderProgram prog = ctx.Translate();
                *spv = Alloc(prog.BinaryCode, false);
                *spvLen = prog.BinaryCode.Length;
                *json = Alloc(Describe(prog.Info, acc), true);
                return 0;
            }
            catch (Exception e)
            {
                *err = AllocString($"{e.GetType().Name}: {e.Message.Split('\n')[0]}");
                return -1;
            }
        }

        // SPIRV-Cross output -> MSL for Metal (MslFix.cs). vertex != 0 for vertex shaders. Same return convention.
        [UnmanagedCallersOnly(EntryPoint = "nxsh_fix_msl")]
        public static int FixMsl(byte* msl, int vertex, byte** output, byte** err)
        {
            *output = null; *err = null;
            try
            {
                *output = AllocString(MslFix.Apply(Marshal.PtrToStringUTF8((IntPtr)msl), vertex != 0));
                return 0;
            }
            catch (Exception e)
            {
                *err = AllocString($"{e.GetType().Name}: {e.Message.Split('\n')[0]}");
                return -1;
            }
        }

        [UnmanagedCallersOnly(EntryPoint = "nxsh_free")]
        public static void Free(void* p) => NativeMemory.Free(p);

        // The resources of a translated stage (written by hand: NativeAOT has no reflection-based JSON).
        static byte[] Describe(ShaderProgramInfo i, Accessor acc)
        {
            var ms = new MemoryStream();
            using (var w = new Utf8JsonWriter(ms))
            {
                w.WriteStartObject();
                w.WriteString("stage", i.Stage.ToString());
                if (i.Stage == ShaderStage.Compute)
                {
                    w.WriteStartArray("localSize");
                    w.WriteNumberValue(acc.QueryComputeLocalSizeX());
                    w.WriteNumberValue(acc.QueryComputeLocalSizeY());
                    w.WriteNumberValue(acc.QueryComputeLocalSizeZ());
                    w.WriteEndArray();
                }
                else w.WriteNull("localSize");
                w.WriteStartArray("cbuffers");
                foreach (var b in i.CBuffers)
                {
                    w.WriteStartObject();
                    w.WriteNumber("slot", (int)b.Slot); w.WriteNumber("set", b.Set); w.WriteNumber("binding", b.Binding);
                    w.WriteEndObject();
                }
                w.WriteEndArray();
                w.WriteStartArray("sbuffers");
                foreach (var b in i.SBuffers)
                {
                    w.WriteStartObject();
                    w.WriteNumber("slot", (int)b.Slot); w.WriteNumber("cbSlot", (int)b.SbCbSlot); w.WriteNumber("cbOffset", (int)b.SbCbOffset);
                    w.WriteNumber("set", b.Set); w.WriteNumber("binding", b.Binding); w.WriteString("flags", b.Flags.ToString());
                    w.WriteEndObject();
                }
                w.WriteEndArray();
                w.WriteStartArray("textures");
                foreach (var t in i.Textures)
                {
                    w.WriteStartObject();
                    w.WriteNumber("cbufSlot", t.CbufSlot); w.WriteNumber("handle", t.HandleIndex); w.WriteString("type", t.Type.ToString());
                    w.WriteNumber("set", t.Set); w.WriteNumber("binding", t.Binding); w.WriteBoolean("separate", t.Separate);
                    w.WriteNumber("arrayLength", t.ArrayLength); w.WriteString("flags", t.Flags.ToString());
                    w.WriteEndObject();
                }
                w.WriteEndArray();
                w.WriteStartArray("images");
                foreach (var t in i.Images)
                {
                    w.WriteStartObject();
                    w.WriteNumber("cbufSlot", t.CbufSlot); w.WriteNumber("handle", t.HandleIndex); w.WriteString("type", t.Type.ToString());
                    w.WriteString("format", t.Format.ToString()); w.WriteNumber("set", t.Set); w.WriteNumber("binding", t.Binding);
                    w.WriteEndObject();
                }
                w.WriteEndArray();
                w.WriteBoolean("usesInstanceId", i.UsesInstanceId);
                w.WriteBoolean("usesFragCoord", i.UsesFragCoord);
                w.WriteBoolean("usesDrawParameters", i.UsesDrawParameters);
                w.WriteNumber("fragmentOutputMap", i.FragmentOutputMap);
                w.WriteNumber("clipDistancesWritten", (int)i.ClipDistancesWritten);
                w.WriteEndObject();
            }
            return ms.ToArray();
        }
    }
}
