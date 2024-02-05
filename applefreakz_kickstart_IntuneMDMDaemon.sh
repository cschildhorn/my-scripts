#!/bin/bash

# Script Name: applefreakz_kickstart_IntuneMDMDaemon.sh
# Description: This script tries to circumvent an issue that downloads stop during enrollment if systemextensions apps are installed, vpn connections are opened or a network change will happen.
# Version: 1.0
# Created on: January 2, 2024
# Last Modified: February 5, 2024
# Author: Christian Schildhorn
# Additional Comments: This includes some app names that are checked. Two of the apps can include a system extension (Microsoft Defender and Palo Alto GlobalProtect) that would trigger the issue. All other apps are just examples, this could be any apps that are assigned with a required intent. One specific topic regarding Microsoft Defender is also part of the script -  If you deploy a specific version of Defender, it might happen that the application starts immediatly an auto-update to the current/newer version, which kills downloads of other apps as well. I also integrated two different app lists, if you want to check for different apps on physical and virtual machines. I wanted this because on physical machines I want to use some VPP apps that is not supported in macOS VMs.

## Define variables
scriptname="KickStartIntuneMDMAgent"
logandmetadir="/Library/Logs/Microsoft/Intune/Scripts/$scriptname"
log="$logandmetadir/$scriptname.log"
flagfile="$logandmetadir/flags.txt"
lock_file="/Library/Logs/Microsoft/Intune/Scripts/$scriptname/$scriptname.lock"
applefreakzdir="/Library/Application Support/applefreakz/"
enrollment_file="/Library/Application Support/applefreakz/enrollment_restart_done.lock"

# Redirect stderr to /dev/null to suppress pop-up dialogs
exec 2>/dev/null

## Check if the log directory has been created
if [ -d $logandmetadir ]; then
    ## Already created
    echo "# $(date) | Log directory already exists - $logandmetadir"
else
    ## Creating Metadirectory
    echo "# $(date) | creating log directory - $logandmetadir"
    mkdir -p $logandmetadir
fi

## Check if the applefreakz directory has been created
if [ -d "$applefreakzdir" ]; then
    ## Already created
    echo "# $(date) | Log directory already exists - $applefreakzdir"
else
    ## Creating applefreakz directory
    echo "# $(date) | creating log directory - $applefreakzdir"
    mkdir -p "$applefreakzdir"
fi

# start logging
exec 1>> $log 2>&1
# Begin Script Body
echo ""
echo "##############################################################"
echo "# $(date) | Starting $scriptname"
echo "##############################################################"
echo ""

# Get the Mac's serial number
serial_number=$(system_profiler SPHardwareDataType | awk '/Serial/ {print $4}')

# Define the app names in an array
# Check if the serial number starts with "Z" or not
if [[ "$serial_number" =~ ^Z ]]; then
    echo "# $(date) | Serial number starts with Z. This a VM."
        appnames=(
        "Company Portal"
        "DisplayLink Manager"
        "GlobalProtect"
        "Microsoft Defender"
        "Microsoft Edge"
        "Microsoft Teams classic"
        "OneDrive"
        "Privileges"
        "Support"
        "UTM"
    )
else
    echo "# $(date) | Serial number does not start with Z. This is a real machine"
    appnames=(
        "Company Portal"
        "DisplayLink Manager"
        "GlobalProtect"
        "Microsoft Defender"
        "Microsoft Edge"
        "Microsoft Excel"
        "Microsoft OneNote"
        "Microsoft Outlook"
        "Microsoft PowerPoint"
        "Microsoft Teams classic"
        "Microsoft Word"
        "OneDrive"
        "Privileges"
        "Support"
        "UTM"
    )
fi

# Check if the lock file exists
if [ -e "$lock_file" ]; then
    echo "# $(date) | Check lock file: Script is already running."
    exit 1
else
    # Create a lock file
    touch "$lock_file"
fi

# Define a function to remove the lock file on exit
function cleanup() {
    rm -f "$lock_file"
    echo "# $(date) | Lock file removed."
    killall -q caffinate >/dev/null 2>&1
    echo "# $(date) | De-caffeinate..."
}

# Function to sanitize app names to create valid Bash variable names
function sanitize_app_name() {
    echo "$1" | sed 's/[^a-zA-Z0-9]/_/g'
}

# Function to check if an app is installed using the app names
function check_app_installed() {
    if find "/Applications" -type d -name "$1.app" -maxdepth 1 | grep -q "$1.app"; then
        echo "# $(date) | Check app: $1 is installed."
        return 0
    fi
    echo "# $(date) | Check app: $1 is NOT FOUND."
    return 1
}

# Function to check if Defender version is not 101.23072.0025
function check_defender_version() {
    # Define the path to Microsoft Defender's Info.plist
    plist_path="/Applications/Microsoft Defender.app/Contents/Info.plist"

    # Check if Microsoft Defender is installed
    if [ ! -f "$plist_path" ]; then
        echo "# $(date) | Check MDATP version: Microsoft Defender is not yet installed."
        return 1
    fi

    # Get the current version of Microsoft Defender
    current_version=$(defaults read "$plist_path" CFBundleShortVersionString)

    # Check if the version is not required version
    if [ "$current_version" != "101.23072.0025" ]; then
        echo "# $(date) | Check MDATP version: Defender is updated by auto-update ($current_version)."
        return 0
    else
        echo "# $(date) | Check MDATP version: Defender version is managed app version (101.23072.0025)."
        return 1
    fi
}

# Function to check if plist contains user-id key with any value
function check_gpc_connected() {
    plist_path="/Library/Preferences/com.paloaltonetworks.GlobalProtect.settings.plist"
    key_to_check="user-id"

    # Check if the plist file exists
    if [ -f "$plist_path" ]; then
        # Use plutil to convert plist to XML, then grep to search for the key
        if plutil -convert xml1 -o - "$plist_path" | grep -q "<key>$key_to_check</key>"; then
            echo "# $(date) | Check GPC connect: GPC first connection detected. Key '$key_to_check' found in plist."
            return 0
        else
            echo "# $(date) | Check GPC connect: GPC not connected. Key '$key_to_check' not found in plist."
            return 1
        fi
    else
        echo "# $(date) | Check GPC connect: GPC not installed yet."
        return 2
    fi
}

# Function to restart IntuneMDMAgent processes
function restart_intunemdmagent() {
    while true; do
        # Check if the IntuneMDMDaemon process is running
        if ps aux | grep -q 'IntuneMDMDaemon'; then
            echo "# $(date) | IntuneMDMDaemon is running. Applying fix: Restarting IntuneMDMAgent processes..."
            killall IntuneMdmDaemon
            killall IntuneMdmAgent
            return 0
        else
            echo "# $(date) | IntuneMDMDaemon is not running, checking again in 3 seconds..."
        fi
        sleep 3
    done
}

# Set the function to execute on script exit
trap cleanup EXIT

# Initialize flag variables
all_apps_installed=false
gpc_first_connection=false
defender_version=false
for appname in "${appnames[@]}"; do
    app_installed_var="app_${appname// /_}_installed"
    declare "$app_installed_var=false"
done

# Check if flag file exists and read flag values
if [ -f "$flagfile" ]; then
    source "$flagfile"
fi

# Check if the enrollment_file exists
if [ -e "$enrollment_file" ]; then
    echo "# $(date) | Check enrollment_file file: Script was already running during enrollment."
    exit 0
else
    # Create a enrollment_file
    touch "$enrollment_file"
fi

# Ensure computer does not go to sleep while running this script
echo "# $(date) | Caffeinating this script (PID: $$)"
caffeinate -dimsu -w $$ &

# Loop until all apps are installed or conditions are met
while [ "$all_apps_installed" != "true" ]; do
    for appname in "${appnames[@]}"; do
        # Construct the variable names for flags
        sanitized_appname=$(sanitize_app_name "$appname")
        app_installed_var="app_${sanitized_appname}_installed"

        # Check if app is already installed and not previously processed
        if check_app_installed "$appname" && [ "${!app_installed_var}" != true ]; then
            # Update the flag to true
            declare "$app_installed_var=true"
            echo "# $(date) | Trigger daemon restart: $appname has been detected for the first time."
            # Store flag values in the flag file
            echo "$app_installed_var=true" >> "$flagfile"
            # Call restart_intunemdmagent function
            restart_intunemdmagent
        fi
    done

    # Check if Global Protect is connected
    if check_gpc_connected && [ "$gpc_first_connection" != true ]; then
        gpc_first_connection=true
        echo "# $(date) | Trigger daemon restart: GlobalProtect connected for the first time."
        # Store flag values in the flag file
        echo "gpc_first_connection=true" >> "$flagfile"
        # Call restart_intunemdmagent function
        restart_intunemdmagent
    fi

    # Check if Defender version is not 101.23072.0025
    if check_defender_version && [ "$defender_version" != true ]; then
        defender_version=true
        echo "# $(date) | Trigger daemon restart: Defender is updated to latest version."
        # Store flag values in the flag file
        echo "defender_version=true" >> "$flagfile"
        # Call restart_intunemdmagent function
        restart_intunemdmagent
    fi

    # Check if all apps are installed
    all_apps_installed=true
    for appname in "${appnames[@]}"; do
        app_installed_var="app_${appname// /_}_installed"
        if [ "${!app_installed_var}" != true ]; then
            all_apps_installed=false
        fi
    done

    if [ "$all_apps_installed" = true ] && [ "$gpc_first_connection" = true ] && [ "$defender_version" = true ]; then
        echo "# $(date) | Apps installed, Defender updated, profiles installed and GPC connected."
    else
        echo "# $(date) | Waiting for necessary enrollment steps..."
        sleep 60
    fi
done

# Decaffinate
killall -q caffinate >/dev/null 2>&1
echo "# $(date) | De-caffeinate..."
