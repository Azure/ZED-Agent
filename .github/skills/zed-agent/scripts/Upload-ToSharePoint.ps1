function Upload-ToSharePoint {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$SiteId,
        [Parameter(Mandatory)][string]$TargetFolder,
        [string]$FileName = (Split-Path $FilePath -Leaf)
    )
    $token = (az account get-access-token --resource "https://graph.microsoft.com" --query accessToken -o tsv)
    $headers = @{ Authorization = "Bearer $token" }
    $bytes = [IO.File]::ReadAllBytes($FilePath)
    $uploadUrl = "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/items/root:/$TargetFolder/$($FileName):/content"
    $attempt = 0; $maxRetries = 3
    while ($attempt -lt $maxRetries) {
        try {
            $resp = Invoke-RestMethod -Uri $uploadUrl -Method Put -Headers $headers -Body $bytes `
                -ContentType 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' -ErrorAction Stop
            # Create sharing link
            $linkUrl = "https://graph.microsoft.com/v1.0/sites/$SiteId/drive/items/$($resp.id)/createLink"
            $linkBody = @{ type = 'edit'; scope = 'organization' } | ConvertTo-Json
            $link = Invoke-RestMethod -Uri $linkUrl -Method Post -Headers (@{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }) -Body $linkBody
            return @{ success = $true; webUrl = $link.link.webUrl; driveItemId = $resp.id; lastModified = $resp.lastModifiedDateTime }
        } catch {
            $attempt++
            if ($attempt -ge $maxRetries) { return @{ success = $false; error = $_.Exception.Message } }
            Start-Sleep -Seconds ([math]::Pow(2, $attempt))
        }
    }
}
