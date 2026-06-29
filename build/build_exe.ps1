#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [string]$OutputName = ""
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}

if ([string]::IsNullOrWhiteSpace($OutputName)) {
    $OutputName = (-join ([char[]](0x5947, 0x60F3, 0x76D2, 0x66F4, 0x65B0, 0x5668))) + ".exe"
}

$sourceScript = Join-Path $ProjectRoot "src\update_qixiang.ps1"
$outputExe = Join-Path $ProjectRoot $OutputName
$generatedDir = Join-Path $ProjectRoot "build\.generated"
$iconPath = Join-Path $generatedDir "qixiang_update.ico"
$launcherCs = Join-Path $generatedDir "Launcher.cs"

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function New-IconPngBytes {
    param([Parameter(Mandatory = $true)][int]$Size)

    Add-Type -AssemblyName System.Drawing

    function New-RoundedRectanglePath {
        param(
            [Parameter(Mandatory = $true)][System.Drawing.RectangleF]$Rect,
            [Parameter(Mandatory = $true)][float]$Radius
        )

        $diameter = $Radius * 2
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc($Rect.X, $Rect.Y, $diameter, $diameter, 180, 90)
        $path.AddArc($Rect.Right - $diameter, $Rect.Y, $diameter, $diameter, 270, 90)
        $path.AddArc($Rect.Right - $diameter, $Rect.Bottom - $diameter, $diameter, $diameter, 0, 90)
        $path.AddArc($Rect.X, $Rect.Bottom - $diameter, $diameter, $diameter, 90, 90)
        $path.CloseFigure()
        return $path
    }

    $bitmap = New-Object System.Drawing.Bitmap $Size, $Size
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $scale = $Size / 256.0
    $pink = [System.Drawing.Color]::FromArgb(255, 255, 64, 160)
    $darkPink = [System.Drawing.Color]::FromArgb(255, 214, 38, 128)
    $lightPink = [System.Drawing.Color]::FromArgb(255, 255, 231, 244)
    $white = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)

    $brushLight = New-Object System.Drawing.SolidBrush $lightPink
    $brushPink = New-Object System.Drawing.SolidBrush $pink
    $brushWhite = New-Object System.Drawing.SolidBrush $white
    $penDark = New-Object System.Drawing.Pen $darkPink, ([Math]::Max(4, 12 * $scale))
    $penWhite = New-Object System.Drawing.Pen $white, ([Math]::Max(3, 8 * $scale))

    $outer = New-Object System.Drawing.RectangleF (28 * $scale), (58 * $scale), (200 * $scale), (170 * $scale)
    $outerPath = New-RoundedRectanglePath -Rect $outer -Radius ([float](36 * $scale))
    $graphics.FillPath($brushLight, $outerPath)
    $graphics.DrawPath($penDark, $outerPath)

    $box = New-Object System.Drawing.RectangleF (56 * $scale), (106 * $scale), (144 * $scale), (96 * $scale)
    $boxPath = New-RoundedRectanglePath -Rect $box -Radius ([float](18 * $scale))
    $graphics.FillPath($brushPink, $boxPath)
    $graphics.DrawPath($penWhite, $boxPath)

    $ribbonV = New-Object System.Drawing.RectangleF (112 * $scale), (102 * $scale), (32 * $scale), (104 * $scale)
    $ribbonH = New-Object System.Drawing.RectangleF (52 * $scale), (132 * $scale), (152 * $scale), (28 * $scale)
    $graphics.FillRectangle($brushWhite, $ribbonV)
    $graphics.FillRectangle($brushWhite, $ribbonH)

    $graphics.DrawEllipse($penDark, (74 * $scale), (64 * $scale), (56 * $scale), (50 * $scale))
    $graphics.DrawEllipse($penDark, (126 * $scale), (64 * $scale), (56 * $scale), (50 * $scale))

    $ms = New-Object System.IO.MemoryStream
    $bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $outerPath.Dispose()
    $boxPath.Dispose()
    $brushLight.Dispose()
    $brushPink.Dispose()
    $brushWhite.Dispose()
    $penDark.Dispose()
    $penWhite.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()
    return $ms.ToArray()
}

function Write-UInt16 {
    param([System.IO.BinaryWriter]$Writer, [int]$Value)
    $Writer.Write([uint16]$Value)
}

function Write-UInt32 {
    param([System.IO.BinaryWriter]$Writer, [long]$Value)
    $Writer.Write([uint32]$Value)
}

function New-IcoFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sizes = @(16, 24, 32, 48, 64, 96, 128, 256)
    $images = @()
    foreach ($size in $sizes) {
        $images += ,@($size, (New-IconPngBytes -Size $size))
    }

    $stream = New-Object System.IO.FileStream $Path, ([System.IO.FileMode]::Create), ([System.IO.FileAccess]::Write)
    $writer = New-Object System.IO.BinaryWriter $stream
    try {
        Write-UInt16 $writer 0
        Write-UInt16 $writer 1
        Write-UInt16 $writer $images.Count

        $offset = 6 + (16 * $images.Count)
        foreach ($image in $images) {
            $size = [int]$image[0]
            $bytes = [byte[]]$image[1]
            $writer.Write([byte]($(if ($size -eq 256) { 0 } else { $size })))
            $writer.Write([byte]($(if ($size -eq 256) { 0 } else { $size })))
            $writer.Write([byte]0)
            $writer.Write([byte]0)
            Write-UInt16 $writer 1
            Write-UInt16 $writer 32
            Write-UInt32 $writer $bytes.Length
            Write-UInt32 $writer $offset
            $offset += $bytes.Length
        }

        foreach ($image in $images) {
            $writer.Write([byte[]]$image[1])
        }
    } finally {
        $writer.Dispose()
        $stream.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $sourceScript)) {
    throw "Source script not found: $sourceScript"
}

Ensure-Directory $generatedDir
New-IcoFile -Path $iconPath

$scriptText = [IO.File]::ReadAllText($sourceScript, [Text.Encoding]::UTF8)
$scriptBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($scriptText))

$launcherSource = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Text;

public static class QixiangUpdateProgram
{
    private const string ScriptBase64 = "$scriptBase64";

    [STAThread]
    public static int Main(string[] args)
    {
        string tempScript = Path.Combine(Path.GetTempPath(), ".qixiang_update_" + Guid.NewGuid().ToString("N") + ".ps1");
        try
        {
            string scriptText = Encoding.UTF8.GetString(Convert.FromBase64String(ScriptBase64));
            File.WriteAllText(tempScript, scriptText, new UTF8Encoding(false));

            string powerShell = FindPowerShell();
            string arguments = "-NoProfile -ExecutionPolicy Bypass -File " + Quote(tempScript) + " -SkipAppLaunch";
            foreach (string arg in args)
            {
                arguments += " " + Quote(arg);
            }

            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = powerShell;
            info.Arguments = arguments;
            info.UseShellExecute = false;

            using (Process process = Process.Start(info))
            {
                process.WaitForExit();
                if (process.ExitCode != 0)
                {
                    Console.WriteLine();
                    Console.WriteLine("Update failed. Exit code: " + process.ExitCode);
                    Console.WriteLine();
                    Console.Write("Press Enter to exit...");
                    Console.ReadLine();
                }
                return process.ExitCode;
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.ToString());
            Console.WriteLine();
            Console.Write("Press Enter to exit...");
            Console.ReadLine();
            return 1;
        }
        finally
        {
            try
            {
                if (File.Exists(tempScript))
                {
                    File.Delete(tempScript);
                }
            }
            catch
            {
            }
        }
    }

    private static string FindPowerShell()
    {
        string windir = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        string powershell = Path.Combine(windir, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        if (File.Exists(powershell))
        {
            return powershell;
        }
        return "powershell.exe";
    }

    private static string Quote(string value)
    {
        if (value == null)
        {
            return "\"\"";
        }
        return "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
    }
}
"@

[IO.File]::WriteAllText($launcherCs, $launcherSource, [Text.UTF8Encoding]::new($false))

Add-Type -AssemblyName Microsoft.CSharp
$provider = New-Object Microsoft.CSharp.CSharpCodeProvider
$parameters = New-Object System.CodeDom.Compiler.CompilerParameters
$parameters.GenerateExecutable = $true
$parameters.GenerateInMemory = $false
$parameters.OutputAssembly = $outputExe
$parameters.TreatWarningsAsErrors = $false
$parameters.ReferencedAssemblies.Add("System.dll") | Out-Null
$parameters.CompilerOptions = "/target:exe /platform:anycpu /win32icon:`"$iconPath`""

$results = $provider.CompileAssemblyFromFile($parameters, $launcherCs)
if ($results.Errors.Count -gt 0) {
    foreach ($errorItem in $results.Errors) {
        Write-Error $errorItem.ToString()
    }
    throw "Compilation failed."
}

Write-Host "Built: $outputExe"
