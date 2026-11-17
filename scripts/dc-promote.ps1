<#
  dc-promote.ps1 — runs on jt-dc01 via Azure managed Run Command.
  1. Puts NTDS/SYSVOL on a dedicated data disk (F:)
  2. Stages a one-time post-config task (OUs, users, groups, delegation, policy, auditing)
  3. Creates the forest and schedules a reboot
  Author: Jonathan Tapia
#>
param(
    [Parameter(Mandatory)] [string] $DomainName,
    [Parameter(Mandatory)] [string] $NetbiosName,
    [Parameter(Mandatory)] [string] $SafeModePassword
)

$ErrorActionPreference = 'Stop'
$labDir = 'C:\LabSetup'
New-Item -ItemType Directory -Path $labDir -Force | Out-Null
Start-Transcript -Path "$labDir\dc-promote.log" -Append

if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) {
    Write-Output 'Already a domain controller. Nothing to do.'
    Stop-Transcript
    exit 0
}

# --- 1. Data disk for the AD database ----------------------------------------
# Microsoft guidance: NTDS on a data disk with host caching = None (set in Bicep).
$raw = Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Select-Object -First 1
if ($raw) {
    $raw | Initialize-Disk -PartitionStyle GPT -PassThru |
        New-Partition -DriveLetter F -UseMaximumSize |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel 'ADDS' -Confirm:$false | Out-Null
}

# --- 2. Post-promotion configuration (runs once at next boot as SYSTEM) -------
$postConfig = @'
$ErrorActionPreference = 'Continue'
Start-Transcript -Path 'C:\LabSetup\post-config.log' -Append

# Wait for AD Web Services after the promotion reboot
$domain = $null
for ($i = 0; $i -lt 60 -and -not $domain; $i++) {
    try { $domain = Get-ADDomain -ErrorAction Stop } catch { Start-Sleep -Seconds 20 }
}
if (-not $domain) { Write-Output 'AD never became ready.'; Stop-Transcript; exit 1 }

$dn = $domain.DistinguishedName
$nb = $domain.NetBIOSName
$root = "OU=_JT-Lab,$dn"

# DNS: forward to Azure DNS so private endpoint zones + internet names resolve
Set-DnsServerForwarder -IPAddress 168.63.129.16 -UseRootHint $true

# --- OU structure ---
if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '_JT-Lab'" -SearchBase $dn -SearchScope OneLevel)) {
    New-ADOrganizationalUnit -Name '_JT-Lab' -Path $dn -ProtectedFromAccidentalDeletion $true
}
foreach ($ou in 'Users', 'Helpdesk', 'Admins', 'Groups', 'Servers', 'Workstations') {
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -SearchBase $root -SearchScope OneLevel)) {
        New-ADOrganizationalUnit -Name $ou -Path $root -ProtectedFromAccidentalDeletion $true
    }
}
redircmp.exe "OU=Workstations,$root" | Out-Null

# --- Domain password + lockout policy (what the Sentinel rules watch for) ---
Set-ADDefaultDomainPasswordPolicy -Identity $domain.DNSRoot `
    -MinPasswordLength 12 -ComplexityEnabled $true -MaxPasswordAge '90.00:00:00' `
    -LockoutThreshold 5 -LockoutDuration '00:15:00' -LockoutObservationWindow '00:15:00'

# --- Groups ---
foreach ($g in 'GG-Helpdesk-Tier1', 'GG-Finance', 'GG-Sales') {
    if (-not (Get-ADGroup -Filter "Name -eq '$g'")) {
        New-ADGroup -Name $g -GroupScope Global -GroupCategory Security -Path "OU=Groups,$root"
    }
}

function New-LabPassword { 'Jt!' + [guid]::NewGuid().ToString('N').Substring(0, 12) + 'Aa9' }

function New-LabUser($Sam, $First, $Last, $Title, $Dept, $Ou, $Group) {
    if (Get-ADUser -Filter "SamAccountName -eq '$Sam'") { return }
    New-ADUser -SamAccountName $Sam -UserPrincipalName "$Sam@$($domain.DNSRoot)" `
        -Name "$First $Last" -GivenName $First -Surname $Last -DisplayName "$First $Last" `
        -Title $Title -Department $Dept -Company 'JT Lab Corp' `
        -Path "OU=$Ou,$root" -Enabled $true -ChangePasswordAtLogon $true `
        -AccountPassword (ConvertTo-SecureString (New-LabPassword) -AsPlainText -Force)
    Add-ADGroupMember -Identity $Group -Members $Sam
}

# The Tier 1 tech account (separate from the domain admin account)
New-LabUser 'jontapia.t1' 'Jonathan' 'Tapia' 'IT Support Technician' 'IT' 'Helpdesk' 'GG-Helpdesk-Tier1'
# End users for ticket scenarios
New-LabUser 'mlopez' 'Maria'  'Lopez'  'Accounts Payable Clerk' 'Finance' 'Users' 'GG-Finance'
New-LabUser 'pshah'  'Priya'  'Shah'   'Financial Analyst'      'Finance' 'Users' 'GG-Finance'
New-LabUser 'kbrooks' 'Kevin' 'Brooks' 'Account Executive'      'Sales'   'Users' 'GG-Sales'
New-LabUser 'dkim'   'Daniel' 'Kim'    'Sales Manager'          'Sales'   'Users' 'GG-Sales'

# --- Delegation: Tier 1 can reset passwords + unlock accounts in Users OU only ---
$usersOu = "OU=Users,$root"
dsacls.exe $usersOu /I:S /G "$nb\GG-Helpdesk-Tier1:CA;Reset Password;user" | Out-Null
dsacls.exe $usersOu /I:S /G "$nb\GG-Helpdesk-Tier1:RPWP;lockoutTime;user" | Out-Null
dsacls.exe $usersOu /I:S /G "$nb\GG-Helpdesk-Tier1:RPWP;pwdLastSet;user" | Out-Null

# --- Auditing the detections depend on ---
auditpol.exe /set /subcategory:"Logon" /success:enable /failure:enable | Out-Null
auditpol.exe /set /subcategory:"User Account Management" /success:enable /failure:enable | Out-Null
auditpol.exe /set /subcategory:"Security Group Management" /success:enable | Out-Null

Unregister-ScheduledTask -TaskName 'JT-Lab-PostConfig' -Confirm:$false
Set-Content -Path 'C:\LabSetup\post-config.done' -Value (Get-Date)
Stop-Transcript
'@
Set-Content -Path "$labDir\post-config.ps1" -Value $postConfig -Encoding UTF8

$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File $labDir\post-config.ps1"
$trigger = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName 'JT-Lab-PostConfig' -Action $action -Trigger $trigger `
    -User 'SYSTEM' -RunLevel Highest -Force | Out-Null

# --- 3. Promote to the first DC of a new forest -------------------------------
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
Import-Module ADDSDeployment

Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetbiosName `
    -DomainMode WinThreshold -ForestMode WinThreshold `
    -InstallDns `
    -DatabasePath 'F:\NTDS' -LogPath 'F:\NTDS' -SysvolPath 'F:\SYSVOL' `
    -SafeModeAdministratorPassword (ConvertTo-SecureString $SafeModePassword -AsPlainText -Force) `
    -NoRebootOnCompletion -Force | Out-Null

# Reboot after Run Command reports success, so the deployment doesn't hang.
shutdown.exe /r /t 60 /c 'JT Lab: rebooting to finish AD DS promotion'
Write-Output "Forest $DomainName created. Rebooting in 60 seconds."
Stop-Transcript
