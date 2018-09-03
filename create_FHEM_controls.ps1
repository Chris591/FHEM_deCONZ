Out-File .\controls_deCONZ.txt -Force -NoNewline -Encoding utf8
foreach($file in Get-ChildItem -Path .\FHEM) {
    $date = $file.LastWriteTimeUtc.ToString("yyyy_MM_dd_HH:mm:ss")
    $size = $file.Length
    "UPD $date $size " + $file.Directory.Name+ "/" + $file.Name + "`n" | Out-File .\controls_deCONZ.txt -Append -NoNewline -Encoding utf8
}
