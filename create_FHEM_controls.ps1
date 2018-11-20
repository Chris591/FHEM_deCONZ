$Filename = ".\controls_deCONZ.txt"
Remove-Item $Filename -Force
$Content = ""
foreach($file in Get-ChildItem -Path .\FHEM) {
    $date = $file.LastWriteTimeUtc.ToString("yyyy_MM_dd_HH:mm:ss")
    $size = $file.Length
    $Content += "UPD $date $size " + $file.Directory.Name+ "/" + $file.Name + "`n"
}
$Content = $Content.TrimEnd("`n")
$Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding $False
[System.IO.File]::WriteAllText($Filename, $Content, $Utf8NoBomEncoding)