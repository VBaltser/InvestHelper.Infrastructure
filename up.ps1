[CmdletBinding()]
param(
    [string]$SecretsFile = (Join-Path $PSScriptRoot '.secrets/bootstrap.yml'),
    [string]$VaultPasswordFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$temporaryPassword = $null
$previousSecrets = $env:INVESTHELPER_SECRETS_FILE
$previousPassword = $env:INVESTHELPER_VAULT_PASSWORD_FILE

function Invoke-VagrantChecked {
    param([string[]]$VagrantArguments)
    & vagrant @VagrantArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Vagrant failed (exit $LASTEXITCODE). Fix the reported error and run up.ps1 again."
    }
}

try {
    foreach ($command in @('vagrant', 'ssh-keygen')) {
        if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
            throw "Required command is missing: $command"
        }
    }
    if (-not (Test-Path -LiteralPath $SecretsFile -PathType Leaf)) {
        throw 'Secrets file missing. See bootstrap.example.yml and README.md. No VMs have been changed.'
    }
    $env:INVESTHELPER_SECRETS_FILE = (Resolve-Path -LiteralPath $SecretsFile).Path
    $encrypted = (Get-Content -LiteralPath $SecretsFile -TotalCount 1).StartsWith('$ANSIBLE_VAULT;')
    $env:INVESTHELPER_VAULT_PASSWORD_FILE = $null
    if ($VaultPasswordFile) {
        $env:INVESTHELPER_VAULT_PASSWORD_FILE = (Resolve-Path -LiteralPath $VaultPasswordFile).Path
    } elseif ($encrypted) {
        $securePassword = Read-Host 'Ansible Vault password' -AsSecureString
        $plainPassword = [System.Net.NetworkCredential]::new('', $securePassword).Password
        if (-not $plainPassword) { throw 'Vault password must not be empty.' }
        $temporaryPassword = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
        # Create the file with an explicit ACL before writing the password.
        New-Item -ItemType File -Path $temporaryPassword | Out-Null
        $acl = Get-Acl -LiteralPath $temporaryPassword
        $acl.SetAccessRuleProtection($true, $false)
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $temporaryPassword -AclObject $acl
        [IO.File]::WriteAllText($temporaryPassword, $plainPassword, [Text.UTF8Encoding]::new($false))
        $plainPassword = $null
        $env:INVESTHELPER_VAULT_PASSWORD_FILE = $temporaryPassword
    }
    Push-Location $PSScriptRoot
    try {
        Invoke-VagrantChecked -VagrantArguments @('validate')
        # Provision existing VMs too; control must run only after every managed VM is ready.
        Invoke-VagrantChecked -VagrantArguments @('up', 'ci', 'app', 'monitoring', '--provision')
        Invoke-VagrantChecked -VagrantArguments @('up', 'control', '--provision')
    } finally {
        Pop-Location
    }
    Write-Host 'Infrastructure configured. Jenkins will discover main and run its pipeline.'
    Write-Host 'Jenkins: http://192.168.56.10:8080/  App: http://192.168.56.20:8080/'
} finally {
    if ($temporaryPassword -and (Test-Path -LiteralPath $temporaryPassword)) {
        Remove-Item -LiteralPath $temporaryPassword -Force
    }
    $env:INVESTHELPER_SECRETS_FILE = $previousSecrets
    $env:INVESTHELPER_VAULT_PASSWORD_FILE = $previousPassword
}
