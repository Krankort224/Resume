$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Drawing
$taskRoot='C:\Repository\Resume\export\work'
$word=New-Object -ComObject Word.Application
$word.Visible=$false
$word.DisplayAlerts=0
$results=@()
try {
 foreach($file in (Get-ChildItem "$taskRoot\concept-*-sample.docx")) {
  $doc=$word.Documents.Open($file.FullName,$false,$true)
  $doc.Repaginate()
  $count=$doc.ComputeStatistics(2)
  $out=Join-Path $taskRoot $file.BaseName
  New-Item -ItemType Directory -Path $out -Force | Out-Null
  $doc.ActiveWindow.View.Type=3
  for($n=1;$n -le $count;$n++) {
   $bits=$doc.ActiveWindow.Panes.Item(1).Pages.Item($n).EnhMetaFileBits
   $stream=New-Object System.IO.MemoryStream(,$bits)
   $meta=New-Object System.Drawing.Imaging.Metafile($stream)
   $bmp=New-Object System.Drawing.Bitmap(1240,1754)
   $g=[System.Drawing.Graphics]::FromImage($bmp)
   $g.Clear([System.Drawing.Color]::White)
   $g.DrawImage($meta,0,0,1240,1754)
   $bmp.Save((Join-Path $out "page-$n.png"),[System.Drawing.Imaging.ImageFormat]::Png)
   $g.Dispose(); $bmp.Dispose(); $meta.Dispose(); $stream.Dispose()
  }
  $doc.Close(0)
  $doc=$word.Documents.Open($file.FullName,$false,$true)
  $doc.Repaginate(); $reopened=$doc.ComputeStatistics(2); $doc.Close(0)
  $results+=@{file=$file.Name;pages=$count;reopened_pages=$reopened}
  Write-Output "$($file.Name): $count pages, reopened $reopened"
 }
 $results | ConvertTo-Json | Set-Content "$taskRoot\issue-3-word-qa.json" -Encoding utf8
} finally { $word.Quit() }
