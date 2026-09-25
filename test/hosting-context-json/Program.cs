// Hosting context-JSON smoke test (FIX-INTEROP #3).
//
// The hosting assembly sets JsonSerializerIsReflectionEnabledByDefault=false and parses the
// native context payload through its source-generated HostJsonContext. This test runs the real
// parse path (OpenHarmonyBridge.Initialized reads OHOS_HOST_APP_CONTEXT) under the same
// reflection-disabled switch as the shipping app, so any regression back to
// JsonSerializer.Deserialize<ContextJson> fails here instead of only on device/AOT.
//
// Exit code 0 = every assertion passed; 1 = at least one failed (details on stdout).
using System.Text.Json;
using Microsoft.OpenHarmony.Hosting;

int failures = 0;

void Check(bool condition, string what)
{
    if (!condition)
    {
        failures++;
        Console.WriteLine($"FAIL: {what}");
    }
    else
    {
        Console.WriteLine($"ok: {what}");
    }
}

// 1. The switch is really active for this app: reflection-based serialization is off, so the
//    Hosting assembly can only have parsed the payload through its generated context.
Check(!JsonSerializer.IsReflectionEnabledByDefault, "JsonSerializer.IsReflectionEnabledByDefault is false");

// 2. A full, valid payload is parsed into the published context.
string json =
    "{\"appDir\":\"/data/app\"," +
    "\"filesDir\":\"/data/storage/el2/base/files\"," +
    "\"cacheDir\":\"/data/storage/el2/base/cache\"," +
    "\"bundleName\":\"com.example.smoke\"," +
    "\"abilityName\":\"EntryAbility\"," +
    "\"nodeContent\":42}";
Environment.SetEnvironmentVariable("OHOS_HOST_APP_CONTEXT", json);

OpenHarmonyAppContext? seen = null;
OpenHarmonyBridge.Initialized += context => seen = context;

Check(seen is not null, "subscribing to Initialized publishes the parsed context");
Check(seen?.AppDir == "/data/app", "appDir parsed");
Check(seen?.FilesDir == "/data/storage/el2/base/files", "filesDir parsed");
Check(seen?.CacheDir == "/data/storage/el2/base/cache", "cacheDir parsed");
Check(seen?.BundleName == "com.example.smoke", "bundleName parsed");
Check(seen?.AbilityName == "EntryAbility", "abilityName parsed");
Check(seen?.NodeContent == 42, "nodeContent parsed");
Check(OpenHarmonyBridge.Context is not null, "OpenHarmonyBridge.Context is published");

// 3. Unknown fields stay ignored and a missing nullable field stays empty (the shell may add
//    fields; the parser must not reject the payload for them).
Environment.SetEnvironmentVariable(
    "OHOS_HOST_APP_CONTEXT",
    "{\"appDir\":\"/data/app2\",\"futureField\":{\"x\":1}}");
OpenHarmonyAppContext? updated = null;
OpenHarmonyBridge.Initialized += context => updated = context;
Check(updated?.AppDir == "/data/app2", "unknown fields do not stop the parse");
Check(updated?.BundleName == string.Empty, "absent fields default to empty");

// 4. Malformed JSON is refused without throwing and without clobbering the published context:
//    the late subscriber is replayed the last good snapshot instead of a default one.
Environment.SetEnvironmentVariable("OHOS_HOST_APP_CONTEXT", "{not json");
OpenHarmonyAppContext? afterMalformed = null;
OpenHarmonyBridge.Initialized += context => afterMalformed = context;
Check(afterMalformed?.AppDir == "/data/app2", "malformed JSON replays the last good context");
Check(OpenHarmonyBridge.Context?.AppDir == "/data/app2", "malformed JSON keeps the last good context");

Console.WriteLine(failures == 0 ? "HOSTING CONTEXT JSON SMOKE PASSED" : $"{failures} assertion(s) failed");
return failures == 0 ? 0 : 1;
