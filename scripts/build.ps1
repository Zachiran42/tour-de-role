param(
    [string]$ToolchainFile = '',
    [Parameter(Mandatory = $true)][string]$KeyStore,
    [string]$KeyAlias = 'tour-de-role',
    [string]$OutputFile = '',
    [string]$BuildDir = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = Split-Path -Parent $PSScriptRoot
function Resolve-ProjectPath([string]$Value) {
    if ([System.IO.Path]::IsPathRooted($Value)) { return [System.IO.Path]::GetFullPath($Value) }
    return [System.IO.Path]::GetFullPath((Join-Path $projectRoot $Value))
}
function Invoke-Checked([string]$Executable, [string[]]$Arguments, [string]$Step) {
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Step (code $LASTEXITCODE)." }
}
if (-not $ToolchainFile) { $ToolchainFile = '.toolchain.json' }
$ToolchainFile = Resolve-ProjectPath $ToolchainFile
if (-not (Test-Path -LiteralPath $ToolchainFile -PathType Leaf)) { throw 'Configurez .toolchain.json depuis .toolchain.example.json.' }
$tools = Get-Content -Raw -LiteralPath $ToolchainFile | ConvertFrom-Json
foreach ($field in @('javaHome', 'androidJar', 'buildTools')) {
    if (-not $tools.PSObject.Properties[$field] -or -not $tools.$field) { throw "Champ de toolchain manquant : $field" }
}
$java = Join-Path $tools.javaHome 'bin\java.exe'
$javac = Join-Path $tools.javaHome 'bin\javac.exe'
$jar = Join-Path $tools.javaHome 'bin\jar.exe'
$aapt = Join-Path $tools.buildTools 'aapt2.exe'
$d8 = Join-Path $tools.buildTools 'd8.bat'
$zipalign = Join-Path $tools.buildTools 'zipalign.exe'
$apksigner = Join-Path $tools.buildTools 'lib\apksigner.jar'
foreach ($file in @($java, $javac, $jar, $aapt, $d8, $zipalign, $apksigner, $tools.androidJar)) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Outil introuvable : $file" }
}
$KeyStore = Resolve-ProjectPath $KeyStore
if (-not (Test-Path -LiteralPath $KeyStore -PathType Leaf)) { throw 'La cle de signature fournie est introuvable.' }
if (-not $env:MINIGAMES_KEYSTORE_PASSWORD) { throw 'Definissez MINIGAMES_KEYSTORE_PASSWORD avant de compiler. Le secret ne doit pas etre dans les sources.' }
if (-not $OutputFile) { $OutputFile = 'build\tour-de-role-0.1.0.apk' }
if (-not $BuildDir) { $BuildDir = 'build' }
$OutputFile = Resolve-ProjectPath $OutputFile
$BuildDir = Resolve-ProjectPath $BuildDir
$runDir = Join-Path $BuildDir ('compile-' + [Guid]::NewGuid().ToString('N'))
$generated = Join-Path $runDir 'generated'
$classes = Join-Path $runDir 'classes'
$dex = Join-Path $runDir 'dex'
foreach ($directory in @($runDir, $generated, $classes, $dex, (Split-Path -Parent $OutputFile))) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
$previousJavaHome = $env:JAVA_HOME
$previousPath = $env:PATH
try {
    $env:JAVA_HOME = $tools.javaHome
    $env:PATH = (Join-Path $tools.javaHome 'bin') + [System.IO.Path]::PathSeparator + $env:PATH
    $resources = Join-Path $runDir 'resources.zip'
    $baseApk = Join-Path $runDir 'base.apk'
    $classesJar = Join-Path $runDir 'classes.jar'
    $aligned = Join-Path $runDir 'aligned.apk'
    Write-Output 'Compilation des ressources Android...'
    Invoke-Checked $aapt @('compile', '--dir', (Join-Path $projectRoot 'android\res'), '-o', $resources) 'Compilation des ressources impossible'
    Invoke-Checked $aapt @('link', '-o', $baseApk, '-I', $tools.androidJar, '--manifest', (Join-Path $projectRoot 'android\AndroidManifest.xml'), '--java', $generated, $resources) 'Assemblage des ressources impossible'
    $sources = @(Get-ChildItem -LiteralPath (Join-Path $projectRoot 'android\src') -Filter '*.java' -Recurse | Select-Object -ExpandProperty FullName)
    $sources += @(Get-ChildItem -LiteralPath $generated -Filter '*.java' -Recurse | Select-Object -ExpandProperty FullName)
    if ($sources.Count -eq 0) { throw 'Aucune source Java trouvee.' }
    Write-Output 'Compilation du jeu natif...'
    $compileArgs = @('-encoding', 'UTF-8', '-source', '8', '-target', '8', '-classpath', $tools.androidJar, '-d', $classes) + $sources
    Invoke-Checked $javac $compileArgs 'Compilation Java impossible'
    Invoke-Checked $jar @("-J-Djava.io.tmpdir=$runDir", 'cf', $classesJar, '-C', $classes, '.') 'Archive Java impossible'
    Invoke-Checked $d8 @('--lib', $tools.androidJar, '--min-api', '26', '--output', $dex, $classesJar) 'Conversion DEX impossible'
    $dexFiles = @(Get-ChildItem -LiteralPath $dex -Filter 'classes*.dex' | Sort-Object Name)
    if ($dexFiles.Count -eq 0) { throw 'La conversion ne contient aucun fichier DEX.' }
    foreach ($dexFile in $dexFiles) {
        Invoke-Checked $jar @("-J-Djava.io.tmpdir=$runDir", 'uf', $baseApk, '-C', $dex, $dexFile.Name) 'Ajout DEX impossible'
    }
    Invoke-Checked $zipalign @('-f', '4', $baseApk, $aligned) 'Alignement APK impossible'
    Write-Output 'Signature avec la cle externe fournie...'
    Invoke-Checked $java @('-jar', $apksigner, 'sign', '--ks', $KeyStore, '--ks-key-alias', $KeyAlias, '--ks-pass', 'env:MINIGAMES_KEYSTORE_PASSWORD', '--key-pass', 'env:MINIGAMES_KEYSTORE_PASSWORD', '--out', $OutputFile, $aligned) 'Signature APK impossible'
    Invoke-Checked $java @('-jar', $apksigner, 'verify', '--verbose', $OutputFile) 'Verification de signature impossible'
    Invoke-Checked $zipalign @('-c', '4', $OutputFile) 'Verification de l alignement impossible'
    Write-Output ('APK signe et verifie : ' + $OutputFile)
    Get-FileHash -LiteralPath $OutputFile -Algorithm SHA256 | Select-Object Algorithm, Hash, Path
} finally {
    $env:JAVA_HOME = $previousJavaHome
    $env:PATH = $previousPath
}