param([switch]$Populate,[switch]$Deploy,[switch]$Revert,[switch]$AuditSACLs,[switch]$GetObjectPropertiesGuids,[string]$Config,[string]$Output,[string]$Owner,[string]$CanaryContainer,[string]$ParentOU)

################################################################################
#### ADCanaries - PowerShell 2.0 / Windows Server 2008 R2 compatible version ####
####  - JSON configuration replaced by XML configuration                    ####
####  - No PowerShell 3.0+ only features (ConvertTo/From-Json, member       ####
####    enumeration, etc.)                                                  ####
####                                                                        ####
#### Requirements :                                                         ####
####  - PowerShell 2.0 (default on Windows Server 2008 R2)                  ####
####  - Active Directory module for Windows PowerShell (RSAT-AD-PowerShell) ####
####  - Active Directory Web Services reachable on a Domain Controller      ####
####  - Run from an elevated prompt with Domain Admin equivalent rights     ####
################################################################################

################################################################################
####                         Generic Functions                              ####
################################################################################
Import-Module ActiveDirectory
try { Add-Type -AssemblyName System.DirectoryServices } catch {}
$ErrorActionPreference = "Inquire"

function DisplayHelpAndExit {
  Write-Host "
Usage : .\ADCanaries.ps1  -Populate -Config <Path.xml> -ParentOU <OU> -Owner <Group Name> -CanaryContainer <Name>
                              : Populate default ADCanaries deployment; overwrites the XML config file provided.
                          -Deploy -Config <Path.xml> -Output <Path.csv>
                              : Deploy ADCanaries using the XML configuration file and output a lookup CSV with CanaryName,CanaryGUID
                          -Revert -Config <Path.xml>
                              : Destroy ADCanaries using the XML configuration file
                          -AuditSACLs
                              : Display the list of existing AD objects with (ReadProperty|GenericAll) audit enabled to help measure DS Access audit failure activation impact
                          -GetObjectPropertiesGuids -Output <Path.csv>
                              : Retrieves the schemaIDGuid for attributes of Canaries objectClass and outputs as csv
"
  exit 1
}

function DisplayCanaryBanner {
  $Banner = @'


                       (
                      `-`-.
                      '(   >
                       _) (
                      /    )
                     /_,'  /
 ADCanaries - v0.2     \  /
=======================m"m===

'@
  Write-Host $Banner
  Write-Host "[*] Deployment of ADCanaries require DS Access audit to be enabled on Failure on all your Domain Controllers :"
  Write-Host "
                  Computer Configuration
                    > Policies
                      > Windows Settings
                        > Security Settings
                          > Advanced Auditing Policy Configuration
                            > System Audit Policies
                              > DS Access
                                  Directory Service Access : Failure
  "
  Write-Host "[*] All failed read access to audit-enabled AD objects will generate Windows Security Events."
  Write-Host "[*] Please ensure you have estimated the amount of events this deployment will generate in your log managing system."
}


################################################################################
####                             MISC Functions                             ####
################################################################################

function GetEntryDN {
  # An organizationalUnit has an "OU=" RDN, every other class here uses "CN="
  param($Entry)
  if($Entry.Type -eq "organizationalUnit"){ return "OU=" + $Entry.Name + "," + $Entry.Path }
  return "CN=" + $Entry.Name + "," + $Entry.Path
}

function ADObjectExists {
  param($Path)
  try{
    $null = Get-ADObject -Identity "$Path" -ErrorAction Stop
    return $True
  }catch{
    return $False
  }
}

function ValidateAction {
  $Confirmation = ""
  while($Confirmation -ne "y" -and $Confirmation -ne "n"){
    $Confirmation = Read-Host "[?] Are you sure you want to deploy / remove ADCanaries on your domain ? (y/n)"
  }
  Write-Host ""

  if($Confirmation -eq "n"){exit 0}
}

function CheckParameter($Param) {
  if ([string]::IsNullOrEmpty($Param)) {
      DisplayHelpAndExit
  }
}

function ResolveFullPath {
  # .NET methods (XmlDocument.Load/Save) do not use the PowerShell current location,
  # so relative paths must be resolved explicitly.
  param($Path)
  return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function CheckSACLs {
  $PreviousPreference = $ErrorActionPreference
  $ErrorActionPreference = "SilentlyContinue"
  Write-Host "`n[*] Listing AD objects with ReadAudit enabled (SACL) :"
  Get-ADObject -Filter * | ForEach-Object {
    $DN = $_.DistinguishedName
    $ObjAcl = Get-Acl -Path ("AD:\" + $DN) -Audit
    if($null -ne $ObjAcl){
      foreach($Rule in $ObjAcl.Audit){
        $Rights  = [string]$Rule.ActiveDirectoryRights
        $Trustee = [string]$Rule.IdentityReference
        if($Rights -match "ReadProperty" -or $Rights -match "GenericAll"){
          Write-Host "    - $DN : `t`t$Rights ($Trustee)"
        }
      }
    }
  }
  $ErrorActionPreference = $PreviousPreference
}

function AddAttributeNames {
  param($Table, $Values)
  foreach($Value in $Values){
    if($Value){ $Table[[string]$Value] = $true }
  }
}

function ListObjectAttributes {
    param($ClassName)
    # Based on code from easy365manager.com
    # Ref : https://www.easy365manager.com/how-to-get-all-active-directory-user-object-attributes/
    $SchemaNC   = (Get-ADRootDSE).SchemaNamingContext
    $AttrProps  = @("mayContain","mustContain","systemMayContain","systemMustContain")
    $ClassProps = $AttrProps + @("AuxiliaryClass","SystemAuxiliaryClass","subClassOf","ldapDisplayName")
    $Table      = @{}
    $Loop       = $True

    # Walk the class and all its parent classes
    while($Loop){
      $Class = Get-ADObject -SearchBase $SchemaNC -Filter "ldapDisplayName -eq '$ClassName'" -Properties $ClassProps
      if($null -eq $Class){ break }

      $ParentName = [string]$Class.subClassOf
      if(([string]$Class.ldapDisplayName) -eq $ParentName){ $Loop = $False }

      # Direct attributes
      foreach($Prop in $AttrProps){ AddAttributeNames -Table $Table -Values $Class.$Prop }

      # Auxiliary and SystemAuxiliary class attributes
      $AuxNames = @()
      if($Class.AuxiliaryClass){       $AuxNames += @($Class.AuxiliaryClass) }
      if($Class.SystemAuxiliaryClass){ $AuxNames += @($Class.SystemAuxiliaryClass) }
      foreach($AuxName in $AuxNames){
        $Aux = Get-ADObject -SearchBase $SchemaNC -Filter "ldapDisplayName -eq '$AuxName'" -Properties $AttrProps
        if($null -ne $Aux){
          foreach($Prop in $AttrProps){ AddAttributeNames -Table $Table -Values $Aux.$Prop }
        }
      }
      $ClassName = $ParentName
    }
    return @($Table.Keys | Sort-Object)
}

function GetObjectPropertiesGuids {
    param($Output)
    $PreviousPreference = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"

    $SchemaNC = (Get-ADRootDSE).schemaNamingContext
    $Seen     = @{}
    $Results  = New-Object System.Collections.ArrayList

    foreach($Class in ("User", "Computer", "Group")){
        $Attributes = ListObjectAttributes -ClassName $Class
        Write-Host "[*] Attributes retrieved for objectClass : $Class"
        foreach($Attribute in $Attributes){
            if($Seen.ContainsKey($Attribute)){ continue }
            $Seen[$Attribute] = $true
            $Found = Get-ADObject -SearchBase $SchemaNC -Filter "ldapDisplayName -eq '$Attribute' -and objectClass -eq 'attributeSchema'" -Properties schemaIDGuid
            if(($null -ne $Found) -and ($null -ne $Found.schemaIDGuid)){
                [byte[]]$Bytes = $Found.schemaIDGuid
                $Guid = New-Object System.Guid -ArgumentList (,$Bytes)
                $Row = New-Object PSObject
                Add-Member -InputObject $Row -MemberType NoteProperty -Name "ldapDisplayName" -Value ([string]$Attribute)
                Add-Member -InputObject $Row -MemberType NoteProperty -Name "schemaIDGuid" -Value ($Guid.ToString())
                [void]$Results.Add($Row)
            }
        }
        Write-Host "[*] Attribute's Guids retrieved for objectClass : $Class"
    }

    $ErrorActionPreference = $PreviousPreference
    $FullOutput = ResolveFullPath $Output
    Remove-Item -Path $FullOutput -ErrorAction SilentlyContinue
    $Results | Export-Csv -Path $FullOutput -NoTypeInformation
    $Total = $Results.Count
    Write-Host "[*] Total attributes retrieved : $Total"
    Write-Host "[*] You can grab $Output to lookup these attributes when access is denied on the canaries"
}

################################################################################
####                       XML Configuration Helpers                        ####
################################################################################
# XML layout :
#
# <ADCanaries>
#   <Configuration>
#     <CanaryOwner>Domain Admins</CanaryOwner>
#     <CanaryContainer>  Name / Type / Path / Description / ProtectedFromAccidentalDeletion / OtherAttributes </CanaryContainer>
#     <CanaryGroup>      Name / Type / Path / Description / ProtectedFromAccidentalDeletion / OtherAttributes </CanaryGroup>
#   </Configuration>
#   <Canaries>
#     <Canary>           Name / Type / Path / Description / ProtectedFromAccidentalDeletion / OtherAttributes </Canary>
#     ...
#   </Canaries>
# </ADCanaries>

function NewTextElement {
  # Note : intentionally returns nothing (XmlNode is IEnumerable and would be unrolled by the pipeline)
  param($Doc, $Parent, $ElementName, $Text)
  $Element = $Doc.CreateElement($ElementName)
  $Element.InnerText = [string]$Text
  [void]$Parent.AppendChild($Element)
}

function AddEntryElement {
  param($Doc, $Parent, $ElementName, $EntryName, $EntryType, $EntryPath, $Description)
  $Entry = $Doc.CreateElement($ElementName)
  [void]$Parent.AppendChild($Entry)
  NewTextElement -Doc $Doc -Parent $Entry -ElementName "Name"                           -Text $EntryName
  NewTextElement -Doc $Doc -Parent $Entry -ElementName "Type"                           -Text $EntryType
  NewTextElement -Doc $Doc -Parent $Entry -ElementName "Path"                           -Text $EntryPath
  NewTextElement -Doc $Doc -Parent $Entry -ElementName "Description"                    -Text $Description
  NewTextElement -Doc $Doc -Parent $Entry -ElementName "ProtectedFromAccidentalDeletion" -Text "1"
  $Other = $Doc.CreateElement("OtherAttributes")
  [void]$Entry.AppendChild($Other)
}

function GetChildText {
  param($Node, $ChildName)
  $Child = $Node.SelectSingleNode($ChildName)
  if($null -eq $Child){ return "" }
  return [string]$Child.InnerText
}

function ReadEntry {
  # Converts an XML entry node to a hashtable
  param($Node)
  $Entry = @{}
  $Entry.Name        = GetChildText $Node "Name"
  $Entry.Type        = GetChildText $Node "Type"
  $Entry.Path        = GetChildText $Node "Path"
  $Entry.Description = GetChildText $Node "Description"
  $Protected         = GetChildText $Node "ProtectedFromAccidentalDeletion"
  $Entry.Protected   = ($Protected -eq "1" -or $Protected -eq "true")
  return $Entry
}

function LoadConfigXml {
  param($Path)
  $FullPath = ResolveFullPath $Path
  if(-not (Test-Path -Path $FullPath)){
    Write-Host "[!] Configuration file not found : $FullPath"
    exit 1
  }
  $Doc = New-Object System.Xml.XmlDocument
  try{
    $Doc.Load($FullPath)
  }catch{
    Write-Host "[!] Unable to parse XML configuration file : $FullPath"
    Write-Host "    $_"
    exit 1
  }
  if($null -eq $Doc.DocumentElement -or $Doc.DocumentElement.Name -ne "ADCanaries"){
    Write-Host "[!] Invalid configuration file : root element <ADCanaries> not found"
    exit 1
  }
  # Unary comma : prevent PowerShell from unrolling the XmlDocument
  return ,$Doc
}

function ReadConfiguration {
  # Returns a hashtable : Owner, Container, Group, Canaries (array of hashtables)
  param($Path)
  $Doc  = LoadConfigXml $Path
  $Root = $Doc.DocumentElement

  $ConfNode      = $Root.SelectSingleNode("Configuration")
  $ContainerNode = $Root.SelectSingleNode("Configuration/CanaryContainer")
  $GroupNode     = $Root.SelectSingleNode("Configuration/CanaryGroup")
  if($null -eq $ConfNode -or $null -eq $ContainerNode -or $null -eq $GroupNode){
    Write-Host "[!] Invalid configuration file : <Configuration>, <CanaryContainer> and <CanaryGroup> are required"
    exit 1
  }

  $Result = @{}
  $Result.Owner     = GetChildText $ConfNode "CanaryOwner"
  $Result.Container = ReadEntry $ContainerNode
  $Result.Group     = ReadEntry $GroupNode
  $Canaries = New-Object System.Collections.ArrayList
  foreach($CanaryNode in $Root.SelectNodes("Canaries/Canary")){
    [void]$Canaries.Add((ReadEntry $CanaryNode))
  }
  $Result.Canaries = $Canaries
  return $Result
}

################################################################################
####                 Populate Configuration Functions                       ####
################################################################################
function DefaultCanaries {
    # $ParentOU : canary container DN (CN=...), used for most canaries
    # $RealOU   : real OU / domain DN; an organizationalUnit cannot be created under a container
    param($Doc, $Parent, $ParentOU, $RealOU)

    $Defaults = @(
        @("CanaryUser",     "user",                   "Default Canary user"),
        @("CanaryComputer", "computer",               "Default Canary computer"),
        @("CanaryGroup",    "group",                  "Default Canary group"),
        @("CanaryOU",       "organizationalUnit",     "Default Canary OU"),
        @("CanaryPolicy",   "domainPolicy",           "Default Canary policy"),
        @("CanaryTemplate", "pKICertificateTemplate", "Default Canary certificate template")
    )
    foreach($Def in $Defaults){
        $EntryPath = $ParentOU
        if($Def[1] -eq "organizationalUnit"){ $EntryPath = $RealOU }
        AddEntryElement -Doc $Doc -Parent $Parent -ElementName "Canary" `
                        -EntryName $Def[0] -EntryType $Def[1] -EntryPath $EntryPath `
                        -Description ("[ADCanaries] " + $Def[2] + " -- change it")
    }
}

function PopulateConf {
  param($Config, $ParentOU, $CanaryGroupName, $Owner)
  ValidateAction

  # Check if owner exists (must be a group, it is resolved with Get-ADGroup at deployment)
  try{
    $null = Get-ADGroup -Identity "$Owner" -ErrorAction Stop
  }catch{
    Write-Host "[!] $Owner not found in AD groups please provide a valid Owner group"
    exit 1
  }

  # Check if ParentOU exists
  if(-not (ADObjectExists -Path $ParentOU)){
    Write-Host "[!] $ParentOU not found in AD Objects please provide a valid Parent OU"
    exit 1
  }

  $Doc  = New-Object System.Xml.XmlDocument
  [void]$Doc.AppendChild($Doc.CreateXmlDeclaration("1.0", "utf-8", $null))
  $Root = $Doc.CreateElement("ADCanaries")
  [void]$Doc.AppendChild($Root)

  $ConfNode = $Doc.CreateElement("Configuration")
  [void]$Root.AppendChild($ConfNode)
  NewTextElement -Doc $Doc -Parent $ConfNode -ElementName "CanaryOwner" -Text $Owner

  AddEntryElement -Doc $Doc -Parent $ConfNode -ElementName "CanaryContainer" `
                  -EntryName $CanaryGroupName -EntryType "container" -EntryPath $ParentOU `
                  -Description "[ADCanaries] Default Container -- [VISIBLE TO ATTACKERS] change it"

  $CanariesPath = "CN=$CanaryGroupName,$ParentOU"

  AddEntryElement -Doc $Doc -Parent $ConfNode -ElementName "CanaryGroup" `
                  -EntryName $CanaryGroupName -EntryType "group" -EntryPath $CanariesPath `
                  -Description "[ADCanaries] Default group -- [VISIBLE TO ATTACKERS] change it"

  $CanariesNode = $Doc.CreateElement("Canaries")
  [void]$Root.AppendChild($CanariesNode)
  DefaultCanaries -Doc $Doc -Parent $CanariesNode -ParentOU $CanariesPath -RealOU $ParentOU

  #### Overwrite output file
  $FullPath = ResolveFullPath $Config
  Remove-Item -Path $FullPath -ErrorAction SilentlyContinue
  $Doc.Save($FullPath)

  Get-Content -Path $FullPath | ForEach-Object { Write-Host $_ }
}


################################################################################
####                    Deploy Canaries Functions                           ####
################################################################################
function SetAuditSACL {
    param($DistinguishedName)
    $Everyone       = New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0")
    $ReadProperty   = [System.DirectoryServices.ActiveDirectoryRights]::ReadProperty
    $SuccessFailure = [System.Security.AccessControl.AuditFlags]::Success -bor [System.Security.AccessControl.AuditFlags]::Failure
    $AccessRule     = New-Object System.DirectoryServices.ActiveDirectoryAuditRule($Everyone,$ReadProperty,$SuccessFailure)
    $ACL            = Get-Acl -Path ("AD:\" + $DistinguishedName)
    $ACL.SetAuditRule($AccessRule)
    $ACL | Set-Acl -Path ("AD:\" + $DistinguishedName)
    Write-Host "[*] SACL deployed on : $DistinguishedName"
}

function DenyAllOnCanariesAndChangeOwner {
    param($DistinguishedName, $Owner)
    $AdPath         = "AD:\" + $DistinguishedName
    $Everyone       = New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0")
    $GenericAll     = [System.DirectoryServices.ActiveDirectoryRights]::GenericAll
    $Deny           = [System.Security.AccessControl.AccessControlType]::Deny
    $AccessRule     = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($Everyone,$GenericAll,$Deny)
    $OwnerGroup     = Get-ADGroup -Identity "$Owner"
    $NewOwner       = New-Object System.Security.Principal.SecurityIdentifier($OwnerGroup.SID.Value)
    $ACL            = Get-Acl -Path $AdPath
    $ACL.SetAccessRuleProtection($true, $false)
    $ACL | Set-Acl -Path $AdPath
    $ACL = Get-Acl -Path $AdPath
    $ACL.SetAccessRule($AccessRule)
    $ACL | Set-Acl -Path $AdPath
    $ACL = Get-Acl -Path $AdPath
    $ACL.SetOwner($NewOwner)
    $ACL | Set-Acl -Path $AdPath
    Write-Host "[*] Deny All DACL deployed on : $DistinguishedName"
}

function CreateCanary {
  param($Canary, $Output, $CanaryGroup, $Owner)

  $CanaryGroupDN = $CanaryGroup.distinguishedName
  $CanaryGroupToken = (Get-ADGroup $CanaryGroupDN -Properties @("primaryGroupToken")).primaryGroupToken
  $DistinguishedName = GetEntryDN $Canary

  if (ADObjectExists -Path $DistinguishedName){
    Write-Host "[-] Canary already existed : $DistinguishedName"
  }
  else {
    try{
      New-ADObject -Name $Canary.Name -Path $Canary.Path -Type $Canary.Type -ErrorAction Stop
      $CanaryObject = (Get-ADObject $DistinguishedName -Properties * -ErrorAction Stop)
    }catch{
      Write-Host "[!] Failed to create canary (skipped) : $DistinguishedName"
      Write-Host "    $_"
      if($Canary.Type -eq "organizationalUnit"){
        Write-Host "    Hint : an organizationalUnit can only be created under an OU or the domain root,"
        Write-Host "           not under a container. Set this canary's <Path> to a real OU (e.g. your ParentOU)."
      }
      return
    }

    # Add users / computer / group Canary to CanaryGroup and set primary group
    if ($Canary.Type -eq "user"){
        Add-ADGroupMember -Identity $CanaryGroupDN -Members $DistinguishedName
        Set-ADObject $DistinguishedName -Replace @{primaryGroupID=$CanaryGroupToken}
    }
    if ($Canary.Type -eq "computer"){
        Add-ADGroupMember -Identity $CanaryGroupDN -Members $DistinguishedName
        Set-ADObject $DistinguishedName -Replace @{primaryGroupID=$CanaryGroupToken}
    }
    if ($Canary.Type -eq "group"){
        Add-ADGroupMember -Identity $CanaryGroupDN -Members $DistinguishedName
    }

    # Note : in PowerShell 2.0, foreach over $null still runs once, so guard each item
    foreach($G in $CanaryObject.MemberOf){
        if($G){
            Remove-ADGroupMember -Identity $G -Members $DistinguishedName -Confirm:$false
        }
    }
    Write-Host "[*] Canary created : $DistinguishedName"
    SetAuditSACL -DistinguishedName $DistinguishedName
    Set-ADObject -Identity $DistinguishedName -ProtectedFromAccidentalDeletion $False
    DenyAllOnCanariesAndChangeOwner -DistinguishedName $DistinguishedName -Owner $Owner
    $SamAccountName = $CanaryObject.SamAccountName
    $Name = $CanaryObject.Name
    $Guid = $CanaryObject.ObjectGUID
    Add-Content -Path $Output -Value "$SamAccountName,$Guid,$Name"
  }
}


function DeployCanaries {
  param($Config, $Output)
  ValidateAction
  #### Retrieve Configuration from XML file
  $Conf            = ReadConfiguration -Path $Config
  $CanaryOwner     = $Conf.Owner
  $CanaryContainer = $Conf.Container
  $CanaryGroupConf = $Conf.Group
  $Canaries        = $Conf.Canaries

  #### Overwrite output file
  $FullOutput = ResolveFullPath $Output
  Remove-Item -Path $FullOutput -ErrorAction SilentlyContinue
  Add-Content -Path $FullOutput -Value "CanarySamName,CanaryGUID,CanaryName"

  # Ensure Parent container exists
  $Path = $CanaryContainer.Path
  if(-not (ADObjectExists -Path $Path)){
    Write-Host "[-] Parent OU for default Canary OU not found : $Path -- aborting deployment"
    exit 1
  }

  # Create Container for Canaries
  $DistinguishedName = "CN=" + $CanaryContainer.Name + "," + $CanaryContainer.Path
  if (ADObjectExists -Path $DistinguishedName){
    Write-Host "[-] Canary OU already existed : $DistinguishedName"
  }
  else {
    New-ADObject -Name $CanaryContainer.Name -Path $CanaryContainer.Path -Type $CanaryContainer.Type -Description $CanaryContainer.Description
    Set-ADObject -Identity $DistinguishedName -ProtectedFromAccidentalDeletion $False
    $ACL = Get-Acl -Path ("AD:\" + $DistinguishedName)
    $ACL.SetAccessRuleProtection($true, $false)
    $ACL | Set-Acl -Path ("AD:\" + $DistinguishedName)
    Write-Host "[*] Canary OU created and inheritance disabled : $DistinguishedName"
  }

  # Create Primary Group for Canaries
  $DistinguishedName = "CN=" + $CanaryGroupConf.Name + "," + $CanaryGroupConf.Path
  if (ADObjectExists -Path $DistinguishedName){
    Write-Host "[-] Canary Primary Group already existed : $DistinguishedName"
  }
  else {
    New-ADGroup -Name $CanaryGroupConf.Name -GroupCategory Security -GroupScope Global -DisplayName $CanaryGroupConf.Name -Path $CanaryGroupConf.Path -Description $CanaryGroupConf.Description
    Set-ADObject -Identity $DistinguishedName -ProtectedFromAccidentalDeletion $False
    $ACL = Get-Acl -Path ("AD:\" + $DistinguishedName)
    $ACL.SetAccessRuleProtection($true, $false)
    $ACL | Set-Acl -Path ("AD:\" + $DistinguishedName)
    Write-Host "[*] Canary Group created and inheritance disabled : $DistinguishedName"
  }
  $CanaryGroupObject = (Get-ADGroup -Identity "$DistinguishedName" -Properties *)

  #### Create Canaries
  foreach ($Canary in $Canaries) {
    CreateCanary -Canary $Canary -Output $FullOutput -CanaryGroup $CanaryGroupObject -Owner $CanaryOwner
  }

  # Deny all canary OU no audit
  $DN = "CN=" + $CanaryContainer.Name + "," + $CanaryContainer.Path
  DenyAllOnCanariesAndChangeOwner -DistinguishedName $DN -Owner $CanaryOwner

  Write-Host "`n[*] Done. Lookup Name:Guid for created objects :`n"
  Get-Content -Path $FullOutput
}

################################################################################
####                   Destroy Canaries Functions                           ####
################################################################################

function RemoveDenyAllOnCanary {
    param($DistinguishedName)
    $AdPath         = "AD:\" + $DistinguishedName
    $Everyone       = New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0")
    $GenericAll     = [System.DirectoryServices.ActiveDirectoryRights]::GenericAll
    $Deny           = [System.Security.AccessControl.AccessControlType]::Deny
    $AccessRule     = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($Everyone,$GenericAll,$Deny)
    $NewOwner       = New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0")
    $ACL            = Get-Acl -Path $AdPath
    $ACL.SetOwner($NewOwner)
    $ACL | Set-Acl -Path $AdPath
    Write-Host "[*] Changed Owner to Everyone (S-1-1-0) for : $DistinguishedName"
    $ACL            = Get-Acl -Path $AdPath
    [void]$ACL.RemoveAccessRule($AccessRule)
    $ACL | Set-Acl -Path $AdPath
    Write-Host "[*] Removed Deny All DACL deployed on : $DistinguishedName"
}

function DestroyCanary {
  param($DistinguishedName)
  if(ADObjectExists -Path $DistinguishedName){
    RemoveDenyAllOnCanary -DistinguishedName $DistinguishedName
    Set-ADObject -Identity $DistinguishedName -ProtectedFromAccidentalDeletion $False
    Remove-ADObject -Identity $DistinguishedName -Confirm:$false
    Write-Host "[*] ADCanary object removed : $DistinguishedName"
  }
  else {
    Write-Host "[-] ADCanary object not found : $DistinguishedName"
  }
}

function DestroyCanaries {
  param($Config)
  ValidateAction
  #### Retrieve Configuration from XML file
  $Conf            = ReadConfiguration -Path $Config
  $CanaryContainer = $Conf.Container
  $CanaryGroupConf = $Conf.Group
  $Canaries        = $Conf.Canaries

  #### Remove DACL on Canary OU
  $DistinguishedName = "CN=" + $CanaryContainer.Name + "," + $CanaryContainer.Path
  if (ADObjectExists -Path $DistinguishedName){
    RemoveDenyAllOnCanary -DistinguishedName $DistinguishedName
  }else{
    Write-Host "[!] Canary OU not found : $DistinguishedName"
    Write-Host "[!] Aborting, please ensure provided OU exists and ADCanaries are located under this OU.`n"
    exit 1
  }
  #### Destroy Canaries
  foreach ($Canary in $Canaries) {
    Write-Host ""
    $DistinguishedName = GetEntryDN $Canary
    DestroyCanary -DistinguishedName $DistinguishedName
  }
  # Delete Primary Group for Canaries
  $DistinguishedName = "CN=" + $CanaryGroupConf.Name + "," + $CanaryGroupConf.Path
  Write-Host ""
  DestroyCanary -DistinguishedName $DistinguishedName
  # Delete Container for Canaries
  $DistinguishedName = "CN=" + $CanaryContainer.Name + "," + $CanaryContainer.Path
  Write-Host ""
  DestroyCanary -DistinguishedName $DistinguishedName
}

################################################################################
####                            MAIN()                                      ####
################################################################################
DisplayCanaryBanner

#### Validate arguments & execute functions
if($Populate.IsPresent){
  CheckParameter $Config
  CheckParameter $ParentOU
  CheckParameter $Owner
  CheckParameter $CanaryContainer
  PopulateConf -Config $Config -ParentOU $ParentOU -Owner $Owner -CanaryGroupName $CanaryContainer
} elseif($Deploy.IsPresent){
  CheckParameter $Config
  CheckParameter $Output
  DeployCanaries -Config $Config -Output $Output
} elseif($Revert.IsPresent){
  CheckParameter $Config
  DestroyCanaries -Config $Config
} elseif($AuditSACLs.IsPresent){
  CheckSACLs
} elseif($GetObjectPropertiesGuids.IsPresent){
  CheckParameter $Output
  GetObjectPropertiesGuids -Output $Output
}else{
  DisplayHelpAndExit
}
Write-Host "`n"