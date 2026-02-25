# PowerShell script to generate benchmark zip files for HarmonyOS
# This replaces the zip functionality in generate.perl for Windows systems

$benchmarks = @(
    "500.perlbench_r", "502.gcc_r", "505.mcf_r", "520.omnetpp_r", "523.xalancbmk_r",
    "525.x264_r", "531.deepsjeng_r", "541.leela_r", "548.exchange2_r", "557.xz_r",
    "503.bwaves_r", "507.cactuBSSN_r", "508.namd_r", "510.parest_r", "511.povray_r",
    "519.lbm_r", "521.wrf_r", "526.blender_r", "527.cam4_r", "538.imagick_r",
    "544.nab_r", "549.fotonik3d_r", "554.roms_r"
)

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$rawfileDir = Join-Path $projectRoot "entry\src\main\resources\rawfile"

Write-Host "Starting benchmark zip file generation..."
Write-Host "Project root: $projectRoot"
Write-Host "Rawfile directory: $rawfileDir"

# Ensure rawfile directory exists
if (-not (Test-Path $rawfileDir)) {
    New-Item -ItemType Directory -Path $rawfileDir -Force | Out-Null
}

$successCount = 0
$failCount = 0

foreach ($benchmark in $benchmarks) {
    Write-Host "`nProcessing $benchmark..."

    # Create temp directory
    $tmpDir = Join-Path $projectRoot "tmp"
    if (Test-Path $tmpDir) {
        Remove-Item $tmpDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $tmpDir | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmpDir "input") | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmpDir "output") | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $tmpDir "compare") | Out-Null

    # Source directories
    $allInputDir = Join-Path $projectRoot "benchspec\CPU\$benchmark\data\all\input"
    $refrateInputDir = Join-Path $projectRoot "benchspec\CPU\$benchmark\data\refrate\input"
    $refrateOutputDir = Join-Path $projectRoot "benchspec\CPU\$benchmark\data\refrate\output"
    $refrateCompareDir = Join-Path $projectRoot "benchspec\CPU\$benchmark\data\refrate\compare"

    try {
        # Copy files
        if (Test-Path $allInputDir) {
            Copy-Item "$allInputDir\*" (Join-Path $tmpDir "input") -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $refrateInputDir) {
            Copy-Item "$refrateInputDir\*" (Join-Path $tmpDir "input") -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $refrateOutputDir) {
            Copy-Item "$refrateOutputDir\*" (Join-Path $tmpDir "output") -Recurse -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path $refrateCompareDir) {
            Copy-Item "$refrateCompareDir\*" (Join-Path $tmpDir "compare") -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Create zip file
        $zipFile = Join-Path $rawfileDir "$benchmark.zip"
        if (Test-Path $zipFile) {
            Remove-Item $zipFile -Force
        }

        Compress-Archive -Path "$tmpDir\*" -DestinationPath $zipFile -Force
        Write-Host "  Created: $zipFile" -ForegroundColor Green
        $successCount++
    }
    catch {
        Write-Host "  Error processing $benchmark : $_" -ForegroundColor Red
        $failCount++
    }
    finally {
        # Cleanup
        if (Test-Path $tmpDir) {
            Remove-Item $tmpDir -Recurse -Force
        }
    }
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Generation complete!" -ForegroundColor Cyan
Write-Host "Success: $successCount" -ForegroundColor Green
Write-Host "Failed: $failCount" -ForegroundColor Red
Write-Host "========================================" -ForegroundColor Cyan
