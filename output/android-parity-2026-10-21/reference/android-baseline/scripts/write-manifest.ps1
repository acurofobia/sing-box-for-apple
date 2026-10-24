$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dist = Join-Path $projectRoot 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$rules = Get-ChildItem -LiteralPath (Join-Path $projectRoot 'app\src\main\assets\rulesets') -Filter '*.srs' | Sort-Object Name | ForEach-Object {
    @{ file = $_.Name; bytes = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower() }
}
$application = Get-ChildItem -LiteralPath (Join-Path $projectRoot 'app\src') -File -Recurse | Sort-Object FullName | ForEach-Object {
    @{ file = $_.FullName.Substring($projectRoot.Length + 1).Replace('\','/'); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLower() }
}
$apk = Join-Path $dist 'WhiteLink-0.1.0-test.apk'
$aar = Join-Path $projectRoot 'app\libs\libbox.aar'
$manifest = [ordered]@{
    name = 'WhiteLink'; version = '0.1.0-test'; applicationId = 'io.whitelink.android'
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
    minSdk = 24; targetSdk = 36; compileSdk = 36
    abi = @('arm64-v8a','x86_64')
    source = @{ sfa = 'bc73504fcb858400a939140ad785ed92f4c9f429'; core = 'af6e64c3b69e6132ebaee0e1a3d24e93903f6709'; turn = 'local ThirdParty/VKTurnProxy; anton48/vk-turn-proxy-ios@5daeb9b'; adaptation = 'local iOS prototype patch and Android patches included in source bundle' }
    toolchain = @{ go = '1.26.4'; gomobile = 'github.com/sagernet/gomobile@v0.1.12'; ndk = '30.0.14904198'; jdk = '21.0.10'; gradle = '9.1.0'; agp = '8.13.2'; kotlin = '2.2.21'; buildTools = '36.0.0' }
    buildTags = @('with_gvisor','with_wireguard','with_utls','with_clash_api','with_low_memory','badlinkname','tfogo_checklinkname0')
    limitations = @('Phone/gateway interoperability and long-duration network tests are user-side','Interactive VK CAPTCHA is not implemented; explicit failure without automatic retry','IPv6 captured and rejected','No automatic mode failover; one saved profile','Debug APK, not a production release')
    apk = @{ bytes = (Get-Item -LiteralPath $apk).Length; sha256 = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLower() }
    libbox = @{ sha256 = (Get-FileHash -LiteralPath $aar -Algorithm SHA256).Hash.ToLower() }
    routingSha256 = (Get-FileHash -LiteralPath (Join-Path $projectRoot 'app\src\main\assets\routing.json') -Algorithm SHA256).Hash.ToLower()
    ruleSets = @($rules); applicationSource = @($application)
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $dist 'build-manifest.json') -Encoding utf8
