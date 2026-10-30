param([string]$ToolchainFile='.toolchain.json')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
if(-not [IO.Path]::IsPathRooted($ToolchainFile)){$ToolchainFile=Join-Path $root $ToolchainFile}
$tools=Get-Content -Raw $ToolchainFile|ConvertFrom-Json
$classes=Join-Path $root 'build/tests'
New-Item -ItemType Directory -Force $classes|Out-Null
& (Join-Path $tools.javaHome 'bin/javac.exe') -encoding UTF-8 -d $classes (Join-Path $root 'android/src/fr/cercle/tourderole/Core.java') (Join-Path $root 'tests/CoreTest.java')
if($LASTEXITCODE -ne 0){throw 'Compilation tests échouée'}
& (Join-Path $tools.javaHome 'bin/java.exe') -cp $classes fr.cercle.tourderole.CoreTest
if($LASTEXITCODE -ne 0){throw 'Tests échoués'}
