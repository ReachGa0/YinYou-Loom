# ============================================================
# run_all.ps1 —— 全量回归：把所有测试台跑一遍
#
# 用途：改动任何 RTL 之后跑这一条，确认没有破坏别的模块。
# 用法：.\sim\run_all.ps1 -Python "<python路径>"
# ============================================================
param(
    [string]$Python = "python"
)

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
New-Item -ItemType Directory -Force sim/out | Out-Null

$script:total  = 0
$script:failed = 0

function Test-Suite {
    param(
        [string]   $Name,
        [string[]] $Sources,
        [string]   $Extra = ""
    )
    $script:total++
    $vvp = "sim/out/$Name.vvp"

    $argv = @("-g2012")
    if ($Extra -ne "") { $argv += $Extra }
    $argv += @("-o", $vvp)
    $argv += $Sources

    & iverilog @argv 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ("  [FAIL] {0} —— 编译失败" -f $Name)
        $script:failed++
        return
    }

    $log = & vvp $vvp 2>&1 | Out-String
    if ($log -match "RESULT: ALL PASS") {
        Write-Host ("  [PASS] {0}" -f $Name)
    } else {
        Write-Host ("  [FAIL] {0}" -f $Name)
        ($log -split "`n") | Where-Object { $_ -match "FAIL" } | ForEach-Object {
            Write-Host ("         " + $_.Trim())
        }
        $script:failed++
    }
}

Write-Host ""
Write-Host "===== 1. 音频链路（含 WAV 与频谱分析）====="
& "$PSScriptRoot/run_sim.ps1" -Python $Python
if ($LASTEXITCODE -ne 0) { $script:failed++ }
$script:total++

Write-Host ""
Write-Host "===== 2. 基础模块 ====="
Test-Suite "tb_sync_reset" @("sim/tb_sync_reset.v", "rtl/common/sync_reset.v")

foreach ($d in 15, 5, 30) {
    Test-Suite "tb_clk_div_$d" @("sim/tb_clk_div.v", "rtl/common/clk_div.v") "-Ptb_clk_div.DIV=$d"
}

Test-Suite "tb_frac_div" @("sim/tb_frac_div.v", "rtl/common/frac_div.v")

Write-Host ""
Write-Host "===== 3. I2S 发送器 ====="
Test-Suite "tb_i2s_tx" @("sim/tb_i2s_tx.v", "rtl/io/i2s_tx.v")

Write-Host ""
Write-Host "===== 4. I2C 与显示 ====="
Test-Suite "tb_i2c_master" @(
    "sim/tb_i2c_master.v", "sim/i2c_slave_model.v", "rtl/io/i2c_master.v")

Test-Suite "tb_oled_sh1106" @(
    "sim/tb_oled_sh1106.v", "sim/i2c_slave_model.v",
    "rtl/display/oled_sh1106.v", "rtl/io/i2c_master.v")

Test-Suite "tb_oled_ssd1306" @(
    "sim/tb_oled_sh1106.v", "sim/i2c_slave_model.v",
    "rtl/display/oled_sh1106.v", "rtl/io/i2c_master.v") "-Ptb_oled_sh1106.MODE=1"

Write-Host ""
Write-Host "========================================"
Write-Host ("  共 {0} 套测试，失败 {1} 套" -f $script:total, $script:failed)
Write-Host "========================================"

if ($script:failed -gt 0) { exit 1 }
