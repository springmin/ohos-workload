// MULTI-OVL: multi-overlay arbitration for the shell's ArkWeb components.
//
// The ArkTS shell used to own a single hidden ArkWeb overlay, so the HybridWebView, the
// BlazorWebView and every plain WebView shared one component: the first registration kept it
// and every later web control only "armed" itself without rendering (FIX-WVP arbitration; a
// BlazorWebView frame even moved the hybrid page onto its own box, FIX-BACKSIZE). The shell now
// declares two ArkWeb overlays and this class is the managed half of that contract:
//
//   * slot pool: a connected web handler claims one of the <see cref="MaxOverlays"/> slots and
//     releases it on disconnect. The cap is a slice-wide constant: a third simultaneous web
//     control does not paint instead of silently reusing another control's overlay, and the
//     claim order is the connection order (the HybridWebView connects before the BlazorWebView
//     on the sample page, so hybrid -> slot 0, Blazor -> slot 1).
//   * wire codec: per-overlay commands carry the slot as the first argument line ("s<slot>" or
//     "s<slot>\n<payload>"); global commands (hide/suspend/resume/cookie/cookieGet) stay
//     untagged and keep their single-overlay meaning (all overlays). The shell echoes the slot
//     on its page events ("s<slot>|<state>") and on the navigation-decision envelope
//     ("__OHNAV|s<slot>|<url>|<id>"), so events only reach the handler that owns the slot; an
//     untagged state stays a fan-out for a shell that predates the second overlay.
//
// The encoding is deliberately textual and prefix-based: the command path is
// OpenHarmonyBridge.WebCommand -> ohos_host_web_command -> NAPI -> the shell's registerWebSink
// callback, which receives exactly one (op, arg) pair, so the slot has to travel inside those
// strings (no native signature or host-export change: the contract stays 150/150).
using System;
using System.Globalization;

namespace Microsoft.OpenHarmony.Hosting;

/// <summary>
/// Slot pool and wire codec for the shell's multi-overlay ArkWeb support (MULTI-OVL). The pool
/// is process-wide and lock-protected; acquire/release are cheap and never throw.
/// </summary>
public static class OpenHarmonyOverlays
{
    /// <summary>Number of ArkWeb overlays the shell declares (MULTI-OVL cap N=2).</summary>
    public const int MaxOverlays = 2;

    /// <summary>First line prefix a tagged argument carries ("s0", "s1", ...).</summary>
    public const char SlotPrefix = 's';

    private static readonly object s_sync = new();
    // The slot table is swappable for the off-device suite's pool drill (the same reflective
    // seam pattern the interaction tests use for native state).
    private static bool[] s_used = new bool[MaxOverlays];

    /// <summary>
    /// Claims the first free overlay slot (0, then 1, ...). Returns -1 when the cap is reached:
    /// the caller then leaves the control without an overlay instead of sharing one (a shared
    /// overlay renders the wrong document for at least one of the controls).
    /// </summary>
    public static int Acquire()
    {
        lock (s_sync)
        {
            for (int slot = 0; slot < s_used.Length; slot++)
            {
                if (!s_used[slot])
                {
                    s_used[slot] = true;
                    return slot;
                }
            }
        }
        return -1;
    }

    /// <summary>Returns one claimed slot to the pool; -1 and out-of-range values are ignored.</summary>
    public static void Release(int slot)
    {
        if (slot < 0 || slot >= MaxOverlays)
        {
            return;
        }
        lock (s_sync)
        {
            s_used[slot] = false;
        }
    }

    /// <summary>True for a slot index the shell owns.</summary>
    public static bool IsValid(int slot) => slot >= 0 && slot < MaxOverlays;

    /// <summary>True while a slot is claimed (diagnostics/tests).</summary>
    public static bool IsClaimed(int slot)
    {
        if (!IsValid(slot))
        {
            return false;
        }
        lock (s_sync)
        {
            return s_used[slot];
        }
    }

    /// <summary>
    /// Tags a per-overlay command argument: "s&lt;slot&gt;" for an empty payload (show/hide
    /// style ops) or "s&lt;slot&gt;\n&lt;payload&gt;" for frame/load/data. A negative slot is
    /// returned untagged, so a handler beyond the cap still speaks the legacy single-overlay
    /// protocol instead of corrupting another slot's command.
    /// </summary>
    public static string Tag(int slot, string? payload = null)
    {
        if (!IsValid(slot))
        {
            return payload ?? string.Empty;
        }
        string tag = SlotPrefix + slot.ToString(CultureInfo.InvariantCulture);
        return string.IsNullOrEmpty(payload) ? tag : tag + "\n" + payload;
    }

    /// <summary>
    /// Splits a tagged command argument into its slot and payload. False (slot 0, argument
    /// unchanged) for an untagged argument, which keeps a legacy command routed to the first
    /// overlay.
    /// </summary>
    public static bool TryUntag(string argument, out int slot, out string payload)
    {
        slot = 0;
        payload = argument ?? string.Empty;
        if (argument is null || argument.Length < 2 || argument[0] != SlotPrefix)
        {
            return false;
        }
        int digit = argument[1] - '0';
        if (digit < 0 || digit >= MaxOverlays)
        {
            return false;
        }
        if (argument.Length > 2 && argument[2] != '\n')
        {
            return false;
        }
        slot = digit;
        payload = argument.Length > 2 ? argument.Substring(3) : string.Empty;
        return true;
    }

    /// <summary>
    /// Tags a page event state with its slot ("s&lt;slot&gt;|&lt;state&gt;") so the shell's
    /// page callback can report which overlay the event belongs to. The shell emits this shape;
    /// the managed side parses it in <see cref="TryParseEventState"/>.
    /// </summary>
    public static string TagState(int slot, string state)
        => IsValid(slot)
            ? SlotPrefix + slot.ToString(CultureInfo.InvariantCulture) + "|" + (state ?? string.Empty)
            : state ?? string.Empty;

    /// <summary>
    /// Parses "s&lt;slot&gt;|&lt;state&gt;" into its slot and state. False for a legacy
    /// untagged state (which stays a fan-out to every connected view).
    /// </summary>
    public static bool TryParseEventState(string state, out int slot, out string rest)
    {
        slot = -1;
        rest = state ?? string.Empty;
        if (state is null || state.Length < 3 || state[0] != SlotPrefix)
        {
            return false;
        }
        int digit = state[1] - '0';
        if (digit < 0 || digit >= MaxOverlays || state[2] != '|')
        {
            return false;
        }
        slot = digit;
        rest = state.Substring(3);
        return true;
    }

    /// <summary>
    /// Tags an eval script with its overlay ("s&lt;slot&gt;\n&lt;script&gt;") so the shell's
    /// registerWebEvalSink callback runs the script on the matching WebviewController. The host
    /// copy path (ohos_host_web_eval) is untouched; a legacy untagged script runs on slot 0.
    /// </summary>
    public static string TagScript(int slot, string script)
        => Tag(slot, script);

    /// <summary>
    /// Tags the navigation-decision envelope the shell delivers through notifyJsMessage
    /// ("__OHNAV|s&lt;slot&gt;|&lt;url&gt;|&lt;id&gt;"). The managed answer ("nav") echoes the
    /// same slot prefix so the shell reloads the right overlay.
    /// </summary>
    public static string TagNavigationRequest(int slot, string url, string requestId)
        => $"__OHNAV|{Tag(slot)}|{url}|{requestId}";

    /// <summary>
    /// Parses a navigation-decision envelope into (slot, url, requestId). A legacy envelope
    /// without a slot reports slot -1 (the handler then answers without a tag).
    /// </summary>
    public static bool TryParseNavigationRequest(string payload, out int slot, out string url, out string requestId)
    {
        slot = -1;
        url = string.Empty;
        requestId = string.Empty;
        if (payload is null || !payload.StartsWith("__OHNAV|", StringComparison.Ordinal))
        {
            return false;
        }
        string body = payload.Substring("__OHNAV|".Length);
        int firstSeparator = body.IndexOf('|');
        if (firstSeparator <= 0)
        {
            return false;
        }
        string first = body.Substring(0, firstSeparator);
        if (TryUntag(first, out int taggedSlot, out string remainder) && remainder.Length == 0)
        {
            slot = taggedSlot;
            body = body.Substring(firstSeparator + 1);
        }
        int lastSeparator = body.LastIndexOf('|');
        if (lastSeparator <= 0)
        {
            return false;
        }
        url = body.Substring(0, lastSeparator);
        requestId = body.Substring(lastSeparator + 1);
        return url.Length > 0 && requestId.Length > 0;
    }
}
