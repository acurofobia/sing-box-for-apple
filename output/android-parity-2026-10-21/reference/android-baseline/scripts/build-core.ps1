param(
    [string]$AndroidSdk = 'C:\Users\Admin\AppData\Local\Android\Sdk',
    [string]$JavaHome = 'C:\Program Files\Android\Android Studio\jbr',
    [string]$Target = 'android/arm64,android/amd64',
    [string]$OutputName = 'libbox.aar'
)
$ErrorActionPreference = 'Stop'
$clientRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$env:GOPATH = Join-Path $clientRoot '.tools\go'
$env:GOCACHE = Join-Path $clientRoot '.tools\go-cache'
$env:GOBIN = Join-Path $env:GOPATH 'bin'
$env:ANDROID_HOME = $AndroidSdk
$env:ANDROID_NDK_HOME = Join-Path $AndroidSdk 'ndk\30.0.14904198'
$env:JAVA_HOME = $JavaHome
$env:PATH = "$JavaHome\bin;$env:GOBIN;$env:PATH"
$env:GOTOOLCHAIN = 'local'
New-Item -ItemType Directory -Force $env:GOBIN,$env:GOCACHE,(Join-Path $clientRoot 'app\libs'),(Join-Path $clientRoot 'build-logs') | Out-Null
Push-Location (Join-Path $clientRoot 'vendor\sing-box')
try {
    # An interrupted Windows gomobile bind leaves hard-linked generated files.
    # Remove only this checkout's generated bind directory before every build.
    $generatedBindPath = [IO.Path]::GetFullPath((Join-Path $clientRoot 'vendor\sing-box\build'))
    $expectedCoreRoot = [IO.Path]::GetFullPath((Join-Path $clientRoot 'vendor\sing-box'))
    if (!$generatedBindPath.StartsWith($expectedCoreRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe generated-bind cleanup path' }
    if (Test-Path -LiteralPath $generatedBindPath) { Remove-Item -LiteralPath $generatedBindPath -Recurse -Force }
    # Pinned upstream: sing-box af6e64c3 + local complete iOS prototype patch;
    # VK TURN source anton48/vk-turn-proxy-ios 5daeb9b, GPL-3.0/MIT file notices.
    # Android changes: protect/bind before connect, physical DNS, no credential
    # disk cache, generation cancellation, strict GETCONF/provision agreement,
    # IPv6 capture/reject, redacted bounded diagnostics. No Apple runtime flags.
    if (!(Test-Path (Join-Path $env:GOBIN 'gomobile.exe'))) {
        go install github.com/sagernet/gomobile/cmd/gomobile@v0.1.12
        if ($LASTEXITCODE -ne 0) { throw 'gomobile install failed' }
    }
    if (!(Test-Path (Join-Path $env:GOBIN 'gobind.exe'))) {
        go install github.com/sagernet/gomobile/cmd/gobind@v0.1.12
        if ($LASTEXITCODE -ne 0) { throw 'gobind install failed' }
    }
    & (Join-Path $env:GOBIN 'gomobile.exe') bind -v -o (Join-Path $clientRoot "app\libs\$OutputName") -target $Target -androidapi 24 -javapkg io.nekohasekai -libname box -trimpath -buildvcs=false -ldflags '-checklinkname=0 -s -w -X github.com/sagernet/sing-box/constant.Version=1.14.2-android-vkturn' -tags 'with_gvisor,with_wireguard,with_utls,with_clash_api,with_low_memory,badlinkname,tfogo_checklinkname0' './experimental/libbox' 2>&1 | Tee-Object (Join-Path $clientRoot 'build-logs\libbox-build.log')
    if ($LASTEXITCODE -ne 0) { throw 'libbox Android build failed; inspect build-logs/libbox-build.log' }
} finally {
    Pop-Location
}
