Place a sysprepped Windows Server image in the following location:

"C:\VMs\BaseImages\

Also, make sure the vhdx is named:

"SysPrepBaseImage"

Additionally, make sure Hyper-V is installed and there is an external switch created and named within Hyper-V switch manager:

"External Switch"

The sysprepped image only has to skip OOBE and to create a administrator account.

Finally, make sure to edit this script and add the administrator password into the $password variable under the 'Credentials' comment and to add your computer's IP address to the $hostIP variable.

The state (MOF) is stored in this location:

C:\Windows\System32\Configuration
