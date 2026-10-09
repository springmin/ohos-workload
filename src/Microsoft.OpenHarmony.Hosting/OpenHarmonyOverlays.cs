// MULTI-OVL/MULTI-OVERLAY-FULL/SLOTS-DYNAMIC: multi-overlay arbitration for the shell's ArkWeb
// components.
//
// The ArkTS shell used to own a single hidden ArkWeb overlay, so the HybridWebView, the
// BlazorWebView and every plain WebView shared one component: the first registration kept it
// and every later web control only "armed" itself without rendering (FIX-WVP arbitration; a
// BlazorWebView frame even moved the hybrid page onto its own box, FIX-BACKSIZE). The shell now
// declares ArkWeb overlays per slot and this class is the managed half of that contract:
//
//   * dynamic slot pool: a connected web handler claims a slot through the owner-aware
//     <see cref="Acquire(IOpenHarmonyOverlaySlotOwner)"/> overload. The pool sizes itself from
//     the shell's declared capacity (<see cref="SetShellCapacity"/>; the shell advertises
//     WEB_SLOT_MAX, and the managed limits are <see cref="MaxOverlays"/> /
//     <see cref="HotOverlays"/>, default 8/2, overridable through the OHOS_OVERLAY_MAX and
//     OHOS_OVERLAY_HOT environment variables). A free slot is claimed directly; a slot the
//     shell has not created yet is created on demand with the shell's "slot ensure" command
//     (the shell also lazily creates a slot when the first tagged command for it arrives, so a
//     lost ensure command self-heals). Slots 0..<see cref="HotOverlays"/> are the shell's
//     always-declared hot pair; a slot at or above that floor is destroyed again when it is
//     released ("slot destroy"), balancing memory (an idle ArkWeb engine keeps its renderer and
//     a loaded document) against the re-create cost (one ArkWeb + one page load, paid only by a
//     later dynamic claim). The immediate-destroy choice is deliberate: there is no timer and
//     the common case (two concurrent web controls) never leaves the hot pair.
//   * over-limit: when every slot the shell declared is claimed, the least-recently-used slot
//     whose owner is not engaged is preempted (MULTI-OVERLAY-FULL semantics kept): its owner's
//     <see cref="IOpenHarmonyOverlaySlotOwner.OnOverlaySlotPreempted"/> runs, the owner follows
//     suspend semantics and replays its load/attach when it later re-acquires. A shell that
//     advertises fewer slots than <see cref="MaxOverlays"/> (or a capacity downgrade after a
//     page reload) preempts the claims beyond the advertised capacity, so the managed pool
//     never tags a slot the shell cannot serve.
//   * wire codec: per-overlay commands carry the slot as the first argument line ("s<slot>" or
//     "s<slot>\n<payload>"); global commands (hide/suspend/resume/cookie/cookieGet) stay
//     untagged and keep their single-overlay meaning (all overlays). The shell echoes the slot
//     on its page events ("s<slot>|<state>"), on the navigation-decision envelope
//     ("__OHNAV|s<slot>|<url>|<id>") and routes the hybrid invoke endpoint per slot
//     (<see cref="EncodeInvokeRequestId"/>). An untagged state stays a fan-out for a shell that
//     predates the second overlay. The shell advertises its overlay capacity as the page event
//     ("capacity", "8"); the pool defaults to <see cref="MaxOverlays"/> so the shipped
//     shell+slice pairing renders 3+ concurrent controls even when the notification beats the
//     managed subscription, and a legacy 2-overlay shell would downgrade the pool through the
//     same event (mismatched shell/slice pairings beyond the advertised capacity are not
//     supported - the kit ships the shell and the slice in lockstep).
//
// The encoding is deliberately textual and prefix-based: the command path is
// OpenHarmonyBridge.WebCommand -> ohos_host_web_command -> NAPI -> the shell's registerWebSink
// callback, which receives exactly one (op, arg) pair, so the slot has to travel inside those
// strings (no native signature or host-export change: the contract stays 151/151).
using System;
using System.Globalization;

namespace Microsoft.OpenHarmony.Hosting;

/// <summary>
/// Owner contract of one shell overlay slot (MULTI-OVERLAY-FULL). A handler implements it so the
/// pool can preempt the least-recently-used slot instead of turning a web control away:
/// the pool calls <see cref="OnOverlaySlotPreempted"/> when the slot is reassigned (the owner
/// then suspends and replays its page when it re-acquires), and reads
/// <see cref="IsOverlaySlotEngaged"/> to prefer idle owners as victims.
/// </summary>
public interface IOpenHarmonyOverlaySlotOwner
{
    /// <summary>
    /// Called (outside the pool lock) when the slot this owner held was reassigned by an
    /// owner-aware <see cref="OpenHarmonyOverlays.Acquire(IOpenHarmonyOverlaySlotOwner)"/> or
    /// dropped by a shell capacity downgrade. The owner must drop its claim: a later
    /// <c>Release</c> for this slot is refused by the pool once the new owner holds it.
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
/// MULTI-OVERLAY-FULL / SLOTS-DYNAMIC). The pool is process-wide and lock-protected;
/// acquire/release are cheap and never throw. Every slot table is swappable by the off-device
/// suite (the same reflective seam pattern the interaction tests use for native state).
/// </summary>
public static class OpenHarmonyOverlays
{
    /// <summary>Default overlay slots the pool may use (SLOTS-DYNAMIC; env OHOS_OVERLAY_MAX, default 8).</summary>
    public const int DefaultMaxOverlays = 8;

    /// <summary>Default always-declared hot slots kept across a release (env OHOS_OVERLAY_HOT).</summary>
    public const int DefaultHotOverlays = 2;

    /// <summary>Lowest meaningful capacity: below two overlays the pool is not a pool.</summary>
    public const int MinMaxOverlays = 2;

    /// <summary>
    /// Highest supported slot count. The wire tag is the single digit after 's' ("s0".."s7") and
    /// the hybrid invoke id stores slot+1 in one byte, so the ceiling is a resource policy, not
    /// a protocol limit; 8 keeps an accidental environment value from exhausting device memory.
    /// </summary>
    public const int MaxSupportedOverlays = 8;

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

    // The pool limits are read once from the environment (SLOTS-DYNAMIC) and stay writable so
    // the off-device suite can drill other limits through the reflective seam.
    private static int s_maxOverlays = ReadLimit("OHOS_OVERLAY_MAX", DefaultMaxOverlays, MinMaxOverlays, MaxSupportedOverlays);
    private static int s_hotOverlays = ReadLimit("OHOS_OVERLAY_HOT", DefaultHotOverlays, MinMaxOverlays, s_maxOverlays);

    // The slot tables are swappable for the off-device suite's pool drill (the same reflective
    // seam pattern the interaction tests use for native state). s_created tracks which slots the
    // shell has declared (hot slots at startup, dynamic slots after "slot ensure"); a released
    // slot at/above the hot floor is destroyed and s_created drops back to false.
    private static bool[] s_used = new bool[s_maxOverlays];
    private static object?[] s_owners = new object?[s_maxOverlays];
    private static long[] s_lastUsed = new long[s_maxOverlays];
    private static bool[] s_created = NewCreatedTable(s_maxOverlays, s_hotOverlays);
    private static long s_clock;

    // Overlay count the shell last advertised (0 = not advertised yet). The optimistic default
    // is MaxOverlays: the kit ships the shell and the slice together, and the shell's
    // notification can arrive after the first handlers connected. SetShellCapacity lowers it
    // (a legacy 2-overlay shell) and preempts any claim the shell cannot serve.
    private static int s_shellCapacity;

    /// <summary>Overlay slots the pool may use (SLOTS-DYNAMIC; env OHOS_OVERLAY_MAX, default 8).</summary>
    public static int MaxOverlays => s_maxOverlays;

    /// <summary>
    /// Hot slots the shell always declares and a release never destroys (env
    /// OHOS_OVERLAY_HOT, default 2, clamped to [2, <see cref="MaxOverlays"/>]).
    /// </summary>
    public static int HotOverlays => s_hotOverlays;

    /// <summary>
    /// Overlay capacity the shell last advertised through its "capacity" page event. Until the
    /// event arrives the pool assumes <see cref="MaxOverlays"/> (the lockstep shell declares
    /// that many); a smaller advertised value clamps every later claim.
    /// </summary>
    public static int ShellCapacity
    {
        get
        {
            lock (s_sync)
            {
                return EffectiveCapacityLocked();
            }
        }
    }

    private static int ReadLimit(string name, int fallback, int minimum, int maximum)
    {
        try
        {
            string? raw = Environment.GetEnvironmentVariable(name);
            if (!string.IsNullOrEmpty(raw) &&
                int.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out int value))
            {
                return Math.Clamp(value, minimum, maximum);
            }
        }
        catch
        {
            // A hostile/unreadable environment falls back to the default.
        }
        return fallback;
    }

    private static bool[] NewCreatedTable(int maxOverlays, int hotOverlays)
    {
        bool[] created = new bool[maxOverlays];
        for (int slot = 0; slot < Math.Min(hotOverlays, maxOverlays); slot++)
        {
            created[slot] = true;
        }
        return created;
    }

    /// <summary>
    /// Effective capacity: the shell's advertised count clamped to the managed maximum, with the
    /// optimistic default (the shell has not answered yet). Caller holds <see cref="s_sync"/>.
    /// </summary>
    private static int EffectiveCapacityLocked()
    {
        int capacity = s_shellCapacity == 0 ? s_maxOverlays : s_shellCapacity;
        return Math.Clamp(capacity, MinMaxOverlays, s_maxOverlays);
    }

    /// <summary>
    /// Records the overlay count the shell can declare (SLOTS-DYNAMIC; the shell's "capacity"
    /// page event). Claims at or above the new capacity are preempted outside the lock: the
    /// handlers suspend and replay on their next use, exactly like an LRU preemption, so a
    /// capacity downgrade cannot leave a control bound to a slot the shell does not serve.
    /// </summary>
    public static void SetShellCapacity(int capacity)
    {
        if (capacity <= 0)
        {
            return;
        }
        int clamped = Math.Clamp(capacity, MinMaxOverlays, s_maxOverlays);
        int[] preemptedSlots;
        IOpenHarmonyOverlaySlotOwner?[] preemptedOwners;
        int preemptedCount = 0;
        lock (s_sync)
        {
            s_shellCapacity = clamped;
            preemptedSlots = new int[s_maxOverlays];
            preemptedOwners = new IOpenHarmonyOverlaySlotOwner?[s_maxOverlays];
            for (int slot = clamped; slot < s_maxOverlays; slot++)
            {
                if (s_used[slot])
                {
                    preemptedSlots[preemptedCount] = slot;
                    preemptedOwners[preemptedCount] = s_owners[slot] as IOpenHarmonyOverlaySlotOwner;
                    preemptedCount++;
                    s_used[slot] = false;
                    s_owners[slot] = null;
                    s_created[slot] = false;
                }
            }
        }
        for (int i = 0; i < preemptedCount; i++)
        {
            preemptedOwners[i]?.OnOverlaySlotPreempted(preemptedSlots[i]);
        }
    }

    /// <summary>
    /// Claims the first free overlay slot (0, then 1, ...) with the legacy hard cap. Returns -1
    /// when the effective cap is reached; callers that pass no owner cannot be told about a
    /// preemption, so this overload must not silently hand an owner's overlay to someone else
    /// (that would render the wrong document for at least one control). A free dynamic slot that
    /// the shell has not declared yet is ensured first, so the returned slot is always servable.
    /// </summary>
    public static int Acquire()
    {
        int claimed;
        bool ensure;
        lock (s_sync)
        {
            claimed = ClaimFreeSlotLocked(null, out ensure);
        }
        if (claimed >= 0 && ensure)
        {
            SendSlotCommand("ensure", claimed);
        }
        return claimed;
    }

    /// <summary>
    /// Owner-aware claim (MULTI-OVERLAY-FULL / SLOTS-DYNAMIC). A free slot is claimed directly
    /// (creating it on demand when the shell has not declared it yet); when the effective
    /// capacity is full the least-recently-used slot whose owner is not engaged is preempted:
    /// its owner's <see cref="IOpenHarmonyOverlaySlotOwner.OnOverlaySlotPreempted"/> runs outside
    /// the lock and the claim transfers to <paramref name="owner"/>. Never returns -1 (the pool
    /// always has a victim), so a web control beyond the hot pair gets an overlay instead of
    /// falling back to the legacy untagged protocol.
    /// </summary>
    public static int Acquire(IOpenHarmonyOverlaySlotOwner owner)
    {
        ArgumentNullException.ThrowIfNull(owner);
        IOpenHarmonyOverlaySlotOwner? victim = null;
        int victimSlot = -1;
        int claimed;
        bool ensure;
        lock (s_sync)
        {
            claimed = ClaimFreeSlotLocked(owner, out ensure);
            if (claimed < 0)
            {
                victimSlot = SelectPreemptionVictim(EffectiveCapacityLocked());
                victim = s_owners[victimSlot] as IOpenHarmonyOverlaySlotOwner;
                s_used[victimSlot] = true;
                s_owners[victimSlot] = owner;
                s_lastUsed[victimSlot] = ++s_clock;
                s_created[victimSlot] = true;
            }
        }
        if (claimed >= 0)
        {
            if (ensure)
            {
                SendSlotCommand("ensure", claimed);
            }
            return claimed;
        }
        if (victim is not null && !ReferenceEquals(victim, owner))
        {
            victim.OnOverlaySlotPreempted(victimSlot);
        }
        return victimSlot;
    }

    /// <summary>
    /// Claims the first free slot below the effective capacity; reports through
    /// <paramref name="ensure"/> whether the shell still has to declare it. Caller holds
    /// <see cref="s_sync"/>.
    /// </summary>
    private static int ClaimFreeSlotLocked(object? owner, out bool ensure)
    {
        ensure = false;
        int capacity = EffectiveCapacityLocked();
        for (int slot = 0; slot < capacity; slot++)
        {
            if (!s_used[slot])
            {
                s_used[slot] = true;
                s_owners[slot] = owner;
                s_lastUsed[slot] = ++s_clock;
                ensure = !s_created[slot];
                s_created[slot] = true;
                return slot;
            }
        }
        return -1;
    }

    /// <summary>
    /// Picks the slot an owner-aware acquire preempts: the least-recently-used slot whose owner
    /// is not engaged (an owner-less legacy claim counts as not engaged). The caller holds
    /// <see cref="s_sync"/>.
    /// </summary>
    private static int SelectPreemptionVictim(int capacity)
    {
        int best = 0;
        bool bestEngaged = IsEngaged(0);
        for (int slot = 1; slot < capacity; slot++)
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

    /// <summary>
    /// Returns one claimed slot to the pool; -1 and out-of-range values are ignored. A released
    /// slot at or above <see cref="HotOverlays"/> is destroyed in the shell (SLOTS-DYNAMIC), so
    /// an idle dynamic ArkWeb cannot keep its engine and document alive; the hot pair survives.
    /// </summary>
    public static void Release(int slot)
    {
        ReleaseCore(slot, null);
    }

    /// <summary>
    /// Owner-checked release (MULTI-OVERLAY-FULL): frees the slot only while
    /// <paramref name="owner"/> still holds it. A preempted handler's late disconnect therefore
    /// cannot free the overlay a newer claim is using.
    /// </summary>
    public static bool Release(int slot, IOpenHarmonyOverlaySlotOwner owner)
    {
        ArgumentNullException.ThrowIfNull(owner);
        return ReleaseCore(slot, owner);
    }

    private static bool ReleaseCore(int slot, object? owner)
    {
        if (!IsValid(slot))
        {
            return false;
        }
        bool destroy = false;
        lock (s_sync)
        {
            if (owner is not null && !ReferenceEquals(s_owners[slot], owner))
            {
                return false;
            }
            s_used[slot] = false;
            s_owners[slot] = null;
            if (slot >= s_hotOverlays && s_created[slot])
            {
                s_created[slot] = false;
                destroy = true;
            }
        }
        if (destroy)
        {
            SendSlotCommand("destroy", slot);
        }
        return true;
    }

    /// <summary>
    /// Sends one shell slot-lifecycle command (SLOTS-DYNAMIC): op "slot", argument
    /// "ensure\n&lt;slot&gt;" or "destroy\n&lt;slot&gt;". The shell answers ensure by declaring
    /// the ArkWeb on demand and destroy by removing it; both are no-ops on a shell that
    /// predates the command (the hot pair still works).
    /// </summary>
    private static void SendSlotCommand(string action, int slot)
        => OpenHarmonyBridge.WebCommand("slot", action + "\n" + slot.ToString(CultureInfo.InvariantCulture));

    /// <summary>True for a slot index the pool can use.</summary>
    public static bool IsValid(int slot) => slot >= 0 && slot < s_maxOverlays;

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
    /// True while the shell has declared <paramref name="slot"/> (diagnostics/tests): the
    /// always-declared hot pair, or a dynamic slot after its "ensure" command (or the shell's
    /// own lazy create).
    /// </summary>
    public static bool IsCreated(int slot)
    {
        if (!IsValid(slot))
        {
            return false;
        }
        lock (s_sync)
        {
            return s_created[slot];
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
        if (!TryParseSlotTag(argument, out int taggedSlot))
        {
            return false;
        }
        slot = taggedSlot;
        payload = argument!.Length > 2 ? argument.Substring(3) : string.Empty;
        return true;
    }

    /// <summary>
    /// Parses the "s&lt;slot&gt;" first line of a tagged argument (optionally followed by
    /// '\n' and the payload). False for an untagged argument or a slot beyond the pool.
    /// </summary>
    private static bool TryParseSlotTag(string? argument, out int slot)
    {
        slot = -1;
        if (argument is null || argument.Length < 2 || argument[0] != SlotPrefix)
        {
            return false;
        }
        int digit = argument[1] - '0';
        if (digit < 0 || digit >= s_maxOverlays)
        {
            return false;
        }
        if (argument.Length > 2 && argument[2] != '\n')
        {
            return false;
        }
        slot = digit;
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
        if (digit < 0 || digit >= s_maxOverlays || state[2] != '|')
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
        => slot < 0 || slot >= s_maxOverlays
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
        if (tag <= 0 || tag > s_maxOverlays)
        {
            return false;
        }
        slot = tag - 1;
        return true;
    }

    /// <summary>
    /// Bit 30 of a hybrid-invoke request id marks the child-window channel (MULTIWINDOW-L3): the
    /// subwindow page numbers its held-open <c>__hwvInvokeDotNet</c> responses with it, the
    /// managed callback dispatches to the child window's handler, and the native result path
    /// (host_napi.cpp <c>ohos_host_hwv_invoke_result</c>) routes the answer back to the child
    /// page's own sink instead of the primary one. The primary encoding leaves the bit clear, so
    /// every existing id decodes exactly as before.
    /// </summary>
    public const int ChildInvokeFlag = 1 << 30;

    /// <summary>
    /// MULTIWINDOW-L3 M4: bit 29 of a child hybrid-invoke request id marks the second child
    /// window ("sub-2"). With two concurrent subwindows that both own child slot 0 the slot alone
    /// is ambiguous; the bit lets the managed callback pick the issuing window's handler and the
    /// native module route the result back to that window's own result sink. Window 0 (sub-1)
    /// leaves the bit clear, so its encoding is byte-for-byte the pre-M4 shape.
    /// </summary>
    public const int ChildSecondWindowFlag = 1 << 29;

    /// <summary>
    /// Composes a child-window hybrid-invoke request id: the child flag, the child pool slot
    /// (slot + 1 in the high byte, like the primary encoding) and the shell's 24-bit sequence.
    /// </summary>
    public static int EncodeChildInvokeRequestId(int slot, int sequence)
        => ChildInvokeFlag | EncodeInvokeRequestId(slot, sequence);

    /// <summary>
    /// MULTIWINDOW-L3 M4: composes a child-window hybrid-invoke request id for the given child
    /// window index (0 = sub-1, 1 = sub-2; out-of-range indices clamp to 0 like the shell).
    /// </summary>
    public static int EncodeChildInvokeRequestId(int windowIndex, int slot, int sequence)
        => (windowIndex > 0 ? ChildSecondWindowFlag : 0) | EncodeChildInvokeRequestId(slot, sequence);

    /// <summary>True when the request id carries the child-window flag.</summary>
    public static bool IsChildInvokeRequestId(int requestId)
        => (requestId & ChildInvokeFlag) != 0;

    /// <summary>
    /// Decodes a child-window hybrid-invoke request id. False for a primary/untagged id (whose
    /// slot byte never exceeds the overlay cap), for the flag alone and for a slot outside the
    /// child pool; the caller fails closed instead of dispatching to another window.
    /// </summary>
    public static bool TryDecodeChildInvokeRequestId(int requestId, out int slot, out int sequence)
        => TryDecodeChildInvokeRequestId(requestId, out _, out slot, out sequence);

    /// <summary>
    /// MULTIWINDOW-L3 M4: the window-aware decode. Both the child flag and the second-window flag
    /// are cleared before the slot byte is extracted, so either window's ids decode to their own
    /// slot; <paramref name="windowIndex"/> is 0 for sub-1 and 1 for sub-2.
    /// </summary>
    public static bool TryDecodeChildInvokeRequestId(int requestId, out int windowIndex, out int slot,
        out int sequence)
    {
        windowIndex = (requestId & ChildSecondWindowFlag) != 0 ? 1 : 0;
        slot = -1;
        sequence = requestId & InvokeSequenceMask;
        if ((requestId & ChildInvokeFlag) == 0)
        {
            return false;
        }
        // The flags sit above the slot byte, so clear both before extracting the slot (bit 30 is
        // not part of the slot + 1 tag).
        int tag = ((requestId & ~(ChildInvokeFlag | ChildSecondWindowFlag)) >> InvokeSlotShift) & 0xFF;
        if (tag <= 0 || tag > s_maxOverlays)
        {
            return false;
        }
        slot = tag - 1;
        return true;
    }
}
