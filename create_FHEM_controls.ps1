Out-File .\controls_deCONZ.txt -Force
foreach($file in Get-ChildItem -Path .\FHEM) {
    $date = $file.LastWriteTimeUtc.ToString("yyyy_MM_dd_HH:mm:ss")
    $size = $file.Length
    "UPD $date $size " + $file.Directory.Name+ "/" + $file.Name | Out-File .\controls_deCONZ.txt -Append
}
