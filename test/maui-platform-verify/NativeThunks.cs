// FIX-R1-MARSHAL-OFF harness helper: enters a slice [UnmanagedCallersOnly] thunk through the
// exact native function pointer the slice registered, instead of binding the managed method
// with Delegate.CreateDelegate (which the runtime rejects for an [UnmanagedCallersOnly] method).
//
// The slice's reverse P/Invoke entries are now `static unsafe IntPtr s_callback = (IntPtr)
// (delegate* unmanaged[Cdecl]<...>)&OnNative...;` fields, so the drill needs two things:
//   NativeThunks.Pointer(type, fieldName) reads the registered pointer back reflectively, and
//   NativeThunks.Invoker<TDelegate>(pointer) wraps it in a Cdecl delegate the harness can call.
// The delegate types below mirror the native signatures the host calls; a mismatch is a test
// failure (the suite's signature pins plus the call itself), never a silent pass.
using System.Reflection;
using System.Runtime.InteropServices;

/// <summary>Reflective access to the slice's registered native thunks.</summary>
internal static class NativeThunks
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void SensorCallback(int type, float x, float y, float z, float w, long timestamp);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void SurfaceCallback(IntPtr window, int width, int height, int mode);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void VoidCallback();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void IntCallback(int value);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void PtrCallback(IntPtr payload);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void HybridInvokeCallback(int requestId, IntPtr method, IntPtr arguments);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void TouchCallback(int type, float x, float y, int pointerCount, int pointerId);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void FrameCallback(long timestamp, long targetTimestamp);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void PinchCallback(int phase, double scale, float x, float y);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void WebEventCallback(IntPtr stateUtf8, IntPtr urlUtf8);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void PickerResultCallback(int requestId, int rc, IntPtr nameUtf8, IntPtr dataUtf8);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void KeystoreResultCallback(int requestId, int rc, IntPtr dataUtf8);

    /// <summary>
    /// Reads the registered native function pointer from a private static IntPtr field. Throws
    /// when the field is missing or not bound, so a slice that stops registering the thunk fails
    /// the drill instead of silently skipping it.
    /// </summary>
    public static IntPtr Pointer(Type declaringType, string fieldName)
    {
        FieldInfo field = declaringType.GetField(fieldName, BindingFlags.NonPublic | BindingFlags.Static)
            ?? throw new InvalidOperationException(
                $"{declaringType.Name}.{fieldName} was not found; the drill pins its registered native thunk");
        if (field.GetValue(null) is IntPtr pointer && pointer != IntPtr.Zero)
        {
            return pointer;
        }
        throw new InvalidOperationException(
            $"{declaringType.Name}.{fieldName} is not a bound native function pointer (expected [UnmanagedCallersOnly] + delegate* unmanaged[Cdecl])");
    }

    /// <summary>Wraps a registered native function pointer in a callable Cdecl delegate.</summary>
    public static TDelegate Invoker<TDelegate>(IntPtr pointer)
        where TDelegate : Delegate
    {
        if (pointer == IntPtr.Zero)
        {
            throw new ArgumentException("the native function pointer is not bound", nameof(pointer));
        }
        return Marshal.GetDelegateForFunctionPointer<TDelegate>(pointer);
    }
}
