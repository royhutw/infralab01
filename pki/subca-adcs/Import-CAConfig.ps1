# ============================================================
#  Import-CAConfig.ps1
#  共用參數載入器（供其餘 .ps1 以 dot-source 方式載入）
#
#  用法（放在各腳本的參數區）：
#    . (Join-Path $PSScriptRoot 'Import-CAConfig.ps1')
#    $Params = Merge-CAConfig -Sections 'Global','RootCADN'
#
#  Merge-CAConfig 會依序讀取 CAConfig.psd1 裡指定的區塊（Section），
#  合併成單一 Hashtable 回傳，讓下方腳本本文可以維持原本
#  $Params.XXX 的寫法，不需要逐一改成 $Config.區塊.XXX。
#
#  【重要】CAConfig.psd1 必須與所有 .ps1 放在同一目錄。
# ============================================================

function Merge-CAConfig {
    param(
        [Parameter(Mandatory)]
        [string[]] $Sections
    )

    $ConfigPath = Join-Path $PSScriptRoot 'CAConfig.psd1'
    if (-not (Test-Path $ConfigPath)) {
        throw "找不到共用參數檔：$ConfigPath（請確認 CAConfig.psd1 與本腳本放在同一目錄）"
    }

    $Config = Import-PowerShellDataFile -Path $ConfigPath
    $Merged = @{}

    foreach ($SectionName in $Sections) {
        if (-not $Config.ContainsKey($SectionName)) {
            throw "CAConfig.psd1 裡找不到區塊：$SectionName（請確認區塊名稱是否打錯，或是否已被移除）"
        }
        foreach ($Key in $Config[$SectionName].Keys) {
            $Merged[$Key] = $Config[$SectionName][$Key]
        }
    }

    return $Merged
}
