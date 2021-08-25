# Ubuntu 20.04 template using Packer for vSphere/vCenter environtments

## Purpose

Using the user-data config file to handle some of the pre-template items, such as filesystems, this will create a ready to use template. It will be hardened per CIS Linux Hardening standards as much as possible.

## Synopsis

The user-data file is generally the same from environment to environment. This one is tweaked to overcome some issues that I think are unique to my environment but are also not very well documented so I'm leaving them here in case anyone stumbles across them.

I ran into some headaches and this is an attempt to document what I found and how it was fixed.

### DHCP

Ubuntu sends a DUID/UUID identifier in a DHCPREQUEST. There are a few examples online instructing you to set the `dhcp-identifier: mac` but that wouldn't work for me. 

I tried adding it as a network section 

```
  network:
    network:
      version: 2
      ethernets:
        ens160:
          dhcp4: true
          dhcp6: false
          dhcp-identifier: mac
```

as well as a late-command

```
  late-commands:
    - 'sed -i "s/dhcp4: true/&\n      dhcp-identifier: mac/" /target/etc/netplan/00-installer-config.yaml'
```

But I kept having a weird situation where I would get different IPs during the boot and install stages and Packer would be expecting one IP but was no longer assigned. 

What I wound up getting to work was setting a kernel parameter `ip=dhcp` in the boot_commands section of the json file. This seemed to force the dhcp-identifier to be MAC, but it brought it's own oddity. I was receiving two IPs on the single attached NIC. Even though there was only one NIC, and it only had one MAC address, I was seeing two IPs. 

I solved this by running a cloud-init runcmd command to remove that flag from /etc/default/grub. These are run after the initial curtin install of the OS, but before the provision section of the Packer build.

The runcmd does pull out the parameter, but also left a netplan yaml config that is part of the cloud-init install. This left the system unable to capture an IP because it had the mac address of the originally created VM's adapter, so another runcmd to remove that yaml.

```
    runcmd:
      - 'sed -i "s/ip=dhcp //g" /etc/default/grub'
      - 'rm /etc/netplan/50-cloud-init.yaml'
```

### CIS partitions

This was more of a prove that it could be done, rather than requirement, but I wanted to follow as closely the CIS Hardening standards for Linux. The standards state that /root, /tmp, /var, /var/log, /var/log/audit, /var/tmp, and /home are all separate, and that /tmp and /var/tmp are mounted without execute permissions and similar. The only option I've seen online was for AWS running a build in chroot, but wasn't able to get it to succeed. I haven't tested this on any cloud platforms, but this does successfully build the correct partitions with the correct permissions in a VMware environment. 

I'm setting up a partitioned FS such as, given as percentages:
| Mount  | Percentage|
|--------|---:|
| root   |35% |
| swap   |5%  |
| tmp    |10% |
| var    |10% |
| var_tmp|5%  |
| var_log    |10% |
| var_log_audit  |10% |
| home   |10% |

This is not including 1G given to /boot as well as 1M given to bios. The reason it doesn't equal 100% is to allow for the 1G+1M of space used, you can squeeze a little more but those percentages leave approx. 2G of a 50G drive unused, but will work on drives as low as 20G. Any smaller than 20G and you'll need to shrink some of the percentages to under about 88% total.

### Write Files

This section was also more of a "see if it can be done" project, but was very beneficial for another project setting up a fully unattended install ISO.

The basis of the section is 
```
  user-data:
    write_files:
    - encoding: b64
      content: ICpmaWx0ZXIKIDp1Znct.......
      owner: root:root
      path: /etc/ufw/user.rules
      permissions: '0644'
```

I write out the files then base64 encode them and drop that string as the content. This runs after install but before the Packer provisioners steps.

base64 encode via:

`base64 clear_text_file.txt > base64_text_file.txt` then drop the string from the base64 file into the user-data config.

### Unique to my environment

In my environment, local user home directories in Linux are under /export/home. This was done to keep our linux and Solaris systems in line and for automounting home directories. It's not needed in most situations so a few of the steps won't be needed by most.

I didn't want the ubuntu default user, so instead am setting the default user as my preferred admin user. That requires some of the late-commands to make sure that user has sudo rights.

The dhcp issue may have been related to the dhcp server in my environment. In my case, dhcp is supplied from a Juniper SRX 650 firewall/router. I'm not very familiar with the platform, but I understand it's running DHCP in the JDHCP form. From what I can tell, the system doesn't handle the DUID presented instead of a MAC address. There is mention of DUID in the DHCPv6 section of the documenation, but that seemed to be related to running the traditional DHCP server, and then only in IPv6 mode. My solution finally got a reliable build that didn't cause issues in the template that were inherited to VMs built from it.

It's possible that with a normal DHCP server setup this issue wouldn't have happened, so the kernel parameter wouldn't have been needed. The `dhcp-identifier: mac` solution(s) may have worked were it not for the SRX gear.

## Files

| Files/Folders |     |     | Req | Description |
|:-------:|-------:|--------:|:--:| -----|
| http/		 | | | O | Folder containing user-data and meta-data. Can be omitted though with some changes to the json under http_directory section|
| | meta-data			| | R |blank, but required for user-data to be recognized|
| | user-data			| | R |cloud-init styled yaml config file|
| provisioners/	| | | O |Folder containing the shell scripts and an ansible playbook to call the ubuntu hardening role, optional but what's the point without some provisioners|
| | ansible/		| | O |Ansible subdirectory|
|  | | playbook.yml		| O |Playbook to call hardening role|
| | shell/			| | O |shell script subdirectory|
| | | baseInit.sh		| O |simple script that installs ansible, runs an update, can be used for a lot of different needs|
| | | post_cleanup.sh		| O |a script run after all others, in this case it removes ansible and cleans up apt|
| ubuntu2004.vcenter.json	| | | R |json config for Packer build. |

You'll notice missing is the hardening role. I keep it in a level up from the packer configs and call it in the ./provisioners/ansible/playbool.yml file. I put the path in the json config. I use a slightly modified version of [alivx's CIS hardening role](https://github.com/alivx/CIS-Ubuntu-20.04-Ansible). The only major differences between how I run the role and the original: I removed a couple of plays and set it so it doesn't require an AllowUser for sshd, because we use AllowGroup instead. If you're going to run a hardening role/script, make sure you know which options are what and be aware you can pretty well fubar a build.

## Parting thoughts

I don't like how Ubuntu requires using literal keystroke codes `<bs><f6><wait><enter>` fed to the boot commands in order to boot into an autoinstall process. Also, the user-data autoinstall config isn't exactly like cloud-init. Namely, the user-data section is what is passed on to cloud-init, the rest is actually [curtin](https://curtin.readthedocs.io/en/latest/index.html) and in my opinion isn't very clearly documented in some ways.

The storage section can be done cleaner I believe, from reading the curtin docs, but as is it works and I'm just gonna leave it.

I have not yet tested this build in any cloud provider. I suspect the only steps needed to make this work in AWS would be to remove the `ip=dhcp` kernel parameter, as well as the downstream fixes of pulling out that parameter and netplan yaml. I ***think*** the storage section will work though, which would mean not having to worry about chroot builds for building against the CIS standards. But again, I have not tested this, so YMMV. 
