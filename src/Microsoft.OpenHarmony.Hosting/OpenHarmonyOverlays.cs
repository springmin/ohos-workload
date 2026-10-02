// MULTI-OVL/MULTI-OVERLAY-FULL: multi-overlay arbitration for the shell's ArkWeb components.
//
// The ArkTS shell used to own a single hidden ArkWeb overlay, so the HybridWebView, the
// BlazorWebView and every plain WebView shared one component: the first registration kept it
// and every later web control only "armed" itself without rendering (FIX-WVP arbitration; a
// BlazorWebView frame even moved the hybrid page onto its own box, FIX-BACKSIZE). The shell now
// declares two ArkWeb overlays and this class is the managed half of that contract:
//
//   * slot pool: a connected web handler claims one of the <see cref="MaxOverlays"/> slots and
//     releases it on disconnect. The legacy <see cref="Acquire()"/> overload keeps the hard cap
//     (a third simultaneous control gets -1); the owner-aware
//     <see cref="Acquire(IOpenHarmonyOverlaySlotOwner)"/> overload instead reuses the pool with
//     LRU semantics (MULTI-OVERLAY-FULL): when every slot is claimed, the least-recently-used
//     slot whose owner is not engaged is preempted - its owner's
//     <see cref="IOpenHarmonyOverlaySlotOwner.OnOverlaySlotPreempted"/> runs, the owner then
//     follows suspend semantics and replays its load/attach when it later re-acquires. The
//     claim order is still the use order (the HybridWebView is created before the
//     BlazorWebView on the sample page, so hybrid -> slot 0, Blazor -> slot 1).
//   * wire codec: per-overlay commands carry the slot as the first argument line ("s<slot>" or
//     "s<slot>\n<payload>"); global commands (hide/suspend/resume/cookie/cookieGet) stay
//     untagged and keep their single-overlay meaning (all overlays). The shell echoes the slot
//     on its page events ("s<slot>|<state>"), on the navigation-decision envelope
//     ("__OHNAV|s<slot>|<url>|<id>") and routes the hybrid invoke endpoint per slot
//     (<see cref="EncodeInvokeRequestId"/>). An untagged state stays a fan-out for a shell that
//     predates the second overlay.
//
// The encoding is deliberately textual and prefix-based: the command path is
// OpenHarmonyBridge.WebCommand -> ohos_host_web_command -> NAPI -> the shell's registerWebSink
// callback, which receives exactly one (op, arg) pair, so the slot has to travel inside those
// strings (no native signature or host-export change: the contract stays 150/150).
using System;
using System.Globalization;

namespace Microsoft.OpenHarmony.Hosting;

/// <summary>
/// Owner contract of one shell overlay slot (MULTI-OVERLAY-FULL). A handler implements it so the
/// pool can preempt the least-recently-used slot instead of turning a third web control away:
/// the pool calls <see cref="OnOverlaySlotPreempted"/> when the slot is reassigned (the owner
/// then suspends and replays its page when it re-acquires), and reads
/// <see cref="IsOverlaySlotEngaged"/> to prefer idle owners as victims.
/// </summary>
public interface IOpenHarmonyOverlaySlotOwner
{
    /// <summary>
    /// Called (outside the pool lock) when the slot this owner held was reassigned by an
    /// owner-aware <see cref="OpenHarmonyOverlays.Acquire(IOpenHarmonyOverlaySlotOwner)"/>.
    /// The owner must drop its claim: a later <c>Release</c> for this slot is refused by the
    /// pool once the new owner holds it.
    /// </summary>
    void OnOverlaySlotPreempted(int slot);

    /// <summary>
    /// True while this owner's overlay is showing/engaged. The pool preempts a non-engaged
    /// owner before an engaged one and breaks ties by least-recent use.
    /// </summary>
    bool IsOverlaySlotEngaged { get; }
}

/// <summary>
/// Slot pool and wire codec for the shell's multi-overlay ArkWeb support (MULTI-OVL /
/// MULTI-OVERLAY-FULL). The pool is process-wide and lock-protected; acquire/release are cheap
/// and never throw. Every slot table is swappable by the off-device suite (the same reflective
/// seam pattern the interaction tests use for native state).
/// </summary>
public static class OpenHarmonyOverlays
{
    /// <summary>Number of ArkWeb overlays the shell declares (MULTI-OVL cap N=2).</summary>
    public const int MaxOverlays = 2;

    /// <summary>First line prefix a tagged argument carries ("s0", "s1", ...).</summary>
    public const char SlotPrefix = 's';

    /// <summary>
    /// Bit position of the overlay slot in a hybrid-invoke request id
    /// (<see cref="EncodeInvokeRequestId"/>). The shell numbers its held-open
    /// <c>__hwvInvokeDotNet</c> responses with <c>((slot + 1) &lt;&lt; 24) | sequence</c>, so the
    /// slot travels the host.notifyHybridInvoke -> managed callback -> ohos_host_hwv_invoke_result
    /// chain inside the request id and needs no native signature change.
    /// </summary>
    public const int InvokeSlotShift = 24;

    /// <summary>Sequence bits a tagged hybrid-invoke request id carries (24 bits).</summary>
    public const int InvokeSequenceMask = (1 << InvokeSlotShift) - 1;

    private static readonly object s_sync = new();
    // The slot tables are swappable for the off-device suite's pool drill (the same reflective
    // seam pattern the interaction tests use for native state).
    private static bool[] s_used = new bool[MaxOverlays];
    private static object?[] s_owners = new object?[MaxOverlays];
    private static long[] s_lastUsed = new long[MaxOverlays];
    private static long s_clock;

    /// <summary>
    /// Claims the first free overlay slot (0, then 1, ...) with the legacy hard cap. Returns -1
    /// when the cap is reached; callers that pass no owner cannot be told about a preemption, so
    /// this overload must not silently hand an owner's overlay to someone else (that would
    /// render the wrong document for at least one control).
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
                    s_owners[slot] = null;
                    s_lastUsed[slot] = ++s_clock;
                    return slot;
                }
            }
        }
        return -1;
    }

    /// <summary>
    /// Owner-aware claim (MULTI-OVERLAY-FULL). A free slot is claimed directly; when the pool is
    /// full the least-recently-used slot whose owner is not engaged is preempted: its owner's
    /// <see cref="IOpenHarmonyOverlaySlotOwner.OnOverlaySlotPreempted"/> runs outside the lock
    /// and the claim transfers to <paramref name="owner"/>. Never returns -1 (the pool always
    /// has a victim), so a third simultaneous web control gets an overlay instead of falling
    /// back to the legacy untagged protocol.
    /// </summary>
    public static int Acquire(IOpenHarmonyOverlaySlotOwner owner)
    {
        ArgumentNullException.ThrowIfNull(owner);
        IOpenHarmonyOverlaySlotOwner? victim = null;
        int victimSlot = -1;
        lock (s_sync)
        {
            for (int slot = 0; slot < s_used.Length; slot++)
            {
                if (!s_used[slot])
                {
                    s_used[slot] = true;
                    s_owners[slot] = owner;
                    s_lastUsed[slot] = ++s_clock;
                    return slot;
                }
            }
            victimSlot = SelectPreemptionVictim();
            victim = s_owners[victimSlot] as IOpenHarmonyOverlaySlotOwner;
            s_used[victimSlot] = true;
            s_owners[victimSlot] = owner;
            s_lastUsed[victimSlot] = ++s_clock;
        }
        if (victim is not null && !ReferenceEquals(victim, owner))
        {
            victim.OnOverlaySlotPreempted(victimSlot);
        }
        return victimSlot;
    }

    /// <summary>
    /// Picks the slot an owner-aware acquire preempts: the least-recently-used slot whose owner
    /// is not engaged (an owner-less legacy claim counts as not engaged). The caller holds
    /// <see cref="s_sync"/>.
    /// </summary>
    private static int SelectPreemptionVictim()
    {
        int best = 0;
        bool bestEngaged = IsEngaged(0);
        for (int slot = 1; slot < s_used.Length; slot++)
        {
            bool engaged = IsEngaged(slot);
            if (bestEngaged && !engaged)
            {
                best = slot;
                bestEngaged = false;
            }
            else if (bestEngaged == engaged && s_lastUsed[slot] < s_lastUsed[best])
            {
                best = slot;
            }
        }
        return best;
    }

    private static bool IsEngaged(int slot)
        => s_owners[slot] is IOpenHarmonyOverlaySlotOwner owner && owner.IsOverlaySlotEngaged;

    /// <summary>
    /// Marks one claimed slot as recently used (LRU bookkeeping). False for an unclaimed/out-of-
    /// range slot. The owner-aware overload only touches the slot while <paramref name="owner"/>
    /// still holds it, so a preempted handler can never refresh the new owner's entry.
    /// </summary>
    public static bool Touch(int slot)
    {
        if (!IsValid(slot))
        {
            return false;
        }
        lock (s_sync)
        {
            if (!s_used[slot])
            {
                return false;
            }
            s_lastUsed[slot] = ++s_clock;
            return true;
        }
    }

    /// <summary>Owner-checked form of <see cref="Touch(int)"/> (MULTI-OVERLAY-FULL).</summary>
    public static bool Touch(int slot, IOpenHarmonyOverlaySlotOwner owner)
    {
        ArgumentNullException.ThrowIfNull(owner);
        if (!IsValid(slot))
        {
            return false;
        }
        lock (s_sync)
        {
            if (!s_used[slot] || !ReferenceEquals(s_owners[slot], owner))
            {
                return false;
            }
            s_lastUsed[slot] = ++s_clock;
            return true;
        }
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
            s_owners[slot] = null;
        }
    }

    /// <summary>
    /// Owner-checked release (MULTI-OVERLAY-FULL): frees the slot only while
    /// <paramref name="owner"/> still holds it. A preempted handler's late disconnect therefore
    /// cannot free the overlay a newer claim is using.
    /// </summary>
    public static bool Release(int slot, IOpenHarmonyOverlaySlotOwner owner)
    {
        ArgumentNullException.ThrowIfNull(owner);
        if (slot < 0 || slot >= MaxOverlays)
        {
            return false;
        }
        lock (s_sync)
        {
            if (!ReferenceEquals(s_owners[slot], owner))
            {
                return false;
            }
            s_used[slot] = false;
            s_owners[slot] = null;
            return true;
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

    /// <summary>True while <paramref name="owner"/> holds <paramref name="slot"/>.</summary>
    public static bool IsClaimedBy(int slot, object owner)
    {
        ArgumentNullException.ThrowIfNull(owner);
        if (!IsValid(slot))
        {
            return false;
        }
        lock (s_sync)
        {
            return s_used[slot] && ReferenceEquals(s_owners[slot], owner);
        }
    }

    /// <summary>
    /// Tags a per-overlay command argument: "s&lt;slot&gt;" for an empty payload (show/hide
    /// style ops) or "s&lt;slot&gt;\n&lt;payload&gt;" for frame/load/data. A negative slot is
    /// returned untagged, so a handler without an overlay still speaks the legacy
    /// single-overlay protocol instead of corrupting another slot's command.
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

    /// <summary>
    /// Composes the tagged hybrid-invoke request id the shell passes to
    /// <c>host.notifyHybridInvoke</c> (MULTI-OVERLAY-FULL): the high byte identifies the overlay
    /// slot (slot + 1, so a legacy untagged id never decodes) and the low 24 bits are the shell's
    /// per-slot sequence. The managed callback routes the invocation to the handler that owns
    /// the slot and answers <c>ohos_host_hwv_invoke_result</c> with the same id, so the shell
    /// completes the held-open response of the same overlay. No native signature/export change.
    /// </summary>
    public static int EncodeInvokeRequestId(int slot, int sequence)
        => slot < 0 || slot >= MaxOverlays
            ? sequence & InvokeSequenceMask
            : ((slot + 1) << InvokeSlotShift) | (sequence & InvokeSequenceMask);

    /// <summary>
    /// Decodes a hybrid-invoke request id (<see cref="EncodeInvokeRequestId"/>). False for an id
    /// without a slot tag (a shell that predates MULTI-OVERLAY-FULL), which the caller routes
    /// through its legacy "last registered hybrid" fallback.
    /// </summary>
    public static bool TryDecodeInvokeRequestId(int requestId, out int slot, out int sequence)
    {
        slot = -1;
        sequence = requestId & InvokeSequenceMask;
        int tag = (requestId >> InvokeSlotShift) & 0xFF;
        if (tag <= 0 || tag > MaxOverlays)
        {
            return false;
        }
        slot = tag - 1;
        return true;
    }
}
