param(
    [Parameter(Mandatory = $true)][int]$ProcessId,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

Add-Type -AssemblyName System.Drawing

if (-not ("NativeWindowCapture" -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class NativeWindowCapture
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint flags);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);
}
"@
}

# DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
[void][NativeWindowCapture]::SetProcessDpiAwarenessContext([IntPtr](-4))

$Process = Get-Process -Id $ProcessId -ErrorAction Stop
$Handle = $Process.MainWindowHandle
if ($Handle -eq [IntPtr]::Zero) { throw "The process has no main window handle." }

$Rect = New-Object NativeWindowCapture+RECT
if (-not [NativeWindowCapture]::GetWindowRect($Handle, [ref]$Rect)) {
    throw "GetWindowRect failed."
}

$Width = $Rect.Right - $Rect.Left
$Height = $Rect.Bottom - $Rect.Top
if ($Width -le 0 -or $Height -le 0) { throw "Invalid window dimensions: ${Width}x${Height}." }

$Bitmap = New-Object System.Drawing.Bitmap($Width, $Height)
$Graphics = [System.Drawing.Graphics]::FromImage($Bitmap)
try {
    $Hdc = $Graphics.GetHdc()
    try {
        if (-not [NativeWindowCapture]::PrintWindow($Handle, $Hdc, 2)) {
            throw "PrintWindow failed."
        }
    }
    finally {
        $Graphics.ReleaseHdc($Hdc)
    }
    $FullPath = [System.IO.Path]::GetFullPath($OutputPath)
    $Directory = [System.IO.Path]::GetDirectoryName($FullPath)
    if (-not [System.IO.Directory]::Exists($Directory)) { [System.IO.Directory]::CreateDirectory($Directory) | Out-Null }
    $Bitmap.Save($FullPath, [System.Drawing.Imaging.ImageFormat]::Png)
}
finally {
    $Graphics.Dispose()
    $Bitmap.Dispose()
}
