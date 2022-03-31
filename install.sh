#!/bin/bash

# find local ssh port from /etc/sshd
local_port=$(awk '/^Port /{print $NF}' /etc/ssh/sshd_config)
if [ ! -n "$local_port" ] || [ "$local_port" -ne "$local_port" ] 2>/dev/null; then
    # Set to default of 22
    local_port=22
fi

# get current user (to install/use ssh keys)
# TODO: make this more error tolerant
ssh_user=$(echo "$PWD" | awk -F'/' -v OFS='/' '{print $3}')
if [ "$ssh_user" = "" ]; then
    # Try using the 1000 user instead 
    ssh_user=$(cat /etc/passwd | grep "1000:1000" | awk -F':' '{print $1}')
    if [ "$ssh_user" = "" ]; then
        # We can't find the user, just use root instead *sigh*
        # TODO: Use home directory to get user names??
        ssh_user="$USER"
    fi
fi

ssh_dir="/home/$ssh_user/.ssh"
ssh_key=

# Configuration setting variables
remote_host=
remote_user=
remote_port=22
forwarded_port=

help() {
    echo "Usage: $0 [OPTIONS]..."
    echo "Installs a reverse ssh tunnel service to automatically [re]connect on boot and internet outages."
    echo -e "\t-r, --remote_host\t\tHostname or IP address of the remote ssh server. (will ask at a prompt if not provided)"
    echo -e "\t-u, --remote_user\t\tUsername to use when connecting to the remote ssh server."
    echo -e "\t-p, --remote_port\t\tPort number of the remote ssh server. (Default: 22)"
    echo -e "\t-i, --identity_file\t\tPath to the ssh private key file to use for authentication to the ssh server. (A new one will be created if not provided.)"
    echo -e "\t-f, --forwarded_port\t\tPort number to forward to the remote ssh server."
    echo -e "\t-h, --help\t\t\tDisplay this help message."
}

# Load commandline arguments
while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
        -r|--remote_host)
            shift # past flag
            remote_host="$1"
            shift # past argument
        ;;
        -u|--remote_user)
            shift # past flag
            remote_user="$1"
            shift # past argument
        ;;
        -p|--remote_port)
            shift # past flag
            remote_port="$1"
            shift # past argument
        ;;
        -i|--identity_file)
            shift # past flag
            ssh_key="$1"
            shift # past argument
        ;;
        -f|--forwarded_port)
            shift # past flag
            forwarded_port="$1"
            shift # past argument
        ;;
        -h|--help)
            help
            exit 0
        ;;
        *) # unknown option
            shift # past argument
        ;;
    esac
done

# Check for permissions before proceeding.
if [ "$USER" != "root" ]; then
    echo "This script needs to be run as root!"
    exit 1
fi

# Check if service already exists
service_dir="/etc/systemd/system/"
service_name="rtunnel.service"
service_exists=
if [ -f "$service_dir/$service_name" ]; then
    service_exists="y"
    echo "Service already installed, using existing configuration..."

    execstart_cmd=$(awk '/^ExecStart/{print $0}' $service_dir/$service_name)
    set $execstart_cmd
    # Scrape current config options.
    while [ "$1" != "" ]; do
        case $1 in
            -R )    shift
                    forwarded_port=$(echo $1 | awk -F':' '{print $1}')
                    local_port=$(echo $1 | awk -F':' '{print $3}')
                    ;;
            -p )    shift
                    remote_port=$1
                    ;;
            -i )    shift
                    ssh_key=$(echo $1 | awk -F'/' '{print $NF}')
                    ssh_dir=${1%"/$ssh_key"}
                    ;;
        esac
        shift
    done

    # TODO: Find host and user
    
fi

# Prompt user for server hostname and user
if [ -z "$remote_host" ]; then
    read -p "Enter remote hostname (for login): " hostname
    # TODO: Verify we can connect to host (And maybe print error then continue?)

    remote_host=$hostname
fi

if [ -z "$remote_user" ]; then
    read -p "Enter remote username (for login): " username
    # TODO: Verify user?

    remote_user=$username
fi

if [ -z "$remote_port" ]; then
    read -p "Enter remote ssh port (for login): " port_num

    remote_port=$port_num
fi

# Check if key file exists, if not, create it.
if [ -z "$ssh_key" ]; then
    # Prompt user
    read -p "Create new ssh key? (y/n): " answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        read -p "Name for new ssh key: " name
        # TODO: verify input!

        echo "\n\n" | ssh-keygen -f $name
        # TODO: make this more script friendly

        ssh_key=$name
    else
        read -p "Enter location of existing key: " key_loc
        ssh_key=$(echo $key_loc | awk -F'/' '{print $NF}')

        # Check if already in .ssh folder
        curr_key_dir=$(echo "$key_loc" | awk -F'/' -v OFS='/' '{print $4}')
        if [ "$curr_key_dir" = ".ssh" ]; then
            ssh_dir=${key_loc%"/$ssh_key"}
        else
            # Copy key into .ssh folder.
            echo "Copying key '$ssh_key' into .ssh folder"
            mkdir -p "$ssh_dir"
            cp "$key_loc" "$ssh_dir"
            chmod 600 "$ssh_dir/$ssh_key"
        fi
    fi
else
    if [ ! -f "$ssh_dir/$ssh_key" ]; then
        # key does not exist, so create it.
        mkdir -p "$ssh_dir"
        echo "\n\n" | ssh-keygen -a 100 -t ed25519 -f "$ssh_dir/$ssh_key"
        # TODO: Additional security config for key?
    fi
fi

# Verify that key works
ssh "$remote_user@$remote_host" -p $remote_port -i "$ssh_dir/$ssh_key" -o StrictHostKeyChecking=no exit
ssh_exitcode=$?
if [ $ssh_exitcode -ne 0 ]; then
    echo "Error logging in, trying to copy key..."

    ssh-copy-id -i "$ssh_dir/$ssh_key" -p $remote_port "$remote_user@$remote_host"

    # Check if successful
    if [ "$?" -ne 0 ]; then
        read -p "Cannot connect to server, are you sure you want to continue installing? (y/n): " answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            echo "Installing, note that the automatic reverse tunnel might not be configured properly"
        else
            echo "Ok, exiting!"
            exit 1
        fi
    fi
fi

# prompt user for the remote port number for this machine.
if [ -z "$forwarded_port" ]; then
    read -p "Please input a remote port to setup forwarding to: " forwarded_port
    while [ $forwarded_port -lt 10000 ] || [ $forwarded_port -ge 65535 ]; do
        echo "Error! Cannot set port to $forwarded_port"
        read -p "Port number must be between 10000 and 65535: " forwarded_port
    done
fi

# Display configuration
echo "**********************************************************************"
echo "* Installing auto remote tunnel service with the following parameters:"
echo "*     Remote User: $remote_user"
echo "* Remote Hostname: $remote_host"
echo "*     Remote Port: $remote_port"
echo "*"
echo "*  Forwarded Port: $forwarded_port"
echo "*  Local SSH Port: $local_port"
echo "*   Identity File: $ssh_dir/$ssh_key"
echo "**********************************************************************"

# Install autossh (if needed)
no_autossh=0
autossh -V > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Installing autossh..."
    # Don't need to use sudo
    apt install -y autossh

    # Check if successful
    if [ $? -ne 0 ]; then
        echo "Error installing autossh! Using regular ssh instead... (might be less fault tolerant)"
        no_autossh=1
    else
        no_autossh=0
    fi
fi

# Install the service
cp "$service_name" "$service_dir"

# Change autossh if needed
if [ $no_autossh -eq 1 ]; then
    sed -i "s/autossh -M 0/ssh/" "$service_dir/$service_name"
fi
# Set remote tunnel service configuration
sed -i "s/<forwarded_port>/$forwarded_port/" "$service_dir/$service_name"
sed -i "s/<local_port>/$local_port/" "$service_dir/$service_name"
# use ' instead of / because of path constants
sed -i "s'<remote_identity>'$ssh_dir/$ssh_key'" "$service_dir/$service_name"
sed -i "s/<remote_port>/$remote_port/" "$service_dir/$service_name"
sed -i "s/<remote_host>/$remote_host/" "$service_dir/$service_name"
sed -i "s/<remote_user>/$remote_user/" "$service_dir/$service_name"



# For now the service is run as root.
sed -i "s/<ssh_user>/root/" "$service_dir/$service_name"

# ssh into remote host to add host checking and verify connection
ssh "$remote_user@$remote_host" -p $remote_port -i "$ssh_dir/$ssh_key" -R $forwarded_port:localhost:$local_port -o StrictHostKeyChecking=no exit
ssh_exitcode=$?

# Reload service daemon
echo "Reloading..."
systemctl daemon-reload

# Start remote tunnel service
echo "Starting..."
if [ "$service_exists" = "y" ]; then
    service rtunnel restart
else
    service rtunnel start
fi

echo "Done!"

if [ $ssh_exitcode -ne 0 ]; then
    echo "rtunnel service is installed but failed to verify connection!"
    echo ""
    echo "Check the status by running "
    echo "'sudo service rtunnel status' or 'sudo systemctl status rtunnel'"
    echo "to verify that the service installed correctly."
else
    echo "Remote Tunneling service has been installed!"
    echo "Check status using 'sudo service rtunnel status' or 'sudo systemctl status rtunnel'"
fi