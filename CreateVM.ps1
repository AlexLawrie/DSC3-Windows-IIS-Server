param (
    [string] $VMName = "WinServer-DSC3-Sys",
    [string] $BaseImagePath = "C:\VMs\BaseImages\SysPrepBaseImage.vhdx",
    [string] $SwitchName = "External Switch"
)

# Location for the copied Virtual Disk
$VMVHDDir = "C:\VMs\$VMName"
$VMVHDPath = "$VMVHDDir\$VMName.vhdx"

# Ensure directory exists
if (-not (Test-Path $VMVHDDir)) {
    New-Item -ItemType Directory -Path $VMVHDDir | Out-Null
}

# Copy base image if it does not exist yet
if (-not (Test-Path $VMVHDPath)) {
    Write-Host "Copying base image to '$VMVHDPath'."
    Copy-Item -Path $BaseImagePath -Destination $VMVHDPath -ErrorAction Stop
    Write-Host "Image copied."
} else {
    Write-Host "Virtual machine disk already exists at '$VMVHDPath'."
}

# Create VM if it does not already exist
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    Write-Host "Virtual machine '$VMName' already exists."
} else {
    Write-Host "Creating virtual machine '$VMName'."
    New-VM -Name $VMName -MemoryStartupBytes 4GB -Generation 1 -SwitchName $SwitchName -BootDevice VHD -VHDPath $VMVHDPath -ErrorAction Stop
    Write-Host "Virtual machine '${VMName}' created."
}

Start-VM -Name $VMName -ErrorAction Stop
Write-Host "Virtual machine '${VMName}' started."


# Wait for VM to respond to ping
Write-Host "Waiting for virtual machine to respond to ping."
$timeout = (Get-Date).AddMinutes(5)
$VMIPAddress = $null

do {
    Start-Sleep -Seconds 5
    try {
        $VMIPAddress = (Get-VMNetworkAdapter -VMName $VMName).IPAddresses |
    Where-Object {
        $_ -match '^([0-9]{1,3}\.){3}[0-9]{1,3}$' -and
        $_ -ne '0.0.0.0' -and
        $_ -notmatch '^169\.254\.'  
    } | Select-Object -First 1

        if ($VMIPAddress -and (Test-Connection -ComputerName $VMIPAddress -Count 1 -Quiet)) {
            Write-Host "Virtual machine is responding to ping at $VMIPAddress"
            break
        } else {
            Write-Host "Virtual machine is not responding to ping yet."
        }
    } catch {
        Write-Host "Still waiting for virtual machine networking."
    }
} while ((Get-Date) -lt $timeout)

if (-not $VMIPAddress) {
    Write-Warning "Virtual machine did not respond to ping within the timeout. Proceeding anyway."
} else {
    Write-Host "Adding Virtual machine IP $VMIPAddress to TrustedHosts on this host machine."
    $currentTrusted = (Get-Item -Path WSMan:\localhost\Client\TrustedHosts).Value

    if (-not $currentTrusted) {
        Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value $VMIPAddress -Force
    }
    elseif ($currentTrusted -notlike "*$VMIPAddress*") {
        $newTrusted = "$currentTrusted,$VMIPAddress"
        Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value $newTrusted -Force
    }
    else {
        Write-Host "Virtual machine IP $VMIPAddress is already in TrustedHosts."
    }
}

Write-Host "Viortual machine is up. Proceeding to PowerShell Direct session check."

# Credentials
$username = "Administrator"
$password = "" # Needs password
$securePassword = ConvertTo-SecureString $password -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($username, $securePassword)

# Configure WinRM and Network inside VM via PowerShell Direct.  All the below is needed for WinRM over HTTP to work
Write-Host "Configuring WinRM and network settings inside virtual machine using PowerShell Direct."

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock {
    # Enable PS Remoting
    Enable-PSRemoting -Force

    # Enable Basic Authentication and Allow Unencrypted traffic
    winrm set winrm/config/service/auth '@{Basic="true"}'
    winrm set winrm/config/client/auth '@{Basic="true"}'
    winrm set winrm/config/service '@{AllowUnencrypted="true"}'
    winrm set winrm/config/client '@{AllowUnencrypted="true"}'

    # Add Host IP to TrustedHosts (replace with your host IP)
    $hostIP = "192.168.1.210"
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value $hostIP -Force

    # Restart WinRM service to apply changes
    Restart-Service WinRM

    # Change network profile to Private
    $netAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    foreach ($adapter in $netAdapters) {
        Set-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -NetworkCategory Private
    }

    Write-Host "WinRM and network configuration complete."

    return 
}
Write-Host "PowerShell Direct configuration done."

# Wait for PowerShell WinRM to work
function Wait-ForPSSession {
    param(
        [string] $ComputerName,
        [System.Management.Automation.PSCredential] $Credential,
        [int] $MaxAttempts = 30,
        [int] $DelaySeconds = 10
    )

    for ($i = 1; $i -le $MaxAttempts; $i++) {
        try {
            Write-Host "Attempt ${i}/${MaxAttempts}: trying to create WinRM PowerShell session to ${ComputerName}."
            $session = New-PSSession -ComputerName $ComputerName -Credential $Credential -Authentication Basic -ErrorAction Stop
            Write-Host "PowerShell session created."
            return $session
        }
        catch {
            Write-Host "  not ready yet: $($_.Exception.Message)"
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    throw "Timed out waiting for PowerShell session to '${ComputerName}' after ${MaxAttempts} attempts."
}

# Give the virtual machine a moment to spin up before polling
Start-Sleep -Seconds 15

# Try create session (with retries)
try {
    $session = Wait-ForPSSession -ComputerName $VMIPAddress -Credential $cred -MaxAttempts 30 -DelaySeconds 10
}
catch {
    Write-Error "Unable to create PowerShell session to virtual machine ${VMIPAddress}: $($_.Exception.Message)"
    exit 1
}

# Define DSC3 configuration
Configuration WebServerConfig {
    param (
        [string] $NodeName = "localhost"
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration

    Node $NodeName {
        WindowsFeature IIS {
            Name = "Web-Server"
            Ensure = "Present"
        }
    }
}

# Output folder for MOF file (on host)
$MOFOutputPath = Join-Path -Path $PSScriptRoot -ChildPath "DSCOutput"
if (-not (Test-Path $MOFOutputPath)) {
    New-Item -ItemType Directory -Path $MOFOutputPath | Out-Null
}

# Generate MOF for virtual machine
Write-Host "Generating DSC3 MOF for VM '$VMName'."
WebServerConfig -OutputPath $MOFOutputPath -NodeName "localhost"

# Copy MOF file to virtual machine
$localMofPath = Join-Path -Path $MOFOutputPath -ChildPath "localhost.mof"
$remoteMofDir = "C:\Windows\System32\Configuration"
$remoteMofPath = Join-Path -Path $remoteMofDir -ChildPath "localhost.mof"

Write-Host "Copying MOF file to virtual machine."
Copy-Item -Path $localMofPath -Destination $remoteMofPath -ToSession $session

# Apply DSC3 configuration inside virtual machine
Write-Host "Applying DSC3 configuration inside virtual machine."
Invoke-Command -Session $session -ScriptBlock {
    Write-Host "Starting DSC3 configuration on node localhost."
    Start-DscConfiguration -Path "C:\Windows\System32\Configuration" -Wait -Verbose -Force
}

# Cleanup
Remove-PSSession -Session $session
Write-Host "Virtual machine configuration complete."
