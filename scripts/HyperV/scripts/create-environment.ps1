Param(
	[Parameter(Mandatory=$true)]
	[string]$devstackIP
)

#################################################################
#  virtualenv and pip install must be run via cmd. There is a bug in the           ##
#  activate.ps1 that actually installs packages in the system site package    ##
#  folder                                                                                                   ##
#################################################################

$virtualenv = "c:\OpenStack\virtualenv"
$openstackDir = "C:\OpenStack"
$baseDir = "$openstackDir\devstack"
$scriptdir = "$baseDir\scripts"
$configDir = "C:\OpenStack\etc"
$templateDir = "$baseDir\templates"
$buildDir = "c:\OpenStack\build\openstack"
$binDir = "$openstackDir\bin"
$novaTemplate = "$templateDir\nova.conf"
$neutronTemplate = "$templateDir\neutron_hyperv_agent.conf"
$hostname = hostname
$mngmtIPOctet = (Get-NetIPAddress -AddressFamily IPv4| where {$_.IPAddress -match "10.21.7.*"}).IPAddress.split('.')[-1]
$dataIP = "10.0.2.$mngmtIPOctet"
$curDataIP = (Get-NetIPAddress | where {$_.InterfaceAlias -match "br100"}).IPAddress.ToString()


$hasVirtualenv = Test-Path $virtualenv
$hasNova = Test-Path $buildDir\nova
$hasNeutron = Test-Path $buildDir\neutron
$hasNeutronTemplate = Test-Path $neutronTemplate
$hasNovaTemplate = Test-Path $novaTemplate
$hasConfigDir = Test-Path $configDir
$hasBinDir = Test-Path $binDir
$hasMkisoFs = Test-Path $binDir\mkisofs.exe
$hasQemuImg = Test-Path $binDir\qemu-img.exe

if ($hasConfigDir -eq $false) {
	mkdir $configDir
}

if ($mngmtIPOctet -and ($dataIP -ne $curDataIP)){
	Get-NetAdapter -Name "*br100*" | Remove-NetIPAddress -Confirm:$false
	Get-NetAdapter -Name "*br100*" | New-NetIpAddress -IPAddress "10.0.2.$mngmtIPOctet" -PrefixLength 23
}

$novaIsRunning = Get-Process -Name nova-compute -erroraction 'silentlycontinue'
$neutronIsRunning = Get-Process -Name neutron-hyperv-agent -erroraction 'silentlycontinue'

function exec_with_retry([string]$cmd, [int]$retry, [int]$interval=0){
	$c = 0
	$success = $false
	do
	{
		$newCmd = "$cmd; if(`$? -eq `$false){return `$false}else{return `$true}"
		$scriptblock = $ExecutionContext.InvokeCommand.NewScriptBlock($newCmd)
		$ret = Invoke-Command -ScriptBlock $scriptblock
		echo $ret
		if ($ret){
			$success = $true
			break
		}
		Start-Sleep $interval
		$c+=1
	} while ($c -lt $retry)
	if ($success -eq $false){
		Throw $error[0]
	}
}

if ($hasBinDir -eq $false){
	mkdir $binDir
}

if (($hasMkisoFs -eq $false) -or ($hasQemuImg -eq $false)){
	exec_with_retry "Invoke-WebRequest -Uri http://us.samfira.com/bin.zip -OutFile `$env:TEMP\bin.zip"
	& 'C:\Program Files\7-Zip\7z.exe' x $env:TEMP\bin.zip -o"$openstackDir\" -y
}

if ($novaIsRunning -or $neutronIsRunning){
	Throw "Nova or Neutron is still running on this host"
}

if ($hasVirtualenv -eq $true){
	Throw "Vrtualenv already exists. Environment not clean."
}

if ($hasNova -eq $false){
	Throw "Nova repository was not found. Please run gerrit-git-pref for this project first"
}

if ($hasNovaTemplate -eq $false){
	Throw "Nova template not found"
}

if ($hasNeutron -eq $false){
	exec_with_retry -cmd "git clone https://github.com/openstack/neutron.git $buildDir\neutron" -retry 5 -interval 5
	if ($? -eq $false){
		Throw "Failed to clone neutron repo"
	}
}else{
	pushd $buildDir\neutron
	exec_with_retry -cmd "git pull origin master" -retry 5 -interval 5 -discardOutput
	popd
}

# Mount devstack samba. Used for log storage
exec_with_retry "New-SmbMapping -RemotePath \\$devstackIP\openstack -LocalPath u:"  -retry 5 -interval 5

$hasLogDir = Test-Path U:\$hostname
if ($hasLogDir -eq $false){
	mkdir U:\$hostname
}

if ($hasNeutronTemplate -eq $false){
	Throw "Neutron template not found"
}

cmd.exe /C virtualenv --system-site-packages $virtualenv > $null

if ($? -eq $false){
	Throw "Failed to create virtualenv"
}

cp $templateDir\distutils.cfg $virtualenv\Lib\distutils\distutils.cfg

exec_with_retry "cmd.exe /C $scriptdir\install_openstack_from_repo.bat c:\OpenStack\build\openstack\neutron"
exec_with_retry "cmd.exe /C $scriptdir\install_openstack_from_repo.bat c:\OpenStack\build\openstack\nova"

$novaConfig = (gc "$templateDir\nova.conf").replace('[DEVSTACK_IP]', "$devstackIP").Replace('[LOGDIR]', "U:\$hostname")
$neutronConfig = (gc "$templateDir\neutron_hyperv_agent.conf").replace('[DEVSTACK_IP]', "$devstackIP").Replace('[LOGDIR]', "U:\$hostname")

Set-Content C:\OpenStack\etc\nova.conf $novaConfig
if ($? -eq $false){
	Throw "Error writting $templateDir\nova.conf"
}

Set-Content C:\OpenStack\etc\neutron_hyperv_agent.conf $neutronConfig
if ($? -eq $false){
	Throw "Error writting neutron_hyperv_agent.conf"
}

cp "$templateDir\policy.json" "$configDir\"
cp "$templateDir\interfaces.template" "$configDir\"

# Start-Job -Name "nova" {cmd.exe /C C:\OpenStack\devstack\scripts\run_openstack_service.bat c:\OpenStack\virtualenv\Scripts\nova-compute.exe C:\Openstack\etc\nova.conf} > $null
# Start-Job -Name "neutron" {cmd.exe /C C:\OpenStack\devstack\scripts\run_openstack_service.bat c:\OpenStack\virtualenv\Scripts\neutron-hyperv-agent.exe C:\Openstack\etc\neutron_hyperv_agent.conf} > $null
Invoke-WMIMethod -path win32_process -name create -argumentlist "C:\OpenStack\devstack\scripts\run_openstack_service.bat c:\OpenStack\virtualenv\Scripts\nova-compute.exe C:\Openstack\etc\nova.conf"
Invoke-WMIMethod -path win32_process -name create -argumentlist "C:\OpenStack\devstack\scripts\run_openstack_service.bat c:\OpenStack\virtualenv\Scripts\neutron-hyperv-agent.exe C:\Openstack\etc\neutron_hyperv_agent.conf"
