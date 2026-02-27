#Requires -RunAsAdministrator
# =============================================================
# ftp_windows.ps1 — Servidor FTP automatizado en Windows (IIS)
#
# Lógica de negocio principal. Las validaciones, prompts y
# helpers NTFS están en ftp_helpers.ps1 (dot-sourced al inicio).
#
# Ejecutar en PowerShell como Administrador:
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\ftp_windows.ps1
# =============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Importar módulo de utilidades ─────────────────────────────
. "$PSScriptRoot\ftp_helpers.ps1"

# ═══════════════════════════════════════════════════════════════
# 1. INSTALACIÓN IDEMPOTENTE — IIS + FTP Service
# ═══════════════════════════════════════════════════════════════

function Install-FTPServer {
    Write-Info "Verificando características IIS/FTP..."

    foreach ($feature in @("Web-Server", "Web-FTP-Server", "Web-FTP-Service", "Web-Mgmt-Console")) {
        $state = (Get-WindowsFeature -Name $feature -ErrorAction SilentlyContinue).InstallState
        if ($state -eq "Installed") {
            Write-OK "$feature ya instalado."
        }
        else {
            Write-Info "Instalando $feature..."
            Install-WindowsFeature -Name $feature -IncludeManagementTools | Out-Null
            Write-OK "$feature instalado."
        }
    }

    Assert-WebAdminModule

    foreach ($svc in @("W3SVC", "FTPSVC")) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            if ($s.Status -ne 'Running') {
                Start-Service $svc
                Set-Service   $svc -StartupType Automatic
            }
            Write-OK "Servicio $svc activo."
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# 2. CONFIGURAR SITIO FTP EN IIS
# ═══════════════════════════════════════════════════════════════

function Configure-FTPSite {
    Assert-WebAdminModule

    Write-Info "Configurando sitio FTP en IIS: '$SITE_NAME'..."

    if (-not (Test-Path $FTP_ROOT)) {
        New-Item -ItemType Directory -Path $FTP_ROOT -Force | Out-Null
        Write-OK "Directorio raíz creado: $FTP_ROOT"
    }

    if (Get-WebSite -Name $SITE_NAME -ErrorAction SilentlyContinue) {
        Write-OK "Sitio FTP '$SITE_NAME' ya existe."
    }
    else {
        New-WebFtpSite -Name $SITE_NAME -Port $FTP_PORT -PhysicalPath $FTP_ROOT -Force
        Write-OK "Sitio FTP '$SITE_NAME' creado en puerto $FTP_PORT."
    }

    # Autenticación: anónima + básica
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.authentication.basicAuthentication.enabled    -Value $true

    # Aislamiento por usuario (LocalUser/<username>)
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.userIsolation.mode -Value 3

    # Sin SSL (entorno de práctica)
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
    Set-ItemProperty "IIS:\Sites\$SITE_NAME" `
        -Name ftpServer.security.ssl.dataChannelPolicy    -Value 0

    # Puertos pasivos
    Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" `
        -Filter "system.ftpServer/firewallSupport" `
        -Name "lowDataChannelPort"  -Value 40000
    Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" `
        -Filter "system.ftpServer/firewallSupport" `
        -Name "highDataChannelPort" -Value 40100

    Stop-WebSite  -Name $SITE_NAME -ErrorAction SilentlyContinue
    Start-WebSite -Name $SITE_NAME
    Write-OK "Sitio FTP configurado e iniciado."
}

# ═══════════════════════════════════════════════════════════════
# 3. GRUPOS Y ESTRUCTURA DE CARPETAS
# ═══════════════════════════════════════════════════════════════

function New-LocalGroups {
    Write-Info "Verificando grupos locales FTP..."
    foreach ($grp in $GROUPS) {
        if (Group-Exists $grp) {
            Write-OK "Grupo '$grp' ya existe."
        }
        else {
            New-LocalGroup -Name $grp -Description "Grupo FTP $grp"
            Write-OK "Grupo '$grp' creado."
        }
    }
}

function Setup-FTPDirectories {
    Write-Info "Configurando estructura de directorios FTP..."

    if (-not (Test-Path $FTP_ROOT)) {
        New-Item -ItemType Directory -Path $FTP_ROOT -Force | Out-Null
    }

    # Carpeta /general: anónimo R, usuarios autenticados RW
    $generalPath = "$FTP_ROOT\general"
    if (-not (Test-Path $generalPath)) {
        New-Item -ItemType Directory -Path $generalPath -Force | Out-Null
    }
    Set-NTFSPermission -Path $generalPath -Identity "Everyone"            -Rights "ReadAndExecute"
    Set-NTFSPermission -Path $generalPath -Identity "Authenticated Users" -Rights "Modify"
    Write-OK "Carpeta 'general' configurada."

    # Carpetas de grupo
    foreach ($grp in $GROUPS) {
        $grpPath = "$FTP_ROOT\$grp"
        if (-not (Test-Path $grpPath)) {
            New-Item -ItemType Directory -Path $grpPath -Force | Out-Null
        }
        Set-NTFSPermission -Path $grpPath -Identity $grp -Rights "Modify"
        Write-OK "Carpeta '$grp' configurada (RW solo grupo)."
    }

    # Directorio base de usuarios individuales
    $usersPath = "$FTP_ROOT\users"
    if (-not (Test-Path $usersPath)) {
        New-Item -ItemType Directory -Path $usersPath -Force | Out-Null
    }
    Write-OK "Directorio de usuarios: $usersPath"
}

# ═══════════════════════════════════════════════════════════════
# 4. GESTIÓN DE REGLAS DE AUTORIZACIÓN IIS
# ═══════════════════════════════════════════════════════════════

function Set-IISAuthorizationRules {
    param([string]$Username, [string]$Group)

    Assert-WebAdminModule
    $sitePath = "IIS:\Sites\$SITE_NAME"
    $filter = "system.ftpServer/security/authorization"

    # Limpiar reglas anteriores del usuario
    Get-WebConfiguration -PSPath $sitePath -Filter "$filter/add" |
    Where-Object { $_.users -eq $Username } |
    ForEach-Object {
        Remove-WebConfigurationElement -PSPath $sitePath -Filter $filter `
            -Name "add" -AtElement @{users = $Username } -ErrorAction SilentlyContinue
    }

    # Acceso anónimo a general (solo lectura)
    Add-WebConfiguration -PSPath $sitePath -Filter $filter -Value @{
        accessType = "Allow"; users = "?"; permissions = "Read"
    } -ErrorAction SilentlyContinue

    # Usuario autenticado: RW en sus 3 carpetas
    Add-WebConfiguration -PSPath $sitePath -Filter $filter -Value @{
        accessType = "Allow"; users = $Username; permissions = "Read, Write"
    } -ErrorAction SilentlyContinue

    Write-OK "Reglas IIS AuthZ configuradas para '$Username'."
}

# ═══════════════════════════════════════════════════════════════
# 5. OPERACIONES CRUD DE USUARIOS
# ═══════════════════════════════════════════════════════════════

function New-FTPUser {
    Write-Host ""
    Write-Host "  ── Nuevo usuario FTP ──" -ForegroundColor Cyan

    $username = Prompt-NewUsername
    $password = Prompt-Password
    $group = Prompt-Group

    # Crear usuario local
    New-LocalUser -Name $username -Password $password `
        -FullName "FTP $username" -Description "Usuario FTP" `
        -PasswordNeverExpires $true | Out-Null
    Add-LocalGroupMember -Group $group -Member $username

    # Árbol de directorios en LocalUser/<username>/
    $userFTPRoot = "$FTP_ROOT\LocalUser\$username"
    foreach ($subdir in @("general", $group, $username)) {
        $dirPath = "$userFTPRoot\$subdir"
        if (-not (Test-Path $dirPath)) {
            New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
        }
    }

    # Permisos NTFS en carpetas reales
    Set-NTFSPermission -Path "$userFTPRoot\$group"    -Identity $group    -Rights "Modify"
    Set-NTFSPermission -Path "$userFTPRoot\$group"    -Identity $username -Rights "Modify"
    Set-NTFSPermission -Path "$userFTPRoot\$username" -Identity $username -Rights "FullControl"
    Set-NTFSPermission -Path $userFTPRoot             -Identity $username -Rights "ReadAndExecute"

    # Junctions hacia carpetas compartidas (general y grupo)
    foreach ($subdir in @("general", $group)) {
        New-NTFSJunction -LinkPath "$userFTPRoot\$subdir" -TargetPath "$FTP_ROOT\$subdir"
    }

    Set-IISAuthorizationRules -Username $username -Group $group

    Write-OK "Usuario '$username' creado en grupo '$group'."
    Write-Host "       Árbol FTP visible al hacer login:"
    Write-Host "         ├── general\          (RW - compartida)"
    Write-Host "         ├── $group\           (RW - grupo)"
    Write-Host "         └── $username\        (RW - personal)"
}

function Change-UserGroup {
    Write-Host ""
    Write-Host "  ── Cambiar grupo de usuario ──" -ForegroundColor Cyan

    $username = Prompt-ExistingUsername

    $currentGroup = ""
    foreach ($grp in $GROUPS) {
        $members = Get-LocalGroupMember -Group $grp -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "\\$username$" }
        if ($members) { $currentGroup = $grp; break }
    }

    Write-Host "  Grupo actual: $(if($currentGroup){ $currentGroup } else { 'ninguno' })"
    $newGroup = Prompt-Group

    if ($newGroup -eq $currentGroup) {
        Write-Warn "El usuario '$username' ya está en '$newGroup'. Sin cambios."; return
    }

    if ($currentGroup) {
        Remove-LocalGroupMember -Group $currentGroup -Member $username -ErrorAction SilentlyContinue
        Remove-NTFSJunction -LinkPath "$FTP_ROOT\LocalUser\$username\$currentGroup"
    }

    Add-LocalGroupMember -Group $newGroup -Member $username

    $newJunction = "$FTP_ROOT\LocalUser\$username\$newGroup"
    New-NTFSJunction -LinkPath $newJunction -TargetPath "$FTP_ROOT\$newGroup"
    Set-NTFSPermission -Path $newJunction -Identity $newGroup    -Rights "Modify"
    Set-NTFSPermission -Path $newJunction -Identity $username    -Rights "Modify"

    Set-IISAuthorizationRules -Username $username -Group $newGroup
    Write-OK "Usuario '$username' movido de '$currentGroup' → '$newGroup'."
}

function Remove-FTPUser {
    Write-Host ""
    Write-Host "  ── Eliminar usuario FTP ──" -ForegroundColor Cyan

    $username = Prompt-ExistingUsername

    if (-not (Prompt-Confirm "¿Eliminar al usuario '$username' y su carpeta?")) {
        Write-Warn "Operación cancelada."; return
    }

    $userFTPRoot = "$FTP_ROOT\LocalUser\$username"
    foreach ($subdir in @("general") + $GROUPS) {
        Remove-NTFSJunction -LinkPath "$userFTPRoot\$subdir"
    }
    if (Test-Path $userFTPRoot) {
        Remove-Item $userFTPRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Remove-LocalUser -Name $username
    Write-OK "Usuario '$username' eliminado."
}

function Get-FTPUserList {
    Write-Host ""
    Write-Host "  ── Usuarios por grupo ──"
    foreach ($grp in $GROUPS) {
        Write-Host "  Grupo: $grp" -ForegroundColor Yellow
        $members = Get-LocalGroupMember -Group $grp -ErrorAction SilentlyContinue
        if ($members) {
            $members | ForEach-Object { Write-Host "    - $($_.Name)" }
        }
        else {
            Write-Host "    <sin usuarios>"
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# 6. MENÚ DE GESTIÓN DE USUARIOS
# ═══════════════════════════════════════════════════════════════

function Invoke-UserMenu {
    while ($true) {
        Print-MenuHeader "GESTIÓN DE USUARIOS FTP"
        Write-Host "║ 1) Crear N usuarios                  ║"
        Write-Host "║ 2) Crear 1 usuario                   ║"
        Write-Host "║ 3) Cambiar grupo de usuario          ║"
        Write-Host "║ 4) Eliminar usuario                  ║"
        Write-Host "║ 5) Listar usuarios FTP               ║"
        Write-Host "║ 6) Volver al menú principal          ║"
        Print-MenuFooter

        switch (Read-Host "  Opción") {
            "1" {
                $n = Prompt-Int "Número de usuarios a crear" 1 100
                for ($i = 1; $i -le $n; $i++) {
                    Write-Host ""; Write-Info "── Usuario $i de $n ──"; New-FTPUser
                }
                Write-OK "$n usuario(s) creado(s)."
            }
            "2" { New-FTPUser }
            "3" { Change-UserGroup }
            "4" { Remove-FTPUser }
            "5" { Get-FTPUserList }
            "6" { return }
            default { Write-Warn "Opción inválida." }
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# 7. MENÚ DE MONITOREO
# ═══════════════════════════════════════════════════════════════

function Show-MonitorMenu {
    while ($true) {
        Print-MenuHeader "MONITOREO IIS FTP"
        Write-Host "║ 1) Estado servicios W3SVC/FTPSVC     ║"
        Write-Host "║ 2) Sitios FTP activos                ║"
        Write-Host "║ 3) Últimos eventos FTP               ║"
        Write-Host "║ 4) Conexiones activas (puerto 21)    ║"
        Write-Host "║ 5) Usuarios y grupos                 ║"
        Write-Host "║ 6) Volver al menú principal          ║"
        Print-MenuFooter

        switch (Read-Host "  Opción") {
            "1" {
                Write-Host ""
                foreach ($svc in @("W3SVC", "FTPSVC")) {
                    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
                    if ($s) {
                        $color = if ($s.Status -eq 'Running') { 'Green' } else { 'Red' }
                        Write-Host "  $svc : $($s.Status)" -ForegroundColor $color
                    }
                    else { Write-Warn "Servicio $svc no encontrado." }
                }
            }
            "2" {
                Write-Host ""
                Assert-WebAdminModule
                Get-WebSite | Format-Table Name, State, PhysicalPath -AutoSize
            }
            "3" {
                Write-Host ""
                Get-EventLog -LogName System -Source "Microsoft-Windows-IIS*" `
                    -Newest 20 -ErrorAction SilentlyContinue |
                Format-Table TimeGenerated, EntryType, Message -AutoSize -Wrap
            }
            "4" {
                Write-Host ""
                netstat -an | Select-String ":21 "
            }
            "5" { Get-FTPUserList }
            "6" { return }
            default { Write-Warn "Opción inválida." }
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# 8. MENÚ PRINCIPAL
# ═══════════════════════════════════════════════════════════════

function Invoke-MainMenu {
    while ($true) {
        Print-MenuHeader "MENÚ PRINCIPAL FTP"
        Write-Host "║ 1) Instalar/Verificar IIS + FTP      ║"
        Write-Host "║ 2) (Re)Configurar sitio FTP en IIS   ║"
        Write-Host "║ 3) Gestión de usuarios               ║"
        Write-Host "║ 4) Monitoreo                         ║"
        Write-Host "║ 5) Salir                             ║"
        Print-MenuFooter

        switch (Read-Host "  Opción") {
            "1" { Install-FTPServer }
            "2" { Configure-FTPSite }
            "3" { Invoke-UserMenu }
            "4" { Show-MonitorMenu }
            "5" { Write-Host ""; Write-Host "  ¡Hasta luego!" -ForegroundColor Green; exit 0 }
            default { Write-Warn "Opción inválida." }
        }
    }
}

# ═══════════════════════════════════════════════════════════════
# ENTRY POINT
# ═══════════════════════════════════════════════════════════════

function Main {
    Require-Admin
    Print-Banner

    Write-Info "Inicializando entorno FTP en Windows..."
    Install-FTPServer
    New-LocalGroups
    Setup-FTPDirectories
    Configure-FTPSite

    Write-Host ""
    Write-OK "Entorno FTP listo."
    Start-Sleep -Seconds 1

    Invoke-MainMenu
}

Main
