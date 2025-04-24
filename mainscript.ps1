$logFile = "C:\labfiles\progress.log"

function Write-Log($msg) {
    $stamp = (Get-Date).ToString("yyyy-MM-dd HHmmss")
    Add-Content $logFile "[INFO] $stamp $msg"
}

Write-Log "Script started in GitHub version."

$AdminUserName  = $env:LAB_ADMIN_USERNAME
$AdminPassword  = $env:LAB_ADMIN_PASSWORD
$tenantId       = $env:LAB_TENANT_ID
$subscriptionId = $env:LAB_SUBSCRIPTION_ID
$clientId       = $env:LAB_CLIENT_ID
$clientSecret   = $env:LAB_CLIENT_SECRET
$labInstanceId  = $env:LAB_INSTANCE_ID
$location       = $env:LAB_LOCATION
if (-not $location) { $location = "eastus2" }

if (-not $AdminUserName -or -not $AdminPassword -or -not $tenantId -or -not $subscriptionId -or -not $clientId -or -not $clientSecret -or -not $labInstanceId) {
    Write-Log "[ERROR] One or more required environment variables are missing."
    return
}

$labCred = New-Object System.Management.Automation.PSCredential($AdminUserName, (ConvertTo-SecureString $AdminPassword -AsPlainText -Force))
Connect-AzAccount -Credential $labCred | Out-Null
Write-Log "Connected to Az using lab credentials."

$env:AZURE_CLIENT_ID     = $clientId
$env:AZURE_CLIENT_SECRET = $clientSecret
$env:AZURE_TENANT_ID     = $tenantId
$env:AZD_NON_INTERACTIVE = "true"
$env:LAB_INSTANCE_ID     = $labInstanceId

azd auth login --client-id $clientId --client-secret $clientSecret --tenant-id $tenantId | Out-Null
az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId | Out-Null
$deployPath = "$HOME\gpt-rag-deploy"
Remove-Item -Recurse -Force $deployPath -ErrorAction SilentlyContinue | Out-Null
git clone -b agentic https://github.com/Azure/gpt-rag.git $deployPath | Out-Null
Set-Location $deployPath

$yamlPath = Join-Path $deployPath "azure.yaml"
$cleanYaml = @"
# yaml-language-server: $schema=https://raw.githubusercontent.com/Azure/azure-dev/main/schemas/v1.0/azure.yaml.json
name: azure-gpt-rag
metadata:
  template: azure-gpt-rag
services:
  dataIngest:
    project: ./.azure/gpt-rag-ingestion
    language: python
    host: function
  orchestrator:
    project: ./.azure/gpt-rag-orchestrator
    language: python
    host: function
  frontend:
    project: ./.azure/gpt-rag-frontend
    language: python
    host: appservice
"@
Set-Content -Path $yamlPath -Value $cleanYaml -Encoding UTF8
Write-Log "Cleaned azure.yaml"

$env:AZD_SKIP_UPDATE_CHECK = "true"
$env:AZD_DEFAULT_YES = "true"
azd init --environment dev-$labInstanceId --no-prompt | Out-Null
Write-Log "Initialized azd environment"

$infraScriptPath = Join-Path $deployPath "infra\scripts"
Remove-Item -Force -ErrorAction SilentlyContinue "$infraScriptPath\preprovision.ps1"
Remove-Item -Force -ErrorAction SilentlyContinue "$infraScriptPath\preDeploy.ps1"
Write-Log "Removed pre-provision/deploy scripts"

$envFile = Join-Path $deployPath ".azure\dev-$labInstanceId\.env"
if (Test-Path $envFile) {
    $envContent = Get-Content $envFile
    if ($envContent -notmatch "^AZURE_NETWORK_ISOLATION=") {
        Add-Content $envFile "`nAZURE_NETWORK_ISOLATION=true"
        Write-Log "Enabled AZURE_NETWORK_ISOLATION"
    }
}
$newKvName = "kv-$labInstanceId"
$kvFiles = Get-ChildItem -Recurse -Include *.bicep,*.json -ErrorAction SilentlyContinue
foreach ($file in $kvFiles) {
    (Get-Content $file.FullName) -replace 'kv0-[a-z0-9]+', $newKvName | Set-Content $file.FullName
}

$openaiBicep = Join-Path $deployPath "infra\core\ai\openai.bicep"
if (Test-Path $openaiBicep) {
    $lines = Get-Content $openaiBicep
    $commented = $lines | ForEach-Object { if ($_ -notmatch "^//") { "// $_" } else { $_ } }
    Set-Content -Path $openaiBicep -Value $commented
    Write-Log "Commented out OpenAI deployment in openai.bicep"
}

azd env set AZURE_KEY_VAULT_NAME $newKvName | Out-Null
azd env set AZURE_SUBSCRIPTION_ID $subscriptionId | Out-Null
azd env set AZURE_LOCATION $location | Out-Null
az account set --subscription $subscriptionId | Out-Null
Write-Log "Configured azd env variables"

azd env set AZURE_TAGS "LabInstance=$labInstanceId" | Out-Null
Write-Log "Set deployment tag: LabInstance=$labInstanceId"

# === Wait for Key Vault to be ready ===
Write-Log "Waiting for Key Vault $newKvName to become available..."

$maxWait = 10
for ($i = 0; $i -lt $maxWait; $i++) {
    try {
        $kvExists = az keyvault show --name $newKvName --query "name" -o tsv
        if ($kvExists) { break }
    } catch { }
    Start-Sleep -Seconds 10
}

# === Grant current user access to secrets ===
try {
    $userObjectId = az ad signed-in-user show --query id -o tsv

    if ($userObjectId) {
        az keyvault set-policy `
            --name $newKvName `
            --object-id $userObjectId `
            --secret-permissions get list | Out-Null

        Write-Log "Granted secret access to Key Vault $newKvName for user $userObjectId"
    } else {
        Write-Log "[ERROR] Could not retrieve signed-in user object ID."
    }
} catch {
    Write-Log "[ERROR] Failed to set Key Vault policy: $_"
}



# === Wait for OpenAI provisioning state to be terminal ===
$maxAttempts = 20
$delaySeconds = 35
$openAiProvisioningState = ""

Write-Log "Waiting for OpenAI resource to reach a terminal state..."

for ($i = 1; $i -le $maxAttempts; $i++) {
    try {
        $openAiProvisioningState = az cognitiveservices account show `
            --name "oai0-$labInstanceId" `
            --resource-group "rg-dev-$labInstanceId" `
            --query "provisioningState" -o tsv

        Write-Log "OpenAI provisioning state: $openAiProvisioningState (Attempt $i)"

        if ($openAiProvisioningState -in @("Succeeded", "Failed", "Canceled", "Deleted")) {
            break
        }
    } catch {
        Write-Log "[WARNING] Failed to get provisioning state: $_"
    }

    Start-Sleep -Seconds $delaySeconds
}

if ($openAiProvisioningState -notin @("Succeeded", "Failed", "Canceled", "Deleted")) {
    Write-Log "[WARNING] OpenAI resource provisioning state not terminal after $maxAttempts attempts. Proceeding anyway..."
}
Write-Log "OpenAI resource provisioning state is terminal: $openAiProvisioningState"

# Path to the parameters file
$paramFilePath = Join-Path $deployPath "infra\main.parameters.json"

# Load and parse the JSON into a hashtable-like object
$paramJson = Get-Content -Raw -Path $paramFilePath | ConvertFrom-Json

# Create a hashtable for deploymentTags if needed
if (-not $paramJson.parameters.deploymentTags) {
    $paramJson.parameters.deploymentTags = @{ value = @{} }
}

# Overwrite or set the LabInstance tag in the value object
$paramJson.parameters.deploymentTags.value = @{ LabInstance = $labInstanceId }

# Write the updated JSON back to the file
$paramJson | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $paramFilePath

Write-Log "Successfully set deploymentTags: LabInstance = $labInstanceId"



Write-Log "Starting azd provision"
azd provision --environment dev-$labInstanceId 2>&1 | Tee-Object -FilePath $logFile -Append
Write-Log "azd provision complete"
$resourceGroup = az group list --query "[?contains(name, 'rg-dev-$labInstanceId')].name" -o tsv
azd env set AZURE_RESOURCE_GROUP $resourceGroup | Out-Null
Write-Log "Set resource group: $resourceGroup"

# Retry OpenAI provisioning
$openAiAccountName = az resource list --resource-group $resourceGroup `
    --resource-type "Microsoft.CognitiveServices/accounts" `
    --query "[?contains(name, 'oai0')].name" -o tsv

$provisioningState = ""
if ($openAiAccountName) {
    $provisioningState = az cognitiveservices account show `
        --name $openAiAccountName `
        --resource-group $resourceGroup `
        --query "provisioningState" -o tsv
}

if (-not $openAiAccountName -or $provisioningState -ne "Succeeded") {
    $fallbackScriptPath = "$env:TEMP\openai.ps1"
    Invoke-WebRequest `
        -Uri "https://raw.githubusercontent.com/LODSContent/ProServ/refs/heads/main/41-442%20MS%20RAG%20GPT/openai.ps1" `
        -OutFile $fallbackScriptPath -UseBasicParsing

    & $fallbackScriptPath `
        -subscriptionId $subscriptionId `
        -resourceGroup $resourceGroup `
        -location $location `
        -labInstanceId $labInstanceId `
        -clientId $clientId `
        -clientSecret $clientSecret `
        -tenantId $tenantId `
        -logFile $logFile
    Write-Log "Retry fallback OpenAI provisioning executed"
}
$storageAccount = az resource list --resource-group $resourceGroup `
    --resource-type "Microsoft.Storage/storageAccounts" `
    --query "sort_by([?type=='Microsoft.Storage/storageAccounts'], &length(name))[0].name" -o tsv

$objectId = az ad sp show --id $clientId --query id -o tsv

az role assignment create `
    --assignee-object-id $objectId `
    --assignee-principal-type ServicePrincipal `
    --role "Storage Blob Data Contributor" `
    --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccount" | Out-Null

Write-Log "Assigned Storage Blob Data Contributor"

$ingestionFunc = az resource list --resource-group $resourceGroup `
    --resource-type "Microsoft.Web/sites" `
    --query "[?contains(name, 'inges')].name" -o tsv
$orchestratorFunc = az resource list --resource-group $resourceGroup `
    --resource-type "Microsoft.Web/sites" `
    --query "[?contains(name, 'orch')].name" -o tsv

if ($ingestionFunc) {
    az functionapp config appsettings set --name $ingestionFunc --resource-group $resourceGroup --settings MULTIMODAL=true | Out-Null
    az functionapp restart --name $ingestionFunc --resource-group $resourceGroup | Out-Null
}
if ($orchestratorFunc) {
    az functionapp config appsettings set --name $orchestratorFunc --resource-group $resourceGroup --settings AUTOGEN_ORCHESTRATION_STRATEGY=multimodal_rag | Out-Null
    az functionapp restart --name $orchestratorFunc --resource-group $resourceGroup | Out-Null
}
Write-Log "Function apps updated"

$webAppName = az resource list --resource-group $resourceGroup `
    --resource-type "Microsoft.Web/sites" `
    --query "[?contains(name, 'webgpt')].name" -o tsv

if ($webAppName) {
    $webAppUrl = az webapp show --name $webAppName --resource-group $resourceGroup --query "defaultHostName" -o tsv
    Write-Log "Deployment URL: https://$webAppUrl"
    Write-Host "Your GPT solution is live at: https://$webAppUrl"
} else {
    Write-Log "Web App not found."
}
Write-Log "Script completed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
