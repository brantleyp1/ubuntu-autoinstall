#!/bin/bash -ex
apt-get update
apt-get remove multipath-tools
apt-get upgrade -y
ufw disable
update-grub && sudo update-grub2
update-initramfs -u -v
exit
