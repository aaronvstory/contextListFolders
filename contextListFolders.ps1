<#!
.SYNOPSIS
  List a directory as a clean tree for humans AND export machine-readable outputs for automation.

.DESCRIPTION
  Prints a Unicode (or ASCII) tree of folders and files up to a given depth, with sizes and levels.
  Simultaneously, it can emit JSON, NDJSON (one JSON object per line), CSV, and Markdown.
  It is designed to be friendly for visual review and for AI/automation pipelines.

.PARAMETER Path
  Root path to inspect. Defaults to current directory.

.PARAMETER Depth
  How many levels deep to list (0 = only root, 1 = immediate children, 2 = two levels, etc.). Default: 1

.PARAMETER IncludeFiles
  Include files in the listing. On by default; use -NoFiles to only show folders.

.PARAMETER IncludeHidden
  Include hidden/system items. Off by default.

.PARAMETER Include
  Include only names matching these wildcard patterns (applied to file/folder name). Optional.

.PARAMETER Exclude
  Exclude names matching these wildcard patterns (applied to file/folder name). Optional.

.PARAMETER Extensions
  Include only these file extensions (e.g. '.py', '.md'). Case-insensitive. Optional.

.PARAMETER Output
  Console output type: Tree | List | None. Default: Tree.

.PARAMETER UseAscii
  Use ASCII tree characters (+--, |) instead of Unicode (├─, │, └─).

.PARAMETER OutJson
  Write a single JSON array file of all items.

.PARAMETER NdJson
  Also emit line-delimited JSON (one object per line) to the console pipeline.

.PARAMETER OutCsv
  Write a CSV export of core fields.

.PARAMETER OutTree
  Write the pretty tree output to a text file.

.PARAMETER MarkdownPath
  Write a Markdown file containing the tree (in a fenced code block) and a summary.

.PARAMETER MarkdownTimestamp
  If set and -MarkdownPath is not provided, auto-generate a timestamped Markdown file in the root
  named directory-tree_yyyyMMdd_HHmmss.md.

.PARAMETER PassThru
  Also return the item objects to the pipeline (useful in scripts).

.EXAMPLE
  .\contextListFolders.ps1 -Path C:\Project -Depth 3 -OutJson tree.json -OutCsv tree.csv -MarkdownPath tree.md -NdJson -PassThru

.NOTES
  Use with PowerShell -NoProfile to avoid startup banner lines.
#>
param(
  [Parameter(Position=0)]
  [string]$Path = (Get-Location).Path,

  [ValidateRange(0, 100)]
  [int]$Depth = 1,

  [Alias('Files')] [bool]$IncludeFiles = $true,
  [switch]$IncludeHidden,
  [string[]]$Include,
  [string[]]$Exclude,
  [string[]]$Extensions,

  [ValidateSet('Tree','List','None')]
  [string]$Output = 'Tree',
  [switch]$UseAscii,

  [string]$OutJson,
  [switch]$NdJson,
  [string]$OutCsv,
  [string]$OutTree,
  [string]$MarkdownPath,
  [switch]$MarkdownTimestamp,

  [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# PATH NORMALIZATION (handle drive roots like C:\ safely)
# ============================================================================
# Strip characters illegal in Windows paths (quotes, angle brackets, etc.)
$Path = $Path -replace '["><\|]', ''
$Path = $Path.Trim()
# Bare drive letter (e.g. "C:") -> add backslash
if ($Path -match '^[A-Za-z]:$') { $Path = "${Path}\" }
# Fallback if empty
if ([string]::IsNullOrWhiteSpace($Path)) { $Path = (Get-Location).Path }
# Normalize through .NET
$Path = [System.IO.Path]::GetFullPath($Path)

# ============================================================================
# INTERACTIVE MODE DETECTION
# ============================================================================
$script:InteractiveMode = -not $PSBoundParameters.ContainsKey('Depth')

if ($script:InteractiveMode) {
  # Path selection
  Write-Host ""
  Write-Host "Current path: " -NoNewline -ForegroundColor Gray
  Write-Host $Path -ForegroundColor Green
  $pathInput = Read-Host "Enter a new path or press Enter to keep current"
  if (-not [string]::IsNullOrWhiteSpace($pathInput)) {
    $pathInput = $pathInput -replace '["><\|]', ''
    $pathInput = $pathInput.Trim().Trim('"').Trim("'")
    if ($pathInput -match '^[A-Za-z]:$') { $pathInput = "${pathInput}\" }
    if (Test-Path -LiteralPath $pathInput) {
      $Path = [System.IO.Path]::GetFullPath($pathInput)
    } else {
      Write-Host "Path not found: $pathInput — using current path." -ForegroundColor Yellow
    }
  }

  $defaultDepth = 1
  while ($true) {
    $prompt = "Enter depth (0-100) [default: $defaultDepth]"
    $response = Read-Host -Prompt $prompt

    if ([string]::IsNullOrWhiteSpace($response)) {
      $Depth = $defaultDepth
      break
    }

    [int]$parsedDepth = 0
    if ([int]::TryParse($response, [ref]$parsedDepth) -and $parsedDepth -ge 0 -and $parsedDepth -le 100) {
      $Depth = $parsedDepth
      break
    }

    Write-Host "Please enter a number between 0 and 100." -ForegroundColor Yellow
  }

  # ===========================================================================
  # CONFIGURATION STATE (for interactive menu)
  # ===========================================================================
  $script:Config = @{
    Output        = 'Tree'
    IncludeFiles  = $true
    IncludeHidden = $false
    UseAscii      = $false
    Extensions    = @()
    Exclude       = @()
    ExportMD      = $false
    ExportJSON    = $false
    ExportCSV     = $false
    ExportTree    = $false
  }

  # Developer preset exclusions
  $script:DevExcludes = @(
    'node_modules', '.git', '.svn', '.hg',
    '__pycache__', '.pytest_cache', '.mypy_cache',
    '.venv', 'venv', 'env',
    'dist', 'build', 'out', 'bin', 'obj',
    '.vs', '.vscode', '.idea',
    'coverage', '.nyc_output', '.next', '.nuxt'
  )

  # ===========================================================================
  # MENU HELPER FUNCTIONS
  # ===========================================================================
  function Show-ConfigMenu {
    Clear-Host
    $folderName = Split-Path -Leaf $Path
    if ([string]::IsNullOrEmpty($folderName)) { $folderName = $Path.TrimEnd('\', '/') }
    $w = 62  # Menu width

    # Box drawing characters
    $tl = [char]0x250C  # top-left
    $tr = [char]0x2510  # top-right
    $bl = [char]0x2514  # bottom-left
    $br = [char]0x2518  # bottom-right
    $h  = [char]0x2500  # horizontal
    $v  = [char]0x2502  # vertical
    $lj = [char]0x251C  # left junction
    $rj = [char]0x2524  # right junction

    function Pad([string]$s, [int]$len) { $s.PadRight($len) }
    function Line([string]$left, [string]$content, [string]$right, [int]$width) {
      $inner = Pad $content ($width - 2)
      "$left$inner$right"
    }

    # Header
    Write-Host ($tl + ($h * ($w - 2)) + $tr) -ForegroundColor DarkCyan
    $title = "  SCAN CONFIGURATION"
    Write-Host ($v + (Pad $title ($w - 2)) + $v) -ForegroundColor DarkCyan
    Write-Host ($lj + ($h * ($w - 2)) + $rj) -ForegroundColor DarkCyan

    # Path and Depth info
    $pathInfo = "  Path: $folderName"
    $depthInfo = "  Depth: $Depth"
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline (Pad $pathInfo 30) -ForegroundColor Green
    Write-Host -NoNewline (Pad $depthInfo 30) -ForegroundColor Green
    Write-Host $v -ForegroundColor DarkCyan
    Write-Host ($lj + ($h * ($w - 2)) + $rj) -ForegroundColor DarkCyan

    # DISPLAY section
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline (Pad "  DISPLAY" ($w - 2)) -ForegroundColor Cyan
    Write-Host $v -ForegroundColor DarkCyan

    # Option 1: Output Format
    $val1 = $script:Config.Output
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline "  [" -ForegroundColor White
    Write-Host -NoNewline "1" -ForegroundColor Yellow
    Write-Host -NoNewline "] Output Format      : " -ForegroundColor Gray
    Write-Host -NoNewline (Pad $val1 34) -ForegroundColor Yellow
    Write-Host $v -ForegroundColor DarkCyan

    # Option 2: Include Files
    $val2 = if ($script:Config.IncludeFiles) { "Yes" } else { "No" }
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline "  [" -ForegroundColor White
    Write-Host -NoNewline "2" -ForegroundColor Yellow
    Write-Host -NoNewline "] Include Files      : " -ForegroundColor Gray
    Write-Host -NoNewline (Pad $val2 34) -ForegroundColor Yellow
    Write-Host $v -ForegroundColor DarkCyan

    # Option 3: Include Hidden
    $val3 = if ($script:Config.IncludeHidden) { "Yes" } else { "No" }
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline "  [" -ForegroundColor White
    Write-Host -NoNewline "3" -ForegroundColor Yellow
    Write-Host -NoNewline "] Include Hidden     : " -ForegroundColor Gray
    Write-Host -NoNewline (Pad $val3 34) -ForegroundColor Yellow
    Write-Host $v -ForegroundColor DarkCyan

    # Option 4: Use ASCII
    $val4 = if ($script:Config.UseAscii) { "Yes" } else { "No" }
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline "  [" -ForegroundColor White
    Write-Host -NoNewline "4" -ForegroundColor Yellow
    Write-Host -NoNewline "] Use ASCII          : " -ForegroundColor Gray
    Write-Host -NoNewline (Pad $val4 34) -ForegroundColor Yellow
    Write-Host $v -ForegroundColor DarkCyan

    # Empty line
    Write-Host ($v + (" " * ($w - 2)) + $v) -ForegroundColor DarkCyan

    # FILTERS section
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline (Pad "  FILTERS" ($w - 2)) -ForegroundColor Cyan
    Write-Host $v -ForegroundColor DarkCyan

    # Option 5: Extensions
    $val5 = if ($script:Config.Extensions.Count -gt 0) { ($script:Config.Extensions -join ', ') } else { "(all)" }
    if ($val5.Length -gt 32) { $val5 = $val5.Substring(0, 29) + "..." }
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline "  [" -ForegroundColor White
    Write-Host -NoNewline "5" -ForegroundColor Yellow
    Write-Host -NoNewline "] Extensions         : " -ForegroundColor Gray
    Write-Host -NoNewline (Pad $val5 34) -ForegroundColor Yellow
    Write-Host $v -ForegroundColor DarkCyan

    # Option 6: Exclude Patterns
    $val6 = if ($script:Config.Exclude.Count -gt 0) { ($script:Config.Exclude -join ', ') } else { "(none)" }
    if ($val6.Length -gt 32) { $val6 = $val6.Substring(0, 29) + "..." }
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline "  [" -ForegroundColor White
    Write-Host -NoNewline "6" -ForegroundColor Yellow
    Write-Host -NoNewline "] Exclude Patterns   : " -ForegroundColor Gray
    Write-Host -NoNewline (Pad $val6 34) -ForegroundColor Yellow
    Write-Host $v -ForegroundColor DarkCyan

    # Empty line
    Write-Host ($v + (" " * ($w - 2)) + $v) -ForegroundColor DarkCyan

    # EXPORTS section
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline (Pad "  EXPORTS  (auto-named, saved to scanned folder)" ($w - 2)) -ForegroundColor Cyan
    Write-Host $v -ForegroundColor DarkCyan

    # Option 7: Markdown
    $val7 = if ($script:Config.ExportMD) { "On" } else { "Off" }
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline "  [" -ForegroundColor White
    Write-Host -NoNewline "7" -ForegroundColor Yellow
    Write-Host -NoNewline "] Markdown (.md)     : " -ForegroundColor Gray
    $color7 = if ($script:Config.ExportMD) { "Green" } else { "DarkGray" }
    Write-Host -NoNewline (Pad $val7 34) -ForegroundColor $color7
    Write-Host $v -ForegroundColor DarkCyan

    # Option 8: JSON
    $val8 = if ($script:Config.ExportJSON) { "On" } else { "Off" }
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline "  [" -ForegroundColor White
    Write-Host -NoNewline "8" -ForegroundColor Yellow
    Write-Host -NoNewline "] JSON (.json)       : " -ForegroundColor Gray
    $color8 = if ($script:Config.ExportJSON) { "Green" } else { "DarkGray" }
    Write-Host -NoNewline (Pad $val8 34) -ForegroundColor $color8
    Write-Host $v -ForegroundColor DarkCyan

    # Option 9: CSV
    $val9 = if ($script:Config.ExportCSV) { "On" } else { "Off" }
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline "  [" -ForegroundColor White
    Write-Host -NoNewline "9" -ForegroundColor Yellow
    Write-Host -NoNewline "] CSV (.csv)         : " -ForegroundColor Gray
    $color9 = if ($script:Config.ExportCSV) { "Green" } else { "DarkGray" }
    Write-Host -NoNewline (Pad $val9 34) -ForegroundColor $color9
    Write-Host $v -ForegroundColor DarkCyan

    # Option 0: Tree Text
    $val0 = if ($script:Config.ExportTree) { "On" } else { "Off" }
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline "  [" -ForegroundColor White
    Write-Host -NoNewline "0" -ForegroundColor Yellow
    Write-Host -NoNewline "] Tree Text (.txt)   : " -ForegroundColor Gray
    $color0 = if ($script:Config.ExportTree) { "Green" } else { "DarkGray" }
    Write-Host -NoNewline (Pad $val0 34) -ForegroundColor $color0
    Write-Host $v -ForegroundColor DarkCyan

    # Empty line
    Write-Host ($v + (" " * ($w - 2)) + $v) -ForegroundColor DarkCyan

    # PRESETS section
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline "  [" -ForegroundColor White
    Write-Host -NoNewline "D" -ForegroundColor Magenta
    Write-Host -NoNewline "] Developer preset   " -ForegroundColor Gray
    Write-Host -NoNewline "[" -ForegroundColor White
    Write-Host -NoNewline "F" -ForegroundColor Magenta
    Write-Host -NoNewline "] Full export        " -ForegroundColor Gray
    Write-Host -NoNewline (Pad "" 14)
    Write-Host $v -ForegroundColor DarkCyan

    # Change path option
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline "  [" -ForegroundColor White
    Write-Host -NoNewline "P" -ForegroundColor Magenta
    Write-Host -NoNewline "] Change path        : " -ForegroundColor Gray
    $pathDisplay = $Path
    if ($pathDisplay.Length -gt 32) { $pathDisplay = "..." + $pathDisplay.Substring($pathDisplay.Length - 29) }
    Write-Host -NoNewline (Pad $pathDisplay 34) -ForegroundColor Green
    Write-Host $v -ForegroundColor DarkCyan

    # Footer separator
    Write-Host ($lj + ($h * ($w - 2)) + $rj) -ForegroundColor DarkCyan

    # Footer actions
    Write-Host -NoNewline $v -ForegroundColor DarkCyan
    Write-Host -NoNewline "  [" -ForegroundColor White
    Write-Host -NoNewline "Enter" -ForegroundColor Green
    Write-Host -NoNewline "] START SCAN  " -ForegroundColor Gray
    Write-Host -NoNewline "[" -ForegroundColor White
    Write-Host -NoNewline "Q" -ForegroundColor Red
    Write-Host -NoNewline "] Cancel" -ForegroundColor Gray
    Write-Host -NoNewline (Pad "" 27)
    Write-Host $v -ForegroundColor DarkCyan

    # Bottom border
    Write-Host ($bl + ($h * ($w - 2)) + $br) -ForegroundColor DarkCyan
  }

  function Apply-Preset {
    param([string]$Preset)
    switch ($Preset) {
      'Developer' {
        $script:Config.Exclude = $script:DevExcludes
        $script:Config.IncludeHidden = $false
      }
      'Full' {
        $script:Config.ExportMD   = $true
        $script:Config.ExportJSON = $true
        $script:Config.ExportCSV  = $true
        $script:Config.ExportTree = $true
      }
    }
  }

  # ===========================================================================
  # MODE SELECTION PROMPT
  # ===========================================================================
  Write-Host ""
  Write-Host "How would you like to proceed?" -ForegroundColor Cyan
  Write-Host "  [" -NoNewline; Write-Host "Enter" -ForegroundColor Green -NoNewline; Write-Host "] Quick scan (defaults)"
  Write-Host "  [" -NoNewline; Write-Host "C" -ForegroundColor Yellow -NoNewline; Write-Host "]     Customize options"
  Write-Host "  [" -NoNewline; Write-Host "D" -ForegroundColor Magenta -NoNewline; Write-Host "]     Developer preset (excludes node_modules, .git, etc.)"
  Write-Host "  [" -NoNewline; Write-Host "F" -ForegroundColor Magenta -NoNewline; Write-Host "]     Full export (all formats, auto-named)"
  Write-Host ""
  $modeChoice = Read-Host "Choice"

  $runScan = $true

  switch ($modeChoice.ToUpper()) {
    'C' {
      # Enter interactive menu
      $menuActive = $true
      while ($menuActive) {
        Show-ConfigMenu
        Write-Host ""
        $key = Read-Host "Option"

        switch ($key.ToUpper()) {
          '1' {
            # Cycle output format
            $formats = @('Tree', 'List', 'None')
            $idx = [array]::IndexOf($formats, $script:Config.Output)
            $script:Config.Output = $formats[($idx + 1) % 3]
          }
          '2' { $script:Config.IncludeFiles = -not $script:Config.IncludeFiles }
          '3' { $script:Config.IncludeHidden = -not $script:Config.IncludeHidden }
          '4' { $script:Config.UseAscii = -not $script:Config.UseAscii }
          '5' {
            Write-Host ""
            $extInput = Read-Host "Enter extensions (e.g., .py,.md,.txt) or empty to clear"
            if ([string]::IsNullOrWhiteSpace($extInput)) {
              $script:Config.Extensions = @()
            } else {
              $script:Config.Extensions = $extInput -split '[,;\s]+' | Where-Object { $_ } | ForEach-Object {
                if (-not $_.StartsWith('.')) { ".$_" } else { $_ }
              }
            }
          }
          '6' {
            Write-Host ""
            $exclInput = Read-Host "Enter patterns to exclude (e.g., node_modules,*.log) or empty to clear"
            if ([string]::IsNullOrWhiteSpace($exclInput)) {
              $script:Config.Exclude = @()
            } else {
              $script:Config.Exclude = $exclInput -split '[,;\s]+' | Where-Object { $_ }
            }
          }
          '7' { $script:Config.ExportMD = -not $script:Config.ExportMD }
          '8' { $script:Config.ExportJSON = -not $script:Config.ExportJSON }
          '9' { $script:Config.ExportCSV = -not $script:Config.ExportCSV }
          '0' { $script:Config.ExportTree = -not $script:Config.ExportTree }
          'D' { Apply-Preset 'Developer' }
          'F' { Apply-Preset 'Full' }
          'P' {
            Write-Host ""
            $newPath = Read-Host "Enter new path (e.g., C:\Projects)"
            if (-not [string]::IsNullOrWhiteSpace($newPath)) {
              $newPath = $newPath -replace '["><\|]', ''
              $newPath = $newPath.Trim().Trim('"').Trim("'")
              if ($newPath -match '^[A-Za-z]:$') { $newPath = "${newPath}\" }
              if (Test-Path -LiteralPath $newPath) {
                $Path = [System.IO.Path]::GetFullPath($newPath)
                Write-Host "Path changed to: $Path" -ForegroundColor Green
              } else {
                Write-Host "Path not found: $newPath" -ForegroundColor Red
              }
            }
          }
          'Q' {
            $menuActive = $false
            $runScan = $false
            Write-Host "Cancelled." -ForegroundColor Yellow
          }
          '' {
            # Enter pressed - start scan
            $menuActive = $false
          }
        }
      }
    }
    'D' {
      Apply-Preset 'Developer'
      Write-Host "Developer preset applied." -ForegroundColor Magenta
    }
    'F' {
      Apply-Preset 'Full'
      Write-Host "Full export preset applied." -ForegroundColor Magenta
    }
    'Q' {
      $runScan = $false
      Write-Host "Cancelled." -ForegroundColor Yellow
    }
    default {
      # Enter or anything else = quick scan with defaults
    }
  }

  if (-not $runScan) {
    exit 0
  }

  # ===========================================================================
  # APPLY CONFIG TO SCRIPT PARAMETERS
  # ===========================================================================
  $Output        = $script:Config.Output
  $IncludeFiles  = $script:Config.IncludeFiles
  $IncludeHidden = $script:Config.IncludeHidden
  $UseAscii      = $script:Config.UseAscii
  $Extensions    = $script:Config.Extensions
  $Exclude       = $script:Config.Exclude

  # Generate auto-named export paths
  $folderName = Split-Path -Leaf $Path
  if ([string]::IsNullOrEmpty($folderName)) { $folderName = $Path.TrimEnd('\', '/') }
  $timestamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
  $baseName   = "${folderName}_${timestamp}"

  if ($script:Config.ExportMD) {
    $MarkdownPath = Join-Path $Path "$baseName.md"
  }
  if ($script:Config.ExportJSON) {
    $OutJson = Join-Path $Path "$baseName.json"
  }
  if ($script:Config.ExportCSV) {
    $OutCsv = Join-Path $Path "$baseName.csv"
  }
  if ($script:Config.ExportTree) {
    $OutTree = Join-Path $Path "${baseName}_tree.txt"
  }

  Write-Host ""
  Write-Host "Starting scan..." -ForegroundColor Green
}

function Write-VerboseLine {
  param([string]$Message)
  Write-Verbose $Message
}

function Format-Size {
  param([long]$Bytes)
  if ($null -eq $Bytes) { return '' }
  $sizes = 'B','KB','MB','GB','TB','PB'
  if ($Bytes -lt 1) { return '0 B' }
  $i = [Math]::Floor([Math]::Log([double]$Bytes, 1024))
  if ($i -ge $sizes.Count) { $i = $sizes.Count - 1 }
  $num = $Bytes / [Math]::Pow(1024, $i)
  return ('{0:N2} {1}' -f $num, $sizes[$i])
}

function Join-RelativePath {
  param(
    [string]$Root,
    [string]$Full
  )
  try {
    $rel = Resolve-Path -LiteralPath $Full -Relative -ErrorAction Stop
    if ($rel -is [System.Array]) { return $rel[0] }
    return $rel
  } catch {
    # Fallback manual trim
    if ($Full -like "$Root*") { return $Full.Substring($Root.Length).TrimStart([char[]]@('\','/'))}
    return $Full
  }
}

function Test-MatchFilters {
  param(
    [System.IO.FileSystemInfo]$Item,
    [string[]]$Include,
    [string[]]$Exclude,
    [string[]]$Extensions
  )
  $name = $Item.Name

  if ($Extensions -and -not $Item.PSIsContainer) {
    $ext = [System.IO.Path]::GetExtension($name)
    $matchExt = $false
    foreach ($e in $Extensions) { if ($ext -ieq $e) { $matchExt = $true; break } }
    if (-not $matchExt) { return $false }
  }

  if ($Include) {
    $includeOk = $false
    foreach ($pat in $Include) { if ($name -like $pat) { $includeOk = $true; break } }
    if (-not $includeOk) { return $false }
  }
  if ($Exclude) {
    foreach ($pat in $Exclude) { if ($name -like $pat) { return $false } }
  }
  return $true
}

function Get-ChildSafe {
  param(
    [string]$Path,
    [switch]$IncludeHidden
  )
  $ea = 'SilentlyContinue'
  try {
    $items = Get-ChildItem -LiteralPath $Path -Force:$IncludeHidden -ErrorAction $ea
    return $items
  } catch {
    return @()
  }
}

# Unicode set (default)
$TreeChars = if ($UseAscii) {
  [pscustomobject]@{ Pipe='|   '; Space='    '; Tee='+-- '; Last='\\-- ' }
} else {
  [pscustomobject]@{ Pipe='│   '; Space='    '; Tee='├── '; Last='└── ' }
}

# Validate and normalize root
$rootInfo = Get-Item -LiteralPath $Path -ErrorAction Stop
$rootPath = $rootInfo.FullName

# Collect items and also build a pretty tree
$items = New-Object System.Collections.Generic.List[object]
$treeLines = New-Object System.Collections.Generic.List[string]
$rootSize = if ($rootInfo.PSIsContainer) { $null } else { $rootInfo.Length }
$rootDisplayName = $rootInfo.Name
if ([string]::IsNullOrEmpty($rootDisplayName)) { $rootDisplayName = $rootPath.TrimEnd('\', '/') }
$rootObj = [pscustomobject]@{
  Type          = if ($rootInfo.PSIsContainer) { 'Directory' } else { 'File' }
  Name          = $rootDisplayName
  FullName      = $rootInfo.FullName
  RelativePath  = '.'
  Level         = 0
  SizeBytes     = $rootSize
  Size          = if ($null -ne $rootSize) { Format-Size $rootSize } else { '' }
  Extension     = [System.IO.Path]::GetExtension($rootInfo.Name)
  IsHidden      = [bool]($rootInfo.Attributes -band [IO.FileAttributes]::Hidden)
  LastWriteTime = $rootInfo.LastWriteTime
  CreationTime  = $rootInfo.CreationTime
  Attributes    = $rootInfo.Attributes.ToString()
}
$items.Add($rootObj) | Out-Null
$treeLines.Add($rootDisplayName) | Out-Null

function Add-Children {
  param(
    [string]$Directory,
    [int]$Level,
    [int]$MaxDepth,
    [string[]]$PrefixParts
  )
  if ($Level -ge $MaxDepth) { return }

  $children = @(Get-ChildSafe -Path $Directory -IncludeHidden:$IncludeHidden)
  if (-not $children -or $children.Count -eq 0) { return }

  # Filter and sort: directories first, then files, name ascending
  $children = @($children | Where-Object {
    if (-not $_.PSIsContainer -and -not $IncludeFiles) { return $false }
    if (-not $IncludeHidden) {
      if ($_.Attributes -band [IO.FileAttributes]::Hidden) { return $false }
      if ($_.Attributes -band [IO.FileAttributes]::System) { return $false }
    }
    if ($_.PSIsContainer) {
      # For directories, apply only Exclude patterns (and always keep for traversal)
      if ($Exclude) {
        $n = $_.Name; if ($Exclude | Where-Object { $n -like $_ }) { return $false }
      }
      return $true
    } else {
      # For files, apply full filter set
      return (Test-MatchFilters -Item $_ -Include $Include -Exclude $Exclude -Extensions $Extensions)
    }
  } | Sort-Object @{Expression = { -not $_.PSIsContainer }}, Name)

  for ($i = 0; $i -lt $children.Count; $i++) {
    $child = $children[$i]
    $isLast = ($i -eq $children.Count - 1)

    $childSize = if ($child.PSIsContainer) { $null } else { $child.Length }
    $rel = Join-RelativePath -Root $rootPath -Full $child.FullName

    $obj = [pscustomobject]@{
      Type          = if ($child.PSIsContainer) { 'Directory' } else { 'File' }
      Name          = $child.Name
      FullName      = $child.FullName
      RelativePath  = $rel
      Level         = $Level + 1
      SizeBytes     = $childSize
      Size          = if ($null -ne $childSize) { Format-Size $childSize } else { '' }
      Extension     = [System.IO.Path]::GetExtension($child.Name)
      IsHidden      = [bool]($child.Attributes -band [IO.FileAttributes]::Hidden)
      LastWriteTime = $child.LastWriteTime
      CreationTime  = $child.CreationTime
      Attributes    = $child.Attributes.ToString()
    }
    $items.Add($obj) | Out-Null

    # Build tree prefix
    $prefix = ''
    if ($PrefixParts) {
      foreach ($p in $PrefixParts) { $prefix += $p }
    }
    $connector = if ($isLast) { $TreeChars.Last } else { $TreeChars.Tee }

    $sizeText = if ($child.PSIsContainer) { '' } else { '  ' + (Format-Size $child.Length) }
    $treeLines.Add($prefix + $connector + $child.Name + $sizeText) | Out-Null

    if ($child.PSIsContainer) {
      $nextPrefixParts = @()
      if ($PrefixParts) { $nextPrefixParts += $PrefixParts }
      $nextPrefixParts += if ($isLast) { $TreeChars.Space } else { $TreeChars.Pipe }
      Add-Children -Directory $child.FullName -Level ($Level + 1) -MaxDepth $MaxDepth -PrefixParts $nextPrefixParts
    }
  }
}

if ($rootInfo.PSIsContainer) {
  Add-Children -Directory $rootPath -Level 0 -MaxDepth $Depth -PrefixParts @()
}

# Build header for console/markdown
$context = [pscustomobject]@{
  RootPath   = $rootPath
  Depth      = $Depth
  Generated  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ssK')
  Host       = $env:COMPUTERNAME
  Username   = $env:USERNAME
  ItemCount  = $items.Count
  DirCount   = (@($items | Where-Object { $_.Type -eq 'Directory' })).Count
  FileCount  = (@($items | Where-Object { $_.Type -eq 'File' })).Count
}

# Console output
switch ($Output) {
  'Tree' {
    Write-Host ("Folder Path: {0}" -f $context.RootPath)
    Write-Host ("Depth: {0}" -f $context.Depth)
    $treeLines | ForEach-Object { Write-Host $_ }
    Write-Host ("`nSummary: {0} items ({1} dirs, {2} files)" -f $context.ItemCount, $context.DirCount, $context.FileCount)
  }
  'List' {
    # Tabular list with level
    $items | Select-Object Type, Level, RelativePath, Name, Size, LastWriteTime | Format-Table -AutoSize
  }
  'None' { }
}

# Auto-naming for Markdown if requested
if ($MarkdownTimestamp -and -not $MarkdownPath) {
  $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $MarkdownPath = Join-Path $rootPath ("directory-tree_{0}.md" -f $stamp)
}

# Optional outputs
if ($OutTree) {
  $header = @(
    "Folder Path: $($context.RootPath)",
    "Depth: $($context.Depth)",
    ''
  )
  Set-Content -LiteralPath $OutTree -Value ($header + $treeLines) -Encoding UTF8
}

if ($MarkdownPath) {
  $md = @()
  $md += "# Directory Tree"
  $md += ''
  $md += ("- Root: {0}" -f $context.RootPath)
  $md += ("- Depth: {0}" -f $context.Depth)
  $md += ("- Generated: {0}" -f $context.Generated)
  $md += ("- Items: {0} (Dirs: {1}, Files: {2})" -f $context.ItemCount, $context.DirCount, $context.FileCount)
  $md += ''
  $md += '```text'
  $md += $treeLines
  $md += '```'
  $md += ''
  $md += '## Data Schema'
  $md += 'Each row/object has: Type, Name, FullName, RelativePath, Level, SizeBytes, Size, Extension, IsHidden, LastWriteTime, CreationTime, Attributes.'
  Set-Content -LiteralPath $MarkdownPath -Value $md -Encoding UTF8
}

if ($OutJson) {
  $items | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $OutJson -Encoding UTF8
}

if ($NdJson) {
  $items | ForEach-Object { $_ | ConvertTo-Json -Compress }
}

if ($OutCsv) {
  $items |
    Select-Object Type,Level,RelativePath,Name,SizeBytes,Size,Extension,IsHidden,LastWriteTime,CreationTime,FullName,Attributes |
    Export-Csv -LiteralPath $OutCsv -UseCulture -NoTypeInformation
}

if ($PassThru) {
  $items
}
