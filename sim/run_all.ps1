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
        [string[]] $Extra = @()
    )
    $script:total++
    $vvp = "sim/out/$Name.vvp"

    $argv = @("-g2012")
    if ($Extra.Count -gt 0) { $argv += $Extra }
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

Test-Suite "tb_wavetable_arbiter_4" @(
    "sim/tb_wavetable_arbiter.v",
    "rtl/synth/wavetable_arbiter.v",
    "rtl/synth/wavetable_bank.v",
    "rtl/synth/wavetable_rom.v") "-Ptb_wavetable_arbiter.VOICES=4"

Test-Suite "tb_wavetable_arbiter_8" @(
    "sim/tb_wavetable_arbiter.v",
    "rtl/synth/wavetable_arbiter.v",
    "rtl/synth/wavetable_bank.v",
    "rtl/synth/wavetable_rom.v") "-Ptb_wavetable_arbiter.VOICES=8"

Test-Suite "tb_wavetable_arbiter_32" @(
    "sim/tb_wavetable_arbiter.v",
    "rtl/synth/wavetable_arbiter.v",
    "rtl/synth/wavetable_bank.v",
    "rtl/synth/wavetable_rom.v") "-Ptb_wavetable_arbiter.VOICES=32"

Test-Suite "tb_voice_alloc" @("sim/tb_voice_alloc.v", "rtl/synth/voice_alloc.v")
Test-Suite "tb_voice_alloc_32" @("sim/tb_voice_alloc32.v", "rtl/synth/voice_alloc.v")
Test-Suite "tb_mixer" @("sim/tb_mixer.v", "rtl/synth/mixer.v")
Test-Suite "tb_mixer_32" @("sim/tb_mixer32.v", "rtl/synth/mixer.v")
Test-Suite "tb_bend_scan" @("sim/tb_bend_scan.v", "rtl/synth/bend_scan.v")
Test-Suite "tb_synth_engine" @(
    "sim/tb_synth_engine.v",
    "rtl/synth/synth_engine.v",
    "rtl/synth/synth_top.v",
    "rtl/synth/bend_scan.v",
    "rtl/synth/mixer.v",
    "rtl/synth/wavetable_arbiter.v",
    "rtl/synth/wavetable_bank.v",
    "rtl/synth/wavetable_rom.v",
    "rtl/synth/voice.v",
    "rtl/synth/voice_osc.v",
    "rtl/synth/voice_adsr.v",
    "rtl/synth/voice_alloc.v")
Test-Suite "tb_synth_engine_32" @(
    "sim/tb_synth_engine32.v",
    "rtl/synth/synth_engine.v",
    "rtl/synth/synth_top.v",
    "rtl/synth/bend_scan.v",
    "rtl/synth/mixer.v",
    "rtl/synth/wavetable_arbiter.v",
    "rtl/synth/wavetable_bank.v",
    "rtl/synth/wavetable_rom.v",
    "rtl/synth/voice.v",
    "rtl/synth/voice_osc.v",
    "rtl/synth/voice_adsr.v",
    "rtl/synth/voice_alloc.v")
Test-Suite "tb_chorus" @("sim/tb_chorus.v", "rtl/synth/chorus.v")
Test-Suite "tb_delay_effect" @("sim/tb_delay_effect.v", "rtl/synth/delay_effect.v")
Test-Suite "tb_reverb_effect" @("sim/tb_reverb_effect.v", "rtl/synth/reverb_effect.v")
Test-Suite "tb_fx_engine" @(
    "sim/tb_fx_engine.v",
    "rtl/synth/fx_engine.v",
    "rtl/synth/chorus.v",
    "rtl/synth/delay_effect.v",
    "rtl/synth/reverb_effect.v")

Write-Host ""
Write-Host "===== 5. P5 交互层（P5A 按键保底 / P5C 超声波）====="
Test-Suite "tb_key_scan" @("sim/tb_key_scan.v", "rtl/input/key_scan.v")
Test-Suite "tb_input_map" @("sim/tb_input_map.v", "rtl/input/input_map.v")
Test-Suite "tb_chord_map" @("sim/tb_chord_map.v", "rtl/input/chord_map.v")
Test-Suite "tb_rotary_decode" @(
    "sim/tb_rotary_decode.v",
    "rtl/input/rotary_decode.v",
    "rtl/input/key_scan.v")
Test-Suite "tb_p5_baseline" @(
    "sim/tb_p5_baseline.v",
    "rtl/input/key_scan.v",
    "rtl/input/input_map.v",
    "rtl/synth/synth_engine.v",
    "rtl/synth/synth_top.v",
    "rtl/synth/bend_scan.v",
    "rtl/synth/mixer.v",
    "rtl/synth/wavetable_arbiter.v",
    "rtl/synth/wavetable_bank.v",
    "rtl/synth/wavetable_rom.v",
    "rtl/synth/voice.v",
    "rtl/synth/voice_osc.v",
    "rtl/synth/voice_adsr.v",
    "rtl/synth/voice_alloc.v")

Test-Suite "tb_sonar_range" @("sim/tb_sonar_range.v", "rtl/input/sonar_range.v")

Test-Suite "tb_rc_adc" @("sim/tb_rc_adc.v", "rtl/input/rc_adc.v")
Test-Suite "tb_joy_filter" @("sim/tb_joy_filter.v", "rtl/input/joy_filter.v")
Test-Suite "tb_expression_map" @("sim/tb_expression_map.v", "rtl/input/expression_map.v")
Test-Suite "tb_pitch_bend_map" @("sim/tb_pitch_bend_map.v", "rtl/input/pitch_bend_map.v")
Test-Suite "tb_test_mode_router" @(
    "sim/tb_test_mode_router.v", "rtl/test/test_mode_router.v")

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

Test-Suite "tb_oled_status_square" @(
    "sim/tb_oled_status.v", "sim/i2c_slave_model.v",
    "rtl/display/oled_sh1106.v", "rtl/io/i2c_master.v") "-Ptb_oled_status.COUNT=3"

Test-Suite "tb_oled_status_dry" @(
    "sim/tb_oled_status.v", "sim/i2c_slave_model.v",
    "rtl/display/oled_sh1106.v", "rtl/io/i2c_master.v") @("-Ptb_oled_status.COUNT=1", "-Ptb_oled_status.TIMBRE=0", "-Ptb_oled_status.BYPASS=1")

Test-Suite "tb_tft_st7789" @(
    "sim/tb_tft_st7789.v", "rtl/display/tft_st7789.v")

Test-Suite "tb_tft_st7789_invoff" @(
    "sim/tb_tft_st7789.v", "rtl/display/tft_st7789.v") "-Ptb_tft_st7789.INVERT=0"

Test-Suite "tb_ui_render" @(
    "sim/tb_ui_render.v", "rtl/display/ui_render.v", "rtl/display/font8x16_rom.v")

Test-Suite "tb_wave_capture" @(
    "sim/tb_wave_capture.v", "rtl/display/wave_capture.v")

Test-Suite "tb_test_mode" @(
    "sim/tb_test_mode.v",
    "rtl/test/test_mode.v",
    "rtl/synth/synth_engine.v",
    "rtl/synth/synth_top.v",
    "rtl/synth/bend_scan.v",
    "rtl/synth/mixer.v",
    "rtl/synth/wavetable_arbiter.v",
    "rtl/synth/wavetable_bank.v",
    "rtl/synth/wavetable_rom.v",
    "rtl/synth/voice.v",
    "rtl/synth/voice_osc.v",
    "rtl/synth/voice_adsr.v",
    "rtl/synth/voice_alloc.v")

Test-Suite "tb_test_mode_32" @(
    "sim/tb_test_mode32.v",
    "rtl/test/test_mode.v",
    "rtl/synth/synth_engine.v",
    "rtl/synth/synth_top.v",
    "rtl/synth/bend_scan.v",
    "rtl/synth/mixer.v",
    "rtl/synth/wavetable_arbiter.v",
    "rtl/synth/wavetable_bank.v",
    "rtl/synth/wavetable_rom.v",
    "rtl/synth/voice.v",
    "rtl/synth/voice_osc.v",
    "rtl/synth/voice_adsr.v",
    "rtl/synth/voice_alloc.v")

$script:total++
$tones32 = @(
    433.59375, 480.46875, 503.90625, 550.78125,
    621.09375, 691.40625, 714.84375, 785.15625,
    832.03125, 855.46875, 925.78125, 972.65625,
    1042.96875, 1136.71875, 1183.59375, 1207.03125,
    1253.90625, 1277.34375, 1324.21875, 1488.28125,
    1535.15625, 1605.46875, 1628.90625, 1746.09375,
    1769.53125, 1839.84375, 1910.15625, 1957.03125,
    2027.34375, 2097.65625, 2121.09375, 2238.28125)
& $Python tools/pcm2wav.py sim/out/test_mode_tones32.txt sim/out/test_mode_tones32.wav | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [FAIL] test_mode_32_spectrum —— WAV 转换失败"
    $script:failed++
} else {
    $spectrumLog = & $Python tools/spectrum_peaks.py sim/out/test_mode_tones32.wav @tones32 2>&1 | Out-String
    if ($spectrumLog -match "RESULT: ALL PASS") {
        Write-Host "  [PASS] test_mode_32_spectrum"
    } else {
        Write-Host "  [FAIL] test_mode_32_spectrum"
        Write-Host $spectrumLog
        $script:failed++
    }
}

Write-Host ""
Write-Host "========================================"
Write-Host ("  共 {0} 套测试，失败 {1} 套" -f $script:total, $script:failed)
Write-Host "========================================"

if ($script:failed -gt 0) { exit 1 }
