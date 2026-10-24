param(
    [string]$Sdk = $env:ANDROID_HOME,
    [string]$Java = $env:JAVA_HOME,
    [switch]$SkipCore,
    [switch]$SkipTests
)
$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (!$Sdk) { $Sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk' }
if (!$Java) { $Java = Join-Path ${env:ProgramFiles} 'Android\Android Studio\jbr' }
$env:JAVA_HOME = $Java
$env:ANDROID_HOME = $Sdk
$env:ANDROID_SDK_ROOT = $Sdk
if (!(Test-Path -LiteralPath (Join-Path $Java 'bin\java.exe'))) { throw 'Укажите JDK через -Java.' }
if (!(Test-Path -LiteralPath (Join-Path $Sdk 'platforms\android-36\android.jar'))) { throw 'Установите Android SDK Platform 36.' }
$sdkProperty = 'sdk.dir=' + $Sdk.Replace('\', '/').Replace(':', '\:')
[System.IO.File]::WriteAllText((Join-Path $projectRoot 'local.properties'), $sdkProperty + "`n", [System.Text.UTF8Encoding]::new($false))
if (!$SkipCore) { & (Join-Path $PSScriptRoot 'build-core.ps1') -AndroidSdk $Sdk -JavaHome $Java }
$buildRoot = $projectRoot
$temporaryDrive = $null
# Windows' Java batch launcher can lose Cyrillic paths. Map this same checkout
# to a free ASCII drive for Gradle and forked test JVMs; remove only our mapping.
if ($projectRoot -match '[^\x00-\x7F]') {
    foreach ($letter in @('Z','Y','X','W','V','U','T','S','R','Q','P')) {
        if (!(Test-Path -LiteralPath ($letter + ':\'))) {
            & subst ($letter + ':') $projectRoot
            if ($LASTEXITCODE -ne 0) { throw 'Не удалось создать временный ASCII-путь для сборки.' }
            $temporaryDrive = $letter + ':'
            $buildRoot = $temporaryDrive + '\'
            break
        }
    }
    if (!$temporaryDrive) { throw 'Нет свободной буквы диска для временного пути сборки.' }
}
$env:GRADLE_USER_HOME = Join-Path $buildRoot '.tools\gradle'
Push-Location $buildRoot
try {
    $tasks = @(':app:assembleDebug', ':app:lintDebug')
    if (!$SkipTests) { $tasks += ':app:testDebugUnitTest' }
    & .\gradlew.bat --no-daemon @tasks
    if ($LASTEXITCODE -ne 0) { throw 'Gradle build failed.' }
    $output = Join-Path $projectRoot 'dist'
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    Copy-Item -LiteralPath 'app\build\outputs\apk\debug\app-debug.apk' -Destination (Join-Path $output 'WhiteLink-0.1.0-test.apk')
    $hash = Get-FileHash -LiteralPath (Join-Path $output 'WhiteLink-0.1.0-test.apk') -Algorithm SHA256
    ($hash.Hash.ToLower() + '  WhiteLink-0.1.0-test.apk') | Set-Content -LiteralPath (Join-Path $output 'SHA256SUMS.txt') -Encoding ascii
    Write-Host (Join-Path $output 'WhiteLink-0.1.0-test.apk')
} finally {
    Pop-Location
    if ($temporaryDrive) { & subst $temporaryDrive /D }
}
