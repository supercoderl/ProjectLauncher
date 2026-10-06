# C# Project Launcher

A lightweight, modern command-line launcher for Windows. It scans a folder for C# / .NET projects, lists the runnable ones in a clean terminal UI, and starts the one you pick with `dotnet run` — right in the same window, so you see every log line.

```
SCAN → DISPLAY → SELECT → RUN
```

No GUI, no install, no dependencies beyond PowerShell (built into Windows) and the .NET SDK.

---

## Folder structure

```
CSharpProjectLauncher/
├── StartLauncher.bat        ← double-click this
├── ProjectLauncher.ps1      ← the whole application
├── config.json              ← your root folder goes here
├── config.example.json      ← every available option
├── cache.json               ← last scan result (created automatically)
└── README.md
```

---

## Quick start

1. Copy the `CSharpProjectLauncher` folder anywhere (for example `C:\Tools\CSharpProjectLauncher`).
2. Open `config.json` and set the folder that contains your projects:
   ```json
   {
     "rootDirectory": "F:\\Workspace"
   }
   ```
   Remember to double the backslashes in JSON (`F:\\Workspace`). Forward slashes also work (`F:/Workspace`).
3. Double-click `StartLauncher.bat`.
4. Type a project number and press **Enter**.
5. Stop the app with **Ctrl+C** — you are taken back to the launcher.

If the files came from a download and Windows blocks them, run this once in PowerShell inside the folder:

```powershell
Get-ChildItem | Unblock-File
```

---

## Requirements

| Requirement | Notes |
|---|---|
| Windows 10 / 11 | ANSI colors need Windows 10 1511 or newer |
| PowerShell | Windows PowerShell 5.1 (built in) or PowerShell 7+. The `.bat` prefers `pwsh` when installed |
| .NET SDK | Needed only to *run* projects. Scanning works without it |

Best experience: **Windows Terminal** (full Unicode, emoji and rounded boxes). Classic CMD/PowerShell windows get a font-safe symbol set automatically.

---

## Using the launcher

| Input | Action |
|---|---|
| `1`, `2`, … | Run that project with `dotnet run` |
| `1p` | Choose a launch profile first (from `Properties\launchSettings.json`) |
| `R` | Clear the screen and rescan (picks up new/deleted projects) and update the cache |
| `C` | Configuration screen (change root folder, rescan) |
| `O` | Show / hide the other (non-runnable) projects |
| `V` | Switch between list view and table view |
| `Q` | Quit |

The list view is used for up to 12 runnable projects; with more, the launcher switches to a compact table automatically. `V` overrides that.

Multi-targeted projects (`<TargetFrameworks>net8.0;net9.0</TargetFrameworks>`) ask which framework to run, because `dotnet run` requires one.

### What happens when you run a project

```
→ Starting PhysioBoo.Api...
  ASP.NET Core • net9.0 • profile: https (default)

> dotnet run --project "F:\Workspace\PhysioBoo\src\PhysioBoo.Api\PhysioBoo.Api.csproj"

  Press Ctrl+C to stop the application.
────────────────────────────────────────────────────────────────
Building...
info: Microsoft.Hosting.Lifetime[14]
      Now listening on: https://localhost:7001
...
────────────────────────────────────────────────────────────────
  ✓ PhysioBoo.Api stopped (Ctrl+C).
    Ran for 00:12:41

  Press ENTER to return to the project launcher...
```

- The process runs **in the same console window** with its normal output, colors and errors.
- The working directory is the project folder, so `appsettings.json` and relative paths resolve the same way they do when you run the project from its own folder.
- **Ctrl+C goes to your app, not the launcher.** While a project runs, the launcher ignores Ctrl+C itself, so your app shuts down gracefully and you land back on the menu.
- `dotnet run` builds/restores as it normally would. The launcher adds no extra build or restore step.

---

## Scan cache

The launcher does **not** scan every time it opens. After each scan it saves the result to `cache.json`, and on the next start it shows that list instantly:

```
  ● Loaded from cache - scanned 2026-10-06 21:54 (2 hours ago), press R to rescan
  ✓ Found 12 C# projects in 3 solutions
  ✓ 9 projects are runnable
```

You decide when to refresh:

- **`R`** on the main menu (or **[2] Rescan** on the configuration screen) scans and updates the cache.
- **`StartLauncher.bat -Rescan`** ignores the cache for that start.

A fresh scan happens automatically only when there is nothing usable to show: the first run, a different root folder (each cache belongs to one root), or a missing/damaged `cache.json`.

If a cached project has been deleted or moved since the last scan, selecting it shows *"This project no longer exists — press R to rescan"* instead of failing. New projects appear after the next `R`. Changes to `excludeDirectories` or `maxDepth` also take effect on the next rescan.

Deleting `cache.json` is always safe.

---

## Configuration

### Where the root folder comes from (in priority order)

1. **Command-line argument**
   ```
   StartLauncher.bat "D:\OtherWorkspace"
   ```
2. **`config.json`** → `rootDirectory` (a relative path is resolved from the launcher's folder)
3. **Environment variable** `CSLAUNCHER_ROOT` (optional fallback)
4. **Ask** — if none of the above is set, the launcher asks for a folder and offers to save it to `config.json`.

If the configured folder does not exist, you get a clear error and a prompt to enter another one.

### All options (`config.example.json`)

```json
{
  "rootDirectory": "F:\\Workspace",
  "excludeDirectories": [ "archive", "samples-old" ],
  "maxDepth": 12
}
```

| Key | Default | Meaning |
|---|---|---|
| `rootDirectory` | – | Folder to scan. The only setting you normally change |
| `excludeDirectories` | `[]` | Extra folder **names** to skip, on top of the built-in list |
| `maxDepth` | `12` | How many folder levels deep to search |

Changing the root folder on the **[C] Configuration** screen writes `config.json` for you (other keys are preserved).

### Command-line switches

```
StartLauncher.bat ["root folder"] [-Rescan] [-Ascii] [-NoColor]
```

- `-Rescan` — ignore the cache and scan on startup

- `-Ascii` — plain ASCII boxes and icons (for unusual console fonts)
- `-NoColor` — no ANSI colors (the `NO_COLOR` environment variable works too)

---

## How project detection works

### 1. Fast folder walk

The launcher walks the root folder with a manual stack (no `Get-ChildItem -Recurse`), so excluded folders are **never entered at all**. Skipped:

- `bin`, `obj`, `node_modules`, `packages`, `TestResults`, `$RECYCLE.BIN`, `System Volume Information`
- every folder whose name starts with `.` (`.git`, `.vs`, `.vscode`, `.idea`, `.github`, …)
- anything you list in `excludeDirectories`
- anything deeper than `maxDepth`

It collects `.sln`, `.slnx` and `.csproj` files only. Nothing is built or restored — only the XML/JSON metadata is read.

### 2. Solutions

`.sln` files are parsed for their `Project(...) = "...", "path\to\X.csproj"` lines; `.slnx` files are read as XML (`<Project Path="..."/>`). Each project shows which solution(s) contain it.

### 3. Reading each `.csproj`

| Information | Where it comes from |
|---|---|
| SDK | `<Project Sdk="…">`, `<Sdk Name="…"/>`, `<Import Sdk="…"/>` |
| Target framework | `TargetFramework` / `TargetFrameworks`; otherwise the nearest `Directory.Build.props`; legacy projects use `TargetFrameworkVersion` |
| Output type | `OutputType`; Web, Worker, Blazor WASM and Aspire SDKs imply `Exe` |
| Launch profiles | `Properties\launchSettings.json`, profiles with `"commandName": "Project"` (the ones `dotnet run` can use; the first is its default) |

When a property is defined several times, unconditional definitions win (last one counts, as in MSBuild).

### 4. Classification (first rule that matches)

| Rule | Shown as | Runnable? |
|---|---|---|
| No SDK attribute (old-style project) | .NET Framework App / Library | ✗ `dotnet run` only supports SDK-style projects |
| `IsTestProject`, `MSTest.Sdk` or `Microsoft.NET.Test.Sdk` reference | Test Project | ✗ use `dotnet test` |
| `IsAspireHost` or `Aspire.AppHost.Sdk` | Aspire AppHost | ✓ |
| `UseMaui` | MAUI App | ✗ needs a platform/device |
| `AzureFunctionsVersion` | Azure Functions | ✗ use `func start` |
| `Microsoft.NET.Sdk.BlazorWebAssembly` | Blazor WebAssembly | ✓ |
| `Microsoft.NET.Sdk.Web` | ASP.NET Core | ✓ |
| `Microsoft.NET.Sdk.Worker` | Worker Service | ✓ |
| `OutputType` Exe/WinExe + `UseWPF` | WPF App | ✓ |
| `OutputType` Exe/WinExe + `UseWindowsForms` | Windows Forms | ✓ |
| `OutputType` WinExe | Windows App | ✓ |
| `OutputType` Exe | Console App | ✓ |
| Anything else | Class Library / Razor Class Library | ✗ |

Non-runnable projects still get a number (shown with **[O]**). Selecting one explains why it can't be launched instead of failing.

---

## Adding the launcher to PATH (optional)

So you can type `StartLauncher` from any terminal:

1. Press **Win**, type *environment variables*, open **Edit environment variables for your account**.
2. Select **Path** → **Edit** → **New**, and add the launcher folder, e.g. `C:\Tools\CSharpProjectLauncher`.
3. Open a new terminal and run:
   ```
   StartLauncher
   StartLauncher "D:\OtherWorkspace"
   ```

Or from PowerShell (current user only):

```powershell
$dir = 'C:\Tools\CSharpProjectLauncher'
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ";$dir", 'User')
```

Prefer a shorter name? Create `pl.cmd` in the same folder:

```bat
@call "%~dp0StartLauncher.bat" %*
```

### Windows Terminal profile (optional)

Add a profile with this command line to open the launcher in its own tab:

```
pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\Tools\CSharpProjectLauncher\ProjectLauncher.ps1"
```

(Use `powershell` instead of `pwsh` if PowerShell 7 isn't installed.)

---

## What the launcher never does

- modify projects, project files or `launchSettings.json`
- build or restore projects during scanning
- start more than one project at a time
- change ports or environment variables

The only files it ever writes are its own `config.json` (when you change the root folder) and `cache.json` (after a scan), both inside the launcher folder. Console settings it touches for the session (UTF-8 output, ANSI mode) are restored when it exits.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Window flashes and closes | Run `StartLauncher.bat` from an open CMD window to read the message |
| "running scripts is disabled" | The `.bat` already passes `-ExecutionPolicy Bypass`; if you run the `.ps1` directly, use the same flag or `Unblock-File` |
| Boxes show as `?` | Use Windows Terminal, or start with `-Ascii` |
| `.NET SDK was not found` | Install the SDK from https://dot.net/download and reopen the terminal |
| New project not in the list | The list comes from the cache — press **R** to rescan |
| Project missing from the list | Check it isn't under an excluded folder, deeper than `maxDepth`, or classified as non-runnable (press **O**) |
| "Terminate batch job (Y/N)?" after quitting | CMD asks this if Ctrl+C was pressed while it hosted the launcher. Answer either way — the launcher has already exited. A Windows Terminal profile (above) avoids it |
| Ctrl+C closes the launcher too | Your system blocks PowerShell's `Add-Type` (constrained language mode). The launcher still works; it shows a warning before running |

---

## Extending to other languages later

Discovery is driven by a list of **detectors**. The scanner itself knows nothing about C#; it routes files by extension to whichever detector registered them. The C# detector is registered near the bottom of `ProjectLauncher.ps1`:

```powershell
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
```

A future Node.js detector would be another `Register-ProjectDetector` call (for example `ProjectExtensions = @('.json')` filtered to `package.json` inside `Inspect`, `CheckPrerequisites` looking for `node`, `GetLaunchCommand` returning `npm run start`). The scan, menu, run and return-to-menu flow stay unchanged.

Dot-sourcing the script loads its functions without starting the UI, which is handy for experimenting:

```powershell
. .\ProjectLauncher.ps1
Get-CSharpProjectInfo 'F:\Workspace\PhysioBoo\src\PhysioBoo.Api\PhysioBoo.Api.csproj'
```
