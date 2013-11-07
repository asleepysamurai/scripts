#!/bin/bash --

# Usage ./buildanddeploy.sh <tenant> <avalondir> <implementationsdir> [<config/config-t2>]

usage()
{
cat << EOF

Usage Options:

This script builds and deploys the specified tenant to your local VM, config or config-t2 environment.

If you face errors while connecting to the AWS servers for config or config-t2 environments, double check the server names with http://ssi-admin.int.ssi-cloud.com/ssi-instance-list.html

OPTIONS:
   -h                          Flag. Show this message
   -t <tenant>                 Mandatory. Tenant name. Should match the folder name for the tenant in the Implementations directory.
   -a <avalondir>              Mandatory. Avalon directory path.
   -i <implementationsdir>     Mandatory. Implementations directory path.
   -e <environment>            Mandatory. Possible values: local, config, config-t2

EOF
}

tenant=
avalondir=
implementationsdir=
environment='local'

while getopts ":ht:a:i:e:" OPTION
do
	case $OPTION in
		h)
			usage
			exit 0
			;;
		t)
			tenant=$OPTARG
			;;
		a)
			avalondir=$OPTARG
			;;
		i)
			implementationsdir=$OPTARG
			;;
		e)
			environment=$OPTARG
			;;
		\?)
			usage
			exit 0
			;;
		:)
			echo "Missing value for mandatory parameter: $OPTARG"
			usage
			exit 1
			;;
	esac
done

if [[ -z $tenant || -z $avalondir || -z $implementationsdir ]]; then
	echo "Mandatory parameters missing."
	usage
	exit 1
fi

if [[ $environment != 'config' && $environment != 'config-t2' ]]; then
	environment='local'
fi

echo "tenant: $tenant"
echo "avalonDir: $avalondir"
echo "implementationDir: $implementationsdir"
echo "environment: $environment"
if [[ $environment == 'local' ]]; then
	echo "Is avalon server running locally?"
	select yn in "Yes" "No"; do
			case $yn in
					Yes ) break;;
					No ) echo "Please start avalon server locally and then run buildanddeploy."; echo "Aborting build and deploy."; exit;;
			esac
	done
fi

echo "Building package..."
chmod +x $implementationsdir/tools/release-management/buildPackage.sh
buildop=`$implementationsdir/tools/release-management/buildPackage.sh $tenant $avalondir`

if [ "$?" != "0" ]; then
	echo buildop
	echo "Building the package for tenant: $tenant failed. Aborting build and deploy."
	exit 1
fi

for word in $buildop
do
	tag=$word
done

echo "Built package with tag: $tag"

if [[ $environment == 'local' ]]; then
	echo "Deploying to local Ubuntu VM"
	echo "Deploying to local machine"
	cd $implementationsdir/tools/release-management
	./package-$tag.sh dbhost=localhost dbport=27017 host=localhost port=7000 user=bruce.lewis@$tenant.com pass=passwordone avalonDir=$avalondir
	if [ "$?" != "0" ]; then
		echo "Deploying to local machine failed. Aborting build and deploy."
		exit 1
	else
		echo "Deploy succeeded. Please restart Avalon server manually."
		echo "Build and deploy succeeded."
	fi
else
	echo "Deploying to AWS $environment environment"

	scriptdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

	declare -a servers
	if [[ $environment == 'config' ]]; then
		# Update server list whenever it changes
		readarray servers < $scriptdir/config_servers.txt
	elif [[ $environment == 'config-t2' ]]; then
		# Update server list whenever it changes
		readarray servers < $scriptdir/config-t2_servers.txt
	else
		echo "Invalid remote environment specified. Aborting build and deploy."
		exit 1
	fi

	scp -oStrictHostKeyChecking=no -P 2222 $implementationsdir/tools/release-management/package-$tag.sh ec2-user@${servers[0]}:~
	if [ "$?" != "0" ]; then
		echo "Failed to secure copy file to ${servers[0]}."
		echo "Check if the server names have been changed and update $environment.txt as required."
		echo "Aborting build and deploy."
		exit 1
	else
		echo "Secure copied file to ${servers[0]}."
		echo "Deploying package on ${servers[0]}."
		ssh -oStrictHostKeyChecking=no -p 2222 ec2-user@${servers[0]} "./package-$tag.sh dbhost=localhost dbport=27017 host=localhost port=7002 user=bruce.lewis@$tenant.com pass=passwordone"
		if [ "$?" != "0" ]; then
			echo "Error occurred while deploying package to ${servers[0]}. Aborting build and deploy."
			exit 1
		else
			echo "Successfully deployed package to ${servers[0]}."
		fi
		echo "Restarting all servers in $environment environment"
		for i in "${servers[@]}"
		do
			if [[ $i == ${servers[0]} ]]; then
				echo "Cleaning up and restarting server: $i"
				ssh -oStrictHostKeyChecking=no -p 2222 ec2-user@$i "sudo /etc/init.d/node restart && rm ./package-$tag.sh" &
			else
				echo "Restarting server: $i"
				ssh -oStrictHostKeyChecking=no -p 2222 ec2-user@$i "sudo /etc/init.d/node restart" &
			fi
			pids[${#pids[@]}]=$!
		done

		for i in "${pids[@]}"
		do
			echo "Checking SSH Session: $i"
			while kill -0 $i &> /dev/null
			do
				sleep 0.1
			done
		done

		echo "All servers restarted"
	fi
fi

echo "Successfully deployed changes for $tenant to $environment environment."