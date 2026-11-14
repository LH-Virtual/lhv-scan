# =============================================================================
#  LHV Scan - the sending part
# =============================================================================
#
#  THIS FILE IS THE ONLY PLACE IN THE WHOLE TOOL THAT USES THE INTERNET.
#
#  It contains one address and one function. The function runs only when you
#  press "Send to My sim" in the window. If you never press that button, the
#  tool never connects to anything.
#
#  WHAT IS SENT
#    1. the code you typed (so LH Virtual knows whose list this is)
#    2. the list - exactly the text that "Show what is sent" displays
#  Nothing else: no folder paths, no user name, nothing about your PC.
# =============================================================================

# The one address this tool ever contacts.
$script:LhvUploadUrl = 'https://lh-virtual.com/api/tours/scan/upload'

# -----------------------------------------------------------------------------
#  Send-LhvList
#  Sends the code and the list to LH Virtual and returns the answer.
#
#  Input : -Code      the code from your My sim page ("Connect the scan tool")
#          -FileText  the list as text (from ConvertTo-LhvAddonFile)
#          -Url       where to send; leave it out to use the address above
#                     (developers use this to test against a test server)
#  Output: @{ ok; message }   message is a sentence to show in the window
# -----------------------------------------------------------------------------
function Send-LhvList {
    param([Parameter(Mandatory = $true)][string]$Code,
          [Parameter(Mandatory = $true)][string]$FileText,
          [string]$Url = $script:LhvUploadUrl)
    try {
        # Use a current, encrypted connection (TLS 1.2).
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        # The message is: { "code": "...", "file": <the list> }
        $body  = '{"code":' + (ConvertTo-Json $Code) + ',"file":' + $FileText + '}'
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $reply = Invoke-WebRequest -Uri $Url -Method Post -Body $bytes -UseBasicParsing -TimeoutSec 30 `
                                   -ContentType 'application/json; charset=utf-8' -UserAgent "LHV-Scan/$($script:LhvScanVersion)"
        $data = $reply.Content | ConvertFrom-Json
        if ($data.ok) {
            return @{ ok = $true; aircraft = [int]$data.aircraft; sceneries = [int]$data.sceneries
                      message = "Sent. $($data.aircraft) aircraft types and $($data.sceneries) airports that LH Virtual flies are on their way to your My sim page." }
        }
        return @{ ok = $false; message = "$($data.error)" }
    } catch {
        # The server answered with an error: show its sentence, not a number.
        $message = ''
        try {
            $stream  = $_.Exception.Response.GetResponseStream()
            $text    = (New-Object IO.StreamReader($stream)).ReadToEnd()
            $message = "$(($text | ConvertFrom-Json).error)"
        } catch { }
        if (-not $message) { $message = 'LH Virtual could not be reached. Check your internet connection, or use "Save as file".' }
        return @{ ok = $false; message = $message }
    }
}
