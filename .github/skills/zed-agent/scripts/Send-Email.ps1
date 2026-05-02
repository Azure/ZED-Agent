function Send-Email {
    <#
    .SYNOPSIS
        Send email via Outlook COM automation with HTML template support.
    .DESCRIPTION
        Uses Outlook COM (not Graph API) because Azure CLI tokens lack Mail.Send
        permission in the Microsoft tenant. Outlook COM sends as the logged-in
        Outlook user and saves to Sent Items automatically.
    .NOTES
        Requires: Microsoft Outlook running with a configured account.
        Run 'setup' first to warm up Outlook COM and complete any first-time dialogs.
    #>
    param(
        [Parameter(Mandatory)][string]$To,
        [string]$Cc,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$BodyHtmlPath,
        [hashtable]$Variables = @{},
        [string[]]$Attachments = @()
    )
    . "$PSScriptRoot\Expand-Template.ps1"
    $htmlBody = Expand-Template -TemplatePath $BodyHtmlPath -Variables $Variables

    $attempt = 0; $maxRetries = 3
    while ($attempt -lt $maxRetries) {
        try {
            $outlook = New-Object -ComObject Outlook.Application
            $mail = $outlook.CreateItem(0)  # 0 = olMailItem
            $mail.To = $To
            if ($Cc) { $mail.CC = $Cc }
            $mail.Subject = $Subject
            $mail.HTMLBody = $htmlBody
            foreach ($file in $Attachments) {
                if (Test-Path $file) {
                    $mail.Attachments.Add($file) | Out-Null
                }
            }
            $mail.Send()
            return @{ success = $true; method = 'OutlookCOM' }
        } catch {
            $attempt++
            if ($attempt -ge $maxRetries) {
                return @{ success = $false; error = $_.Exception.Message; method = 'OutlookCOM' }
            }
            Start-Sleep -Seconds ([math]::Pow(2, $attempt))
        }
    }
}
