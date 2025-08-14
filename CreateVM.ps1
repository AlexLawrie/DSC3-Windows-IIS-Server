# initialising Variables
param (
    [string] $VMName = "WinServer-DSC3-Sys",
    [string] $BaseImagePath = "C:\VMs\BaseImages\SysPrepBaseImage.vhdx",
    [string] $SwitchName = "External Switch"
)

# Location for the copied virtual Disk
$VMVHDDir = "C:\VMs\$VMName"
$VMVHDPath = "$VMVHDDir\$VMName.vhdx"

# Ensure directory exists
if (-not (Test-Path $VMVHDDir)) {                           # -not means if this path does not exist then execute the below
    New-Item -ItemType Directory -Path $VMVHDDir | Out-Null # Out-Null means don't output anything (slient creation)
}

# Copy base image if it does not exist yet
if (-not (Test-Path $VMVHDPath)) {
    Write-Host "Copying base image to '$VMVHDPath'."
    Copy-Item -Path $BaseImagePath -Destination $VMVHDPath -ErrorAction Stop # -ErrorAction is what you want to happen if this fails.  We want the script to stop
    Write-Host "Image copied."
} else {
    Write-Host "Virtual machine disk already exists at '$VMVHDPath'."
}

# Create VM if it does not already exist
if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {                                                                                   # Silently continue means if there is an error, suppress and keep going
    Write-Host "Virtual machine '$VMName' already exists."
} else {
    Write-Host "Creating virtual machine '$VMName'."
    New-VM -Name $VMName -MemoryStartupBytes 4GB -Generation 1 -SwitchName $SwitchName -BootDevice VHD -VHDPath $VMVHDPath -ErrorAction Stop # My Windows server image needs generation 1
    Write-Host "Virtual machine '${VMName}' created."                                                                                        # This variable has '${VMName}' while above are only '$VMName'.  {} is not needed, it's all style
}

Start-VM -Name $VMName -ErrorAction Stop
Write-Host "Virtual machine '${VMName}' started."


# Wait for VM to respond to ping
Write-Host "Waiting for virtual machine to respond to ping."
$timeout = (Get-Date).AddMinutes(5) # Timeout is equal to current time this script is executed plus 5 minutes
$VMIPAddress = $null                # Being declared now instead of up top for easier reading

# DO - repeatedly executes a block of code until a condition becomnes false.  Paired with WHILE
# TRY - Part of error handling.  Put in code that might error.  If error occurs, jump to CATCH
# Throw - Force an error immdiately

do {
    Start-Sleep -Seconds 5                                                                    # Pause the script for 5 seconds before continuing
    try {
        $VMIPAddress = (Get-VMNetworkAdapter -VMName $VMName).IPAddresses |                   # Get-VMNetworkingAdapter contains loads of information.  .IPAddresses means we only want that information from it.  The | means to move that information onto the next section  
    Where-Object {
        $_ -match '^([0-9]{1,3}\.){3}[0-9]{1,3}$' -and                                        # $_ means the current information being pippied via |
        $_ -ne '0.0.0.0' -and                                                                 # -ne means not equal
        $_ -notmatch '^169\.254\.'                                                            # -notmatch means does not match this pattern
    } | Select-Object -First 1                                                                # Takes the first IP address found and applies it to $VMIPAddress

        if ($VMIPAddress -and (Test-Connection -ComputerName $VMIPAddress -Count 1 -Quiet)) { # This if statement only ges throw if both statements are true because of the -and
            Write-Host "Virtual machine is responding to ping at $VMIPAddress"                # Test-Connection is a ping, -1Count means 1 ping only, and -Quiet means return true or false only
            break
        } else {
            Write-Host "Virtual machine is not responding to ping yet."
        }
    } catch {
        Write-Host "Still waiting for virtual machine networking."
    }
} while ((Get-Date) -lt $timeout)                                                             # -lt means less than

if (-not $VMIPAddress) {
    Write-Warning "Virtual machine did not respond to ping within the timeout. Proceeding anyway."
} else {
    Write-Host "Adding Virtual machine IP $VMIPAddress to TrustedHosts on this host machine."
    $currentTrusted = (Get-Item -Path WSMan:\localhost\Client\TrustedHosts).Value             # .Value is the contents of the Trusted Hosts file.

    if (-not $currentTrusted) {                                                               # -not here means if $currentTrusted is empty
        Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value $VMIPAddress -Force        # Adds the IP address to Trusted Hosts.  -Force means try even if there might be a permissions issue
    }
    elseif ($currentTrusted -notlike "*$VMIPAddress*") {                                      # This means if it finds another IP address in trusted hosts not equal to the IP address we found, make sure both get added
        $newTrusted = "$currentTrusted,$VMIPAddress"
        Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value $newTrusted -Force
    }
    else {
        Write-Host "Virtual machine IP $VMIPAddress is already in TrustedHosts."
    }
}

Write-Host "Virtual machine is up. Proceeding to PowerShell Direct session check."

# Credentials
# The reason the password is encrypted and then decrypted is New-Object requires a password to have ConvertTo-SecureString
$username = "Administrator"
$password = "Admina001"
$securePassword = ConvertTo-SecureString $password -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential ($username, $securePassword) # System.Manager.Automation.PSCredential allows for automatic logins

# Configure WinRM and Network inside VM via PowerShell Direct.  All the below is needed for WinRM over HTTP to work
# Also, the below code can be put into sysprep rather than being done here
Write-Host "Configuring WinRM and network settings inside virtual machine using PowerShell Direct."

Invoke-Command -VMName $VMName -Credential $cred -ScriptBlock { # Invoke-Command means to run the following code on a targeted machine.  -ScriptBlock means what to do with the below commands (execute)
    # Enable PowerShell remoting
    Enable-PSRemoting -Force
    # Enable basic authentication and allow unencrypted traffic
    winrm set winrm/config/service/auth '@{Basic="true"}'
    winrm set winrm/config/client/auth '@{Basic="true"}'
    winrm set winrm/config/service '@{AllowUnencrypted="true"}'
    winrm set winrm/config/client '@{AllowUnencrypted="true"}'
     # Add Host IP to TrustedHosts
    $hostIP = "192.168.1.210"
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value $hostIP -Force
    # Restart WinRM service to apply changes
    Restart-Service WinRM
    # Change network profile to private
    $netAdapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }                    # This command is saying get all network adapters that are equal to up.  $_ stores all network adapters and .Status is if its enabled or disabled.  -eq means equal too
    foreach ($adapter in $netAdapters) {
        Set-NetConnectionProfile -InterfaceIndex $adapter.ifIndex -NetworkCategory Private # .ifIndex is a unique number that network adapters have
    }

    Write-Host "WinRM and network configuration complete."

    return 
}
Write-Host "PowerShell Direct configuration done."

# Wait for PowerShell WinRM to work
function Wait-ForPSSession {                                     # Function not needed here.  Kinda like a naming scheme like PHP functions.  However, the advantage of doing functions is I could run a certain function of this script multiple times without running all of it
    param(
        [string] $ComputerName,
        [System.Management.Automation.PSCredential] $Credential, # System.Management.Automation.PSCredential is still storing our details from above.  This is bringing it into this function as a new variable
        [int] $MaxAttempts = 30,
        [int] $DelaySeconds = 10
    )

    for ($i = 1; $i -le $MaxAttempts; $i++) {                                                                                    # -le means less than or equal too.  Standard loop.  Loops 30 times
        try {
            Write-Host "Attempt ${i}/${MaxAttempts}: trying to create WinRM PowerShell session to ${ComputerName}."
            $session = New-PSSession -ComputerName $ComputerName -Credential $Credential -Authentication Basic -ErrorAction Stop # -Authentication Basic is needed here to use WinRM over HTTP instead of HTTPS
            Write-Host "PowerShell session created."
            return $session
        }
        catch {
            Write-Host "  not ready yet: $($_.Exception.Message)" # The first $ means evalute whatever is inside thse parentheses and insert the result here.  It feels like this is not needed?
            Start-Sleep -Seconds $DelaySeconds                    # Again, $_ means anything in the current "pipe".  Exception.Message means show the error message in a human readable format
        }
    }

    throw "Timed out waiting for PowerShell session to '${ComputerName}' after ${MaxAttempts} attempts."
}

# Give the virtual machine a moment to start before polling
Start-Sleep -Seconds 15

# Try create WinRM PowerShell session
try {
    $session = Wait-ForPSSession -ComputerName $VMIPAddress -Credential $cred -MaxAttempts 30 -DelaySeconds 10 # Not needed.  Chat GPT added it
}
catch {
    Write-Error "Unable to create PowerShell session to virtual machine ${VMIPAddress}: $($_.Exception.Message)"
    exit 1
}

# Define DSC3 configuration
Configuration WebServerConfig { # WebServerConfig is a name, not a function.  Configuration is related to DSC3
    param (
        [string] $NodeName = "localhost"
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration # This line will always exist for DSC3
# Custom code below on what you want the state of your server to be
    Node $NodeName {
        WindowsFeature IIS {
            Name = "Web-Server"
            Ensure = "Present"
        }
    }
}

# Output folder for MOF file (creates folder on host)
$MOFOutputPath = Join-Path -Path $PSScriptRoot -ChildPath "DSCOutput" # $PSScriptRoot is a built in variable of the current location of this script
if (-not (Test-Path $MOFOutputPath)) {                                # This block of code is creating a folder called DSCOutput in the folder of the script
    New-Item -ItemType Directory -Path $MOFOutputPath | Out-Null
}

# Generate MOF for virtual machine (inside folder just created)
Write-Host "Generating DSC3 MOF for VM '$VMName'."
WebServerConfig -OutputPath $MOFOutputPath -NodeName "localhost" # This line generates the MOF file

# Copy MOF file to virtual machine
$localMofPath = Join-Path -Path $MOFOutputPath -ChildPath "localhost.mof" # Join-Path does more than create a folder.  Its joined localhost.mof to the end of the path
$remoteMofDir = "C:\Windows\System32\Configuration"
$remoteMofPath = Join-Path -Path $remoteMofDir -ChildPath "localhost.mof" # Defines the path where we want the MOF to be stored

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
