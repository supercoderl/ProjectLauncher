#Requires -Version 5.1
<#
.SYNOPSIS
    C# Project Launcher - discovers .NET projects under a folder and runs them from a modern CLI menu.

.DESCRIPTION
    SCAN -> DISPLAY -> SELECT -> RUN.

    The launcher only reads project metadata (.sln, .slnx, .csproj, launchSettings.json).
    It never builds, restores or modifies your projects, and never changes ports,
    launchSettings.json or global environment variables.

.PARAMETER RootDirectory
    Folder to scan. Takes priority over config.json and the CSLAUNCHER_ROOT environment variable.

.PARAMETER Ascii
    Use plain ASCII characters for boxes and icons (for very old consoles or fonts).

.PARAMETER NoColor
    Disable ANSI colors. The NO_COLOR environment variable is honoured as well.

.PARAMETER Rescan
    Ignore the saved scan (cache.json) and scan the folder on startup.

.EXAMPLE
    .\ProjectLauncher.ps1

.EXAMPLE
    .\ProjectLauncher.ps1 "F:\Workspace"
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$RootDirectory,
    [switch]$Ascii,
    [switch]$NoColor,
    [switch]$Rescan
)

$ErrorActionPreference = 'Stop'

# ==============================================================================================
#  Settings
# ==============================================================================================

$script:AppVersion      = '1.0.0'
$script:ConfigPath      = Join-Path $PSScriptRoot 'config.json'
$script:CachePath       = Join-Path $PSScriptRoot 'cache.json'   # last scan result, reused on startup
$script:CacheVersion    = 1
$script:RootEnvVar      = 'CSLAUNCHER_ROOT'
$script:DefaultMaxDepth = 12

# Folders that are never scanned. In addition, every folder whose name starts with '.' is skipped
# (.git, .vs, .vscode, .idea, .github, ...).
$script:DefaultExcludes = @(
    '.git', '.vs', 'bin', 'obj', 'node_modules', 'packages', 'TestResults',
    '$RECYCLE.BIN', 'System Volume Information'
)

# Exit codes that mean "the user pressed Ctrl+C" rather than "the app failed".
$script:CtrlCExitCodes = @(-1073741510, 130)   # STATUS_CONTROL_C_EXIT, SIGINT convention

# ==============================================================================================
#  Native helpers (compiled once at startup)
#   - EnableVirtualTerminal : turns on ANSI colors in classic conhost (CMD / Windows PowerShell)
#   - RunAttached           : runs a child process in THIS console and waits for it. While it runs,
#                             Ctrl+C is ignored by the launcher (the child still receives it), so
#                             stopping your app returns you to the menu instead of killing the launcher.
# ==============================================================================================

$script:NativeSource = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace CsLauncher
{
    public static class Native
    {
        private delegate bool ConsoleCtrlDelegate(uint ctrlType);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleCtrlHandler(ConsoleCtrlDelegate handler, bool add);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr GetStdHandle(int nStdHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetConsoleMode(IntPtr handle, out uint mode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleMode(IntPtr handle, uint mode);

        private const int STD_OUTPUT_HANDLE = -11;
        private const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;

        // Returning true for CTRL_C_EVENT (0) and CTRL_BREAK_EVENT (1) stops the launcher's own
        // host from reacting. Every process attached to the console still gets the signal.
        private static readonly ConsoleCtrlDelegate SwallowBreak = ctrlType => ctrlType == 0 || ctrlType == 1;

        private static uint? originalMode;

        public static bool EnableVirtualTerminal()
        {
            IntPtr handle = GetStdHandle(STD_OUTPUT_HANDLE);
            uint mode;
            if (!GetConsoleMode(handle, out mode)) return false;
            if (!originalMode.HasValue) originalMode = mode;
            if ((mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0) return true;
            return SetConsoleMode(handle, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        }

        public static void RestoreConsoleMode()
        {
            if (!originalMode.HasValue) return;
            SetConsoleMode(GetStdHandle(STD_OUTPUT_HANDLE), originalMode.Value);
        }

        public static int RunAttached(string fileName, string arguments, string workingDirectory)
        {
            var info = new ProcessStartInfo(fileName, arguments);
            info.UseShellExecute = false;
            info.WorkingDirectory = workingDirectory;

            bool hooked = false;
            try { hooked = SetConsoleCtrlHandler(SwallowBreak, true); } catch { }
            try
            {
                using (Process process = Process.Start(info))
                {
                    process.WaitForExit();
                    return process.ExitCode;
                }
            }
            finally
            {
                if (hooked) { try { SetConsoleCtrlHandler(SwallowBreak, false); } catch { } }
            }
        }
    }
}
'@

# ==============================================================================================
#  Terminal setup: encoding, colors, glyphs
# ==============================================================================================

function Get-GlyphSet([string]$Tier) {
    function U([int]$CodePoint) { [char]::ConvertFromUtf32($CodePoint) }

    if ($Tier -eq 'ascii') {
        return @{
            DTL = '+'; DTR = '+'; DBL = '+'; DBR = '+'; DH = '='; DV = '|'
            RTL = '+'; RTR = '+'; RBL = '+'; RBR = '+'; H = '-'; V = '|'
            TTL = '+'; TT = '+'; TTR = '+'; TML = '+'; TX = '+'; TMR = '+'; TBL = '+'; TB = '+'; TBR = '+'
            Ok = '+'; Err = 'x'; Warn = '!'; Arrow = '->'; Dot = '*'; Bullet = '-'
            Full = '#'; Empty = '.'; Ell = '...'; Ell1 = '~'; Prompt = '>'; Rocket = ''
            Spinner = @('|', '/', '-', '\')
        }
    }

    # Box drawing + a few symbols from the WGL4 set: safe in classic conhost with Consolas.
    $g = @{
        DTL = U 0x2554; DTR = U 0x2557; DBL = U 0x255A; DBR = U 0x255D; DH = U 0x2550; DV = U 0x2551
        H   = U 0x2500; V   = U 0x2502
        TTL = U 0x250C; TT  = U 0x252C; TTR = U 0x2510
        TML = U 0x251C; TX  = U 0x253C; TMR = U 0x2524
        TBL = U 0x2514; TB  = U 0x2534; TBR = U 0x2518
        Arrow = U 0x2192; Dot = U 0x25CF; Bullet = U 0x2022
        Full  = U 0x2588; Empty = U 0x2591; Ell = U 0x2026; Ell1 = U 0x2026
    }

    if ($Tier -eq 'modern') {
        # Windows Terminal, VS Code, ConEmu, WezTerm: full Unicode + emoji.
        $g.RTL = U 0x256D; $g.RTR = U 0x256E; $g.RBL = U 0x2570; $g.RBR = U 0x256F
        $g.Ok = U 0x2713; $g.Err = U 0x2717; $g.Warn = U 0x26A0
        $g.Prompt = U 0x276F; $g.Rocket = U 0x1F680
        $g.Spinner = @(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F | ForEach-Object { U $_ })
    }
    else {
        # Classic console host: stick to glyphs every console font has.
        $g.RTL = $g.TTL; $g.RTR = $g.TTR; $g.RBL = $g.TBL; $g.RBR = $g.TBR
        $g.Ok = U 0x221A; $g.Err = U 0x00D7; $g.Warn = '!'
        $g.Prompt = '>'; $g.Rocket = U 0x25BA
        $g.Spinner = @('|', '/', '-', '\')
    }
    return $g
}

function Get-Palette([bool]$Enabled) {
    $codes = @{
        Reset = '0'; Bold = '1'
        Red = '91'; Green = '92'; Yellow = '93'; Blue = '94'; Magenta = '95'; Cyan = '96'; White = '97'; Gray = '90'
        Key = '1;96'
    }
    $palette = @{}
    $esc = [string][char]27
    foreach ($name in $codes.Keys) {
        $palette[$name] = if ($Enabled) { $esc + '[' + $codes[$name] + 'm' } else { '' }
    }
    return $palette
}

function Initialize-Terminal {
    $script:SavedEncoding = $null
    try {
        $script:SavedEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
    } catch { }

    if (-not ('CsLauncher.Native' -as [type])) {
        try { Add-Type -TypeDefinition $script:NativeSource -Language CSharp -ErrorAction Stop | Out-Null } catch { }
    }
    $script:Native = 'CsLauncher.Native' -as [type]

    $vt = $false
    if ($script:Native) { try { $vt = [bool]$script:Native::EnableVirtualTerminal() } catch { $vt = $false } }
    if (-not $vt -and $Host.UI.PSObject.Properties['SupportsVirtualTerminal']) { $vt = [bool]$Host.UI.SupportsVirtualTerminal }

    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { }

    $script:Interactive = -not $redirected
    $script:VT          = $vt -and -not $redirected
    $script:UseColor    = $script:VT -and -not $NoColor -and -not $env:NO_COLOR

    $modern = [bool]($env:WT_SESSION -or $env:TERM_PROGRAM -eq 'vscode' -or $env:ConEmuANSI -eq 'ON' -or $env:WEZTERM_EXECUTABLE)
    $tier = if ($Ascii) { 'ascii' } elseif ($modern) { 'modern' } else { 'classic' }

    $script:G = Get-GlyphSet $tier
    $script:A = Get-Palette $script:UseColor
}

function Restore-Terminal {
    if ($script:A) { [Console]::Write($script:A.Reset) }
    if ($script:Native) { try { $script:Native::RestoreConsoleMode() } catch { } }
    if ($script:SavedEncoding) { try { [Console]::OutputEncoding = $script:SavedEncoding } catch { } }
}

# ==============================================================================================
#  UI helpers
# ==============================================================================================

$script:BoxWidth = 62   # inner width of banners and section boxes

function Write-Line([string]$Text = '') { [Console]::WriteLine($Text) }
function Write-Text([string]$Text)      { [Console]::Write($Text) }

function Get-VisibleLength([string]$Text) { ($Text -replace '\x1b\[[0-9;]*m', '').Length }

function Get-ConsoleWidth {
    try { $w = [Console]::WindowWidth; if ($w -ge 40) { return $w } } catch { }
    return 120
}

function Limit-Text([string]$Text, [int]$Width) {
    if ($null -eq $Text) { $Text = '' }
    if ($Width -le 0) { return '' }
    if ($Text.Length -le $Width) { return $Text }
    if ($Width -eq 1) { return $Text.Substring(0, 1) }
    return $Text.Substring(0, $Width - 1) + $G.Ell1
}

function Get-Plural([int]$Count, [string]$Word) {
    if ($Count -eq 1) { return "$Count $Word" } else { return "$Count ${Word}s" }
}

function Clear-Screen {
    if ($script:Interactive) { try { Clear-Host } catch { } }
}

# Rewrites the current line in place (progress bars, spinners).
function Write-Inline([string]$Text) {
    if ($script:VT) {
        Write-Text ("`r" + $Text + [char]27 + '[K')
    }
    else {
        $pad = (Get-ConsoleWidth) - 1 - (Get-VisibleLength $Text)
        if ($pad -lt 0) { $pad = 0 }
        Write-Text ("`r" + $Text + (' ' * $pad))
    }
}

function Write-BannerRow([string]$Text = '', [string]$Style = '') {
    $w = $script:BoxWidth
    $left = [int][math]::Floor(($w - $Text.Length) / 2)
    $right = $w - $Text.Length - $left
    Write-Line ($A.Cyan + $G.DV + $A.Reset + (' ' * $left) + $Style + $Text + $A.Reset + (' ' * $right) + $A.Cyan + $G.DV + $A.Reset)
}

function Write-Banner([switch]$Compact) {
    $w = $script:BoxWidth
    $title = 'C# PROJECT LAUNCHER'
    if ($G.Rocket) { $title = $G.Rocket + ' ' + $title }

    Write-Line ($A.Cyan + $G.DTL + ($G.DH * $w) + $G.DTR + $A.Reset)
    if ($Compact) {
        $left = ' ' + $title
        $right = 'v' + $script:AppVersion + ' '
        $space = [math]::Max(1, $w - $left.Length - $right.Length)
        Write-Line ($A.Cyan + $G.DV + $A.Reset + $A.Bold + $A.White + $left + $A.Reset + (' ' * $space) + $A.Gray + $right + $A.Reset + $A.Cyan + $G.DV + $A.Reset)
    }
    else {
        Write-BannerRow
        Write-BannerRow $title ($A.Bold + $A.White)
        Write-BannerRow
        Write-BannerRow ("Fast $($G.Bullet) Simple $($G.Bullet) Developer Friendly") $A.Gray
        Write-BannerRow
    }
    Write-Line ($A.Cyan + $G.DBL + ($G.DH * $w) + $G.DBR + $A.Reset)
}

function Write-SectionTitle([string]$Title, [string]$Note = '') {
    $w = $script:BoxWidth
    $left = ' ' + $Title
    $right = if ($Note) { $Note + ' ' } else { '' }
    $space = [math]::Max(1, $w - $left.Length - $right.Length)
    Write-Line ($A.Gray + $G.RTL + ($G.H * $w) + $G.RTR + $A.Reset)
    Write-Line ($A.Gray + $G.V + $A.Reset + $A.Bold + $A.White + $left + $A.Reset + (' ' * $space) + $A.Gray + $right + $G.V + $A.Reset)
    Write-Line ($A.Gray + $G.RBL + ($G.H * $w) + $G.RBR + $A.Reset)
}

function Write-Rule { Write-Line ($A.Gray + ($G.H * ($script:BoxWidth + 2)) + $A.Reset) }

function Write-Status([string]$Kind, [string]$Text) {
    switch ($Kind) {
        'ok'    { $icon = $A.Green + $G.Ok }
        'err'   { $icon = $A.Red + $G.Err }
        'warn'  { $icon = $A.Yellow + $G.Warn }
        'run'   { $icon = $A.Cyan + $G.Arrow }
        default { $icon = $A.Blue + $G.Dot }
    }
    Write-Line ('  ' + $icon + $A.Reset + ' ' + $Text)
}

function Write-ErrorBlock([string]$Title, [System.Collections.IDictionary]$Sections, [string[]]$Footer) {
    Write-Line
    Write-Line ('  ' + $A.Red + $G.Err + ' ' + $A.Bold + $Title + $A.Reset)
    if ($Sections) {
        foreach ($key in $Sections.Keys) {
            Write-Line
            Write-Line ('  ' + $A.Gray + $key + ':' + $A.Reset)
            Write-Line ('  ' + $A.White + $Sections[$key] + $A.Reset)
        }
    }
    if ($Footer) {
        Write-Line
        foreach ($line in $Footer) { Write-Line ('  ' + $line) }
    }
    Write-Line
}

function Write-MenuKey($Key, [string]$Label, [string]$Hint = '') {
    $line = '  ' + $A.Key + '[' + $Key + ']' + $A.Reset + ' ' + $Label
    if ($Hint) { $line += '  ' + $A.Gray + $Hint + $A.Reset }
    Write-Line $line
}

function Set-Flash([string]$Kind, [string]$Text) { $script:Flash = @{ Kind = $Kind; Text = $Text } }

function Write-Flash {
    if ($script:Flash) {
        Write-Status $script:Flash.Kind $script:Flash.Text
        $script:Flash = $null
    }
}

function Read-Input([string]$Label) {
    if ($Label) { Write-Line ($A.Bold + $Label + $A.Reset) }
    Write-Text ($A.Cyan + $G.Prompt + $A.Reset + ' ')
    $line = [Console]::ReadLine()
    if ($null -eq $line) { return $null }
    return $line.Trim()
}

function Wait-Enter([string]$Message = 'Press ENTER to continue...') {
    Write-Line ('  ' + $A.Gray + $Message + $A.Reset)
    [void][Console]::ReadLine()
}

function Select-Option([string]$Title, [string[]]$Items) {
    while ($true) {
        Write-Line
        Write-Line ('  ' + $A.Bold + $A.White + $Title + $A.Reset)
        Write-Line
        for ($i = 0; $i -lt $Items.Count; $i++) {
            $hint = if ($i -eq 0) { '(default)' } else { '' }
            Write-MenuKey ($i + 1) $Items[$i] $hint
        }
        Write-MenuKey 'B' 'Back'
        Write-Line
        $answer = Read-Input 'Select (ENTER = 1):'
        if ($null -eq $answer -or $answer -match '^b(ack)?$') { return $null }
        if ($answer -eq '') { return $Items[0] }
        if ($answer -match '^\d{1,4}$' -and [int]$answer -ge 1 -and [int]$answer -le $Items.Count) {
            return $Items[[int]$answer - 1]
        }
        Write-Status warn "Please enter a number between 1 and $($Items.Count)."
    }
}

function Write-ProgressBar([int]$Current, [int]$Total, [string]$Label) {
    $width = 32
    $ratio = if ($Total -gt 0) { [double]$Current / $Total } else { 1.0 }
    $filled = [int][math]::Floor($ratio * $width)
    $percent = [int][math]::Floor($ratio * 100)
    $bar = $A.Cyan + ($G.Full * $filled) + $A.Gray + ($G.Empty * ($width - $filled)) + $A.Reset
    Write-Inline ('  [' + $bar + '] ' + ('{0,3}%' -f $percent) + '  ' + $A.Gray + (Limit-Text $Label 36) + $A.Reset)
}

# Generic box-drawn table. Columns: @{ Title; Width; Align = 'Left'|'Right'; Color }
function Write-Table([object[]]$Columns, $Rows) {
    $sep = $A.Gray + $G.V + $A.Reset
    $border = {
        param($left, $mid, $right)
        $segments = foreach ($c in $Columns) { $G.H * ($c.Width + 2) }
        '  ' + $A.Gray + $left + ($segments -join $mid) + $right + $A.Reset
    }

    Write-Line (& $border $G.TTL $G.TT $G.TTR)
    $cells = foreach ($c in $Columns) { ' ' + $A.Bold + $A.White + (Limit-Text $c.Title $c.Width).PadRight($c.Width) + $A.Reset + ' ' }
    Write-Line ('  ' + $sep + ($cells -join $sep) + $sep)
    Write-Line (& $border $G.TML $G.TX $G.TMR)

    foreach ($row in $Rows) {
        $cells = for ($i = 0; $i -lt $Columns.Count; $i++) {
            $c = $Columns[$i]
            $text = Limit-Text ([string]$row[$i]) $c.Width
            $text = if ($c.Align -eq 'Right') { $text.PadLeft($c.Width) } else { $text.PadRight($c.Width) }
            ' ' + $c.Color + $text + $A.Reset + ' '
        }
        Write-Line ('  ' + $sep + ($cells -join $sep) + $sep)
    }
    Write-Line (& $border $G.TBL $G.TB $G.TBR)
}

# ==============================================================================================
#  Configuration
#  Root directory priority: 1) command-line argument  2) config.json  3) CSLAUNCHER_ROOT  4) ask
# ==============================================================================================

function Read-LauncherConfig {
    $config = [ordered]@{ rootDirectory = $null; excludeDirectories = @(); maxDepth = $script:DefaultMaxDepth }
    $script:ConfigError = $null
    if (Test-Path -LiteralPath $script:ConfigPath) {
        try {
            $json = [IO.File]::ReadAllText($script:ConfigPath) | ConvertFrom-Json
            foreach ($property in $json.PSObject.Properties) { $config[$property.Name] = $property.Value }
        }
        catch {
            $script:ConfigError = "config.json could not be read: $($_.Exception.Message)"
        }
    }
    return $config
}

function Save-LauncherConfig([string]$Root) {
    $config = Read-LauncherConfig            # re-read so other keys are preserved
    $config['rootDirectory'] = $Root
    $json = $config | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object System.Text.UTF8Encoding $false))
}

function Get-MaxDepth {
    $depth = $script:DefaultMaxDepth
    try { $value = [int]$script:Config.maxDepth; if ($value -gt 0) { $depth = $value } } catch { }
    return $depth
}

function ConvertTo-FullPath([string]$Path, [string]$BaseDirectory) {
    if (-not $Path) { return $null }
    $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"').Trim("'"))
    if (-not $p) { return $null }
    try {
        if (-not [IO.Path]::IsPathRooted($p)) {
            $base = if ($BaseDirectory) { $BaseDirectory } else { (Get-Location -PSProvider FileSystem).ProviderPath }
            $p = [IO.Path]::Combine($base, $p)
        }
        $full = [IO.Path]::GetFullPath($p)
        if ($full.Length -gt 3) { $full = $full.TrimEnd('\', '/') }
        return $full
    }
    catch { return $null }
}

function Test-Directory([string]$Path) { return ($Path -and [IO.Directory]::Exists($Path)) }

function Request-RootDirectory {
    while ($true) {
        Write-Line
        $answer = Read-Input 'Enter the folder that contains your projects (or Q to quit):'
        if ($null -eq $answer -or $answer -match '^q(uit)?$') { return $null }
        if ($answer -eq '') { continue }

        $full = ConvertTo-FullPath $answer
        if (-not (Test-Directory $full)) {
            Write-Status err "The directory does not exist: $answer"
            continue
        }

        Write-Line
        $save = Read-Input 'Save this folder to config.json for next time? [Y/n]'
        $saved = $false
        if ($null -ne $save -and $save -notmatch '^n(o)?$') {
            try { Save-LauncherConfig $full; $saved = $true; Write-Status ok 'Saved to config.json' }
            catch { Write-Status warn "Could not write config.json: $($_.Exception.Message)" }
        }
        return @{ Path = $full; Saved = $saved }
    }
}

function Initialize-Root {
    $candidate = $null; $source = $null; $base = $null
    $envValue = [Environment]::GetEnvironmentVariable($script:RootEnvVar)

    if ($RootDirectory) {
        $candidate = $RootDirectory; $source = 'command-line argument'
    }
    elseif ($script:Config.rootDirectory) {
        $candidate = [string]$script:Config.rootDirectory; $source = 'config.json'; $base = $PSScriptRoot
    }
    elseif ($envValue) {
        $candidate = $envValue; $source = "environment variable $($script:RootEnvVar)"
    }

    Clear-Screen
    Write-Banner

    if ($candidate) {
        $full = ConvertTo-FullPath $candidate $base
        if (Test-Directory $full) {
            $script:Root = $full
            $script:RootSource = $source
            return $true
        }
        Write-ErrorBlock 'The configured directory does not exist.' ([ordered]@{ Path = $candidate; Source = $source }) @('Please update the configuration.')
    }
    else {
        Write-Line
        if ($script:ConfigError) { Write-Status warn $script:ConfigError }
        Write-Status info 'No root directory is configured yet.'
        Write-Line ('  ' + $A.Gray + 'Set "rootDirectory" in config.json, pass a folder as an argument, or enter one now.' + $A.Reset)
    }

    $answer = Request-RootDirectory
    if (-not $answer) { return $false }
    $script:Root = $answer.Path
    $script:RootSource = if ($answer.Saved) { 'config.json' } else { 'entered for this session' }
    return $true
}

# ==============================================================================================
#  Project detectors
#
#  The scanner is language-agnostic. Each detector declares the file extensions it owns and
#  supplies scriptblocks for reading solutions, inspecting a project file and building the
#  launch command. Version 1 registers only the C# detector (see the bottom of this file).
#
#  To add a language later (Node, Python, Go, ...), write the equivalent functions and call
#  Register-ProjectDetector with a new hashtable - nothing else has to change.
# ==============================================================================================

$script:Detectors = New-Object System.Collections.Generic.List[hashtable]

function Register-ProjectDetector([hashtable]$Detector) { $script:Detectors.Add($Detector) }

function New-ProjectRecord([string]$Path, [string]$Language) {
    [pscustomobject]@{
        Index          = 0
        Name           = [IO.Path]::GetFileNameWithoutExtension($Path)
        Language       = $Language
        Detector       = $null
        ProjectFile    = $Path
        Directory      = [IO.Path]::GetDirectoryName($Path)
        RelativePath   = ''
        Type           = 'Unknown'
        Frameworks     = @()
        Framework      = '-'
        Solution       = ''
        IsRunnable     = $false
        Reason         = ''
        LaunchProfiles = @()
    }
}

# ---------------------------------------- C# / .NET -------------------------------------------

function Test-True([string]$Value) { return [bool]($Value -and $Value.Trim() -eq 'true') }

# Returns the value of an MSBuild property. Unconditional definitions win; the last one counts,
# like MSBuild's own evaluation. Falls back to the first conditional value.
function Get-MsBuildProperty([System.Xml.XmlDocument]$Xml, [string]$Name) {
    $result = $null; $fallback = $null
    foreach ($node in $Xml.SelectNodes("//*[local-name()='$Name']")) {
        $value = $node.InnerText.Trim()
        if (-not $value) { continue }
        $parent = $node.ParentNode
        $conditional = $node.HasAttribute('Condition') -or ($parent -is [System.Xml.XmlElement] -and $parent.HasAttribute('Condition'))
        if (-not $conditional) { $result = $value }
        elseif ($null -eq $fallback) { $fallback = $value }
    }
    if ($result) { return $result }
    return $fallback
}

function Read-XmlFile([string]$Path) {
    $xml = New-Object System.Xml.XmlDocument
    $xml.XmlResolver = $null
    $xml.Load($Path)
    return $xml
}

# Target framework inherited from the nearest Directory.Build.props (cached per folder).
function Find-InheritedFrameworks([string]$Directory) {
    if (-not $Directory) { return $null }
    if ($script:PropsCache.ContainsKey($Directory)) { return $script:PropsCache[$Directory] }

    $result = $null
    $props = [IO.Path]::Combine($Directory, 'Directory.Build.props')
    if ([IO.File]::Exists($props)) {
        try {
            $xml = Read-XmlFile $props
            $result = Get-MsBuildProperty $xml 'TargetFrameworks'
            if (-not $result) { $result = Get-MsBuildProperty $xml 'TargetFramework' }
        } catch { }
    }
    if (-not $result) { $result = Find-InheritedFrameworks ([IO.Path]::GetDirectoryName($Directory)) }

    $script:PropsCache[$Directory] = $result
    return $result
}

# Names of launch profiles that 'dotnet run' can use (commandName = Project), in file order.
# The first one is what 'dotnet run' picks by default.
function Get-LaunchProfiles([string]$ProjectDirectory) {
    $file = [IO.Path]::Combine($ProjectDirectory, 'Properties', 'launchSettings.json')
    if (-not [IO.File]::Exists($file)) { return @() }
    try {
        $raw = [IO.File]::ReadAllText($file)
        $raw = [regex]::Replace($raw, '(?m)^\s*//.*$', '')      # line comments
        $raw = [regex]::Replace($raw, ',(\s*[}\]])', '$1')       # trailing commas
        $json = $raw | ConvertFrom-Json
        $names = @()
        if ($json.profiles) {
            foreach ($profile in $json.profiles.PSObject.Properties) {
                if ($profile.Value.commandName -eq 'Project') { $names += $profile.Name }
            }
        }
        return $names
    }
    catch { return @() }
}

function Read-CSharpSolution([string]$Path) {
    $directory = [IO.Path]::GetDirectoryName($Path)
    $relative = @()
    if ($Path.EndsWith('.slnx', [StringComparison]::OrdinalIgnoreCase)) {
        $xml = Read-XmlFile $Path
        $relative = @($xml.SelectNodes("//*[local-name()='Project']") | ForEach-Object { $_.GetAttribute('Path') })
    }
    else {
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            if ($line -match '^\s*Project\("\{[^}]*\}"\)\s*=\s*"[^"]*"\s*,\s*"([^"]+\.csproj)"') { $relative += $Matches[1] }
        }
    }
    foreach ($item in $relative) {
        if (-not $item) { continue }
        $item = $item.Replace('\', [IO.Path]::DirectorySeparatorChar).Replace('/', [IO.Path]::DirectorySeparatorChar)
        try { [IO.Path]::GetFullPath([IO.Path]::Combine($directory, $item)) } catch { }
    }
}

function Get-CSharpProjectInfo([string]$Path) {
    $p = New-ProjectRecord -Path $Path -Language 'C#'

    try { $xml = Read-XmlFile $Path }
    catch {
        $p.Type = 'Unreadable'
        $p.Reason = 'The project file is not valid XML.'
        return $p
    }

    # --- SDKs: <Project Sdk="..">, <Sdk Name=".."/>, <Import Sdk=".."/> ---
    $root = $xml.DocumentElement
    $sdkValues = @()
    if ($root.HasAttribute('Sdk')) { $sdkValues += $root.GetAttribute('Sdk') }
    foreach ($n in $xml.SelectNodes("//*[local-name()='Sdk']"))          { $sdkValues += $n.GetAttribute('Name') }
    foreach ($n in $xml.SelectNodes("//*[local-name()='Import'][@Sdk]")) { $sdkValues += $n.GetAttribute('Sdk') }
    $sdks = @($sdkValues | ForEach-Object { $_ -split ';' } | ForEach-Object { ($_ -split '/')[0].Trim() } | Where-Object { $_ })

    $packages = @($xml.SelectNodes("//*[local-name()='PackageReference']") | ForEach-Object { $_.GetAttribute('Include') } | Where-Object { $_ })

    $isLegacy = $sdks.Count -eq 0
    $isWeb    = $sdks -contains 'Microsoft.NET.Sdk.Web'
    $isWasm   = $sdks -contains 'Microsoft.NET.Sdk.BlazorWebAssembly'
    $isWorker = $sdks -contains 'Microsoft.NET.Sdk.Worker'
    $isRazor  = $sdks -contains 'Microsoft.NET.Sdk.Razor'
    $isAspire = (Test-True (Get-MsBuildProperty $xml 'IsAspireHost')) -or ($sdks -contains 'Aspire.AppHost.Sdk')
    $isTest   = (Test-True (Get-MsBuildProperty $xml 'IsTestProject')) -or ($sdks -contains 'MSTest.Sdk') -or ($packages -contains 'Microsoft.NET.Test.Sdk')
    $isMaui   = Test-True (Get-MsBuildProperty $xml 'UseMaui')
    $functionsVersion = Get-MsBuildProperty $xml 'AzureFunctionsVersion'

    # --- Target framework(s) ---
    $tf = Get-MsBuildProperty $xml 'TargetFrameworks'
    if (-not $tf) { $tf = Get-MsBuildProperty $xml 'TargetFramework' }
    if (-not $tf -and $isLegacy) {
        $version = Get-MsBuildProperty $xml 'TargetFrameworkVersion'
        if ($version) { $tf = 'net' + (($version -replace '^[vV]', '') -replace '\.', '') }
    }
    if (-not $tf) { $tf = Find-InheritedFrameworks $p.Directory }
    $p.Frameworks = @(if ($tf) { $tf -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ } })
    $p.Framework = if ($p.Frameworks.Count) { $p.Frameworks -join ', ' } else { '-' }

    # --- Output type (web / worker / Aspire SDKs imply Exe) ---
    $outputType = Get-MsBuildProperty $xml 'OutputType'
    if (-not $outputType) {
        $outputType = if ($isWeb -or $isWasm -or $isWorker -or $isAspire) { 'Exe' } else { 'Library' }
    }
    $isExe = @('Exe', 'WinExe', 'AppContainerExe') -contains $outputType

    # --- Classification ---
    if ($isLegacy) {
        if ($isExe) {
            $p.Type = '.NET Framework App'
            $p.Reason = "Legacy (non-SDK) project format. 'dotnet run' only supports SDK-style projects; open it in Visual Studio instead."
        }
        else {
            $p.Type = '.NET Framework Library'
            $p.Reason = 'The project appears to be a class library.'
        }
    }
    elseif ($isTest) {
        $p.Type = 'Test Project'
        $p.Reason = "This is a test project. Run it with 'dotnet test' instead."
    }
    elseif ($isAspire) {
        $p.Type = 'Aspire AppHost'
        $p.IsRunnable = $true
    }
    elseif ($isMaui) {
        $p.Type = 'MAUI App'
        $p.Reason = "MAUI apps need a target platform/device. Start it from Visual Studio or with 'dotnet build -t:Run -f <framework>'."
    }
    elseif ($functionsVersion) {
        $p.Type = 'Azure Functions'
        $p.Reason = "Azure Functions run inside the Functions host. Use 'func start' in the project folder."
    }
    elseif ($isExe) {
        $p.IsRunnable = $true
        $p.Type = if ($isWasm) { 'Blazor WebAssembly' }
                  elseif ($isWeb) { 'ASP.NET Core' }
                  elseif ($isWorker) { 'Worker Service' }
                  elseif (Test-True (Get-MsBuildProperty $xml 'UseWPF')) { 'WPF App' }
                  elseif (Test-True (Get-MsBuildProperty $xml 'UseWindowsForms')) { 'Windows Forms' }
                  elseif ($outputType -eq 'WinExe') { 'Windows App' }
                  else { 'Console App' }
    }
    else {
        $p.Type = if ($isRazor) { 'Razor Class Library' } elseif ($isWeb) { 'Web Library' } else { 'Class Library' }
        $p.Reason = 'The project appears to be a class library.'
    }

    if ($p.IsRunnable) { $p.LaunchProfiles = @(Get-LaunchProfiles $p.Directory) }
    return $p
}

function Test-DotNetSdk {
    if ($script:DotNetSdk) { return $script:DotNetSdk }   # only success is cached

    $missing = @{
        Ok = $false
        Title = '.NET SDK was not found.'
        Footer = @('Please install the .NET SDK and make sure', "'dotnet' is available in PATH.", '', ($A.Gray + 'Download: https://dot.net/download' + $A.Reset))
    }

    $command = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { return $missing }

    $sdks = $null
    try { $sdks = & $command.Path --list-sdks 2>$null } catch { }
    if (-not $sdks) {
        $missing.Footer = @("'dotnet' was found, but no SDK is installed (runtime only).", 'Please install the .NET SDK.', '', ($A.Gray + 'Download: https://dot.net/download' + $A.Reset))
        return $missing
    }

    $script:DotNetSdk = @{ Ok = $true; Path = $command.Path }
    return $script:DotNetSdk
}

function ConvertTo-CommandLine([string[]]$Arguments) {
    $quoted = foreach ($arg in $Arguments) {
        if ($arg -eq '' -or $arg -match '[\s"\\/]') { '"' + ($arg -replace '"', '\"') + '"' } else { $arg }
    }
    return ($quoted -join ' ')
}

function Get-DotNetRunCommand($Project, [hashtable]$Options) {
    $sdk = Test-DotNetSdk
    $arguments = @('run', '--project', $Project.ProjectFile)
    if ($Options.Framework) { $arguments += @('--framework', $Options.Framework) }
    if ($Options.Profile)   { $arguments += @('--launch-profile', $Options.Profile) }
    return @{
        FileName         = $sdk.Path
        Arguments        = $arguments
        WorkingDirectory = $Project.Directory
        Display          = 'dotnet ' + (ConvertTo-CommandLine $arguments)
    }
}

# ==============================================================================================
#  Scanner
# ==============================================================================================

function New-ScanResult {
    param(
        $Projects = @(), [int]$SolutionCount = 0, [int]$FolderCount = 0, [TimeSpan]$Elapsed = [TimeSpan]::Zero,
        $ScannedAt = $null, [switch]$FromCache, [switch]$RootMissing
    )
    $all = @($Projects)
    [pscustomobject]@{
        Projects      = $all
        Runnable      = @($all | Where-Object { $_.IsRunnable })
        Others        = @($all | Where-Object { -not $_.IsRunnable })
        SolutionCount = $SolutionCount
        FolderCount   = $FolderCount
        Elapsed       = $Elapsed
        ScannedAt     = $(if ($ScannedAt) { [datetime]$ScannedAt } else { Get-Date })
        FromCache     = [bool]$FromCache
        RootMissing   = [bool]$RootMissing
    }
}

# ---------------------------------------- Scan cache ------------------------------------------
# The last scan is stored in cache.json next to the script. On startup it is loaded instead of
# scanning, so the menu appears instantly. Press R (or start with -Rescan) to scan again.
# The cache belongs to one root folder; switching folders ignores it and scans fresh.

function Save-ScanCache($Scan, [string]$Root) {
    $projects = foreach ($p in $Scan.Projects) {
        [ordered]@{
            Index          = $p.Index
            DetectorId     = $p.Detector.Id
            Language       = $p.Language
            Name           = $p.Name
            ProjectFile    = $p.ProjectFile
            Directory      = $p.Directory
            RelativePath   = $p.RelativePath
            Type           = $p.Type
            Frameworks     = @($p.Frameworks)
            Framework      = $p.Framework
            Solution       = $p.Solution
            IsRunnable     = [bool]$p.IsRunnable
            Reason         = $p.Reason
            LaunchProfiles = @($p.LaunchProfiles)
        }
    }
    $data = [ordered]@{
        version       = $script:CacheVersion
        rootDirectory = $Root
        scannedAt     = $Scan.ScannedAt.ToString('o')
        elapsedMs     = [int]$Scan.Elapsed.TotalMilliseconds
        folderCount   = $Scan.FolderCount
        solutionCount = $Scan.SolutionCount
        projects      = @($projects)
    }
    try {
        $json = ConvertTo-Json -InputObject $data -Depth 6
        [IO.File]::WriteAllText($script:CachePath, $json, (New-Object System.Text.UTF8Encoding $false))
    }
    catch {
        Set-Flash warn "The scan could not be cached: $($_.Exception.Message)"
    }
}

function Read-ScanCache([string]$Root) {
    if (-not [IO.File]::Exists($script:CachePath)) { return $null }
    try {
        $data = [IO.File]::ReadAllText($script:CachePath) | ConvertFrom-Json
        if ($data.version -ne $script:CacheVersion) { return $null }
        if (-not [string]::Equals([string]$data.rootDirectory, $Root, [StringComparison]::OrdinalIgnoreCase)) { return $null }

        $projects = New-Object System.Collections.Generic.List[object]
        foreach ($item in @($data.projects)) {
            if (-not $item) { continue }
            $detector = $script:Detectors | Where-Object { $_.Id -eq $item.DetectorId } | Select-Object -First 1
            if (-not $detector) { continue }
            $p = New-ProjectRecord -Path ([string]$item.ProjectFile) -Language ([string]$item.Language)
            $p.Index          = [int]$item.Index
            $p.Detector       = $detector
            $p.Name           = [string]$item.Name
            $p.Directory      = [string]$item.Directory
            $p.RelativePath   = [string]$item.RelativePath
            $p.Type           = [string]$item.Type
            $p.Frameworks     = @($item.Frameworks | Where-Object { $_ } | ForEach-Object { [string]$_ })
            $p.Framework      = [string]$item.Framework
            $p.Solution       = [string]$item.Solution
            $p.IsRunnable     = [bool]$item.IsRunnable
            $p.Reason         = [string]$item.Reason
            $p.LaunchProfiles = @($item.LaunchProfiles | Where-Object { $_ } | ForEach-Object { [string]$_ })
            $projects.Add($p)
        }

        $scannedAt = [datetime]::Parse([string]$data.scannedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        return New-ScanResult -Projects ($projects | Sort-Object Index) -SolutionCount ([int]$data.solutionCount) `
            -FolderCount ([int]$data.folderCount) -Elapsed ([TimeSpan]::FromMilliseconds([double]$data.elapsedMs)) `
            -ScannedAt $scannedAt.ToLocalTime() -FromCache
    }
    catch {
        return $null   # unreadable or outdated cache: just scan again
    }
}

function Format-Age([datetime]$Since) {
    $span = (Get-Date) - $Since
    if ($span.TotalMinutes -lt 1) { return 'just now' }
    if ($span.TotalHours -lt 1)   { return (Get-Plural ([int][math]::Floor($span.TotalMinutes)) 'minute') + ' ago' }
    if ($span.TotalDays -lt 1)    { return (Get-Plural ([int][math]::Floor($span.TotalHours)) 'hour') + ' ago' }
    return (Get-Plural ([int][math]::Floor($span.TotalDays)) 'day') + ' ago'
}

function Get-RelativePath([string]$Root, [string]$Path) {
    if ($Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
        $relative = $Path.Substring($Root.Length).TrimStart('\', '/')
        if ($relative) { return $relative } else { return '.' }
    }
    return $Path
}

function Invoke-ProjectScan([string]$Root) {
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $script:PropsCache = @{}
    $maxDepth = Get-MaxDepth

    $excluded = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($script:DefaultExcludes) + @($script:Config.excludeDirectories)) { if ($name) { [void]$excluded.Add([string]$name) } }

    # extension -> which detector owns it, and whether it is a project or a solution file
    $routes = @{}
    foreach ($detector in $script:Detectors) {
        foreach ($ext in $detector.ProjectExtensions)  { $routes[$ext.ToLowerInvariant()] = @{ Detector = $detector; Kind = 'Project' } }
        foreach ($ext in $detector.SolutionExtensions) { $routes[$ext.ToLowerInvariant()] = @{ Detector = $detector; Kind = 'Solution' } }
    }

    # ---- Phase 1: walk the tree (metadata only, excluded folders are never entered) ----
    $found = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push(@($Root, 0))
    $folders = 0; $projectCount = 0; $frame = 0
    $tick = [Diagnostics.Stopwatch]::StartNew()

    while ($stack.Count -gt 0) {
        $item = $stack.Pop()
        $directory = $item[0]; $depth = $item[1]
        $folders++

        try { $files = [IO.Directory]::GetFiles($directory) } catch { $files = @() }
        foreach ($file in $files) {
            $route = $routes[[IO.Path]::GetExtension($file).ToLowerInvariant()]
            if ($route) {
                $found.Add([pscustomobject]@{ Path = $file; Kind = $route.Kind; Detector = $route.Detector })
                if ($route.Kind -eq 'Project') { $projectCount++ }
            }
        }

        if ($depth -lt $maxDepth) {
            try { $subdirectories = [IO.Directory]::GetDirectories($directory) } catch { $subdirectories = @() }
            for ($i = $subdirectories.Count - 1; $i -ge 0; $i--) {
                $name = [IO.Path]::GetFileName($subdirectories[$i])
                if ($name.StartsWith('.') -or $excluded.Contains($name)) { continue }
                $stack.Push(@($subdirectories[$i], ($depth + 1)))
            }
        }

        if ($script:Interactive -and $tick.ElapsedMilliseconds -ge 80) {
            $spinner = $G.Spinner[$frame % $G.Spinner.Count]; $frame++
            Write-Inline ('  ' + $A.Cyan + $spinner + $A.Reset + ' Searching ' + ('{0:N0}' -f $folders) + ' folders ' + $G.Bullet + ' ' + (Get-Plural $projectCount 'project file'))
            $tick.Restart()
        }
    }

    # ---- Phase 2: read solutions, then inspect each project file ----
    $solutionMap = @{}
    $solutions = @($found | Where-Object { $_.Kind -eq 'Solution' })
    foreach ($solution in $solutions) {
        $solutionName = [IO.Path]::GetFileName($solution.Path)
        $members = @()
        try { $members = @(& $solution.Detector.ReadSolution $solution.Path) } catch { }
        foreach ($member in $members) {
            $key = $member.ToLowerInvariant()
            if (-not $solutionMap.ContainsKey($key)) { $solutionMap[$key] = New-Object System.Collections.Generic.List[string] }
            if (-not $solutionMap[$key].Contains($solutionName)) { $solutionMap[$key].Add($solutionName) }
        }
    }

    $projectFiles = @($found | Where-Object { $_.Kind -eq 'Project' })
    $projects = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($entry in $projectFiles) {
        $index++
        if ($script:Interactive -and ($tick.ElapsedMilliseconds -ge 40 -or $index -eq 1)) {
            Write-ProgressBar $index $projectFiles.Count ([IO.Path]::GetFileName($entry.Path))
            $tick.Restart()
        }

        try { $project = & $entry.Detector.Inspect $entry.Path }
        catch {
            $project = New-ProjectRecord -Path $entry.Path -Language $entry.Detector.Language
            $project.Type = 'Unreadable'
            $project.Reason = "The project file could not be read: $($_.Exception.Message)"
        }
        $project.Detector = $entry.Detector
        $project.RelativePath = Get-RelativePath $Root $project.Directory
        $key = $entry.Path.ToLowerInvariant()
        if ($solutionMap.ContainsKey($key)) { $project.Solution = ($solutionMap[$key] -join ', ') }
        $projects.Add($project)
    }

    if ($script:Interactive) {
        Write-ProgressBar 1 1 ('{0:N0} folders searched' -f $folders)
        Write-Line
    }

    # Stable order: by location, runnable projects numbered first, then the others.
    $sorted = @($projects | Sort-Object -Property RelativePath, Name)
    $ordered = @($sorted | Where-Object { $_.IsRunnable }) + @($sorted | Where-Object { -not $_.IsRunnable })
    for ($i = 0; $i -lt $ordered.Count; $i++) { $ordered[$i].Index = $i + 1 }

    $stopwatch.Stop()
    return New-ScanResult -Projects $ordered -SolutionCount $solutions.Count -FolderCount $folders -Elapsed $stopwatch.Elapsed
}

# ==============================================================================================
#  Screens
# ==============================================================================================

function Get-TypeColor([string]$Type) {
    if ($Type -like 'ASP.NET*' -or $Type -like 'Blazor*' -or $Type -like 'Aspire*') { return $A.Magenta }
    if ($Type -like 'Worker*') { return $A.Yellow }
    if ($Type -like 'Console*') { return $A.Green }
    if ($Type -like 'WPF*' -or $Type -like 'Windows*') { return $A.Blue }
    return $A.Cyan
}

function Get-MaxLength($Items, [string]$Property) {
    $max = 0
    foreach ($item in $Items) { $len = ([string]$item.$Property).Length; if ($len -gt $max) { $max = $len } }
    return $max
}

function Get-EffectiveView {
    if ($script:View -ne 'auto') { return $script:View }
    if ($script:Scan.Runnable.Count -gt 12) { return 'table' } else { return 'list' }
}

function Write-ProjectEntry($Project, [int]$NumberWidth) {
    $number = '[' + ([string]$Project.Index).PadLeft($NumberWidth) + ']'
    $indent = ' ' * (2 + $number.Length + 1)

    $meta = @($Project.Framework)
    if ($Project.Solution) { $meta += $Project.Solution }
    if ($Project.LaunchProfiles.Count) { $meta += (Get-Plural $Project.LaunchProfiles.Count 'launch profile') }
    $separator = ' ' + $G.Bullet + ' '

    Write-Line ('  ' + $A.Key + $number + $A.Reset + ' ' + $A.Bold + $A.White + $Project.Name + $A.Reset)
    Write-Line ($indent + (Get-TypeColor $Project.Type) + $Project.Type + $A.Reset + $A.Gray + $separator + ($meta -join $separator) + $A.Reset)
    Write-Line ($indent + $A.Gray + $Project.Directory + $A.Reset)
    Write-Line
}

function Write-ProjectTable($Projects) {
    $numberWidth = ([string]($Projects[-1].Index)).Length
    $columns = @(
        @{ Title = '#';         Width = [math]::Max(1, $numberWidth); Align = 'Right'; Color = $A.Key },
        @{ Title = 'Project';   Width = [math]::Min(36, [math]::Max(7, (Get-MaxLength $Projects 'Name')));      Color = $A.White },
        @{ Title = 'Framework'; Width = [math]::Min(16, [math]::Max(9, (Get-MaxLength $Projects 'Framework'))); Color = $A.Gray },
        @{ Title = 'Type';      Width = [math]::Min(20, [math]::Max(4, (Get-MaxLength $Projects 'Type')));      Color = $A.Cyan }
    )
    $used = 3
    foreach ($c in $columns) { $used += $c.Width + 3 }
    $locationWidth = (Get-ConsoleWidth) - 1 - $used - 3
    $showLocation = $locationWidth -ge 12
    if ($showLocation) {
        $columns += , @{ Title = 'Location'; Width = [math]::Min($locationWidth, [math]::Max(8, (Get-MaxLength $Projects 'RelativePath'))); Color = $A.Gray }
    }

    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($p in $Projects) {
        $cells = @([string]$p.Index, $p.Name, $p.Framework, $p.Type)
        if ($showLocation) { $cells += $p.RelativePath }
        $rows.Add([string[]]$cells)
    }
    Write-Table $columns $rows
    Write-Line
}

function Write-OtherProjects($Projects) {
    $numberWidth = ([string]($Projects[-1].Index)).Length
    $nameWidth = [math]::Min(32, (Get-MaxLength $Projects 'Name'))
    $infoWidth = 0
    foreach ($p in $Projects) { $len = ($p.Type + ' ' + $G.Bullet + ' ' + $p.Framework).Length; if ($len -gt $infoWidth) { $infoWidth = $len } }
    $infoWidth = [math]::Min(36, $infoWidth)

    foreach ($p in $Projects) {
        $number = '[' + ([string]$p.Index).PadLeft($numberWidth) + ']'
        $info = Limit-Text ($p.Type + ' ' + $G.Bullet + ' ' + $p.Framework) $infoWidth
        Write-Line ('  ' + $A.Gray + $number + ' ' + (Limit-Text $p.Name $nameWidth).PadRight($nameWidth) + '  ' + $info.PadRight($infoWidth) + '  ' + $p.RelativePath + $A.Reset)
    }
    Write-Line
}

function Write-ScanSummary([bool]$Fresh) {
    $scan = $script:Scan
    if ($scan.RootMissing) { return }

    $seconds = '{0:0.00}s' -f $scan.Elapsed.TotalSeconds
    if ($Fresh) {
        Write-Status ok ("Scan completed in $seconds " + $A.Gray + '(' + ('{0:N0}' -f $scan.FolderCount) + ' folders)' + $A.Reset)
    }
    elseif ($scan.FromCache) {
        Write-Status info ('Loaded from cache ' + $A.Gray + '- scanned ' + $scan.ScannedAt.ToString('yyyy-MM-dd HH:mm') + ' (' + (Format-Age $scan.ScannedAt) + '), press R to rescan' + $A.Reset)
    }
    else {
        Write-Status ok ('Last scan at ' + $scan.ScannedAt.ToString('HH:mm:ss') + " ($seconds) " + $A.Gray + '- press R to rescan' + $A.Reset)
    }

    if ($scan.Projects.Count -eq 0) {
        $languages = ($script:Detectors | ForEach-Object { $_.Language }) -join ', '
        Write-Status warn "No $languages projects were found in this folder."
        return
    }

    foreach ($group in ($scan.Projects | Group-Object -Property Language)) {
        $line = 'Found ' + (Get-Plural $group.Count "$($group.Name) project")
        if ($scan.SolutionCount -gt 0 -and $script:Detectors.Count -eq 1) { $line += ' in ' + (Get-Plural $scan.SolutionCount 'solution') }
        Write-Status ok $line
    }

    $runnable = $scan.Runnable.Count
    $others = $scan.Others.Count
    if ($runnable -gt 0) { Write-Status ok ($(if ($runnable -eq 1) { '1 project is runnable' } else { "$runnable projects are runnable" })) }
    else { Write-Status warn 'No runnable projects were found.' }
    if ($others -gt 0) { Write-Status err ($(if ($others -eq 1) { '1 project cannot be run' } else { "$others projects cannot be run" })) }
}

function Write-ProjectMenu {
    $scan = $script:Scan
    $runnable = $scan.Runnable
    $others = $scan.Others

    Write-Line
    Write-SectionTitle 'AVAILABLE PROJECTS' $(if ($runnable.Count) { "$($runnable.Count) runnable" } else { '' })
    Write-Line

    if ($runnable.Count -eq 0) {
        Write-Line ('  ' + $A.Gray + 'Nothing to launch here yet.' + $A.Reset)
        Write-Line
    }
    elseif ((Get-EffectiveView) -eq 'table') {
        Write-ProjectTable $runnable
    }
    else {
        $numberWidth = ([string]($runnable[-1].Index)).Length
        foreach ($p in $runnable) { Write-ProjectEntry $p $numberWidth }
    }

    if ($script:ShowOthers -and $others.Count) {
        Write-SectionTitle 'OTHER PROJECTS' 'not runnable'
        Write-Line
        Write-OtherProjects $others
    }

    Write-Line
    Write-MenuKey 'R' 'Rescan projects'
    Write-MenuKey 'C' 'Configuration'
    if ($others.Count) {
        Write-MenuKey 'O' ($(if ($script:ShowOthers) { 'Hide' } else { 'Show' }) + " other projects ($($others.Count))")
    }
    if ($runnable.Count) {
        Write-MenuKey 'V' $(if ((Get-EffectiveView) -eq 'table') { 'List view' } else { 'Table view' })
    }
    Write-MenuKey 'Q' 'Quit'

    if (@($runnable | Where-Object { $_.LaunchProfiles.Count -gt 1 }).Count) {
        Write-Line
        Write-Line ('  ' + $A.Gray + 'Tip: add P to a number (e.g. 1p) to choose a launch profile.' + $A.Reset)
    }
    Write-Line
    Write-Rule
    Write-Line
    Write-Flash
}

function Show-Home([bool]$Rescan) {
    Clear-Screen
    Write-Banner
    Write-Line
    Write-Line ('  ' + $A.Gray + 'Root directory' + $A.Reset)
    Write-Line ('  ' + $A.White + $script:Root + $A.Reset)
    Write-Line

    $fresh = $false
    if (-not (Test-Directory $script:Root)) {
        Write-ErrorBlock 'The configured directory does not exist.' ([ordered]@{ Path = $script:Root }) @('Please update the configuration (press C).')
        $script:Scan = New-ScanResult -RootMissing
    }
    elseif ($Rescan -or -not $script:Scan) {
        Write-Line ('  ' + $A.Cyan + 'Scanning projects' + $G.Ell + $A.Reset)
        Write-Line
        $script:Scan = Invoke-ProjectScan $script:Root
        Save-ScanCache $script:Scan $script:Root
        Write-Line
        $fresh = $true
    }

    Write-ScanSummary $fresh
    Write-ProjectMenu
}

function Show-ConfigMenu {
    while ($true) {
        Clear-Screen
        Write-Banner -Compact
        Write-Line
        Write-SectionTitle 'CONFIGURATION'
        Write-Line
        Write-Line ('  ' + $A.Gray + 'Current root directory:' + $A.Reset)
        Write-Line
        Write-Line ('  ' + $A.White + $script:Root + $A.Reset)
        if (-not (Test-Directory $script:Root)) { Write-Status err 'This directory does not exist.' }
        Write-Line
        Write-Line ('  ' + $A.Gray + 'Source:      ' + $script:RootSource + $A.Reset)
        Write-Line ('  ' + $A.Gray + 'Config file: ' + $script:ConfigPath + $A.Reset)
        Write-Line
        Write-Line '  Options:'
        Write-Line
        Write-MenuKey '1' 'Change root directory'
        Write-MenuKey '2' 'Rescan'
        Write-MenuKey 'B' 'Back'
        Write-Line
        Write-Rule
        Write-Line
        Write-Flash

        $choice = Read-Input 'Select:'
        if ($null -eq $choice -or $choice -match '^(b|back)?$') { return 'back' }
        if ($choice -eq '2') { return 'rescan' }
        if ($choice -eq '1') {
            Write-Line
            $answer = Read-Input 'New root directory (leave empty to cancel):'
            if (-not $answer) { continue }

            $full = ConvertTo-FullPath $answer
            if (-not (Test-Directory $full)) {
                Set-Flash err "The directory does not exist: $answer"
                continue
            }

            $script:Root = $full
            try {
                Save-LauncherConfig $full
                $script:RootSource = 'config.json'
                Set-Flash ok 'Root directory saved to config.json.'
            }
            catch {
                $script:RootSource = 'entered for this session'
                Set-Flash warn "Using the new folder for this session; config.json could not be written: $($_.Exception.Message)"
            }
            return 'rescan'
        }
        Set-Flash warn "Unknown option '$choice'."
    }
}

# ==============================================================================================
#  Running a project
# ==============================================================================================

function Invoke-AttachedProcess([string]$FileName, [string[]]$Arguments, [string]$WorkingDirectory) {
    $commandLine = ConvertTo-CommandLine $Arguments
    if ($script:Native) {
        $code = $script:Native::RunAttached($FileName, $commandLine, $WorkingDirectory)
        try { [void]$script:Native::EnableVirtualTerminal() } catch { }
        return $code
    }
    # Fallback (e.g. Add-Type blocked by policy): still runs in this console.
    $process = Start-Process -FilePath $FileName -ArgumentList $commandLine -WorkingDirectory $WorkingDirectory -NoNewWindow -Wait -PassThru
    return $process.ExitCode
}

function Start-LauncherProject($Project, [bool]$ChooseProfile) {
    if (-not $Project.IsRunnable) {
        Clear-Screen
        Write-Banner -Compact
        Write-ErrorBlock 'This project cannot be launched.' ([ordered]@{ Project = $Project.Name; Reason = $Project.Reason; Path = $Project.ProjectFile })
        Wait-Enter 'Press ENTER to return to the project launcher...'
        return
    }

    # The list may come from the cache, so make sure the project is still there.
    if (-not [IO.File]::Exists($Project.ProjectFile)) {
        Clear-Screen
        Write-Banner -Compact
        Write-ErrorBlock 'This project no longer exists.' ([ordered]@{ Project = $Project.Name; Path = $Project.ProjectFile }) @('The project list is out of date. Press R to rescan.')
        Wait-Enter 'Press ENTER to return to the project launcher...'
        return
    }

    $detector = $Project.Detector
    $check = & $detector.CheckPrerequisites
    if (-not $check.Ok) {
        Clear-Screen
        Write-Banner -Compact
        Write-ErrorBlock $check.Title $null $check.Footer
        Wait-Enter 'Press ENTER to return to the project launcher...'
        return
    }

    $options = @{ Framework = $null; Profile = $null }

    $frameworks = @($Project.Frameworks | Where-Object { $_ -notmatch '\$\(' })
    if ($frameworks.Count -gt 1) {
        Clear-Screen
        Write-Banner -Compact
        Write-Line
        Write-Status info "$($Project.Name) targets several frameworks."
        $options.Framework = Select-Option 'Choose a target framework' $frameworks
        if (-not $options.Framework) { return }
    }

    if ($ChooseProfile) {
        if ($Project.LaunchProfiles.Count -eq 0) {
            Set-Flash warn "$($Project.Name) has no launch profiles in Properties\launchSettings.json."
            return
        }
        Clear-Screen
        Write-Banner -Compact
        $options.Profile = Select-Option "Choose a launch profile for $($Project.Name)" $Project.LaunchProfiles
        if (-not $options.Profile) { return }
    }

    $command = & $detector.GetLaunchCommand $Project $options

    $details = @($Project.Type, $(if ($options.Framework) { $options.Framework } else { $Project.Framework }))
    if ($options.Profile) { $details += "profile: $($options.Profile)" }
    elseif ($Project.LaunchProfiles.Count) { $details += "profile: $($Project.LaunchProfiles[0]) (default)" }

    Clear-Screen
    Write-Banner -Compact
    Write-Line
    Write-Line ('  ' + $A.Cyan + $G.Arrow + $A.Reset + ' ' + $A.Bold + $A.White + "Starting $($Project.Name)..." + $A.Reset)
    Write-Line ('    ' + $A.Gray + ($details -join (' ' + $G.Bullet + ' ')) + $A.Reset)
    Write-Line
    Write-Line ('  ' + $A.Gray + '>' + $A.Reset + ' ' + $command.Display)
    Write-Line
    if ($script:Native) { Write-Line ('  ' + $A.Gray + 'Press Ctrl+C to stop the application.' + $A.Reset) }
    else { Write-Status warn 'Ctrl+C will also close the launcher in this PowerShell session.' }
    Write-Rule
    Write-Line

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $exitCode = Invoke-AttachedProcess $command.FileName $command.Arguments $command.WorkingDirectory
    }
    catch {
        Write-Text $A.Reset
        Write-ErrorBlock "Could not start $($Project.Name)." ([ordered]@{ Reason = $_.Exception.Message })
        Wait-Enter 'Press ENTER to return to the project launcher...'
        return
    }
    $stopwatch.Stop()

    Write-Text $A.Reset
    Write-Line
    Write-Rule
    Write-Line
    $elapsed = '{0:hh\:mm\:ss}' -f $stopwatch.Elapsed
    if ($exitCode -eq 0) { Write-Status ok "$($Project.Name) stopped." }
    elseif ($script:CtrlCExitCodes -contains $exitCode) { Write-Status ok "$($Project.Name) stopped (Ctrl+C)." }
    else { Write-Status err "$($Project.Name) exited with code $exitCode." }
    Write-Line ('    ' + $A.Gray + "Ran for $elapsed" + $A.Reset)
    Write-Line
    Wait-Enter 'Press ENTER to return to the project launcher...'
}

# ==============================================================================================
#  Main loop
# ==============================================================================================

function Start-Launcher {
    Initialize-Terminal
    try {
        $script:Config = Read-LauncherConfig
        $script:View = 'auto'
        $script:ShowOthers = $false
        $script:Flash = $null
        $script:Scan = $null

        if (-not (Initialize-Root)) { return }

        # Reuse the last scan when there is one for this folder; scan only when asked (R / -Rescan).
        if (-not $Rescan) { $script:Scan = Read-ScanCache $script:Root }
        $rescan = -not $script:Scan
        while ($true) {
            Show-Home $rescan
            $rescan = $false

            $choice = Read-Input 'Select a project:'
            if ($null -eq $choice) { break }                       # input closed
            if ($choice -eq '') { continue }
            if ($choice -match '^(q|quit|exit)$') { break }
            if ($choice -match '^r$') { $rescan = $true; continue }
            if ($choice -match '^c$') { if ((Show-ConfigMenu) -eq 'rescan') { $rescan = $true }; continue }
            if ($choice -match '^o$') { $script:ShowOthers = -not $script:ShowOthers; continue }
            if ($choice -match '^v$') { $script:View = if ((Get-EffectiveView) -eq 'table') { 'list' } else { 'table' }; continue }

            if ($choice -match '^(\d{1,6})\s*(p)?$') {
                $number = [int]$Matches[1]
                $chooseProfile = [bool]$Matches[2]
                $project = $script:Scan.Projects | Where-Object { $_.Index -eq $number } | Select-Object -First 1
                if (-not $project) { Set-Flash warn "There is no project number $number."; continue }
                Start-LauncherProject $project $chooseProfile
                continue
            }

            Set-Flash warn "Unknown option '$choice'. Enter a project number, R, C, O, V or Q."
        }

        Write-Line
        Write-Line ('  ' + $A.Gray + 'Bye!' + $A.Reset)
        Write-Line
    }
    finally {
        Restore-Terminal
    }
}

# ==============================================================================================
#  Detector registration (version 1: C# only)
# ==============================================================================================

Register-ProjectDetector @{
    Id                 = 'csharp'
    Language           = 'C#'
    ProjectExtensions  = @('.csproj')
    SolutionExtensions = @('.sln', '.slnx')
    ReadSolution       = { param([string]$Path) Read-CSharpSolution $Path }
    Inspect            = { param([string]$Path) Get-CSharpProjectInfo $Path }
    CheckPrerequisites = { Test-DotNetSdk }
    GetLaunchCommand   = { param($Project, [hashtable]$Options) Get-DotNetRunCommand $Project $Options }
}

# Dot-sourcing the script (". .\ProjectLauncher.ps1") loads the functions without starting the UI.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Start-Launcher
    }
    catch {
        [Console]::WriteLine('')
        [Console]::WriteLine('  Unexpected error: ' + $_.Exception.Message)
        [Console]::WriteLine('  Press ENTER to exit...')
        [void][Console]::ReadLine()
        exit 1
    }
}
