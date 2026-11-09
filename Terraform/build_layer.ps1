# Construye la Lambda layer de psycopg2 para Linux x86_64.
# En Windows no sirve un "pip install" normal (bajaria binarios de Windows),
# por eso se descarga la wheel manylinux con --platform.
# Uso: ./build_layer.ps1   -> genera layer_build/python/ para Terraform.

$ErrorActionPreference = "Stop"

$layerDir = Join-Path $PSScriptRoot "layer_build"
$pythonDir = Join-Path $layerDir "python"

if (Test-Path $layerDir) {
    Remove-Item -Recurse -Force $layerDir
}
New-Item -ItemType Directory -Path $pythonDir | Out-Null

Write-Host "Descargando psycopg2-binary para Linux x86_64 (python 3.9)..."

pip install `
    --platform manylinux2014_x86_64 `
    --python-version 3.9 `
    --implementation cp `
    --only-binary=:all: `
    --target $pythonDir `
    "psycopg2-binary==2.9.9"

Write-Host "Layer construida en: $pythonDir"
