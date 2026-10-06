// MULTIWINDOW-L2: the application subwindow's ArkWeb host (the second web host).
//
// The shell declares the ArkWeb overlay pool of the primary window in pages/Index.ets; the
// subwindow's own page (pages/SubWindow.ets) declares a second, independent pool and registers
// it through host.registerChildWebSink / host.registerChildWebEvalSink (host_napi.cpp). This
// class is the managed half:
//
//   * transport: the child host shares the single web command/eval wire. Commands are sent as
//     ohos_host_web_command with the op prefixed by CommandMarker ("child:"); the native module
//     strips the marker and posts to the child sink, so the primary sink is never touched. The
//     per-slot tag inside the argument keeps the exact same "s<slot>" codec the primary pool
//     uses (OpenHarmonyOverlays.Tag).
//   * slot pool: MaxOverlays slots (the shell's SUB_WEB_SLOT_MAX), first-free claims, no LRU
//     preemption (a child-window page with more simultaneous web controls than the pool keeps
//     the extras unmounted - documented). Every slot is dynamic: releasing it sends the shell's
//     "slot destroy", so an idle child ArkWeb does not keep its engine alive.
//   * ready gate: the child page can load after a managed web control connected. Commands for
//     a window that has not advertised its capacity ("w:<windowId>|capacity|<n>" page event)
//     are queued (bounded) and flushed when the advertisement arrives; a shell that predates
//     the child host never advertises and the queued commands are dropped, which is exactly the
//     pre-L2 behavior (no child web mount, no primary regression).
//   * events: the child page tags every page event with its window and slot
//     ("w:<windowId>|s<slot>|<state>"); OpenHarmonyWebViewHandler.OnPageEvent routes them by
//     window to the handler that owns the claim.
//
// Off-device (the headless suite) the native library is absent: CommandSent/PageEvent stay the
// observed surface and every native call degrades to a no-op (same contract as
// OpenHarmonyBridge.WebCommand). AOT-safe: Utf8 source-generated LibraryImport only.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Microsoft.OpenHarmony.Hosting;

/// <summary>
/// Window-scoped ArkWeb pool for the application subwindow (MULTIWINDOW-L2). Every member is
/// cheap, lock-protected and never throws; an unknown window is reported as not applicable.
/// </summary>
public static partial class OpenHarmonyChildWeb
{
    /// <summary>
    /// Prefix the managed transport puts on child commands/scripts. Mirrors kChildWebMarker in
    /// host_napi.cpp; a host library that predates the marker never receives one because the
    /// managed side only sends after the child page advertised its capacity.
    /// </summary>
    public const string CommandMarker = "child:";

    /// <summary>
    /// Prefix the child shell page puts on its page events ("w:&lt;window&gt;|s&lt;slot&gt;|..."),
    /// so OpenHarmonyWebViewHandler.OnPageEvent can tell them apart from the primary host's
    /// untagged "s&lt;slot&gt;|..." states.
    /// </summary>
    public const string StatePrefix = "w:";

    /// <summary>The primary window id (mirrors OpenHarmonyWindowSurface.PrimaryWindowId and the
    /// native OHOS_HOST_WINDOW_PRIMARY_ID; pinned together by the interaction suite).</summary>
    public const string PrimaryWindowId = "main";

    /// <summary>Overlay slots the subwindow host may declare (mirrors SUB_WEB_SLOT_MAX in
    /// pages/SubWindow.ets).</summary>
    public const int MaxOverlays = 2;

    /// <summary>Bound on the per-window pre-ready command queue; an overflowing command is
    /// dropped with one status line instead of growing without limit.</summary>
    public const int MaxPendingCommands = 64;

    private const string HostLibrary = "libopenharmonyhost.so";

    [LibraryImport(HostLibrary, EntryPoint = "ohos_host_web_command", StringMarshalling = StringMarshalling.Utf8)]
    private static partial int WebCommandNative(string op, string arg);

    [LibraryImport(HostLibrary, EntryPoint = "ohos_host_web_eval", StringMarshalling = StringMarshalling.Utf8)]
    private static partial int WebEvalNative(string script, int requestId);

    /// <summary>True once a native call failed to bind: every later send degrades to the
    /// observed no-op instead of throwing per command.</summary>
    private static bool s_nativeUnavailable;

    private sealed class HostState
    {
        /// <summary>Shell-advertised slot capacity (0 = not advertised yet).</summary>
        public int Capacity;
        public readonly bool[] Used = new bool[MaxOverlays];
        public readonly object?[] Owners = new object?[MaxOverlays];
        /// <summary>Commands that arrived before the shell page advertised its child host.</summary>
        public readonly List<PendingCommand> Pending = new();
        public bool OverflowLogged;
    }

    private readonly struct PendingCommand
    {
        public PendingCommand(string op, string? arg)
        {
            Op = op;
            Arg = arg;
        }

        public string Op { get; }
        public string? Arg { get; }
    }

    private static readonly object s_sync = new();
    private static readonly Dictionary<string, HostState> s_hosts = new(StringComparer.Ordinal);

    /// <summary>
    /// Raised for every child command before it reaches the native host (diagnostics/tests), with
    /// the window id, the op and the argument exactly as the child page would receive them.
    /// </summary>
    public static event Action<string, string, string?>? CommandSent;

    /// <summary>
    /// Raised for every child page event (window, slot, state, url), already routed off the
    /// primary pool's channel. State is the untagged "started/finished/error/history|..." rest.
    /// </summary>
    public static event Action<string, int, string, string>? PageEvent;

    /// <summary>True when the window is a secondary (non-primary) managed window.</summary>
    public static bool IsApplicable(string? windowId)
        => !string.IsNullOrEmpty(windowId) &&
           !string.Equals(windowId, PrimaryWindowId, StringComparison.Ordinal);

    /// <summary>True once the shell page of this window registered its child web host and
    /// advertised a usable capacity.</summary>
    public static bool IsReady(string? windowId)
    {
        if (!IsApplicable(windowId))
        {
            return false;
        }
        lock (s_sync)
        {
            return s_hosts.TryGetValue(windowId!, out HostState? host) && host.Capacity > 0;
        }
    }

    /// <summary>Advertised capacity of the window's child pool (0 while unknown).</summary>
    public static int GetCapacity(string? windowId)
    {
        if (!IsApplicable(windowId))
        {
            return 0;
        }
        lock (s_sync)
        {
            return s_hosts.TryGetValue(windowId!, out HostState? host) ? host.Capacity : 0;
        }
    }

    /// <summary>
    /// Claims the first free slot of the window's child pool; -1 when the pool is full. The
    /// claim is valid before the shell host is ready: commands are queued until the capacity
    /// advertisement arrives. Never throws.
    /// </summary>
    public static int Acquire(string windowId, IOpenHarmonyOverlaySlotOwner owner)
    {
        if (!IsApplicable(windowId) || owner is null)
        {
            return -1;
        }
        lock (s_sync)
        {
            HostState host = GetOrCreateLocked(windowId);
            int capacity = host.Capacity > 0 ? Math.Min(host.Capacity, MaxOverlays) : MaxOverlays;
            for (int slot = 0; slot < capacity; slot++)
            {
                if (!host.Used[slot])
                {
                    host.Used[slot] = true;
                    host.Owners[slot] = owner;
                    return slot;
                }
            }
            return -1;
        }
    }

    /// <summary>
    /// Returns one slot to the window's pool. An owner-checked release is refused once the slot
    /// was re-acquired (or belongs to another window's lifecycle). The shell destroys the slot
    /// when the page is ready; a pre-ready release only purges the queued commands of that slot.
    /// </summary>
    public static bool Release(string windowId, int slot, IOpenHarmonyOverlaySlotOwner owner)
    {
        if (!IsApplicable(windowId) || owner is null || slot < 0 || slot >= MaxOverlays)
        {
            return false;
        }
        bool destroy = false;
        lock (s_sync)
        {
            if (!s_hosts.TryGetValue(windowId, out HostState? host) || !host.Used[slot] ||
                !ReferenceEquals(host.Owners[slot], owner))
            {
                return false;
            }
            host.Used[slot] = false;
            host.Owners[slot] = null;
            if (host.Capacity > 0)
            {
                destroy = true;
            }
            else
            {
                host.Pending.RemoveAll(item => MatchesSlot(item.Arg, slot));
            }
        }
        if (destroy)
        {
            Send(windowId, "slot", "destroy\n" + slot.ToString(System.Globalization.CultureInfo.InvariantCulture));
        }
        return true;
    }

    /// <summary>True while the owner still holds the slot (diagnostics/tests).</summary>
    public static bool IsClaimedBy(string windowId, int slot, object owner)
    {
        if (!IsApplicable(windowId) || owner is null || slot < 0 || slot >= MaxOverlays)
        {
            return false;
        }
        lock (s_sync)
        {
            return s_hosts.TryGetValue(windowId, out HostState? host) && host.Used[slot] &&
                   ReferenceEquals(host.Owners[slot], owner);
        }
    }

    /// <summary>True while the slot is claimed by any owner (diagnostics/tests).</summary>
    public static bool IsClaimed(string windowId, int slot)
    {
        if (!IsApplicable(windowId) || slot < 0 || slot >= MaxOverlays)
        {
            return false;
        }
        lock (s_sync)
        {
            return s_hosts.TryGetValue(windowId, out HostState? host) && host.Used[slot];
        }
    }

    /// <summary>Number of queued pre-ready commands (diagnostics/tests).</summary>
    public static int PendingCount(string windowId)
    {
        if (!IsApplicable(windowId))
        {
            return 0;
        }
        lock (s_sync)
        {
            return s_hosts.TryGetValue(windowId, out HostState? host) ? host.Pending.Count : 0;
        }
    }

    /// <summary>
    /// Sends one per-overlay child command; <paramref name="arg"/> carries the "s&lt;slot&gt;"
    /// tag exactly like the primary wire. Before the child host is ready the command is queued
    /// and flushed by the capacity advertisement.
    /// </summary>
    public static void Command(string windowId, string op, string? arg = null)
    {
        if (!IsApplicable(windowId) || string.IsNullOrEmpty(op))
        {
            return;
        }
        Send(windowId, op, arg);
    }

    /// <summary>
    /// Runs one script on the window's ArkWeb controller; the shell answers through
    /// notifyWebEvalResult keyed by <paramref name="requestId"/>. False when the child host is
    /// not ready (nothing to run the script on yet) or the native call could not bind.
    /// </summary>
    public static bool Eval(string windowId, int slot, string script, int requestId)
    {
        if (!IsApplicable(windowId) || string.IsNullOrEmpty(script) || !IsReady(windowId) || s_nativeUnavailable)
        {
            return false;
        }
        string tagged = OpenHarmonyOverlays.TagScript(slot, script);
        try
        {
            return WebEvalNative(CommandMarker + tagged, requestId) == 0;
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
            s_nativeUnavailable = true;
            return false;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// Parses a child page-event state. False (window unchanged) for every state that is not
    /// tagged with <see cref="StatePrefix"/> - a primary or legacy event.
    /// </summary>
    public static bool TryParseState(string? state, out string windowId, out string rest)
    {
        windowId = string.Empty;
        rest = state ?? string.Empty;
        if (state is null || !state.StartsWith(StatePrefix, StringComparison.Ordinal))
        {
            return false;
        }
        int separator = state.IndexOf('|', StatePrefix.Length);
        if (separator <= StatePrefix.Length)
        {
            return false;
        }
        windowId = state.Substring(StatePrefix.Length, separator - StatePrefix.Length);
        rest = state.Substring(separator + 1);
        return windowId.Length > 0;
    }

    /// <summary>
    /// Applies one child-tagged page event. "capacity|&lt;n&gt;" marks the window's host ready and
    /// flushes its queued commands; "s&lt;slot&gt;|&lt;state&gt;" raises <see cref="PageEvent"/>.
    /// Malformed states are ignored.
    /// </summary>
    public static void CompleteState(string state, string url)
    {
        if (!TryParseState(state, out string windowId, out string rest))
        {
            return;
        }
        if (rest.StartsWith("capacity|", StringComparison.Ordinal))
        {
            if (int.TryParse(rest.Substring("capacity|".Length), out int capacity))
            {
                SetCapacity(windowId, capacity);
            }
            return;
        }
        if (rest.Length > 2 && rest[0] == 's' && rest[2] == '|' &&
            rest[1] >= '0' && rest[1] < '0' + MaxOverlays)
        {
            PageEvent?.Invoke(windowId, rest[1] - '0', rest.Substring(3), url ?? string.Empty);
        }
    }

    /// <summary>
    /// Records the shell's advertised child capacity ("capacity" page event) and flushes the
    /// commands queued before it. A repeated advertisement is idempotent.
    /// </summary>
    public static void SetCapacity(string windowId, int capacity)
    {
        if (!IsApplicable(windowId) || capacity <= 0)
        {
            return;
        }
        List<PendingCommand> flush;
        lock (s_sync)
        {
            HostState host = GetOrCreateLocked(windowId);
            host.Capacity = Math.Clamp(capacity, 1, MaxOverlays);
            flush = new List<PendingCommand>(host.Pending);
            host.Pending.Clear();
        }
        foreach (PendingCommand command in flush)
        {
            NativeSend(command.Op, command.Arg);
        }
    }

    /// <summary>
    /// Window-aware slot claim: the historical primary pool for the primary/unknown window,
    /// the subwindow's child pool otherwise. Handlers call this everywhere they used to call
    /// <see cref="OpenHarmonyOverlays.Acquire(IOpenHarmonyOverlaySlotOwner)"/>, so the primary
    /// path keeps its exact behavior.
    /// </summary>
    public static int AcquireForWindow(string? windowId, IOpenHarmonyOverlaySlotOwner owner)
        => IsApplicable(windowId)
            ? Acquire(windowId!, owner)
            : OpenHarmonyOverlays.Acquire(owner);

    /// <summary>Window-aware release (see <see cref="AcquireForWindow"/>).</summary>
    public static void ReleaseForWindow(string? windowId, int slot, IOpenHarmonyOverlaySlotOwner owner)
    {
        if (IsApplicable(windowId))
        {
            Release(windowId!, slot, owner);
        }
        else
        {
            OpenHarmonyOverlays.Release(slot, owner);
        }
    }

    /// <summary>
    /// Window-aware LRU touch (see <see cref="AcquireForWindow"/>). The child pool has no LRU
    /// preemption in this wave, so a child touch is a no-op.
    /// </summary>
    public static void TouchForWindow(string? windowId, int slot, IOpenHarmonyOverlaySlotOwner owner)
    {
        if (!IsApplicable(windowId))
        {
            OpenHarmonyOverlays.Touch(slot, owner);
        }
    }

    /// <summary>
    /// Window-aware command transport: primary/unknown keeps <see cref="OpenHarmonyBridge.WebCommand(string, string?)"/>
    /// byte-for-byte; a secondary window goes through the child transport (CommandMarker + sink).
    /// </summary>
    public static void CommandForWindow(string? windowId, string op, string? arg = null)
    {
        if (IsApplicable(windowId))
        {
            Command(windowId!, op, arg);
        }
        else
        {
            OpenHarmonyBridge.WebCommand(op, arg);
        }
    }

    /// <summary>Clears every window's pool state (the off-device suite's seam).</summary>
    internal static void ResetForTests()
    {
        lock (s_sync)
        {
            s_hosts.Clear();
        }
    }

    private static HostState GetOrCreateLocked(string windowId)
    {
        if (!s_hosts.TryGetValue(windowId, out HostState? host))
        {
            host = new HostState();
            s_hosts.Add(windowId, host);
        }
        return host;
    }

    /// <summary>
    /// Queues (pre-ready) or sends one child command. <see cref="CommandSent"/> observes every
    /// command either way, so diagnostics and tests see the transport independent of the shell's
    /// readiness.
    /// </summary>
    private static void Send(string windowId, string op, string? arg)
    {
        CommandSent?.Invoke(windowId, op, arg);
        bool queued = false;
        lock (s_sync)
        {
            HostState host = GetOrCreateLocked(windowId);
            if (host.Capacity <= 0)
            {
                if (host.Pending.Count >= MaxPendingCommands)
                {
                    if (!host.OverflowLogged)
                    {
                        host.OverflowLogged = true;
                        OpenHarmonyBridge.WriteStatus(
                            $"[maui] child web pending overflow: {windowId} {op}");
                    }
                    return;
                }
                host.Pending.Add(new PendingCommand(op, arg));
                queued = true;
            }
        }
        if (!queued)
        {
            NativeSend(op, arg);
        }
    }

    private static void NativeSend(string op, string? arg)
    {
        if (s_nativeUnavailable)
        {
            return;
        }
        try
        {
            WebCommandNative(CommandMarker + op, arg ?? string.Empty);
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
            // No native host (tests / a host library without the child route): degrade silently.
            s_nativeUnavailable = true;
        }
        catch (Exception)
        {
            // A command must never take the app down.
        }
    }

    /// <summary>
    /// True when the command's tagged argument names <paramref name="slot"/> ("s&lt;slot&gt;" or
    /// "s&lt;slot&gt;\n..."); untagged/global arguments do not belong to a slot and are kept.
    /// </summary>
    private static bool MatchesSlot(string? arg, int slot)
        => arg is not null && arg.Length >= 2 && arg[0] == OpenHarmonyOverlays.SlotPrefix &&
           arg[1] - '0' == slot && (arg.Length == 2 || arg[2] == '\n');
}
