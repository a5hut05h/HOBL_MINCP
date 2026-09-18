using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace InputInject;

internal sealed class HighResolutionPeriodicTimer : IDisposable
{
    private const uint CreateWaitableTimerHighResolution = 0x00000002;
    private const uint TimerAllAccess = 0x001F0003;
    private const uint WaitObject0 = 0x00000000;
    private const uint WaitFailed = 0xFFFFFFFF;
    private const uint Infinite = 0xFFFFFFFF;

    private readonly SafeWaitHandle timerHandle;

    public HighResolutionPeriodicTimer(TimeSpan interval)
    {
        int intervalMilliseconds = checked((int)interval.TotalMilliseconds);
        if (intervalMilliseconds <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(interval),
                "The timer interval must be at least one millisecond.");
        }

        timerHandle = CreateWaitableTimerEx(
            nint.Zero,
            null,
            CreateWaitableTimerHighResolution,
            TimerAllAccess);

        if (timerHandle.IsInvalid)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        long dueTime = -intervalMilliseconds * 10_000L;
        if (!SetWaitableTimer(
                timerHandle,
                ref dueTime,
                intervalMilliseconds,
                nint.Zero,
                nint.Zero,
                false))
        {
            int error = Marshal.GetLastWin32Error();
            timerHandle.Dispose();
            throw new Win32Exception(error);
        }
    }

    public void WaitForNextTick()
    {
        uint result = WaitForSingleObject(timerHandle, Infinite);
        if (result == WaitObject0)
        {
            return;
        }

        if (result == WaitFailed)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }

        throw new InvalidOperationException($"Unexpected timer wait result: 0x{result:X8}.");
    }

    public void Dispose()
    {
        timerHandle.Dispose();
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateWaitableTimerExW", SetLastError = true)]
    private static extern SafeWaitHandle CreateWaitableTimerEx(
        nint timerAttributes,
        [MarshalAs(UnmanagedType.LPWStr)] string? timerName,
        uint flags,
        uint desiredAccess);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWaitableTimer(
        SafeWaitHandle timerHandle,
        ref long dueTime,
        int periodMilliseconds,
        nint completionRoutine,
        nint completionArgument,
        [MarshalAs(UnmanagedType.Bool)] bool resume);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(
        SafeWaitHandle handle,
        uint milliseconds);
}
