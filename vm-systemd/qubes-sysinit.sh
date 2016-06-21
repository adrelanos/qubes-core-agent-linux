#!/bin/sh

# List of services enabled by default (in case of absence of qubesdb entry)
DEFAULT_ENABLED_NETVM="network-manager qubes-network qubes-update-check qubes-updates-proxy"
DEFAULT_ENABLED_PROXYVM="qubes-network qubes-firewall qubes-netwatcher qubes-update-check"
DEFAULT_ENABLED_APPVM="cups qubes-update-check"
DEFAULT_ENABLED_TEMPLATEVM="$DEFAULT_ENABLED_APPVM updates-proxy-setup"
DEFAULT_ENABLED=""

if [ -z "`ls /sys/bus/pci/devices/`" ]; then
    # do not enable meminfo-writer (so qmemman for this domain) when any PCI
    # device is present
    DEFAULT_ENABLED="$DEFAULT_ENABLED meminfo-writer"
    DEFAULT_ENABLED_APPVM="$DEFAULT_ENABLED_APPVM meminfo-writer"
    DEFAULT_ENABLED_PROXYVM="$DEFAULT_ENABLED_PROXYVM meminfo-writer"
    DEFAULT_ENABLED_TEMPLATEVM="$DEFAULT_ENABLED_TEMPLATEVM meminfo-writer"
fi


QDB_READ=qubesdb-read
QDB_LS=qubesdb-multiread

# Location of files which contains list of protected files
PROTECTED_FILE_LIST='/etc/qubes/protected-files.d'

read_service() {
    $QDB_READ /qubes-service/$1 2> /dev/null
}

systemd_pkg_version=`systemctl --version|head -n 1`
if ! dmesg | grep -q "$systemd_pkg_version running in system mode."; then
    # Ensure we're running right version of systemd (the one started by initrd may be different)
    systemctl daemon-reexec
fi

# Wait for xenbus initialization
while [ ! -e /dev/xen/xenbus -a ! -e /proc/xen/xenbus ]; do
  sleep 0.1
done

mkdir -p /var/run/qubes
chgrp qubes /var/run/qubes
chmod 0775 /var/run/qubes
mkdir -p /var/run/qubes-service
mkdir -p /var/run/xen-hotplug

# Set permissions to /proc/xen/xenbus, so normal user can talk to xenstore, to
# open vchan connection. Note that new code uses /dev/xen/xenbus (which have
# permissions set by udev), so this probably can go away soon
chmod 666 /proc/xen/xenbus

# Set permissions to /proc/xen/privcmd, so a user in qubes group can access
chmod 660 /proc/xen/privcmd
chgrp qubes /proc/xen/privcmd

[ -e /proc/u2mfn ] || modprobe u2mfn
# Set permissions to files needed by gui-agent
chmod 666 /proc/u2mfn

# Set default services depending on VM type
TYPE=`$QDB_READ /qubes-vm-type 2> /dev/null`
[ "$TYPE" = "AppVM" ] && DEFAULT_ENABLED=$DEFAULT_ENABLED_APPVM && touch /var/run/qubes/this-is-appvm
[ "$TYPE" = "NetVM" ] && DEFAULT_ENABLED=$DEFAULT_ENABLED_NETVM && touch /var/run/qubes/this-is-netvm
[ "$TYPE" = "ProxyVM" ] && DEFAULT_ENABLED=$DEFAULT_ENABLED_PROXYVM && touch /var/run/qubes/this-is-proxyvm
[ "$TYPE" = "TemplateVM" ] && DEFAULT_ENABLED=$DEFAULT_ENABLED_TEMPLATEVM && touch /var/run/qubes/this-is-templatevm

# Enable default services
for srv in $DEFAULT_ENABLED; do
    touch /var/run/qubes-service/$srv
done

# Enable services
for srv in `$QDB_LS /qubes-service/ 2>/dev/null |grep ' = 1'|cut -f 1 -d ' '`; do
    touch /var/run/qubes-service/$srv
done

# Disable services
for srv in `$QDB_LS /qubes-service/ 2>/dev/null |grep ' = 0'|cut -f 1 -d ' '`; do
    rm -f /var/run/qubes-service/$srv
done

# Set the hostname
if ! grep -rq "^/etc/hostname$" "${PROTECTED_FILE_LIST}" 2>/dev/null; then
    name=`$QDB_READ /name`
    if [ -n "$name" ]; then
        hostname $name
        if [ -e /etc/debian_version ]; then
            ipv4_localhost_re="127\.0\.1\.1"
        else
            ipv4_localhost_re="127\.0\.0\.1"
        fi
        sed -i "s/^\($ipv4_localhost_re\(\s.*\)*\s\).*$/\1${name}/" /etc/hosts
        sed -i "s/^\(::1\(\s.*\)*\s\).*$/\1${name}/" /etc/hosts
    fi
fi

# Set the timezone
if ! grep -rq "^/etc/timezone$" "${PROTECTED_FILE_LIST}" 2>/dev/null; then
    timezone=`$QDB_READ /qubes-timezone 2> /dev/null`
    if [ -n "$timezone" ]; then
        ln -sf ../usr/share/zoneinfo/$timezone /etc/localtime
        if [ -e /etc/debian_version ]; then
            echo "$timezone" > /etc/timezone
        else
            echo "# Clock configuration autogenerated based on Qubes dom0 settings" > /etc/sysconfig/clock
            echo "ZONE=\"$timezone\"" >> /etc/sysconfig/clock
        fi
    fi
fi

# Prepare environment for other services
echo > /var/run/qubes-service-environment

debug_mode=`$QDB_READ /qubes-debug-mode 2> /dev/null`
if [ -n "$debug_mode" -a "$debug_mode" -gt 0 ]; then
    echo "GUI_OPTS=-vv" >> /var/run/qubes-service-environment
fi

exit 0
