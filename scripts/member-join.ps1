<#
  member-join.ps1 — runs on jt-srv01 via Azure managed Run Command.
  Installs admin tools (ADUC, DNS, GPMC), waits for the new DC, joins the domain
  into the Servers OU, then schedules a reboot.
  Author: Jonathan Tapia
#>
param(
    [Parameter(Mandatory)] [string] $DomainName,
    [Parameter(Mandatory)] [string] $NetbiosName,
    [Parameter(Mandatory)] [string] $DcIp,
    [Parameter(Mandatory)] [string] $OuPath,
    [Parameter(Mandatory)] [string] $JoinUser,
    [Parameter(Mandatory)] [string] $JoinPassword
)

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path 'C:\LabSetup' -Force | Out-Null
Start-Transcript -Path 'C:\LabSetup\member-join.log' -Append

if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
    Write-Output 'Already domain-joined.'
    Stop-Transcript
    exit 0
}

# Management server for the help desk: AD Users & Computers, DNS, Group Policy
Install-WindowsFeature -Name RSAT-AD-Tools, RSAT-DNS-Server, GPMC | Out-Null

$cred = New-Object System.Management.Automation.PSCredential(
    "$NetbiosName\$JoinUser", (ConvertTo-SecureString $JoinPassword -AsPlainText -Force))

# The DC reboots after promotion and then builds the OU tree,
# so retry for up to 30 minutes.
$joined = $false
for ($i = 1; $i -le 60 -and -not $joined; $i++) {
    try {
        $ldap = Test-NetConnection -ComputerName $DcIp -Port 389 -WarningAction SilentlyContinue
        if ($ldap.TcpTestSucceeded) {
            Clear-DnsClientCache
            Add-Computer -DomainName $DomainName -OUPath $OuPath -Credential $cred -Force -ErrorAction Stop
            $joined = $true
            Write-Output "Joined $DomainName on attempt $i."
        } else {
            Write-Output "Attempt ${i}: DC not answering on LDAP yet."
        }
    } catch {
        Write-Output "Attempt ${i}: $($_.Exception.Message)"
    }
    if (-not $joined) { Start-Sleep -Seconds 30 }
}

if (-not $joined) { throw 'Domain join did not succeed within 30 minutes. See C:\LabSetup\member-join.log' }

# After the join reboot, let the Tier 1 group RDP into this management server.
$grant = @"
`$group = '$NetbiosName\GG-Helpdesk-Tier1'
for (`$i = 0; `$i -lt 30; `$i++) {
    try { Add-LocalGroupMember -Group 'Remote Desktop Users' -Member `$group -ErrorAction Stop; break }
    catch { if (`$_.Exception.Message -match 'already a member') { break }; Start-Sleep -Seconds 20 }
}
Unregister-ScheduledTask -TaskName 'JT-Lab-GrantRdp' -Confirm:`$false
"@
Set-Content -Path 'C:\LabSetup\grant-rdp.ps1' -Value $grant -Encoding UTF8
Register-ScheduledTask -TaskName 'JT-Lab-GrantRdp' -User 'SYSTEM' -RunLevel Highest -Force `
    -Trigger (New-ScheduledTaskTrigger -AtStartup) `
    -Action (New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\LabSetup\grant-rdp.ps1') | Out-Null

shutdown.exe /r /t 60 /c "JT Lab: joined $DomainName"
Stop-Transcript
