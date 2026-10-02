using Microsoft.OpenHarmony.Hosting;

/// <summary>
/// MULTI-OVERLAY-FULL pool drill owner: records the preemption the pool hands out and reports a
/// controllable engagement state, so the suite can drive LRU/engaged-preference decisions
/// without a device.
/// </summary>
internal sealed class MultiOverlayFakeOwner : IOpenHarmonyOverlaySlotOwner
{
    public MultiOverlayFakeOwner(string name, bool engaged = false)
    {
        Name = name;
        Engaged = engaged;
    }

    public string Name { get; }

    public bool Engaged { get; set; }

    public int Preemptions { get; private set; }

    public int PreemptedSlot { get; private set; } = -1;

    public void OnOverlaySlotPreempted(int slot)
    {
        Preemptions++;
        PreemptedSlot = slot;
    }

    public bool IsOverlaySlotEngaged => Engaged;
}
