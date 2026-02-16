$InterfaceAlias = "Ethernet 2"
$ServerIP = "192.168.100.1"
$PrefixLength = 24
$ScopeNetwork = "192.168.100.0"
$SubnetMask = "255.255.255.0"

$feature = Get-WindowsFeature DHCP
if (-not $feature.Installed) {
    Install-WindowsFeature -Name DHCP -IncludeManagementTools
}

$ipCheck = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {$_.IPAddress -eq $ServerIP}
if (-not $ipCheck) {
    Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceAlias $InterfaceAlias -IPAddress $ServerIP -PrefixLength $PrefixLength
}

function Test-IsValidScopeIP ($IP) {
    if ($IP -match '^192\.168\.100\.(\d{1,3})$') {
        $last = [int]$Matches[1]
        return ($last -ge 1 -and $last -le 254)
    }
    return $false
}

$ScopeName = Read-Host "Nombre del Ambito"

do {
    $StartRange = Read-Host "IP Inicial"
} until (Test-IsValidScopeIP $StartRange)

do {
    $EndRange = Read-Host "IP Final"
} until (Test-IsValidScopeIP $EndRange)

$LeaseHours = Read-Host "Duracion del Lease en horas"
$LeaseTime = New-TimeSpan -Hours $LeaseHours

$scopeExists = Get-DhcpServerv4Scope -ErrorAction SilentlyContinue | Where-Object { $_.ScopeId -eq $ScopeNetwork }

if (-not $scopeExists) {
    Add-DhcpServerv4Scope -Name $ScopeName -StartRange $StartRange -EndRange $EndRange -SubnetMask $SubnetMask -State Active -LeaseDuration $LeaseTime
}

$Gateway = "192.168.100.1"

Set-DhcpServerv4OptionValue -ScopeId $ScopeNetwork -Router $Gateway

Restart-Service DHCPServer

function Get-DHCPStatus {
    $service = Get-Service DHCPServer
    Write-Host "Estado del Servicio: $($service.Status)"
    $scope = Get-DhcpServerv4Scope | Where-Object { $_.ScopeId -eq $ScopeNetwork }
    if ($scope) {
        Get-DhcpServerv4Lease -ScopeId $scope.ScopeId | Select-Object ClientIPAddress, HostName, AddressState | Format-Table -AutoSize
    }
}

Get-DHCPStatus