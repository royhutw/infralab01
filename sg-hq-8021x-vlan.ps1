# 定義網域與標的 OU 路徑
$DomainDN   = "DC=corp,DC=foo,DC=bar,DC=tw"
$ParentOU   = "OU=HQ,$DomainDN"
$TargetOU   = "OU=8021X-HQ,$ParentOU"

# 1. 檢查並建立 OU=8021X-HQ
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$TargetOU'" -ErrorAction SilentlyContinue)) {
    Write-Host "Creating OU: 8021X-HQ under $ParentOU..." -ForegroundColor Yellow
    New-ADOrganizationalUnit -Name "8021X-HQ" -Path $ParentOU -ProtectedFromAccidentalDeletion $true
} else {
    Write-Host "OU: 8021X-HQ already exists." -ForegroundColor Cyan
}

# 2. 定義 HQ 專用 802.1x 群組清單
$HQGroups = @(
    @{ Name = "SG-HQ-8021X-VLAN20-T0PAW-Users";     Description = "HQ Tier 0 PAW User Auth Group (VLAN 20)" },
    @{ Name = "SG-HQ-8021X-VLAN25-T0BZ-Devices";    Description = "HQ Tier 0 Bastion MAB Group (VLAN 25)" },
    @{ Name = "SG-HQ-8021X-VLAN35-Printers";        Description = "HQ Printers MAB Group (VLAN 35)" },
    @{ Name = "SG-HQ-8021X-VLAN37-IoT-Devices";     Description = "HQ IoT Devices MAB Group (VLAN 37)" },
    @{ Name = "SG-HQ-8021X-VLAN38-IPPhones";        Description = "HQ IP Phones MAB Group (VLAN 38)" },
    @{ Name = "SG-HQ-8021X-VLAN40-Unjoined-PCs";    Description = "HQ Unjoined PCs MAB Group (VLAN 40)" },
    @{ Name = "SG-HQ-8021X-VLAN50-Domain-Computers";Description = "HQ Domain Computers Machine Auth Group (VLAN 50)" },
    @{ Name = "SG-HQ-8021X-VLAN60-IT-Users";        Description = "HQ IT Department User Auth Group (VLAN 60)" },
    @{ Name = "SG-HQ-8021X-VLAN70-GA-Users";        Description = "HQ GA Department User Auth Group (VLAN 70)" },
    @{ Name = "SG-HQ-8021X-VLAN71-MC-Users";        Description = "HQ MC Department User Auth Group (VLAN 71)" },
    @{ Name = "SG-HQ-8021X-VLAN72-LA-Users";        Description = "HQ LA Department User Auth Group (VLAN 72)" },
    @{ Name = "SG-HQ-8021X-VLAN73-NT-Users";        Description = "HQ NT Department User Auth Group (VLAN 73)" },
    @{ Name = "SG-HQ-8021X-VLAN74-NP-Users";        Description = "HQ NP Department User Auth Group (VLAN 74)" },
    @{ Name = "SG-HQ-8021X-VLAN75-PI-Users";        Description = "HQ PI Department User Auth Group (VLAN 75)" },
    @{ Name = "SG-HQ-8021X-VLAN80-CF-Users";        Description = "HQ High Confidential Dept User Auth Group (VLAN 80)" }
)

# 3. 批次建立群組 (加上 SG-HQ- 字首以資識別)
foreach ($Group in $HQGroups) {
    if (-not (Get-ADGroup -Filter "Name -eq '$($Group.Name)'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $Group.Name `
                    -GroupScope Global `
                    -GroupCategory Security `
                    -Path $TargetOU `
                    -Description $Group.Description
        Write-Host "Successfully created group: $($Group.Name)" -ForegroundColor Green
    } else {
        Write-Host "Group already exists: $($Group.Name)" -ForegroundColor Gray
    }
}