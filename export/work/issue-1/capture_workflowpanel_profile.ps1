param(
    [Parameter(Mandatory = $true)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. "C:\Repository\Tools\WorkflowPanel\_dev\workflow_panel.ps1"

$Context = New-ProfileSettingsEditor -ProfileFilePath "C:\Repository\Tools\WorkflowPanel\profiles\self.json"
try {
    $Form = $Context.Form
    $Form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $Form.Location = New-Object System.Drawing.Point(-10000, -10000)
    $Form.ShowInTaskbar = $false
    $Form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $Form.PerformLayout()
    foreach ($Control in $Form.Controls) {
        $Control.PerformLayout()
        foreach ($Child in $Control.Controls) { $Child.PerformLayout() }
    }
    $Context.Tabs.Select()
    [System.Windows.Forms.Application]::DoEvents()

    $Bitmap = New-Object System.Drawing.Bitmap($Form.Width, $Form.Height)
    try {
        $Bounds = New-Object System.Drawing.Rectangle(0, 0, $Form.Width, $Form.Height)
        $Form.DrawToBitmap($Bitmap, $Bounds)
        $FullPath = [System.IO.Path]::GetFullPath($OutputPath)
        $Directory = [System.IO.Path]::GetDirectoryName($FullPath)
        if (-not [System.IO.Directory]::Exists($Directory)) { [System.IO.Directory]::CreateDirectory($Directory) | Out-Null }
        $Bitmap.Save($FullPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $Bitmap.Dispose()
    }
}
finally {
    $Context.Form.Dispose()
}
