// Post-processing of SPIRV-Cross MSL for Metal's limits (the passes run in this order):
//
// drop_optnone: SPIRV-Cross implements Ryujinx's NoContraction ("precise") operations as helpers (spvFMul, spvFAdd, ...)
//   marked [[clang::optnone]]: never inlined, so every float op became a GPU function call (a 960x540 ray march took
//   32 ms). The helpers already compute exactly rounded results, so optnone goes. What "precise" protects is the vertex
//   position being identical across shaders: vertex shaders mark it [[invariant]] and the runtime compiles with
//   preserveInvariance.
// tex_arrays: cbuf-indexed bindless textures (Ryujinx BindlessToArray): `arr[i]` with element i = the handle word at
//   byte 8i of a uniform buffer. Metal can't bind 8192 textures, so the array shrinks to ArraySlots and is indexed
//   through a per-draw map the runtime fills (`constant uchar* spvTexMap [[buffer(30)]]`, element -> slot; slot 0 =
//   dummy). The sampler array becomes one sampler. A comment tells the runtime which handle words the shader can reach:
//   `// nxrt-texarray <binding> slots <n> stride <bytes> offs <a,b,...>` (stride 0 = unknown: every element is mapped).
// fold_samplers: Metal allows 16 sampler slots per stage; a few shaders use 17-19 textures, each with its own sampler.
//   Rule (the runtime follows it for every shader): sampler slot = texture binding % 16. The entry point loses its
//   [[sampler(n >= 16)]] parameters and inside its body those names become the sampler at n % 16.
// guard_loops (GPU safety): every `do { } while` loop gets an iteration cap of 65536, so a garbage or NaN bound is a
//   wrong pixel instead of a GPU hang (which resets the GPU for the whole system).
// clamp_buffers (GPU safety): Metal has no robust buffer access. Every `<x>p_s<n>._m0[i]` (inside main0) becomes
//   `..._m0[min(uint(i), spvSbWords[b - 16] - 1u)]`, with the word counts of the bound buffers in a new entry parameter
//   `constant uint* spvSbWords [[buffer(15)]]` (the runtime always binds it). Threadgroup arrays get the same clamp
//   with their static size.
using System.Text;
using System.Text.RegularExpressions;

namespace NxXlat
{
    static class MslFix
    {
        public static string Apply(string src, bool vertex)
        {
            src = DropOptnone(src, vertex);
            src = TexArrays(src);
            src = FoldSamplers(src);
            src = GuardLoops(src);
            src = ClampBuffers(src);
            return src;
        }

        static string DropOptnone(string src, bool vertex)
        {
            src = src.Replace("[[clang::optnone]] ", "");
            if (vertex) src = src.Replace(" [[position]];", " [[position, invariant]];");
            return src;
        }

        const int ArrayLen = 8192;   // Accessor.QueryTextureArrayLengthFromBuffer: a whole 64 KB cbuf, one handle per 8 bytes
        static readonly Regex TexArr = new($@"array<(\w+<float>), {ArrayLen}> (\w+) \[\[texture\((\d+)\)\]\]");

        static string TexArrays(string src)
        {
            var arrs = TexArr.Matches(src);
            if (arrs.Count == 0) return src;
            if (arrs.Count > 1) throw new InvalidDataException("more than one cbuf texture array");
            string ty = arrs[0].Groups[1].Value, name = arrs[0].Groups[2].Value, binding = arrs[0].Groups[3].Value;
            int slots = Accessor.ArraySlots;
            src = ReplaceFirst(src, $"array<{ty}, {ArrayLen}> {name} [[texture({binding})]]",
                               $"array<{ty}, {slots}> {name} [[texture({binding})]], constant uchar* spvTexMap [[buffer(30)]]");
            src = ReplaceFirst(src, $"array<sampler, {ArrayLen}> {name}Smplr [[sampler({binding})]]", $"sampler {name}Smplr [[sampler({binding})]]");
            src = Regex.Replace(src, $@"\b{name}Smplr\[\w+\]", $"{name}Smplr");
            // Trace each index: `int _i = int(min(uint(... _w ...), 8191u));`, `uint _w = uint(int(uint(_b + C) >> uint(2)));`,
            // `int _b = ... << S;` -> record stride 1 << S, handle offset C.
            var strides = new HashSet<int>();
            var offs = new SortedSet<int>();
            foreach (Match im in Regex.Matches(src, $@"\b{name}\[(\w+)\]"))
            {
                string idx = im.Groups[1].Value;
                Match m = Regex.Match(src, $@"\b{idx} = int\(min\(uint\(.*?\b(_\d+)\b");
                Match w = m.Success ? Regex.Match(src, $@"\b{m.Groups[1].Value} = uint\(int\(uint\((_\d+) \+ (\d+)\) >> uint\(2\)\)\);") : Match.Empty;
                Match b = w.Success ? Regex.Match(src, $@"\b{w.Groups[1].Value} = [^;]*<< (\d+);") : Match.Empty;
                if (!b.Success)
                {
                    strides.Add(0);
                    continue;
                }
                strides.Add(1 << int.Parse(b.Groups[1].Value));
                offs.Add(int.Parse(w.Groups[2].Value));
            }
            int stride = strides.Count == 1 ? strides.First() : 0;
            src = Regex.Replace(src, $@"\b{name}\[(\w+)\]", $"{name}[spvTexMap[$1]]");
            string note = $"// nxrt-texarray {binding} slots {slots} stride {stride} offs {(stride != 0 ? string.Join(",", offs) : "-")}\n";
            return note + src;
        }

        static readonly Regex Param = new(@",\s*sampler (\w+) \[\[sampler\((\d+)\)\]\]");

        static string FoldSamplers(string src)
        {
            var ps = Param.Matches(src).Select(m => (name: m.Groups[1].Value, n: int.Parse(m.Groups[2].Value))).ToList();
            if (!ps.Any(p => p.n >= 16)) return src;
            var bySlot = new Dictionary<int, string>();
            foreach (var p in ps) bySlot[p.n] = p.name;
            int entry = src.LastIndexOf("[[sampler(");   // inside the entry signature (last function)
            int headStart = src.LastIndexOf('\n', entry) + 1;
            string head = src[..headStart], body = src[headStart..];
            foreach (var (name, n) in ps)
            {
                if (n < 16) continue;
                if (!bySlot.TryGetValue(n % 16, out string alias))
                    throw new InvalidDataException($"no sampler at slot {n % 16} to share with {name}");
                body = new Regex($@",\s*sampler {name} \[\[sampler\({n}\)\]\]").Replace(body, "", 1);
                body = Regex.Replace(body, $@"\b{name}\b", alias);
            }
            return head + body;
        }

        static readonly Regex Do = new(@"^([ \t]*)do\n\1\{\n", RegexOptions.Multiline);

        static string GuardLoops(string src)
        {
            int n = 0;
            return Do.Replace(src, m =>
            {
                n++;
                string ind = m.Groups[1].Value;
                return $"{ind}uint spvLoopGuard{n} = 0u;\n{ind}do\n{ind}{{\n{ind}    if (++spvLoopGuard{n} > 65536u) break;\n";
            });
        }

        static readonly Regex Ssbo = new(@"device \w+& (\w+) \[\[buffer\((\d+)\)\]\]");
        static readonly Regex Shared = new(@"threadgroup spvUnsafeArray<\w+, (\d+)> (\w+);");

        // Every `name[expr]` -> `name[min(uint(expr), bound)]` (brackets matched by hand).
        static string WrapIndices(string src, string name, string bound)
        {
            var sb = new StringBuilder();
            var pat = new Regex($@"\b{Regex.Escape(name)}\[");
            int i = 0;
            while (true)
            {
                Match m = pat.Match(src, i);
                if (!m.Success) break;
                int end = m.Index + m.Length, j = end, depth = 1;
                while (depth > 0)
                {
                    depth += src[j] == '[' ? 1 : src[j] == ']' ? -1 : 0;
                    j++;
                }
                sb.Append(src, i, end - i).Append("min(uint(").Append(src, end, j - 1 - end).Append("), ").Append(bound).Append(")]");
                i = j;
            }
            sb.Append(src, i, src.Length - i);
            return sb.ToString();
        }

        static string ClampBuffers(string src)
        {
            int entry = src.LastIndexOf("main0(");
            int headStart = src.LastIndexOf('\n', entry) + 1;
            string head = src[..headStart], body = src[headStart..];
            string signature = body.Split('\n', 2)[0];
            var sbs = Ssbo.Matches(signature);
            foreach (Match m in sbs)
                body = WrapIndices(body, m.Groups[1].Value + "._m0", $"spvSbWords[{int.Parse(m.Groups[2].Value) - 16}] - 1u");
            if (sbs.Count > 0) body = ReplaceFirst(body, "main0(", "main0(constant uint* spvSbWords [[buffer(15)]], ");
            foreach (Match m in Shared.Matches(body))
                body = WrapIndices(body, m.Groups[2].Value, $"{int.Parse(m.Groups[1].Value) - 1}u");
            return head + body;
        }

        static string ReplaceFirst(string s, string old, string replacement)
        {
            int i = s.IndexOf(old, StringComparison.Ordinal);
            return i < 0 ? s : s[..i] + replacement + s[(i + old.Length)..];
        }
    }
}
