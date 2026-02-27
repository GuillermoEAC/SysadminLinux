# =============================================================
# ftp_helpers.ps1 — Módulo de utilidades, validaciones y prompts
#                   para ftp_windows.ps1 (IIS FTP)
# Uso: . "$PSScriptRoot\ftp_helpers.ps1"
# =============================================================

# ── Constantes globales ───────────────────────────────────────
$FTP_ROOT = "C:\FTP"
$SITE_NAME = "FTP Site"
$FTP_PORT = 21
$GROUPS = @("reprobados", "recursadores")

# ═══════════════════════════════════════════════════════════════
# VALIDACIONES DE ENTORNO
# ═══════════════════════════════════════════════════════════════

# Verifica que el proceso actual tenga privilegios de Administrador
function Require-Admin {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Error "ERROR: Ejecuta PowerShell como Administrador."
        exit 1
    }
}

# Devuelve $true si el usuario local existe
function User-Exists {
    param([string]$Name)
    return [bool](Get-LocalUser -Name $Name -ErrorAction SilentlyContinue)
}

# Devuelve $true si el grupo local existe
function Group-Exists {
    param([string]$Name)
    return [bool](Get-LocalGroup -Name $Name -ErrorAction SilentlyContinue)
}

# Devuelve $true si el servicio Windows existe y está corriendo
function Service-IsRunning {
    param([string]$ServiceName)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    return ($null -ne $svc -and $svc.Status -eq 'Running')
}

# Verifica que el módulo WebAdministration esté disponible e importado
function Assert-WebAdminModule {
    if (-not (Get-Module -Name WebAdministration)) {
        if (Get-Module -ListAvailable -Name WebAdministration) {
            Import-Module WebAdministration -ErrorAction Stop
        }
        else {
            Write-Error "El módulo WebAdministration no está disponible. Instala los roles IIS primero."
            throw "WebAdministration no disponible"
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# VALIDACIONES DE FORMATO / TIPO DE DATO
# ═══════════════════════════════════════════════════════════════

# Valida que el nombre de usuario cumpla con el formato de Windows
# (1-20 chars, sin caracteres especiales problemáticos)
function Test-ValidUsername {
    param([string]$Name)
    return $Name -match '^[a-zA-Z][a-zA-Z0-9_\-]{0,19}$'
}

# Valida que la contraseña tenga al menos 4 caracteres
function Test-ValidPassword {
    param([System.Security.SecureString]$SecurePass)
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePass))
    return $plain.Length -ge 4
}

# Valida que $Value sea un entero en el rango [$Min, $Max]
function Test-ValidInt {
    param([string]$Value, [int]$Min, [int]$Max)
    if ($Value -notmatch '^\d+$') { return $false }
    $n = [int]$Value
    return ($n -ge $Min -and $n -le $Max)
}

# Valida que el nombre de grupo sea uno de los grupos FTP permitidos
function Test-ValidFTPGroup {
    param([string]$GroupName)
    return ($GROUPS -contains $GroupName)
}

# ═══════════════════════════════════════════════════════════════
# PROMPTS INTERACTIVOS (con re-intento automático)
# ═══════════════════════════════════════════════════════════════

# Solicita un string no vacío
function Prompt-NonEmpty {
    param([string]$Label)
    while ($true) {
        $val = Read-Host "  $Label"
        if ($val.Trim() -ne "") { return $val.Trim() }
        Write-Warn "No puede ir vacío."
    }
}

# Solicita un nombre de usuario nuevo (formato válido + que no exista)
function Prompt-NewUsername {
    while ($true) {
        $val = Read-Host "  Nombre de usuario"
        if (-not (Test-ValidUsername $val)) {
            Write-Warn "Nombre inválido. Usa letras, números, _ o - (empieza con letra, máx 20 chars)."
        }
        elseif (User-Exists $val) {
            Write-Warn "El usuario '$val' ya existe. Elige otro nombre."
        }
        else {
            return $val
        }
    }
}

# Solicita un nombre de usuario que ya debe existir
function Prompt-ExistingUsername {
    while ($true) {
        $val = Read-Host "  Nombre de usuario"
        if (User-Exists $val) { return $val }
        Write-Warn "El usuario '$val' no existe."
    }
}

# Solicita una contraseña segura (sin eco, mínimo 4 caracteres)
function Prompt-Password {
    param([string]$Label = "Contraseña")
    while ($true) {
        $ss = Read-Host "  $Label (mín 4 caracteres)" -AsSecureString
        if (Test-ValidPassword $ss) { return $ss }
        Write-Warn "Contraseña demasiado corta (mínimo 4 caracteres)."
    }
}

# Solicita un entero en el rango [$Min, $Max]
function Prompt-Int {
    param([string]$Label, [int]$Min, [int]$Max)
    while ($true) {
        $raw = Read-Host "  $Label ($Min-$Max)"
        if (Test-ValidInt $raw $Min $Max) { return [int]$raw }
        Write-Warn "Número inválido (rango $Min-$Max)."
    }
}

# Muestra el listado de grupos y devuelve el nombre del grupo elegido
function Prompt-Group {
    while ($true) {
        Write-Host "  Grupos disponibles:"
        for ($i = 0; $i -lt $GROUPS.Count; $i++) {
            Write-Host "    $($i+1)) $($GROUPS[$i])"
        }
        $raw = Read-Host "  Selecciona grupo (1-$($GROUPS.Count))"
        if (Test-ValidInt $raw 1 $GROUPS.Count) {
            return $GROUPS[[int]$raw - 1]
        }
        Write-Warn "Opción inválida."
    }
}

# Solicita confirmación s/n, devuelve $true si el usuario responde "s"
function Prompt-Confirm {
    param([string]$Label = "¿Confirmas?")
    $resp = Read-Host "  $Label [s/N]"
    return $resp -match '^[sS]$'
}

# ═══════════════════════════════════════════════════════════════
# UTILIDADES DE SALIDA (logging con color)
# ═══════════════════════════════════════════════════════════════

function Write-OK { param([string]$Msg) Write-Host "[OK]   $Msg" -ForegroundColor Green }
function Write-Info { param([string]$Msg) Write-Host "[INFO] $Msg" -ForegroundColor Cyan }
function Write-Warn { param([string]$Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Err { param([string]$Msg) Write-Host "[ERR]  $Msg" -ForegroundColor Red }

function Print-Banner {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║      SERVIDOR FTP — WINDOWS (IIS)            ║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
}

function Print-MenuHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host ("║  {0,-36}║" -f $Title) -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════╣" -ForegroundColor Cyan
}

function Print-MenuFooter {
    Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan
}

# ═══════════════════════════════════════════════════════════════
# UTILIDADES NTFS
# ═══════════════════════════════════════════════════════════════

# Aplica una regla de permiso NTFS a una ruta para un usuario/grupo
function Set-NTFSPermission {
    param(
        [string]$Path,
        [string]$Identity,
        [string]$Rights,
        [string]$Type = "Allow",
        [bool]  $Inherit = $true
    )
    $acl = Get-Acl $Path
    $inherit = if ($Inherit) { "ContainerInherit,ObjectInherit" } else { "None" }
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Identity, $Rights, $inherit, "None", $Type)
    $acl.SetAccessRule($rule)
    Set-Acl -Path $Path -AclObject $acl
}

# Crea un junction NTFS (equivalente a bind mount)
# Borra el directorio destino si ya existe vacío antes de crear el junction
function New-NTFSJunction {
    param([string]$LinkPath, [string]$TargetPath)
    if (Test-Path $LinkPath) {
        Remove-Item $LinkPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    cmd /c "mklink /J `"$LinkPath`" `"$TargetPath`"" 2>&1 | Out-Null
}

# Elimina un junction NTFS sin borrar el destino
function Remove-NTFSJunction {
    param([string]$LinkPath)
    if (Test-Path $LinkPath) {
        cmd /c "rmdir `"$LinkPath`"" 2>&1 | Out-Null
    }
}
