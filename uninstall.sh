#!/bin/bash

if [ "$USER" != "root" ]; then
    echo "This script needs to be run as root!"
    exit 1
fi

# Check if service already exists
service_dir="/etc/systemd/system/"
service_name="rtunnel.service"
if [ -f "$service_dir/$service_name" ]; then
    read -p "Are you sure you want to uninstall the rtunnel service? (y/n): " answer
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        service rtunnel stop
        systemctl disable rtunnel

        rm "$service_dir/$service_name"

        systemctl daemon-reload

        echo "Uninstalled!"
    else
        exit 0
    fi
fi


