#!/usr/bin/perl

###########################################################################
# A program to "intergrate" WiFi WPA settings into an existing
# wpa_supplicant.conf file by way of wpa_cli.
#
# This program was designed to be partnered with systemd and udev to allow
# "hot config" when a USB flash drive is inserted. The original target was
# Raspberry Pi OS Lite, and specifically Raspbian GNU/Linux 11 (bullseye).
#
# Copyright(c) 2023 by Lester Hightower
###########################################################################
# Helpful URLs
# ------------
# https://raspberrypi.stackexchange.com/questions/98524/add-external-conf-to-wpa-supplicant-conf
# https://nxmnpg.lemoda.net/8/wpa_cli
# https://unix.stackexchange.com/questions/477393/multiple-same-ssid-in-wpa-supplicant-conf
#
# udev USB drive insertion
# https://serverfault.com/questions/766506/automount-usb-drives-with-systemd
# https://stackoverflow.com/questions/20084740/udev-run-program-on-usb-flash-drive-insert
# https://github.com/rbrito/usbmount
#
# Notes
# -----
# Prior to using systemd to directly ExecStartPost this program, I tried to
# use incron to monitor /media and that failed. When I was pursuing that
# approach, this command was useful to identify if the newly mounted path
# was on a USB device or not:
# $ find /dev/disk/by-id/ -type l -printf '%l|%f\n' | grep '/sda2|' | cut -d'|' -f2 | cut -d- -f1
# usb
#
# As mentioned, incron failed to work (incron died on usb insertion), and so I moved to ExecStartPost
# in /etc/systemd/system/usb-mount@.service
# root@basalsure2:/home/hightowe/bin# incrontab -l
# /media/       IN_CREATE       echo "New file/dir $# was created in /media" >> /root/incron.log
# /media/       IN_MOVED_TO     echo "New file/dir $# was moved to /media" >> /root/incron.log
###########################################################################

use strict;
use Getopt::Long;                             # core
use Pod::Usage;                               # core
use Time::Piece;                              # core
use File::Copy;                               # core
use File::Basename qw(basename dirname);      # core
use Cwd qw(abs_path);                         # core
use IPC::Open3;                               # core
use Symbol 'gensym';                          # core
use Data::Dumper;                             # core

my $VERSION = "0.2.2";

# Will only return with options we think we can use
our $opts = MyGetOpts();

# Load config file
our $CONF = get_config_or_die($opts->{conf});
#print "LHHD: ".Dumper($CONF)."\n";

# We've read the conf and so we want to go ahead and move it
# out of the way if --rename-processed-conf is specified.
# Note that MyGetOpts() abs_path's $opts->{conf}
if ((!$opts->{"dry-run"}) && $opts->{"rename-processed-conf"}) {
  my $now = localtime; # A Time::Piece object
  my $rename_to = sprintf("%s-processed_%s_%s", $opts->{conf}, $now->ymd(""), $now->hms(""));
  if (!  move($opts->{conf}, $rename_to)) {
    warn "Failed to move $opts->{conf} to $rename_to: $!\n";
  }
}

my $starting_status = get_wpa_status($CONF->{IFACE});
my $networks = get_list_networks();
#print "LHHD: ".Dumper($networks, $starting_status) . "\n";

do_wpa_supplicant_integration($networks);

exit;

##########################################################
##########################################################
##########################################################

sub get_config_or_die {
  my $conf_file = shift @_;

  # Slurp file w/out File::Slurp
  open my $fh, '<:unix', $conf_file or die "Couldn't open config file $conf_file $!";
  my $conf_content = do { local $/; <$fh> };
  close $fh;

  # Parse the content into %conf
  my %conf;
  foreach $_ (split(/\n/, $conf_content)) {
    chomp;                  # no newline
    s/#.*//;                # no comments
    s/^\s+//;               # no leading white
    s/\s+$//;               # no trailing white
    next unless length;     # anything left?
    my ($key, $val) = split(/\s*=\s*/, $_, 2);
    $val =~ s/^"//; $val =~ s/"$//; # Remove quotation marks
    $conf{$key} = $val;
  }

  foreach my $req_conf (qw(IFACE METHOD)) {
    die "Config option $req_conf is required!\n" if (! exists($conf{$req_conf}));
  }
  $conf{METHOD} = lc($conf{METHOD});  # We want METHOD to be lower-cased
  die "Invalid METHOD in config: $conf{METHOD}\n" if ($conf{METHOD} !~ m/^(integrate|replace)$/);

  return \%conf;
}

# Convenience function to reduce code duplication
sub ipc_open3 {
  my @cmd = @_;
  my $pid = open3(my $chld_in, my $chld_out, my $chld_err = gensym, @cmd);
  # reap zombie and retrieve exit status
  waitpid( $pid, 0 );
  my $child_exit_status = $? >> 8;

  my @stdout_lines = <$chld_out>;
  map { chomp $_ } @stdout_lines;
  return \@stdout_lines;
}

# wpa_cli -i wlan0 status
sub get_wpa_status {
  my $iface      = shift @_;
  my @cmd = (qw( wpa_cli -i ), $iface, 'status');
  my $stdout_lines = ipc_open3(@cmd);
  chomp @{$stdout_lines};
  return $stdout_lines;
}

# Convenience function to run simple, one parameter
# wpa_cli commands that should return OK on success.
sub wpa_simple_command {
  my $iface      = shift @_;
  my $command    = shift @_;
  my @cmd = (qw( wpa_cli -i ), $iface, $command);
  my $stdout_lines = ipc_open3(@cmd);
  my $retval = $stdout_lines->[0]; # Single-line output from get_network
  chomp($retval);
  if ($retval ne 'OK') {
    warn "Error running simple command \"$command\": $retval\n";
    return -1;
  }
  return 0;
}

# To add a note to the wpa_supplicant debug log
# wpa_cli -i wlan0 note "test note"
sub get_wpa_make_note {
  my $iface      = shift @_;
  my $note       = shift @_;
  my @cmd = (qw( wpa_cli -i ), $iface, 'note', $note);
  my $stdout_lines = ipc_open3(@cmd);
  my $retval = $stdout_lines->[0]; # Single-line output from get_network
  chomp($retval);
  if ($retval ne 'OK') {
    warn "Error making a note: $retval\n";
    return -1;
  }
  return 0;
}

# Usage: get_network <network id> <variable>
# $ wpa_cli -i wlan0 get_network 1 id_str
sub get_network_variable {
  my $iface      = shift @_;
  my $network_id = shift @_;
  my $variable   = shift @_;
  my @cmd = (qw( wpa_cli -i ), $iface, 'get_network', $network_id, $variable);
  my $stdout_lines = ipc_open3(@cmd);
  my $val = $stdout_lines->[0]; # Single-line output from get_network
  $val =~ s/^"//; $val =~ s/"$//; # Remove quotation marks
  return $val;
}

# Note that the data from list_networks is tab separated
sub get_list_networks {
  my @cmd = (qw( wpa_cli -i ), $CONF->{IFACE}, 'list_networks');
  my $stdout_lines = ipc_open3(@cmd);
  my $hdr_line = shift @{$stdout_lines};
  my @headers = split(m%\s*/\s*%, $hdr_line);
  #print "LHHD: ".Dumper(\@headers) . "\n";
  my @networks = ();
  foreach my $line (@{$stdout_lines}) {
    my @values = split(/\t/, $line);
    my %vals = ();
    foreach my $i (0 .. $#headers) {
      $vals{$headers[$i]} = $values[$i];
    }
    # Add some additional information for this network
    foreach my $key (qw(id_str priority key_mgmt)) {
      $vals{$key} = get_network_variable($CONF->{IFACE}, $vals{'network id'}, $key);
    }

    push @networks, \%vals;
  }
  return \@networks;
}

# The heavy lifting of this program happens inside of
# this subroutine.
sub do_wpa_supplicant_integration {
  $networks = shift @_;  # The networks from get_list_networks()

  # Required and optional keys
  my $now = localtime; # A Time::Piece object
  my @req_keys = qw(ssid psk);
  my $opt_keys = {
        key_mgmt => 'WPA-PSK',
        priority => undef,
        id_str => basename($0) . sprintf("_%s_%s", $now->ymd(""), $now->hms("")),
        };
  # Build the %keys to be put into place
  my %keys = ();
  foreach my $key (@req_keys) {
    if (! exists($CONF->{$key})) {
      die "Config option $key is required and is missing!\n";
    }
    $keys{$key} = $CONF->{$key};
  }
  foreach my $key (keys %{$opt_keys}) {
    if (exists($CONF->{$key})) {
      $keys{$key} = $CONF->{$key};
    } elsif (defined($opt_keys->{$key})) {
      $keys{$key} = $opt_keys->{$key};
    }
  }

  # Figuring out what we want to do here is a bit tricky.
  # The rules are as follows:
  #   1. If the *.conf file defines an id_str and a config
  #      for that id_str already exists, then we want to
  #      operate on it.
  #   2. If the *.conf file does not define an id_str, then
  #      we want to look for configs with matching ssid values.

  # Find any networks that match the configs we are working on
  my $matching_nws = {};
  my $matching_nws_by_id = {};
  foreach my $type (qw( id_str ssid )) {
    if (defined($CONF->{$type})) {
      @{$matching_nws->{$type}} = grep { $_->{$type} eq $keys{$type} } @{$networks};
    }
    foreach my $nw (@{$matching_nws->{$type}}) {
      $matching_nws_by_id->{$nw->{'network id'}} = $nw;
    }
  }
  print "\%matching_nws: ".Dumper($matching_nws, $matching_nws_by_id)."\n" if ($CONF->{verbose});

  #METHOD=integrate|replace

  my $matching_nw_count = scalar(keys %{$matching_nws_by_id});

  my $procedure = undef;
  my $nw_id_to_modify = undef;
  if ($matching_nw_count == 0) {
    $procedure = 'add';
  } elsif ($matching_nw_count == 1) {
    if ($CONF->{METHOD} eq 'replace') {
      $procedure = 'replace';
    } else {
      $procedure = 'modify';
    }
    $nw_id_to_modify = (keys %{$matching_nws_by_id})[0]; # Only one entry here
  } elsif ($matching_nw_count > 1) {
    $procedure = 'replace';
    if ($CONF->{METHOD} ne 'replace') {
      die "Found $matching_nw_count matching networks and therefore cannot do METHOD=$CONF->{METHOD}\n";
    }
  }

  print "Ready to work: METHOD=$CONF->{METHOD} and procedure=$procedure\n" if ($CONF->{verbose});
  print Dumper(\%keys)."\n" if ($CONF->{verbose});

  if ($opts->{"dry-run"}) {
    my $t = '';
    $t .= "Run with --dry-run. This is what I would have done otherwise:\n\n";
    $t .= "Using METHOD=$CONF->{METHOD} and following PROCEDURE=$procedure...\n\n";
    if ($procedure eq 'add') {
      $t .= "I would have added this network entry:\n".Dumper(\%keys)."\n";
    } elsif ($procedure eq 'modify') {
      $t .= "I would have modified this network entry:\n".Dumper(\%keys)."\n";
    } elsif ($procedure eq 'replace') {
      $t .= "I would have removed these network entres:\n".Dumper($matching_nws_by_id)."\n";
      $t .= "\n _and_\n";
      $t .= "I would have added this network entry:\n".Dumper(\%keys)."\n";
    }
    print $t;
    exit 0;
  }

  my @errors = ();
  if ($procedure eq 'add') {
    my $errors = wpa_cli_do_add($networks, \%keys);
    push @errors, @{$errors};
  } elsif ($procedure eq 'modify') {
    my $errors = do_set_network_for_keys($nw_id_to_modify, \%keys);
    push @errors, @{$errors};
  } elsif ($procedure eq 'replace') {
    my @remove_errs = ();
    foreach my $nw_id (sort keys %{$matching_nws_by_id}) {
      print "Removing nw_id=$nw_id\n";
      # wpa_cli -i wlan0 remove_network 5
      my @cmd = (qw( wpa_cli -i ), $CONF->{IFACE}, 'remove_network', $nw_id);
      my $result = join("\n", @{ipc_open3(@cmd)});
      if ($result ne 'OK') {
        push @remove_errs, "ERROR " . join(" ", @cmd) . ": $result";
      }
    }
    if (scalar(@remove_errs)) {
      print "REMOVE ERRORS:\n" . join("\n", @remove_errs) ."\n";
      # We had errors but we may also have removed some networks, and so
      # we are going to ask wpa_supplicant to re-read its configuration file.
      my @cmd = (qw( wpa_cli -i ), $CONF->{IFACE}, 'reconfigure');
      my $result = join("\n", @{ipc_open3(@cmd)});
      die "Bailing out after failing to remove all needed networks.\n";
    }

    # If we get this far, we removed the networks that we needed to and
    # can add the one that we need to now.

    # First, refresh $networks because of our removes...
    my $networks_orig = $networks; # Just in case we want to see the orig
    $networks = get_list_networks();
    # Now add what we needed to...
    my $errors = wpa_cli_do_add($networks, \%keys);
    push @errors, @{$errors};
  } else {
    die "I do not know how to perform procedure $procedure. Bailing out.\n";
  }

  my $errcnt = scalar(@errors);
  if ($errcnt) {
    # We had errors so we are going to ask wpa_supplicant to re-read its configuration file.
    my @cmd = (qw( wpa_cli -i ), $CONF->{IFACE}, 'reconfigure');
    my $result = join("\n", @{ipc_open3(@cmd)});
    print join(" ", @cmd) . ": $result\n";
    die "Bailing out due to errors, as follows:\n".Dumper(\@errors)."\n";
  } else {
    get_wpa_make_note($CONF->{IFACE}, "Applied changes from $opts->{conf}.");
    wpa_simple_command($CONF->{IFACE}, "save_config");
    wpa_simple_command($CONF->{IFACE}, "reassociate");
    my $ending_status = get_wpa_status($CONF->{IFACE});
    print Dumper($ending_status)."\n" if ($CONF->{verbose});
  }
}

# Runs "wpa_cli set_network <key> <val> for a set of
# key/val pairs in the $keys hash.
sub do_set_network_for_keys {
  my $nw_id = shift @_;
  my $keys  = shift @_;

  my @errors = ();
  foreach my $key (sort keys %{$keys}) {
    # set_network [network_id variable value]
    my $val = wpa_cli_quoteval($key, $keys->{$key});
    my @cmd = (qw( wpa_cli -i ), $CONF->{IFACE}, 'set_network', $nw_id, $key, $val);
    my $result = join("\n", @{ipc_open3(@cmd)});
    if ($result ne 'OK') {
      push @errors, "ERROR " . join(" ", @cmd) . ": $result";
    }
    #print join(" ", @cmd) . ": $result\n";
  }

  return \@errors;
}

# Adds a network (wpa_cli add_network) and sanity checks
# that one was added at the next "network id" increment.
sub wpa_cli_do_add {
  my $networks = shift @_;
  my $keys = shift @_;

  my @cmd = (qw( wpa_cli -i ), $CONF->{IFACE}, 'add_network');
  my $stdout_lines = join("\n", @{ipc_open3(@cmd)});
  my $new_nw_number = $stdout_lines;
  #print "LHHD: new_nw_number = $new_nw_number\n";

  my $new_networks = get_list_networks();
  my $new_nw = $new_networks->[$#{$new_networks}]; # Array is properly sorted
  my $new_nw_id = $new_nw->{'network id'};
  my $prior_high_id = $networks->[$#{$networks}]->{'network id'};
  if ($new_nw_id != ($prior_high_id + 1)) {
    die "The highest network id was $prior_high_id and I expected to add one, but I see: $new_nw_id\n";
  }

  my $errors = do_set_network_for_keys($new_nw_id, $keys);
  my $errcnt = scalar(@{$errors});

  if ($errcnt) {
    print "Experienced $errcnt error(s). Removing newly added network.\n";
    my @cmd = (qw( wpa_cli -i ), $CONF->{IFACE}, 'remove_network', $new_nw_id);
    my $result = join("\n", @{ipc_open3(@cmd)});
    print join(" ", @cmd) . ": $result\n";
  } else {
    my $new_networks = get_list_networks();
    my $new_nw = $new_networks->[$#{$new_networks}]; # Array is properly sorted
    print "Newly added network:\n" . Dumper($new_nw) . "\n" if ($CONF->{verbose});
  }

  return $errors;
}

# wpa_cli is very finicky about some (most) values being quoted
# when given on the command line, but also insists that some not
# be. This function helps cope with that.
sub wpa_cli_quoteval {
  my $key = shift @_;
  my $val = shift @_;

  # Cannot quote some keys, like key_mgmt
  my @dont_quote_keys = qw( key_mgmt priority );
  if (scalar(grep(m/^$key$/, @dont_quote_keys))) {
    return sprintf('%s', $val);
  }
  # Most values must be quoted!
  return sprintf('"%s"', $val);
}

# The command line option processor
sub MyGetOpts {
  my %opts=();
  my @params = (
        "confdir=s", "conffile=s", "conf=s",
        "quiet-exit-if-no-conf", "verbose",
	"rename-processed-conf",
        "help", "h", "dry-run",
        );
  my $result = &GetOptions(\%opts, @params);

  my $use_help_msg = "Use --help to see information on command line options.";

  # Set any undefined booleans to 0
  foreach my $param (@params) {
    if ($param !~ m/=/ && (! defined($opts{$param}))) {
      $opts{$param} = 0; # Booleans
    }
  }

  # If the user asked for help give it and exit
  if ($opts{help} || $opts{h}) {
    #print GetUsageMessage();
    #pod2usage(-exitval => 0, -verbose => 2);
    pod2usage(-exitval => 0, -verbose => 99, -sections => "NAME|SYNOPSIS|DESCRIPTION|OPTIONS|COPYRIGHT");
    exit;
  }

  # If GetOptions failed it told the user why, so let's exit.
  if (! int($result)) {
    print "\n" . $use_help_msg . "\n";
    exit;
  }

  my @errs=();

  # Allow --conf or --confdir/--conffile, but not both
  for my $key (qw(confdir conffile)) {
    if (exists($opts{$key}) && exists($opts{conf})) {
      die "You cannot specify both --$key and --conf\n";
    }
  }

  # If the user gave us a confdir then we'll use it to look for
  # the --conffile or wpa_integrate_ssid.conf there.
  if (exists($opts{confdir})) {
    my $conf_path = $opts{confdir};
    my $conf_file = undef;
    if (exists($opts{conffile})) {
      $conf_file = $opts{conffile};
    } else {
      $conf_file = default_conffile_name();
    }
    $opts{conf} = abs_path($conf_path.'/'.$conf_file);
  }


  # Validate access to the conf file or quietly exit if
  # --quiet-exit-if-no-conf is set.
  if (! exists($opts{conf})) {
    push @errs, "You must specify a config file: --conf=<file> or --confdir/--conffile";
  } elsif (! (-f -r $opts{conf})) {
    if ($opts{'quiet-exit-if-no-conf'}) {
      print "Quietly exiting after not finding $opts{conf}\n" if ($opts{verbose});
      exit 0;
    }
    push @errs, "Config file does not exist or is unreadable: $opts{conf}";
  }

  if (scalar(@errs)) {
    warn "There were errors:\n" .
        "  " . join("\n  ", @errs) . "\n\n";
    print $use_help_msg . "\n";
    exit;
  }

  return \%opts;
}

sub GetUsageMessage {
  my $t .= "The Usage Mesage is a TODO item\n";
  return $t;
}

sub default_conffile_name {
  my $perl_file = __FILE__;
  my $conf_file = basename(__FILE__);
  $conf_file =~ s/[.]pl$/.conf/;
  return $conf_file;
}


__END__

=head1 NAME

wpa_integrate_ssid.pl - Integrate settings into wpa_supplicant.conf

=head1 SYNOPSIS

wpa_integrate_ssid.pl --conf=wpa-hotconfig.txt

=head1 DESCRIPTION

B<This program> will read the given config file, apply the settings
within it to the system wpa_supplicant.conf file, save that information
and then ask wpa supplicant to reassociate with those new settings. The
program was designed to be partnered with systemd and udev to allow WPA
"hot config" when a USB flash drive is inserted. The original target was
Raspberry Pi OS Lite, and specifically Raspbian GNU/Linux 11 (bullseye).

=head1 OPTIONS

=over 8

=item B<-help | -h>

Print this help message and exit.

=item B<-conf | -confdir + -conffile>

You can either directly specify the config file:

    -conf=/full/path/to/wpa-hotconf.txt

Or you can specify both the -confdir and -conffile

    -confdir=/path/to -conffile=wpa-hotconf.txt

=item B<-quiet-exit-if-no-conf>

This option tells the program to quietly exit if the conf file
does not exist. This option is most useful when the program is being
auto-called by udev+systemd at the time of a USB flash drive insertion.

=item B<-rename-processed-conf>

This option tells the program to rename the config file that it
processes, and it does so my appending "-processed_WHEN" to the
filename. This option is most useful when the program is being
auto-called by udev+systemd at the time of a USB flash drive insertion.

=item B<-verbose>

Print more verbose information about what the program is doing.

=item B<-dry-run>

Print out what the program would do, but don't actually do it.

=back

=head1 COPYRIGHT

Copyright(c) 2023 by Lester Hightower

=cut

