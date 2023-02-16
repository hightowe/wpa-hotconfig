# NAME

wpa\_integrate\_ssid.pl - Integrate settings into wpa\_supplicant.conf

# SYNOPSIS

wpa\_integrate\_ssid.pl --conf=wpa-hotconfig.txt

# DESCRIPTION

**This program** will read the given config file, apply the settings
within it to the system wpa\_supplicant.conf file, save that information
and then ask wpa supplicant to reassociate with those new settings. The
program was designed to be partnered with systemd and udev to allow WPA
"hot config" when a USB flash drive is inserted. The original target was
Raspberry Pi OS Lite, and specifically Raspbian GNU/Linux 11 (bullseye).

# OPTIONS

- **-help | -h**

    Print this help message and exit.

- **-conf | -confdir + -conffile**

    You can either directly specify the config file:

        -conf=/full/path/to/wpa-hotconf.txt

    Or you can specify both the -confdir and -conffile

        -confdir=/path/to -conffile=wpa-hotconf.txt

- **-quiet-exit-if-no-conf**

    This option tells the program to quietly exit if the conf file
    does not exist. This option is most useful when the program is being
    auto-called by udev+systemd at the time of a USB flash drive insertion.

- **-rename-processed-conf**

    This option tells the program to rename the config file that it
    processes, and it does so my appending "-processed\_WHEN" to the
    filename. This option is most useful when the program is being
    auto-called by udev+systemd at the time of a USB flash drive insertion.

- **-verbose**

    Print more verbose information about what the program is doing.

- **-dry-run**

    Print out what the program would do, but don't actually do it.

# COPYRIGHT

Copyright(c) 2023 by Lester Hightower
