# Define the MSIX file path and output directory
$msixPath = "C:\temp\msix-hero-3.0.0.0.msix"
$outputDirectory = "C:\temp\msix-extracted"
$apiKey = "[Enterkey]"  # Replace with your actual API key
$baseUrl = "[Enter URL string \api]"
$htmlReportPath = "C:\temp\msix_analysis_report.html"

# Define the endpoints
$analysisEndpoint = "$baseUrl/apps/msix-analysis"
$appAttachEndpoint = "$baseUrl/apps/msix-app-attach-analysis"

# Initialize progress
$totalSteps = 9
$currentStep = 0

# Helper function to recursively convert JSON content to HTML
function ConvertTo-FormattedJsonHtml {
    param (
        [Parameter(Mandatory = $true)]
        [object]$JsonObject
    )

    $htmlOutput = ""

    if ($JsonObject -is [System.Management.Automation.PSCustomObject] -or $JsonObject -is [Hashtable]) {
        # It's an object/dictionary
        $htmlOutput += "<ul>"
        foreach ($key in $JsonObject.PSObject.Properties.Name) {
            $value = $JsonObject.$key
            $htmlOutput += "<li><strong>${key}:</strong> "
            $htmlOutput += ConvertTo-FormattedJsonHtml -JsonObject $value
            $htmlOutput += "</li>"
        }
        $htmlOutput += "</ul>"
    }
    elseif ($JsonObject -is [System.Collections.IEnumerable] -and -not ($JsonObject -is [string])) {
        # It's an array or collection
        $htmlOutput += "<ul>"
        foreach ($item in $JsonObject) {
            $htmlOutput += "<li>"
            $htmlOutput += ConvertTo-FormattedJsonHtml -JsonObject $item
            $htmlOutput += "</li>"
        }
        $htmlOutput += "</ul>"
    }
    elseif ($JsonObject -eq $null) {
        # It's null
        $htmlOutput += "<em>null</em>"
    }
    else {
        # It's a scalar value
        $htmlOutput += [System.Web.HttpUtility]::HtmlEncode($JsonObject.ToString())
    }

    return $htmlOutput
}

# Function to send analysis request to EtherAssist API with retry logic and formatted output
function Invoke-MSIXAnalysis {
    param (
        [string]$url,
        [string]$analysisType,
        [string]$promptInfo,  # Accept question as string
        [int]$maxRetries = 3,
        [int]$timeoutSeconds = 60
    )

    # Create payload dynamically as a hashtable with the question prompt
    $payload = @{
        "question" = $promptInfo
    }

    $jsonPayload = $payload | ConvertTo-Json -Depth 100

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            Write-Progress -Activity "MSIX Analysis Script" -Status "Analyzing: ${analysisType} (Attempt $attempt)" -PercentComplete ((($script:currentStep) / $script:totalSteps) * 100)
            # Send HTTP POST request to EtherAssist API with timeout
            $response = Invoke-RestMethod -Uri $url -Method Post -Headers $script:headers -Body $jsonPayload -TimeoutSec $timeoutSeconds

            if ($response.success -and $response.status -eq 200) {
                $script:htmlContent += "<div class='section'>"
                $script:htmlContent += "<h2>Analysis: ${analysisType}</h2>"

                # Clean up the response to remove code fences
                $jsonContent = $response.answer -replace '```json', '' -replace '```', '' -replace '^\s*', '' -replace '\s*$', ''

                # Attempt to parse JSON content; output formatted HTML
                try {
                    $jsonObject = $jsonContent | ConvertFrom-Json -ErrorAction Stop
                    $jsonFormatted = ConvertTo-FormattedJsonHtml -JsonObject $jsonObject
                    $script:htmlContent += $jsonFormatted
                } catch {
                    Write-Output "Error parsing JSON content: $_"
                    $script:htmlContent += "<pre class='code-block'>Raw Response: $($response.answer)</pre>"
                }

                $script:htmlContent += "</div>"
            } else {
                Write-Output "Error in response: Status Code - $($response.status)"
            }
            return  # Exit function on success
        } catch {
            Write-Output "Attempt $attempt failed: $_"
            if ($attempt -eq $maxRetries) {
                Write-Output "Max retries reached. Failed to analyze MSIX package."
                exit
            } else {
                Start-Sleep -Seconds 5
            }
        }
    }
}

# Step 1: Check if output directory exists; if not, create it
$currentStep++
Write-Progress -Activity "MSIX Analysis Script" -Status "Step ${currentStep} of ${totalSteps}: Preparing output directory" -PercentComplete (($currentStep / $totalSteps) * 100)
if (!(Test-Path -Path $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

# Step 2: Copy the MSIX file to a temporary ZIP file
$currentStep++
Write-Progress -Activity "MSIX Analysis Script" -Status "Step ${currentStep} of ${totalSteps}: Preparing MSIX file for extraction" -PercentComplete (($currentStep / $totalSteps) * 100)
$tempZipPath = "$($outputDirectory)\temp.zip"
Copy-Item -Path $msixPath -Destination $tempZipPath -Force

# Step 3: Extract the ZIP file
$currentStep++
Write-Progress -Activity "MSIX Analysis Script" -Status "Step ${currentStep} of ${totalSteps}: Extracting MSIX package" -PercentComplete (($currentStep / $totalSteps) * 100)
Expand-Archive -Path $tempZipPath -DestinationPath $outputDirectory -Force

# Step 4: Remove the temporary ZIP file
$currentStep++
Write-Progress -Activity "MSIX Analysis Script" -Status "Step ${currentStep} of ${totalSteps}: Cleaning up temporary files" -PercentComplete (($currentStep / $totalSteps) * 100)
Remove-Item -Path $tempZipPath -Force

# Step 5: Locate the AppxManifest.xml file
$currentStep++
Write-Progress -Activity "MSIX Analysis Script" -Status "Step ${currentStep} of ${totalSteps}: Locating AppxManifest.xml" -PercentComplete (($currentStep / $totalSteps) * 100)
$appManifestPath = Join-Path -Path $outputDirectory -ChildPath "AppxManifest.xml"
if (!(Test-Path -Path $appManifestPath)) {
    Write-Error "AppxManifest.xml not found in the MSIX package."
    exit
}

# Step 6: Extract App Name from AppxManifest.xml
$currentStep++
Write-Progress -Activity "MSIX Analysis Script" -Status "Step ${currentStep} of ${totalSteps}: Extracting app name from AppxManifest.xml" -PercentComplete (($currentStep / $totalSteps) * 100)
[xml]$xmlContent = Get-Content -Path $appManifestPath -Raw
$appName = $xmlContent.Package.Properties.DisplayName

# Read the content of AppxManifest.xml
$appManifestContent = Get-Content -Path $appManifestPath -Raw

# Step 7: Define the questions for each analysis type with clear instructions
$questionMSIX = "Ensure output is in JSON format without markdown code fences or formatting. Analyze the following AppxManifest.xml content and provide feedback and recommendations: $appManifestContent"
$questionAppAttach = "Ensure output is in JSON format without markdown code fences or formatting. Analyze the following AppxManifest.xml content for MSIX App Attach compatibility, provide any issues found, and recommendations: $appManifestContent"

# Set headers for the API request
$headers = @{
    "Authorization" = "Bearer $apiKey"
    "Content-Type"  = "application/json"
}

# Initialize HTML report content with App Name
$htmlContent = @"
<html>
<head>
    <title>MSIX Analysis Report - $appName</title>
    <style>
        body { font-family: Arial, sans-serif; line-height: 1.6; margin: 20px; }
        h1 { color: #4CAF50; }
        h2 { color: #333; border-bottom: 2px solid #4CAF50; padding-bottom: 5px; }
        .section { margin-bottom: 30px; }
        .recommendation { background-color: #e7f3fe; padding: 15px; border-left: 6px solid #2196F3; margin-bottom: 15px; }
        .issue { background-color: #ffebee; padding: 15px; border-left: 6px solid #f44336; margin-bottom: 15px; }
        .code-block { background-color: #f5f5f5; padding: 10px; border: 1px solid #ccc; overflow: auto; white-space: pre-wrap; word-wrap: break-word; }
        .analysis-content { margin-top: 15px; }
        pre { white-space: pre-wrap; word-wrap: break-word; }
        table { border-collapse: collapse; width: 100%; margin-top: 15px; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
        ul { margin-left: 20px; }
        li { margin-bottom: 5px; }
    </style>
</head>
<body>
    <h1>MSIX Analysis Report for $appName</h1>
    <p>Report generated on $(Get-Date)</p>
"@

# Step 8: Run the analysis for general MSIX configuration
$currentStep++
Invoke-MSIXAnalysis -url $analysisEndpoint -analysisType "General MSIX Configuration" -promptInfo $questionMSIX

# Step 9: Run the analysis for MSIX App Attach compatibility
$currentStep++
Invoke-MSIXAnalysis -url $appAttachEndpoint -analysisType "MSIX App Attach Compatibility" -promptInfo $questionAppAttach

# Finalize HTML content and save the report
Write-Progress -Activity "MSIX Analysis Script" -Status "Finalizing and saving the HTML report" -PercentComplete 100 -Completed
$htmlContent += "</body></html>"
Set-Content -Path $htmlReportPath -Value $htmlContent -Force -Encoding UTF8

Write-Output "MSIX analysis completed."
Write-Output "HTML report generated at: $htmlReportPath"
