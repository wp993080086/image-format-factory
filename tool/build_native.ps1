<#
.SYNOPSIS
    重建随包分发的原生库（libwebp / libheif / libde265）。

.DESCRIPTION
    Windows 端有两条能力依赖原生库（ADR-010）：
    - libwebp：WebP 编码（`image` 包只有解码器）
    - libheif + libde265：HEIC/HEIF 解码（Windows 系统没有 HEVC 解码组件）

    仓库里已经放好了构建产物（windows/native/bin/x64），正常开发不需要跑这个脚本。
    只有在需要升级版本或改编译选项时才跑。

    依赖：Visual Studio 2022（含 C++ 工具链与 CMake）、Ninja。
    VS 自带的 cmake/ninja 在
      %ProgramFiles%\Microsoft Visual Studio\2022\<Edition>\Common7\IDE\CommonExtensions\Microsoft\
        CMake\CMake\bin\cmake.exe
        CMake\Ninja\ninja.exe

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tool/build_native.ps1
#>
[CmdletBinding()]
param(
    [string]$OutputDir = "$PSScriptRoot\..\windows\native\bin\x64",
    [string]$WorkDir = "$env:TEMP\pixel-forge-native"
)

$ErrorActionPreference = 'Stop'

# 版本锁定：改动这些版本必须同步更新 ADR-010 与 windows/native/README.md
$versions = @{
    'libwebp'   = '1.4.0'
    'libde265'  = '1.0.15'
    'libheif'   = '1.18.2'
}

$sources = @{
    'libwebp'  = 'https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.4.0.tar.gz'
    'libde265' = 'https://github.com/strukturag/libde265/releases/download/v1.0.15/libde265-1.0.15.tar.gz'
    'libheif'  = 'https://github.com/strukturag/libheif/releases/download/v1.18.2/libheif-1.18.2.tar.gz'
}

function Find-VsTools {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { throw '找不到 vswhere，请先安装 Visual Studio 2022' }
    $install = & $vswhere -latest -products '*' -property installationPath
    if (-not $install) { throw '找不到 Visual Studio 安装目录' }

    $cmake = Join-Path $install 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
    $ninja = Join-Path $install 'Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe'
    $vcvars = Join-Path $install 'VC\Auxiliary\Build\vcvars64.bat'
    foreach ($p in @($cmake, $ninja, $vcvars)) {
        if (-not (Test-Path $p)) { throw "缺少构建工具：$p" }
    }
    return @{ Cmake = $cmake; Ninja = $ninja; VcVars = $vcvars }
}

function Invoke-CMake {
    param([string]$Args)
    # vcvars64.bat 只在当前进程生效，用 cmd 串起来跑
    $cmd = "call `"$($script:vs.VcVars)`" >nul && `"$($script:vs.Cmake)`" $Args"
    cmd /c $cmd
    if ($LASTEXITCODE -ne 0) { throw "cmake 失败：$Args" }
}

function Get-Source {
    param([string]$Name, [string]$Url)
    $dir = Join-Path $WorkDir "src\$Name-$($versions[$Name])"
    if (Test-Path $dir) { return $dir }
    New-Item -ItemType Directory -Force (Join-Path $WorkDir 'src') | Out-Null
    $archive = Join-Path $WorkDir "src\$Name-$($versions[$Name]).tar.gz"
    Write-Host "下载 $Name $($versions[$Name]) ..."
    curl.exe -sSL --retry 5 --retry-delay 2 -o $archive $Url
    tar -xzf $archive -C (Join-Path $WorkDir 'src')
    return $dir
}

$script:vs = Find-VsTools
New-Item -ItemType Directory -Force $WorkDir | Out-Null

# --- libde265（静态库，供 libheif 链接）---
$de265 = Get-Source 'libde265' $sources['libde265']
Invoke-CMake "-S `"$de265`" -B `"$WorkDir\build\de265`" -G Ninja -DCMAKE_BUILD_TYPE=Release " +
    "-DBUILD_SHARED_LIBS=OFF -DENABLE_SDL=OFF -DENABLE_ENCODER=OFF " +
    "-DCMAKE_INSTALL_PREFIX=`"$WorkDir\prefix`""
Invoke-CMake "--build `"$WorkDir\build\de265`""
Invoke-Cmake "--install `"$WorkDir\build\de265`""

# --- libheif（动态库，内含 libde265）---
$heif = Get-Source 'libheif' $sources['libheif']
Invoke-CMake "-S `"$heif`" -B `"$WorkDir\build\heif`" -G Ninja -DCMAKE_BUILD_TYPE=Release " +
    "-DBUILD_SHARED_LIBS=ON -DCMAKE_PREFIX_PATH=`"$WorkDir\prefix`" " +
    "-DCMAKE_INSTALL_PREFIX=`"$WorkDir\prefix`" " +
    "-DCMAKE_CXX_FLAGS=-DLIBDE265_STATIC_BUILD -DCMAKE_C_FLAGS=-DLIBDE265_STATIC_BUILD " +
    "-DWITH_LIBDE265=ON -DWITH_X265=OFF -DWITH_AOM_DECODER=OFF -DWITH_AOM_ENCODER=OFF " +
    "-DWITH_DAV1D=OFF -DWITH_EXAMPLES=OFF -DWITH_LIBSHARPYUV=OFF " +
    "-DENABLE_PLUGIN_LOADING=OFF -DBUILD_TESTING=OFF"
Invoke-CMake "--build `"$WorkDir\build\heif`""
Invoke-Cmake "--install `"$WorkDir\build\heif`""

# --- libwebp（动态库，依赖 libsharpyuv）---
$webp = Get-Source 'libwebp' $sources['libwebp']
Invoke-CMake "-S `"$webp`" -B `"$WorkDir\build\webp`" -G Ninja -DCMAKE_BUILD_TYPE=Release " +
    "-DBUILD_SHARED_LIBS=ON -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF " +
    "-DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF " +
    "-DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_LIBWEBPMUX=OFF " +
    "-DWEBP_BUILD_EXTRAS=OFF -DWEBP_BUILD_ANIM_UTILS=OFF"
Invoke-CMake "--build `"$WorkDir\build\webp`""

# --- 收集产物 ---
New-Item -ItemType Directory -Force $OutputDir | Out-Null
Copy-Item "$WorkDir\prefix\bin\heif.dll" $OutputDir -Force
Copy-Item "$WorkDir\build\webp\libwebp.dll" (Join-Path $OutputDir 'webp.dll') -Force
Copy-Item "$WorkDir\build\webp\libsharpyuv.dll" $OutputDir -Force

Write-Host ''
Write-Host '完成，产物：'
Get-ChildItem $OutputDir | Select-Object Name, Length | Format-Table -AutoSize
