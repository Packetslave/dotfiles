#!/bin/bash

# Sync Homebrew installations between Macs via Dropbox
#

BREW="/opt/homebrew/bin/brew"
DB="~/Dropbox/Library/Homebrew"

# first get local settings
echo "Reading local settings ..."
rm -f /tmp/brew-sync.*
$BREW tap > /tmp/brew-sync.taps
$BREW list > /tmp/brew-sync.installed

# then combine it with list in Dropbox
echo "Reading settings from Dropbox ..."
[ -e ${DB}/brew-sync.taps ] && cat ${DB}/brew-sync.taps >> /tmp/brew-sync.taps
[ -e ${DB}/brew-sync.installed ] && cat ${DB}/brew-sync.installed >> /tmp/brew-sync.installed

# make the lists unique and sync into Dropbox
echo "Syncing to Dropbox ..."
mkdir -p ${DB}
cat /tmp/brew-sync.taps | sort | uniq > ${DB}/brew-sync.taps
cat /tmp/brew-sync.installed | sort | uniq > ${DB}/brew-sync.installed

# Set taps
echo "Enabling taps ..."
for TAP in `cat ${DB}/brew-sync.taps`; do
	$BREW tap ${TAP}
done

# Install missing Homebrew packages
echo "Install missing packages ..."
for PACKAGE in `cat ${DB}/brew-sync.installed`; do
	$BREW install ${PACKAGE}
done
