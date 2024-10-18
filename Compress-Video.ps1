# Compress-Video.ps1

Param (
    [Parameter(Mandatory = $true, ValueFromPipeline = $true, Position = 0)]
    [string]$InputVideo
)

# Function to calculate video bitrate
function Calculate-Bitrate {
    param (
        [double]$TotalKBps,
        [double]$AudioKBps
    )
    $VideoKBps = $TotalKBps - $AudioKBps
    return [math]::Round($VideoKBps, 0)
}

# Define paths to ffmpeg and ffprobe located in the same directory as the script
$ffmpegPath = Join-Path $PSScriptRoot "ffmpeg.exe"
$ffprobePath = Join-Path $PSScriptRoot "ffprobe.exe"

# Check if ffmpeg and ffprobe exist
if (-not (Test-Path -Path $ffmpegPath)) {
    Write-Error "ffmpeg.exe not found in the script directory."
    Read-Host -Prompt "Press Enter to exit"
    exit 1
}

if (-not (Test-Path -Path $ffprobePath)) {
    Write-Error "ffprobe.exe not found in the script directory."
    Read-Host -Prompt "Press Enter to exit"
    exit 1
}

# Verify input file exists
if (-not (Test-Path -Path $InputVideo)) {
    Write-Error "Input file '$InputVideo' does not exist."
    Read-Host -Prompt "Press Enter to exit"
    exit 1
}

# Prompt user for target size in MB with input validation
do {
    $Input = Read-Host "Enter the desired target file size in MB (e.g., 18)"
    # Remove any leading/trailing whitespace
    $Input = $Input.Trim()
    
    # Initialize variable for parsed input
    $ParsedInput = 0
    
    # Check if input is a positive integer and within a reasonable range (e.g., 1-1000 MB)
    if ([int]::TryParse($Input, [ref]$ParsedInput) -and $ParsedInput -gt 0 -and $ParsedInput -le 1000) {
        $TargetSizeMB = $ParsedInput
        $ValidInput = $true
    }
    else {
        Write-Host "Please enter a valid positive integer between 1 and 1000 for the file size." -ForegroundColor Red
        $ValidInput = $false
    }
} until ($ValidInput)

# Get video information
$ffprobeOutput = & "$ffprobePath" -v quiet -print_format json -show_format -show_streams "$InputVideo"
$videoInfo = $ffprobeOutput | ConvertFrom-Json

$Duration = [double]$videoInfo.format.duration
if (-not $Duration) {
    Write-Error "Could not retrieve video duration."
    Read-Host -Prompt "Press Enter to exit"
    exit 1
}

$AudioStream = $videoInfo.streams | Where-Object { $_.codec_type -eq 'audio' } | Select-Object -First 1
if ($AudioStream) {
    $AudioKBps = [math]::Round($AudioStream.bit_rate / 1000, 0)
}
else {
    Write-Warning "No audio stream found. Using default audio bitrate of 128 kbps."
    $AudioKBps = 128
}

Write-Host "===== Video Information ====="
Write-Host "Duration (seconds): $Duration"
Write-Host "Audio Bitrate (kbps): $AudioKBps"
Write-Host "Target Size (MB): $TargetSizeMB"
Write-Host "============================"

# Calculate target video bitrate
$TotalKBps = ($TargetSizeMB * 8192) / $Duration  # 1 MB = 8192 kb
$VideoKBps = Calculate-Bitrate -TotalKBps $TotalKBps -AudioKBps $AudioKBps

Write-Host "Total Bitrate (kbps): $TotalKBps"
Write-Host "Video Bitrate (kbps): $VideoKBps"

if ($VideoKBps -le 0) {
    Write-Error "Calculated video bitrate is non-positive. Check target size and video duration."
    Read-Host -Prompt "Press Enter to exit"
    exit 1
}

# Set output file name in the same directory as input
$InputFileName = [System.IO.Path]::GetFileNameWithoutExtension($InputVideo)
$InputDirectory = [System.IO.Path]::GetDirectoryName($InputVideo)
$OutputFile = Join-Path $InputDirectory "${InputFileName}_${TargetSizeMB}MB.mp4"

Write-Host "===== Encoding Parameters ====="
Write-Host "Input Video: $InputVideo"
Write-Host "Output File: $OutputFile"
Write-Host "Video Bitrate (kbps): $VideoKBps"
Write-Host "Audio Bitrate (kbps): $AudioKBps"
Write-Host "==============================="

# Define pass log file path in TEMP directory to avoid clutter
$PassLog = "$env:TEMP\ffmpeg2pass"

# Two-pass encoding
$TwoPass = $true

if ($TwoPass) {
    Write-Host "Starting Two-Pass Encoding..."

    # First Pass with scaling to 720p
    Write-Host "First Pass..."
    & "$ffmpegPath" -y -i "$InputVideo" `
        -c:v libx264 `
        -b:v ${VideoKBps}k `
        -vf "scale=1280:720:force_original_aspect_ratio=decrease" `
        -pass 1 `
        -passlogfile $PassLog `
        -an `
        -f mp4 NUL
    if ($LASTEXITCODE -ne 0) {
        Write-Error "First pass encoding failed."
        Read-Host -Prompt "Press Enter to exit"
        exit 1
    }

    # Second Pass with scaling to 720p and audio encoding
    Write-Host "Second Pass..."
    & "$ffmpegPath" -y -i "$InputVideo" `
        -c:v libx264 `
        -b:v ${VideoKBps}k `
        -vf "scale=1280:720:force_original_aspect_ratio=decrease" `
        -pass 2 `
        -passlogfile $PassLog `
        -c:a aac `
        -b:a ${AudioKBps}k `
        "$OutputFile"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Second pass encoding failed."
        Read-Host -Prompt "Press Enter to exit"
        exit 1
    }

    # Clean up log files
    Remove-Item "$PassLog.log", "$PassLog.log.mbtree" -ErrorAction SilentlyContinue
}
else {
    Write-Host "Starting Single-Pass Encoding..."
    & "$ffmpegPath" -y -i "$InputVideo" `
        -c:v libx264 `
        -b:v ${VideoKBps}k `
        -vf "scale=1280:720:force_original_aspect_ratio=decrease" `
        -c:a aac `
        -b:a ${AudioKBps}k `
        "$OutputFile"
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Single-pass encoding failed."
        Read-Host -Prompt "Press Enter to exit"
        exit 1
    }
}

Write-Host "Compression Complete!"
Write-Host "Output File: '$OutputFile'"

# Wait for user to acknowledge before closing
Read-Host -Prompt "Press Enter to exit"
