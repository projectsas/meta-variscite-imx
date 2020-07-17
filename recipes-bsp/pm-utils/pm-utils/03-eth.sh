#!/bin/bash -e

# Power up Ethernet
eth_up()
{
	ifconfig eth1 up
}

# Power down Ethernet
eth_down()
{
	ifconfig eth1 down
}

# Check if Ethernet should be powered down during suspend
eth_should_be_down_in_suspend()
{
	# TODO specifically check for VAR-SOM-6UL
	if grep -q 6UL /sys/devices/soc0/soc_id; then
		return 0
	else
		return 1
	fi
}

eth_should_be_down_in_suspend || exit 0

case $1 in

"suspend")
	eth_down
	;;
"resume")
	eth_up
	;;
esac

