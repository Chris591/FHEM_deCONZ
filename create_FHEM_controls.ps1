$Filename = ".\controls_deCONZ.txt"
Remove-Item $Filename -Force
foreach($file in Get-ChildItem -Path .\FHEM) {
    $date = $file.LastWriteTimeUtc.ToString("yyyy_MM_dd_HH:mm:ss")
    $size = $file.Length
    "UPD $date $size " + $file.Directory.Name+ "/" + $file.Name >> $Filename
}
