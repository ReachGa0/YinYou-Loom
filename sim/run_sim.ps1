param(
    [string]$Python = "python"
)

$ErrorActionPreference = "Stop"

# 切到仓库根目录（本脚本在 sim/ 下）
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

New-Item -ItemType Directory -Force sim/out | Out-Null

Write-Host "[1/4] 编译 testbench ..."
iverilog -I rtl/common -g2012 -o sim/out/tb_voice_osc.vvp sim/tb_voice_osc.v rtl/synth/voice_osc.v rtl/synth/wavetable_rom.v
if ($LASTEXITCODE -ne 0) { throw "iverilog 编译失败" }

Write-Host "[2/4] 运行仿真 ..."
vvp sim/out/tb_voice_osc.vvp
if ($LASTEXITCODE -ne 0) { throw "vvp 仿真失败" }

Write-Host "[3/4] 文本转 WAV ..."
& $Python tools/pcm2wav.py sim/out/sine_440.txt sim/out/sine_440.wav
if ($LASTEXITCODE -ne 0) { throw "pcm2wav 转换失败" }

Write-Host "[4/6] 频谱分析 ..."
& $Python tools/spectrum.py sim/out/sine_440.wav 440
if ($LASTEXITCODE -ne 0) { throw "spectrum 分析失败" }

Write-Host "[5/6] 编译 voice 测试台 ..."
iverilog -I rtl/common -g2012 -o sim/out/tb_voice.vvp sim/tb_voice.v rtl/synth/voice.v rtl/synth/voice_osc.v rtl/synth/wavetable_rom.v rtl/synth/voice_adsr.v
if ($LASTEXITCODE -ne 0) { throw "iverilog 编译 tb_voice 失败" }

Write-Host "[6/6] 运行 voice 测试并检查 ADSR 四段 ..."
vvp sim/out/tb_voice.vvp
if ($LASTEXITCODE -ne 0) { throw "vvp 运行 tb_voice 失败" }
& $Python tools/adsr_check.py sim/out/voice_dump.txt 30000
if ($LASTEXITCODE -ne 0) { throw "adsr_check 未通过" }

Write-Host "仿真流程完成: sim/out/sine_440.wav"
