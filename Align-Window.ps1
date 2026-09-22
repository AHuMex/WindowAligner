$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class WindowApi {
    public delegate bool EnumWindowsCallback(IntPtr hWnd, IntPtr data);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)] public struct MONITORINFO {
        public uint cbSize; public RECT rcMonitor, rcWork; public uint dwFlags;
    }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EnumWindows(EnumWindowsCallback callback, IntPtr data);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowTextLength(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter,
        int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", EntryPoint = "SetThreadDpiAwarenessContext", SetLastError = true)]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
}

public sealed class WindowChoice {
    public IntPtr Handle;
    public string Title;
    public string ProcessName;
    public uint ProcessId;
    public override string ToString() { return Title + "  [" + ProcessName + ", PID " + ProcessId + "]"; }
}
'@

function Use-PhysicalDpi([scriptblock]$Action) {
    $previous = [IntPtr]::Zero
    try {
        foreach ($context in @(-4, -3, -2)) {
            $previous = [WindowApi]::SetThreadDpiAwarenessContext([IntPtr]::new($context))
            if ($previous -ne [IntPtr]::Zero) { break }
        }
    }
    catch [System.EntryPointNotFoundException] { }
    try { & $Action }
    finally {
        if ($previous -ne [IntPtr]::Zero) {
            [void][WindowApi]::SetThreadDpiAwarenessContext($previous)
        }
    }
}

function Get-WindowChoices {
    $found = New-Object 'System.Collections.Generic.List[WindowChoice]'
    $callback = [WindowApi+EnumWindowsCallback] {
        param([IntPtr]$handle, [IntPtr]$data)
        if (-not [WindowApi]::IsWindowVisible($handle)) { return $true }
        $length = [WindowApi]::GetWindowTextLength($handle)
        if ($length -le 0) { return $true }
        $buffer = New-Object System.Text.StringBuilder ($length + 1)
        [void][WindowApi]::GetWindowText($handle, $buffer, $buffer.Capacity)
        $title = $buffer.ToString().Trim()
        if (-not $title) { return $true }
        $processId = [uint32]0
        [void][WindowApi]::GetWindowThreadProcessId($handle, [ref]$processId)
        if ($processId -eq $PID) { return $true }
        try { $name = (Get-Process -Id $processId -ErrorAction Stop).ProcessName }
        catch { $name = 'неизвестно' }
        $item = New-Object WindowChoice
        $item.Handle = $handle
        $item.Title = $title
        $item.ProcessName = $name
        $item.ProcessId = $processId
        $found.Add($item)
        return $true
    }
    [void][WindowApi]::EnumWindows($callback, [IntPtr]::Zero)
    return $found | Sort-Object Title, ProcessName
}

function Set-WindowAlignment([IntPtr]$handle, [bool]$atBottom) {
    if (-not [WindowApi]::IsWindow($handle)) { throw 'Окно закрыто. Обновите список.' }
    if ([WindowApi]::IsIconic($handle)) { throw 'Окно свернуто. Сначала восстановите его.' }

    $rect = New-Object WindowApi+RECT
    if (-not [WindowApi]::GetWindowRect($handle, [ref]$rect)) {
        throw "Не удалось получить размер окна (ошибка Win32: $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) { throw 'Некорректный размер окна.' }

    $monitor = [WindowApi]::MonitorFromWindow($handle, 2)
    if ($monitor -eq [IntPtr]::Zero) { throw 'Не удалось определить монитор окна.' }
    $info = New-Object WindowApi+MONITORINFO
    $info.cbSize = [uint32][Runtime.InteropServices.Marshal]::SizeOf([type][WindowApi+MONITORINFO])
    if (-not [WindowApi]::GetMonitorInfo($monitor, [ref]$info)) {
        throw "Не удалось получить рабочую область монитора (ошибка Win32: $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }

    $workWidth = $info.rcWork.Right - $info.rcWork.Left
    $workHeight = $info.rcWork.Bottom - $info.rcWork.Top
    $x = $info.rcWork.Left + [int][Math]::Floor(($workWidth - $width) / 2.0)
    if ($atBottom) { $y = $info.rcWork.Bottom - $height }
    else { $y = $info.rcWork.Top + [int][Math]::Floor(($workHeight - $height) / 2.0) }

    # Keep size, z-order and focus unchanged.
    $flags = [uint32](0x0001 -bor 0x0004 -bor 0x0010 -bor 0x0200)
    if (-not [WindowApi]::SetWindowPos($handle, [IntPtr]::Zero, $x, $y, 0, 0, $flags)) {
        throw "Не удалось переместить окно (ошибка Win32: $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }
    return "Готово: X=$x, Y=$y"
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Выравнивание окон'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(680, 360)
$form.MinimumSize = New-Object System.Drawing.Size(550, 310)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$instruction = New-Object System.Windows.Forms.Label
$instruction.Text = 'Выберите окно. Выравнивание учитывает рабочую область его монитора.'
$instruction.Location = New-Object System.Drawing.Point(16, 14)
$instruction.AutoSize = $true
$form.Controls.Add($instruction)

$list = New-Object System.Windows.Forms.ListBox
$list.Location = New-Object System.Drawing.Point(16, 42)
$list.Size = New-Object System.Drawing.Size(648, 245)
$list.Anchor = 'Top,Bottom,Left,Right'
$list.HorizontalScrollbar = $true
$form.Controls.Add($list)

$refresh = New-Object System.Windows.Forms.Button
$refresh.Text = 'Обновить'
$refresh.Location = New-Object System.Drawing.Point(16, 300)
$refresh.Size = New-Object System.Drawing.Size(110, 32)
$refresh.Anchor = 'Bottom,Left'
$form.Controls.Add($refresh)

$center = New-Object System.Windows.Forms.Button
$center.Text = 'Выровнять по центру'
$center.Location = New-Object System.Drawing.Point(136, 300)
$center.Size = New-Object System.Drawing.Size(160, 32)
$center.Anchor = 'Bottom,Left'
$center.Enabled = $false
$form.Controls.Add($center)

$bottom = New-Object System.Windows.Forms.Button
$bottom.Text = 'Выровнять по низу'
$bottom.Location = New-Object System.Drawing.Point(306, 300)
$bottom.Size = New-Object System.Drawing.Size(160, 32)
$bottom.Anchor = 'Bottom,Left'
$bottom.Enabled = $false
$form.Controls.Add($bottom)

$status = New-Object System.Windows.Forms.Label
$status.Text = 'Выберите окно.'
$status.Location = New-Object System.Drawing.Point(476, 306)
$status.Size = New-Object System.Drawing.Size(188, 22)
$status.Anchor = 'Bottom,Left,Right'
$status.AutoEllipsis = $true
$form.Controls.Add($status)

$list.Add_SelectedIndexChanged({
    $center.Enabled = ($null -ne $list.SelectedItem)
    $bottom.Enabled = $center.Enabled
})
$refresh.Add_Click({
    $list.Items.Clear()
    try {
        foreach ($item in (Get-WindowChoices)) { [void]$list.Items.Add($item) }
        $status.Text = "Найдено окон: $($list.Items.Count)"
    }
    catch {
        $status.Text = 'Ошибка обновления.'
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Ошибка')
    }
})
$center.Add_Click({
    if ($null -eq $list.SelectedItem) { return }
    try { $status.Text = Use-PhysicalDpi { Set-WindowAlignment $list.SelectedItem.Handle $false } }
    catch {
        $status.Text = 'Ошибка выравнивания.'
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Ошибка')
    }
})
$bottom.Add_Click({
    if ($null -eq $list.SelectedItem) { return }
    try { $status.Text = Use-PhysicalDpi { Set-WindowAlignment $list.SelectedItem.Handle $true } }
    catch {
        $status.Text = 'Ошибка выравнивания.'
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Ошибка')
    }
})
$form.Add_Shown({ $refresh.PerformClick() })
[void]$form.ShowDialog()
$form.Dispose()
