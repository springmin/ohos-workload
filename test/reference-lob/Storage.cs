// Form persistence: a single JSON document under FileSystem.AppDataDirectory, serialized with
// a source-generated context so the NativeAOT image needs no reflection-based JSON metadata.
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Maui.Storage;

namespace ReferenceLob;

public sealed record FormData(string Name, string Email, string Notes, string Priority, bool Notify);

[JsonSerializable(typeof(FormData))]
internal sealed partial class ReferenceJsonContext : JsonSerializerContext
{
}

public static class ReferenceStore
{
    public static string FormPath => Path.Combine(FileSystem.AppDataDirectory, "reference-form.json");

    public static void SaveForm(FormData data)
    {
        string json = JsonSerializer.Serialize(data, ReferenceJsonContext.Default.FormData);
        File.WriteAllText(FormPath, json);
    }

    public static FormData? LoadForm()
    {
        try
        {
            if (!File.Exists(FormPath))
            {
                return null;
            }
            return JsonSerializer.Deserialize(File.ReadAllText(FormPath), ReferenceJsonContext.Default.FormData);
        }
        catch
        {
            return null;
        }
    }
}
