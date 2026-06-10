# Domain and secure channel
nltest /sc_verify:(Get-WmiObject Win32_ComputerSystem).Domain

# Services — anything not running that should be
Get-Service | Where-Object {$_.StartType -eq 'Automatic' -and $_.Status -ne 'Running'} |
    Select-Object Name, Status, StartType

# Recent critical/error events since boot
$boot = (Get-Date) - (New-TimeSpan -Seconds (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.Second)
Get-WinEvent -FilterHashtable @{LogName='System','Application'; Level=1,2; StartTime=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime} |
    Select-Object TimeCreated, LevelDisplayName, ProviderName, Message -First 20

# Disk space on all volumes
Get-PSDrive -PSProvider FileSystem |
    Select-Object Name,
        @{N='Used GB';  E={[math]::Round($_.Used/1GB,1)}},
        @{N='Free GB';  E={[math]::Round($_.Free/1GB,1)}},
        @{N='Total GB'; E={[math]::Round(($_.Used+$_.Free)/1GB,1)}}

# Network — IP, DNS servers, default gateway
Get-NetIPConfiguration | Select-Object InterfaceAlias, IPv4Address, DNSServer,
    @{N='Gateway';E={$_.IPv4DefaultGateway.NextHop}}

# DC reachability and clock skew (Kerberos fails above 5 min)
w32tm /query /status

# Listening ports — spot anything unexpected
Get-NetTCPConnection -State Listen |
    Select-Object LocalAddress, LocalPort,
        @{N='Process';E={(Get-Process -Id $_.OwningProcess).Name}} |
    Sort-Object LocalPort
