// Stand-in for Ryujinx.Common.Utilities.EmbeddedResources (the shader translator only reads its GLSL helper functions):
// the resource whose name ends with the file's name.
using System.IO;
using System.Linq;
using System.Reflection;

namespace Ryujinx.Common
{
    public static class EmbeddedResources
    {
        public static string ReadAllText(string filename)
        {
            Assembly assembly = typeof(EmbeddedResources).Assembly;
            string leaf = Path.GetFileName(filename.Replace('\\', '/'));
            string name = assembly.GetManifestResourceNames().FirstOrDefault(n => n.EndsWith(leaf));
            if (name == null) return null;
            using Stream stream = assembly.GetManifestResourceStream(name);
            using StreamReader reader = new(stream);
            return reader.ReadToEnd();
        }
    }
}
