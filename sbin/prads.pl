#!/usr/bin/perl -w


# PRADS, the Passive Real-time Asset Detection System
package Prads;

use strict;
use warnings;
use POSIX qw(setsid);
use FindBin;
use Getopt::Long qw/:config auto_version auto_help/;
use Net::Pcap;
use Data::Dumper;
use DBI;

use constant ETH_TYPE_ARP       => 0x0806;
use constant ETH_TYPE_802Q1T    => 0x8100;
use constant ETH_TYPE_802Q1MT   => 0x9100;
use constant ETH_TYPE_IP        => 0x0800;
use constant ETH_TYPE_IPv6      => 0x86dd;
use constant ARP_OPCODE_REPLY   => 2;

BEGIN {

    # list of NetPacket:: modules
    my @modules = map { "NetPacket::$_" } qw/Ethernet IP ARP ICMP TCP UDP/;
    my $bundle  = 0;

    MODULE:
    for my $module (@modules) {

        # try to use installed version first
        eval "use $module";
        next MODULE unless($@);

        if($ENV{'DEBUG'}) {
            warn "$module is not installed. Using bundled version instead\n";
        }

        # use bundled version instead
        local @INC = ("$FindBin::Bin/../lib");
        eval "use $module";
        die $@ if($@);
        $bundle++;
    }

    if($ENV{'DEBUG'} and $bundle) {
        warn "Run this command to install missing modules:\n";
        warn "\$ perl -MCPAN -e'install NetPacket'\n";
    }
}

=head1 NAME

prads.pl - inspired by passive.sourceforge.net and http://lcamtuf.coredump.cx/p0f.shtml

=head1 VERSION

0.2

=head1 SYNOPSIS

 $ prads.pl [options]

 OPTIONS:

 --dev|-d |--iface|-i    : network device (default: eth0)
 --config|-c             : path to prads configfile
 --confdir|-cd           : path to prads config dir (default /etc/prads)
 --service-signatures|-s : path to service-signatures file (default: /etc/prads/tcp-service.sig)
 --os-fingerprints|-o    : path to os-fingerprints file (default: /etc/prads/os.fp
 --debug                 : enable debug messages 0-255 (default: disabled(0))
 --verbose               : debug 1
 --dump                  : Dumps all signatures and fingerprints then exits
 --dumpdb                : Dumps all assets in database
 --arp                   : Enables ARP discover check
 --service               : Enables Service detection
 --os                    : Enables OS detection
 --db                    : DBI string (default: dbi:SQLite:dbname=prads.db)
 --help                  : this help message
 --version               : show prads.pl version

=cut

################################################################################
############# C - O - N - F - I - G - U - R - A - T - I - O - N ################
################################################################################

our $VERSION       = 0.93;
our $DEBUG         = 0;
our $DUMPDB        = 0;
our $DAEMON        = 0;
our $DUMP          = 0;
our $VLAN          = 0;
our $ARP           = 1;
our $SERVICE_TCP   = 1;
our $SERVICE_UDP   = 1;
our $UDP           = 1;
our $OS            = 1;
our $OS_SYN        = 1;
our $OS_SYNACK     = 1;
our $OS_UDP        = 1;
our $ICMP          = 1;
our $OS_ICMP       = 1;
our $BPF           = q();
our $PERSIST       = 1;

# Database globals.
our %ASSET;
our $DATABASE      = q(dbi:SQLite:dbname=prads.db);
our $DB_USERNAME;
our $DB_PASSWORD;
our $AUTOCOMMIT = 1;
our $TIMEOUT = 10;
our $DB_LAST_UPDATE = 0;
our $SQL_IP = 'ipaddress';
our $SQL_FP = 'os_fingerprint';
our $SQL_MAC = 'mac_address';
our $SQL_DETAILS = 'os_details';
our $SQL_HOSTNAME = 'hostname';
our $SQL_TIME = 'timestamp';
our $SQL_ATON = 'INET_ATON(?)';
our $SQL_NTOA = 'INET_NTOA(?)';

my $DEVICE;
my $LOGFILE                 = q(/dev/null);
my $PIDFILE                 = q(/var/run/prads.pid);
my $CONFDIR                 = q(../../etc);
my $CONFIG                  = qq($CONFDIR/prads.conf);

pre_config();

my $S_SIGNATURE_FILE        = qq($CONFDIR/tcp-service.sig);
my $OS_SYN_FINGERPRINT_FILE = qq($CONFDIR/tcp-syn.fp);
my $OS_SYNACK_FINGERPRINT_FILE = qq($CONFDIR/tcp-synack.fp);
my $OS_ICMP_FINGERPRINT_FILE= qq($CONFDIR/osi.fp);
my $OS_UDP_FINGERPRINT_FILE = qq($CONFDIR/osu.fp);
my $MAC_SIGNATURE_FILE      = qq($CONFDIR/mac.sig);
my $MTU_SIGNATURE_FILE      = qq($CONFDIR/mtu.sig);
my %pradshosts              = ();
my %ERROR          = (
    init_dev => q(Unable to determine network device for monitoring - %s),
    lookup_net => q(Unable to look up device information for %s - %s),
    create_object => q(Unable to create packet capture on device %s - %s),
    compile_object_compile => q(Unable to compile packet capture filter),
    compile_object_setfilter => q(Unable to set packet capture filter),
    loop => q(Unable to perform packet capture),
);
my $PRADS_HOSTNAME = `hostname`;
chomp $PRADS_HOSTNAME;

sub pre_config
{
   # make an educated confdir guess.
   for my $dir ($CONFDIR, qw(../etc /etc/prads)){
      if (-d $dir and -f "$dir/prads.conf") {
         $CONFDIR = $dir;
         $CONFIG = "$dir/prads.conf";
         last;
      }
   }
   # extract & load config before parsing rest of commandline
   for my $i (0..@ARGV-1){
      if($ARGV[$i] =~ /^--?(config|c)$/){
         $CONFIG = splice @ARGV, $i, $i+1;
         print "Loading config $CONFIG\n";
         last; # we've modified @ARGV
      }elsif($ARGV[$i] =~ /^--?(confdir|cd)$/){
         $CONFDIR = $ARGV[$i+1];
         print "Loading config from $CONFDIR";
      }
   }
}

# loads default config if none specified
my $conf = load_config("$CONFIG");
my $C_INIT = $CONFIG;

sub default_config {
   my $conf = shift;
   $DATABASE       = $conf->{'db'}                  || $DATABASE;
   $DB_USERNAME    = $conf->{'db_username'} if $conf->{'db_username'};
   $DB_PASSWORD    = $conf->{'db_password'};
   $DEVICE         = $conf->{interface};
   $ARP            = $conf->{arp}                   || $ARP;
   $SERVICE_TCP    = $conf->{service_tcp}           || $SERVICE_TCP;
   $SERVICE_UDP    = $conf->{service_udp}           || $SERVICE_UDP;
   $DEBUG          = $conf->{debug}                 || $ENV{'DEBUG'} || $DEBUG;
   $DUMPDB         = $conf->{dumpdb}                || $ENV{'DUMPDB'} || $DUMPDB;
   $DAEMON         = $conf->{daemon}                || $DAEMON;
   $BPF            = $conf->{bpfilter}              || $BPF;
   $OS_SYNACK      = $conf->{os_synack_fingerprint} || $OS;
   $OS_SYN         = $conf->{os_syn_fingerprint}    || $OS;
   $OS_UDP         = $conf->{os_udp_fingerprint}    || $OS;
   $ICMP           = $conf->{icmp}                  || $ICMP;
   $OS_ICMP        = $conf->{os_icmp}               || $OS_ICMP;
   $LOGFILE        = $conf->{log_file}              || $LOGFILE;
   $PIDFILE        = $conf->{pid_file}              || $PIDFILE;
   $PRADS_HOSTNAME = $conf->{hostname}              || $PRADS_HOSTNAME;
   $PERSIST        ||= $conf->{persist};
}
default_config($conf);

$OS = 1 if ($OS_SYNACK == 1 || $OS_SYN ==1 );
$UDP = 1 if ($SERVICE_UDP != 1 || $OS_UDP != 1);

# commandline overrides config & defaults
Getopt::Long::GetOptions(
    'config|c=s'             => \$CONFIG,
    'confdir|cd=s'             => \$CONFDIR,
    'dev|d=s'                => \$DEVICE,
    'iface|i=s'              => \$DEVICE,
    'service-signatures|s=s' => \$S_SIGNATURE_FILE,
    'os-fingerprints|o=s'    => \$OS_SYN_FINGERPRINT_FILE,
    'debug=s'                => \$DEBUG,
    'dumpdb'                 => \$DUMPDB,
    'verbose'                => \$DEBUG,
    'dump'                   => \$DUMP,
    'daemon'                 => \$DAEMON,
    'arp'                    => \$ARP,
    'service-tcp'            => \$SERVICE_TCP,
    'service-udp'            => \$SERVICE_UDP,
    'os'                     => \$OS,
    'db=s'                   => \$DATABASE,
    # bpf filter
);
# if 2nd config file specified, load that one too
if ($C_INIT ne $CONFIG){
    load_config("$CONFIG");
}

################################################################################
############# M - A - I - N ####################################################
################################################################################

my $PRADS_START = time;

if ($DUMP) {
   print "\n ##### Dumps all signatures and fingerprints then exits ##### \n";

   print "Loading UDP fingerprints\n" if ($DEBUG>0);
   my $UDP_SIGS = load_os_udp_fingerprints($OS_UDP_FINGERPRINT_FILE);
   print Dumper $UDP_SIGS;

   print "Loading ICMP fingerprints\n" if ($DEBUG>0);
   my $ICMP_SIGS = load_os_icmp_fingerprints($OS_ICMP_FINGERPRINT_FILE);
   print Dumper $ICMP_SIGS;

   print "Loading MAC fingerprints\n" if ($DEBUG>0);
   my $MAC_SIGS = load_mac($MAC_SIGNATURE_FILE);
   print Dumper $MAC_SIGS;

   print "\n *** Loading OS SYN fingerprints *** \n\n";
   my $OS_SYN_SIGS = load_os_syn_fingerprints($OS_SYN_FINGERPRINT_FILE);
   print Dumper $OS_SYN_SIGS;

   print "\n *** Loading OS SYNACK fingerprints *** \n\n";
   my $OS_SYNACK_SIGS = load_os_syn_fingerprints($OS_SYNACK_FINGERPRINT_FILE);
   print Dumper $OS_SYN_SIGS;

   print "\n *** Loading Service signatures *** \n\n";
   my @TCP_SERVICE_SIGNATURES = load_signatures($S_SIGNATURE_FILE);
   print Dumper @TCP_SERVICE_SIGNATURES;

   print "\n *** Loading MTU signatures *** \n\n";
   my $MTU_SIGNATURES = load_mtu($MTU_SIGNATURE_FILE);
   print Dumper $MTU_SIGNATURES;

   exit 0;
}

# Signal handlers
use vars qw(%sources);
$SIG{"HUP"}   = \&prepare_stats_dump;
$SIG{"INT"}   = sub { game_over() };
$SIG{"TERM"}  = sub { game_over() };
$SIG{"QUIT"}  = sub { game_over() };
$SIG{"KILL"}  = sub { game_over() };
$SIG{"ALRM"}  = sub { if($PERSIST) { asset_db(); commit_db(); } alarm $TIMEOUT; };

#$SIG{"CHLD"} = 'IGNORE';

warn "Starting prads.pl...\n";

warn "Loading OS fingerprints\n" if ($DEBUG>0);
my $OS_SYN_SIGS = load_os_syn_fingerprints($OS_SYN_FINGERPRINT_FILE)
              or Getopt::Long::HelpMessage();
my $OS_SYNACK_SIGS;
if ($OS_SYNACK) {
    $OS_SYNACK_SIGS = load_os_syn_fingerprints($OS_SYNACK_FINGERPRINT_FILE)
              or Getopt::Long::HelpMessage();
}

my $OS_SYN_DB = {};

warn "Loading MAC fingerprints\n" if ($DEBUG>0);
my $MAC_SIGS = load_mac($MAC_SIGNATURE_FILE);

warn "Loading MTU fingerprints\n" if ($DEBUG>0);
my $MTU_SIGNATURES = load_mtu($MTU_SIGNATURE_FILE);

warn "Loading ICMP fingerprints\n" if ($DEBUG>0);
my $ICMP_SIGS = load_os_icmp_fingerprints($OS_ICMP_FINGERPRINT_FILE);

warn "Loading UDP fingerprints\n" if ($DEBUG>0);
my $UDP_SIGS = load_os_udp_fingerprints($OS_UDP_FINGERPRINT_FILE);

warn "Initializing device\n" if ($DEBUG>0);
warn "Using $DEVICE\n" if $DEVICE;
$DEVICE = init_dev($DEVICE)
          or Getopt::Long::HelpMessage();

warn "Loading TCP Service signatures\n" if ($DEBUG>0);
my @TCP_SERVICE_SIGNATURES = load_signatures($S_SIGNATURE_FILE)
                 or Getopt::Long::HelpMessage();

warn "Loading UDP Service signatures\n" if ($DEBUG>0);
# Currently loading the wrong sig file :)
my @UDP_SERVICE_SIGNATURES = load_signatures($S_SIGNATURE_FILE)
                 or Getopt::Long::HelpMessage();

warn "Setting up database ". $DATABASE ."\n" if $PERSIST and ($DEBUG > 0);
$OS_SYN_DB = setup_db($DATABASE,$DB_USERNAME,$DB_PASSWORD) if $PERSIST;

warn "Creating object\n" if ($DEBUG>0);
my $PCAP = create_object($DEVICE);

warn "Compiling Berkeley Packet Filter\n" if ($DEBUG>0);
filter_object($PCAP);

# Preparing stats
my %info = ();
my %stats = ();
Net::Pcap::stats ($PCAP, \%stats);
$stats{"timestamp"} = time;
my $inpacket = my $dodump = 0;

# Prepare to meet the Daemon
print "Daemon: $DAEMON, PWD: ".`pwd`."\n";
if ( $DAEMON ) {
        print "Daemonizing...\n";
        chdir ("/") or die "chdir /: $!\n";
        open (STDIN, "/dev/null") or die "open /dev/null: $!\n";
        open (STDOUT, "> $LOGFILE") or die "open > /dev/null: $!\n";
        defined (my $dpid = fork) or die "fork: $!\n";
        if ($dpid) {
                # Write PID file
                open (PID, "> $PIDFILE") or die "open($PIDFILE): $!\n";
                print PID $dpid, "\n";
                close (PID);
                exit 0;
        }
        setsid ();
        open (STDERR, ">&STDOUT");
}

alarm $TIMEOUT if not $AUTOCOMMIT;
warn "Looping over object\n" if ($DEBUG>0);
Net::Pcap::loop($PCAP, -1, \&packets, '') or die $ERROR{'loop'};

# If we ever should come into this state...
game_over();
exit;

################################################################################
############# F - U - N - C - T - I - O - N - S - ##############################
################################################################################

=head1 FUNCTIONS

=head2 setup_db

 Load persistent database

=cut

sub setup_db {
   my ($db,$user,$password) = @_;
   my $print_error = $DEBUG ? 1 : 0;
   my $dbh = DBI->connect($db,$user,$password,
                          {AutoCommit => $AUTOCOMMIT,
                          RaiseError => 1, PrintError=> $print_error});
   my ($sql, $sth);
   
   eval{
      if($DATABASE =~ /dbi:sqlite/i){
         print STDERR "Warning, SQLite schema deprecated. schema will change soon!\n".
         "planned changes to cols:\n".
         "ip -> ipaddress, fingerprint -> os_fingerprint, mac -> mac_address, ".
         "details->os_details, reporting -> hostname\n";
         $SQL_IP = 'ip';
         $SQL_FP = 'fingerprint';
         $SQL_MAC = 'mac';
         $SQL_TIME = 'time';
         $SQL_DETAILS = 'details';
         $SQL_HOSTNAME = 'reporting';
         $SQL_ATON = '?';
         $SQL_NTOA = '?';
         $sql = qq(
CREATE TABLE asset (
   $SQL_IP TEXT,
   service TEXT,
   time TEXT,
   $SQL_FP TEXT,
   $SQL_MAC TEXT,
   os TEXT,
   $SQL_DETAILS TEXT,
   link TEXT,
   distance TEXT,
   $SQL_HOSTNAME TEXT
););
      }elsif($DATABASE =~/dbi:mysql/i){
         $sql = qq(
CREATE TABLE IF NOT EXISTS `asset` (
   `assetID`        INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
   `hostname`       VARCHAR(255) NOT NULL default '',
   `sensorID`       INT UNSIGNED NOT NULL default '0',
   `timestamp`      DATETIME NOT NULL default '0000-00-00 00:00:00',
   `ipaddress`      decimal(39,0) unsigned default NULL,
   `mac_address`    VARCHAR(20) NOT NULL default '',
   `mac_vendor`     VARCHAR(50) NOT NULL default '',
   `os`             VARCHAR(20) NOT NULL default '',
   `os_details`     VARCHAR(255) NOT NULL default '',
   `os_fingerprint` VARCHAR(255) NOT NULL default '',
   `link`           VARCHAR(20) NOT NULL default '',
   `distance`       INT UNSIGNED NOT NULL default '0',
   `service`        VARCHAR(50) NOT NULL default '',
   `application`    VARCHAR(255) NOT NULL default '',
   `port`           INT UNSIGNED NOT NULL default '0',
   `protocol`       TINYINT UNSIGNED NOT NULL default '0',
   `hex_payload`    VARCHAR(255) default ''
) TYPE=InnoDB;
);
      }elsif($DATABASE =~ /^dbi:pg/i){
         $SQL_ATON = '?';
         $SQL_NTOA = '?';
         $sql = qq(
CREATE TABLE asset (
   -- assetID        INT NOT NULL AUTO_INCREMENT,
   assetID        INT NOT NULL default nextval('asset_id_seq'),
   hostname       TEXT default '',
   sensorID       INT NOT NULL default '0',
   timestamp      TIMESTAMP default NULL,
   --ipaddress      decimal(39,0) default NULL,
   ipaddress      inet default null,
   mac_address    VARCHAR(20) NOT NULL default '',
   mac_vendor     VARCHAR(50) NOT NULL default '',
   os             TEXT default '',
   os_details     TEXT default '',
   os_fingerprint TEXT default '',
   link           TEXT default '',
   distance       INT default '0',
   service        TEXT default '',
   application    TEXT default '',
   port           INT default '0',
   protocol       SMALLINT NOT NULL default '0',
   hex_payload    TEXT default '',
   --constraint uniq unique (ipaddress,port,protocol,service,application),
   --UNIQUE           KEY unique_row_key (ipaddress,port,protocol,service,application),
   --PRIMARY          KEY (sensorID,assetID),
   constraint prikey primary key (sensorID, assetID),
   CHECK (assetID>=0),
   CHECK (sensorID>=0),
   CHECK (distance>=0),
   CHECK (port>=0),
   CHECK (protocol >=0)
);
END;
);
      }
      $sth = $dbh->prepare($sql);
      $sth->execute;
   };
   $dbh->commit;

   if($DUMPDB){
      print STDERR "Issuing select * from asset;\n";
      $sql = "SELECT * from asset;";
      $sth = $dbh->prepare($sql) or die "foo $!";
      $sth->execute or die "$!";
      $sth->dump_results;
   }
   return $dbh;
}

=head2 packets

 Callback function for C<Net::Pcap::loop>.

  * Strip ethernet encapsulation of captured packet
  * pass to protocol handlers

=cut

sub packets {
    # Lock
    $inpacket = 1;

    my ($user_data, $header, $packet) = @_;
    $pradshosts{"tstamp"} = time;
    warn "Ethernet Packet received - processing...\n" if($DEBUG>50);
    my $eth      = NetPacket::Ethernet->decode($packet);

    # if VLAN Tag - strip VLANID
    if ( $eth->{type} == ETH_TYPE_802Q1T  ){
        (my $vid, $eth->{type}, $eth->{data}) = unpack('nna*' , $eth->{data});
    }
    # If VLAN MetroTag - strip MetroTag,TPID,VLANID
    elsif ( $eth->{type} == ETH_TYPE_802Q1MT ){
        (my $mvid, my $tpid, my $vid, $eth->{type}, $eth->{data}) = unpack('nnna*' , $eth->{data});
    }

    # Check if ARP
    if ($eth->{type} == ETH_TYPE_ARP) {
        warn "Packet is of type ARP...\n" if($DEBUG>50);
        if ($ARP == 1) {
            arp_check ($eth, $pradshosts{"tstamp"});
        }
        inpacket_dump_stats();
        return;
    }
    # Check if IP ( also ETH_TYPE_IPv6 ?)
    elsif ( $eth->{type} != ETH_TYPE_IP){
        warn "Not an IPv4 packet... Ethernet_type = $eth->{type} \n" if($DEBUG>50);
        inpacket_dump_stats();
        return;
    }

    # We should now have us an IP packet... good!
    #my $ethernet = NetPacket::Ethernet::strip($packet);
    #my $ip       = NetPacket::IP->decode($ethernet);
    my $ip       = NetPacket::IP->decode($eth->{data});

    # OS finger printing
    # Collect necessary info from IP packet; if
    my $ttl      = $ip->{'ttl'};
    my $ipopts   = $ip->{'options'}; # Not used in p0f
    my $len      = $ip->{'len'};     # total length of packet
    my $id       = $ip->{'id'};

    my $ipflags  = $ip->{'flags'};   # 2=dont fragment/1=more fragments, 0=nothing set
    my $df;
    if($ipflags == 2){
        $df = 1; # Dont fragment
    }else{
        $df = 0; # Fragment or more fragments
    }

    # Check if this is a TCP packet
    if($ip->{proto} == 6) {
      warn "Packet is of type TCP...\n" if($DEBUG>50);
      packet_tcp($ip, $ttl, $ipopts, $len, $id, $ipflags, $df);
      inpacket_dump_stats();
      return;
    }
    # Check if this is a ICMP packet
    elsif($ip->{proto} == 1) {
       warn "Packet is of type ICMP...\n" if($DEBUG>50);
       packet_icmp($ip, $ttl, $ipopts, $len, $id, $ipflags, $df) if $ICMP == 1;
       inpacket_dump_stats();
       return;
    }
    # Check if this is a UDP packet
    elsif ($ip->{proto} == 17) {
       warn "Packet is of type UDP...\n" if($DEBUG>50);
       packet_udp($ip, $ttl, $ipopts, $len, $id, $ipflags, $df);
       inpacket_dump_stats();
       return;
    }
    warn "Packet is of type $ip->{proto}...\n" if($DEBUG>50);
    inpacket_dump_stats();
    return;
}

=head2 packet_icmp

 Parse ICMP packet

=cut

sub packet_icmp {
    my ($ip, $ttl, $ipopts, $len, $id, $ipflags, $df) = @_;
    # Collect necessary info from ICMP packet
    my $icmp      = NetPacket::ICMP->decode($ip->{'data'});
    my $type = $icmp->{'type'};
    my $code = $icmp->{'code'};
#   my $cksum = $icmp->{'cksum'};
    my $data = $icmp->{'data'};

    my $src_ip = $ip->{'src_ip'};
    my $dst_ip = $ip->{'dest_ip'};
    my $flags  = $ip->{'flags'};
    my $foffset= $ip->{'foffset'};
    my $tos    = $ip->{'tos'};

    # We need to guess initial TTL
    my $gttl = normalize_ttl($ttl);
    my $dist = $gttl - $ttl;

    $ipopts = "." if not $ipopts;

    # Im not sure how IP should be printed :/
    # This is work under developtment :)
    if ($OS_ICMP == 1){
       # Highly fuzzy - need thoughts/input
       # asset database: want to know the following intel:
       # src ip, {OS,DETAILS}, service (port), timestamp, fingerprint
       # maybe also add binary IP packet for audit?
       my $link = 'ethernet';

       # Try to guess OS
       #print "TEST [$tos:$type,$code,$gttl,$df,$ipopts,$len,$ipflags,$foffset]\n";
       my ($os, $details, $fp) = icmp_os_find_match($type,$code,$gttl,$df,$ipopts,$len,$ipflags,$foffset,$tos);
       add_asset('ICMP', $src_ip, $fp, $dist, $link, $os, $details);
       return;
     }
     return;
}

=head2 packet_udp

 Parse UDP packet

=cut

sub packet_udp {
    return if $UDP != 1;

    my ($ip, $ttl, $ipopts, $len, $id, $ipflags, $df) = @_;

    # Collect necessary info from UDP packet
    my $udp       = NetPacket::UDP->decode($ip->{'data'});
    my $src_ip  = $ip->{'src_ip'};

    if ($SERVICE_UDP == 1) {
        #my $src_port  = $udp->{'src_port'};
        #my $data      = $udp->{'data'};
        #my $dest_port = $udp->{'dest_port'};
        #my $cksum     = $udp->{'cksum'};

        my $ulen      = $udp->{'len'};
        #my $data      = $udp->{'data'};
        my $foffset   = $ip->{'foffset'};

        # We need to guess initial TTL
        my $gttl = normalize_ttl($ttl);
        my $dist = $gttl - $ttl;

        $ipopts = "." if not $ipopts;
        my $fplen  = $len - $ulen;
        $fplen = 0 if $fplen < 0;
        my $link = 'ethernet';
        my $UOS = 'UNKNOWN';
        my $DETAILS = 'UNKNOWN';

        # Try to guess OS
        # Fingerprint format: $fplen,$ttl,$df,$io,$if,$fo
        my $oss = udp_os_find_match($fplen,$gttl,$df,$ipopts,$ipflags,$foffset);
        my ($os, $details) = %$oss if $oss;
        $os  = $os || $UOS;
        $details = $details || $DETAILS;
        add_asset('UDP', $src_ip, "$fplen:$gttl:$df:$ipopts:$ipflags:$foffset", $dist, $link, $os, $details);
    }
    # UDP SERVICE CHECK
    elsif ( (my $data = $udp->{'data'}) && $SERVICE_UDP == 1) {
       udp_service_check ($data,$src_ip,$udp->{'src_port'},$pradshosts{"tstamp"});
       return;
    }
    return;
}

=head2 packet_tcp

 Parse TCP packet
  * Decode contents of TCP/IP packet contained within captured ethernet packet
  * Search through the signatures, print dst host, dst port, and ID String.
  * Collect pOSf data : ttl,tot,orig_df,op,ocnt,mss,wss,wsc,tstamp,quirks
   # Fingerprint entry format:
   #
   # wwww:ttt:D:ss:OOO...:QQ:OS:Details
   #
   # wwww     - window size (can be * or %nnn or Sxx or Txx)
   #            "Snn" (multiple of MSS) and "Tnn" (multiple of MTU) are allowed.
   # ttt      - initial TTL
   # D        - don't fragment bit (0 - not set, 1 - set)
   # ss       - overall SYN packet size (* has a special meaning)
   # OOO      - option value and order specification (see below)
   # QQ       - quirks list (see below)
   # OS       - OS genre (Linux, Solaris, Windows)
   # details  - OS description (2.0.27 on x86, etc)

=cut

sub packet_tcp {
    my ($ip, $ttl, $ipopts, $len, $id, $ipflags, $df) = @_;
    # Collect necessary info from TCP packet; if
    my $tcp      = NetPacket::TCP->decode($ip->{'data'});
    my $winsize = $tcp->{'winsize'};
    my $tcpflags= $tcp->{'flags'};
    my $tcpopts = $tcp->{'options'};
    my $seq     = $tcp->{'seqnum'};
    my $ack     = $tcp->{'acknum'};
    my $urg     = $tcp->{'urg'};
    my $data    = $tcp->{'data'};
    my $reserved= $tcp->{'reserved'};
    my $src_port= $tcp->{'src_port'};
    my $dst_port= $tcp->{'dst_port'};

    # Check if SYN is set (both SYN and SYN+ACK)
    if ($OS == 1 && ($tcpflags & SYN)){
        warn "Initial connection... Detecting OS...\n" if($DEBUG>20);
        my ($optcnt, $scale, $mss, $sackok, $ts, $optstr, @quirks) = check_tcp_options($tcpopts);

        # big packets are packets of size > 100
        my $tot = ($len < 100)? $len : 0;

        # do we have an all-zero timestamp?
        my $t0 = (not defined $ts or $ts != 0)? 0:1;

        # parse rest of quirks
        my @new_quirks;
        push @new_quirks, check_quirks($id,$ipopts,$urg,$reserved,$ack,$tcpflags,$data,@quirks);
        # Some notes here - cording to p0f sigs, we are not displaying the quirks
        # in the right order.. 'P', 'T' and 'Z' would come before other quirks.
        # Etc, a normal Linux today would be: "ZAT"
        # While we will print "TZA"
        my $quirkstring = quirks_tostring(@new_quirks);

        my $src_ip = $ip->{'src_ip'};

        # debug info
        my $packet = "ip:$src_ip size=$len ttl=$ttl, DF=$df, ipflags=$ipflags, winsize=$winsize, tcpflags=$tcpflags, OC:$optcnt, WSC:$scale, MSS:$mss, SO:$sackok,T0:$t0, Q:$quirkstring O: $optstr ($seq/$ack) tstamp=" . $pradshosts{"tstamp"};
        print "OS: $packet\n" if($DEBUG > 2);

        # We need to guess initial TTL
        my $gttl = normalize_ttl($ttl);
        my $dist = $gttl - $ttl;

        my $wss = normalize_wss($winsize, $mss);
        my $fpstring = "$wss:$gttl:$df:$tot:$optstr:$quirkstring";

        # TODO: make a list of previously matched OS'es (NAT ips) and
        # check on $db->{$ip}->{$fingerprint}

        my ($sigs, $type, $link, $os, $details, @more);
        if ($tcpflags & ACK) {
            if ($OS_SYNACK) {
                $sigs = $OS_SYNACK_SIGS;
                $type = 'SYNACK';
            }
        } else {
            $type = 'SYN';
            $sigs = $OS_SYN_SIGS;
        }
        if(defined($sigs)){
            ($os, $details, @more) = tcp_os_find_match($sigs,
                                $tot, $optcnt, $t0, $df,\@new_quirks, $mss, $scale,
                                $winsize, $gttl, $optstr, $src_ip, $fpstring);
            # Get link type
            $link = get_mtu_link($mss);
            # asset database: want to know the following intel:
            # src ip, {OS,DETAILS}, service (port), timestamp, fingerprint
            # maybe also add binary IP packet for audit?
            add_asset($type, $src_ip, $fpstring, $dist, $link, $os, $details, @more);
        }
    }

    ### SERVICE: DETECTION
    ### Can also do src/dst_port
    if ($tcp->{'data'} && $SERVICE_TCP == 1) {
       # Check content(TCP data) against signatures
       warn "TCP service matching...\n" if $DEBUG >50;
       tcp_service_check ($tcp->{'data'},$ip->{'src_ip'},$tcp->{'src_port'},$pradshosts{"tstamp"});
    }
    return;
}

=head2 match_opts

 Function to match options

=cut

sub match_opts {
    my ($o1, $o2) = @_;
    my @o1 = split /,/,$o1;
    my @o2 = split /,/,$o2;
    for(@o1){
        print "$_:$o2[0]\n" if $DEBUG & 8;
        if(/([MW])(\d*|\*)/){
            if(not $o2[0] =~ /$1($2|\*)/){
                print "$o2[0] != $1$2\n" if $DEBUG > 1;
                return 0;
            }
        }elsif($_ ne $o2[0]){
            return 0;
        }
        shift @o2;
    }
    return @o2 == 0;
}

=head2 tcp_os_find_match

 port of p0f find_match()
 # WindowSize : InitialTTL : DontFragmentBit : Overall Syn Packet Size : Ordered Options Values : Quirks : OS : Details

 returns: ($os, $details, [...])
 or undef on fail

 for each signature in db:
  match packet size (0 means >= PACKET_BIG (=200))
  match tcp option count
  match zero timestamp
  match don't fragment bit (ip->off&0x4000!= 0)
  match quirks

  check MSS (mod or no)
  check WSCALE

  -- do complex windowsize checks
  -- match options
  -- fuzzy match ttls

  -- do NAT checks
  == dump unknow packet

  TODO:
    NAT checks, unknown packets, error handling, refactor
=cut

sub tcp_os_find_match{
# Port of p0f matching code
    my ($sigs, $tot, $optcnt, $t0, $df, $qq, $mss, $scale, $winsize, $gttl, $optstr, $ip, $fp) = @_;
    my @quirks = @$qq;

    my $guesses = 0;

    #warn "Matching $packet\n" if $DEBUG;
    #sigs ($ss,$oc,$t0,$df,$qq,$mss,$wsc,$wss,$oo,$ttl)
    my $matches = $sigs;
    my $j = 0;
    my @ec = ('packet size', 'option count', 'zero timestamp', 'don\'t fragment bit');
    for($tot, $optcnt, $t0, $df){
        if($matches->{$_}){
            $matches = $matches->{$_};
            #print "REDUCE: $j:$_: " . Dumper($matches). "\n";
            $j++;

        }else{
            print "ERR: $ip [$fp] Packet has no match for $ec[$j]:$_\n" if $DEBUG > 0;
            return;
        }
    }
    # we should have $matches now.
    warn "ERR: $ip [$fp] No match in fp db, but should have a match.\n" and return if not $matches;

    #print "INFO: p0f tot:oc:t0:frag match: " . Dumper($matches). "\n";
    if(not @quirks) {
        $matches = $matches->{'.'};
        warn "ERR: $ip [$fp] No quirks match.\n" and return if not defined $matches;
    }else{
        my $i;
        for(keys %$matches){
            my @qq = split //;
            next if @qq != @quirks;
            $i = 0;
            for(@quirks){
                if(grep /^$_$/,@qq){
                    $i++;
                }else{
                    #next;
                    last;
                }
            }
            $matches = $matches->{$_} and last if $i == @quirks;
        }
        warn "ERR: $ip [$fp]  No quirks match\n" and return if not $i;
    }
    #print "INFO: p0f quirks match: " . Dumper( $matches). "\n";

    # Maximum Segment Size
    my @mssmatch = grep {
       (/^\%(\d)*$/ and ($mss % $_) == 0) or
       (/^(\d)*$/ and $mss eq $_) or
       ($_ eq '*')
    } keys %$matches;
    #print "INFO: p0f mss match: " . Dumper(@mssmatch). "\n";
    warn "ERR: $ip [$fp] No mss match in fp db.\n" and return if not @mssmatch;

    # WSCALE. There may be multiple simultaneous matches to search beyond this point.
    my (@wmatch,@fuzmatch);
    for my $s (@mssmatch){
        for my $wsc ($scale, '*'){
            my $t = $matches->{$s}->{$wsc};
            next if not $t;

            # WINDOWSIZE
            for my $wss (keys %$t){
                #print "INFO: wss:$winsize,$_, " . Dumper($t->{$_}) ."\n";
                if( ($wss =~ /S(\d*)/ and $1*$mss == $winsize) or
                    ($wss =~ /M(\d*)/ and $1*($mss+40) == $winsize) or
                    ($wss =~ /%(\d*)/ and $winsize % $1 == 0) or
                    ($wss eq $winsize) or
                    ($wss eq '*')
                  ){
                    push @wmatch, $t->{$wss};
                }else{
                    push @fuzmatch, $t->{$wss};
                }
            }
        }
    }
    if(not @wmatch and @fuzmatch){
        $guesses++;
        @wmatch = @fuzmatch;
    }
    if(not @wmatch){
        print "$pradshosts{tstamp} $ip [$fp] Closest matches: \n" if $DEBUG > 0;
        for my $s (@mssmatch){
            print Data::Dumper->Dump([$matches->{$s}],["MSS$s"]) if $DEBUG >0;
        }

        return;
    }
    #print "INFO: wmatch: " . Dumper(@wmatch) ."\n";

    # TCP option sequence
    my @omatch;
    for my $h (@wmatch){
        for(keys %$h){
            #print "INFO: omatch:$optstr:$_ " .Dumper($h->{$_}) ."\n";
            push @omatch, $h->{$_} and last if match_opts($optstr,$_);
        }
    }
    if(not @omatch){
        print "$pradshosts{tstamp} $ip [$fp] Closest matches: \n";
        print Data::Dumper->Dump([@wmatch],["WSS"]);
        return;
    }

    my @os;
    for(@omatch){
        my $match = $_->{$gttl};
        if(not $match and $gttl < 255){
            # re-normalize ttl, machine may be really distant
            # (over ttl/2 hops away)
            my $ttl = normalize_ttl($gttl+1);
            #print "Re-adjusted ttl from $gttl to $ttl\n" if $ttl != 64;
            $match = $_->{$ttl};
        }
        #print "INFO: omatch: " .Dumper($match) ."\n";
        if($match){
            for(keys %$match){
                push @os, ($_, $match->{$_});
            }
        }
    }
    if(not @os){
        print "$pradshosts{tstamp} $ip [$fp] Closest matches: \n" if $DEBUG > 0;
        print Data::Dumper->Dump([@omatch],["TTL"]) if $DEBUG > 0;
        return;
    }

    # if we have non-generic matches, filter out generics
    my $skip = 0;
    my @filtered;

    # loop through to check for non-generics
    my ($os, $details, @more) = @os;
    while($os){
        if($os =~ /^[^@]/){
            $skip++;
            last;
        }
        ($os, $details, @more) = @more;
    }
    # filter generics
    ($os, $details, @more) = @os;
    do{
        if(not ($skip and $os =~ /^@/)){
            push @filtered, ($os, $details);
        }
        ($os, $details, @more) = @more;
    }while($os);
    return @filtered;
}

=head2 check_quirks

 # Parse most quirks.
 # quirk P (opts past EOL) and T(non-zero 2nd timestamp) are implemented in
 # check_tcp_options, where it makes most sense.
 # TODO: '!' : broken opts (?)

=cut

sub check_quirks {
    my ($id,$ipopts,$urg,$reserved,$ack,$tcpflags,$data,@old_quirks) = @_;
    my @quirks;
    # Etc, a normal Linux today would be: "ZAT"
    # While we will print "TZA"

    for(@old_quirks){
        if($_ =~ /P/) {
            push @quirks, 'P'
        }
    }
    push @quirks, 'Z' if not $id;
    push @quirks, 'I' if $ipopts;
    push @quirks, 'U' if $urg;
    push @quirks, 'X' if $reserved;
    push @quirks, 'A' if $ack;
    push @quirks, 'F' if $tcpflags & ~(SYN|ACK);
    push @quirks, 'D' if $data;

    for(@old_quirks){
        if($_ =~ /T/) {
            push @quirks, 'T'
        }
        if($_ =~ /!/) {
            push @quirks, '!';
        }
    }

    return @quirks;
}

=head2 quirks_tostring

 Function to make quirks into a string.

=cut

sub quirks_tostring {
    my @quirks = @_;
    my $quirkstring = '';
    for(@quirks){
        $quirkstring .= $_;
    }
    $quirkstring = '.' if not @quirks;
    return $quirkstring;
}

=head2 check_tcp_options

 Takes tcp options as input, and returns which args are set.

 Input format:
 $tcpoptions

 Output format.
 ($count, $scale, $mss, $sackok, $ts, $optstr, $quirks);

=cut

sub check_tcp_options{
   # NetPacket::IP->decode gives us binary opts
   # so get the interesting bits here
   my ($opts) = @_;
   my ($scale, $mss, $sackok, $ts, $t2) = (0,undef,0,undef,0);
   print "opts: ". unpack("B*", $opts)."\n" if $DEBUG & 8;
   my ($kind, $rest, $size, $data, $count) = (0,0,0,0,0);
   my $optstr = '';
   my @quirks;
   while (length $opts){
      ($kind, $rest) = unpack("C a*", $opts);
      #$kind = vec $opts, 0, 8;
      #$rest = substr $opts, 8;
      last if not length $kind;
      $count++;
      if($kind == 0){
         print "EOL\n" if $DEBUG & 8;
         $optstr .= "E,";
         # quirk if opts past EOL
         push @quirks, 'P' if length $rest;
         #last;
      }elsif($kind == 1){
         # NOP
         print "NOP\n" if $DEBUG & 8;
         $optstr .= "N,";
      }else{
         ($size, $rest) = unpack("C a*", $rest);

         # Sanity check!
         $size = $size - 2;
         if($size > length $rest){
            print "hex broken options: ". unpack("H*", $rest)."\n";
            push @quirks, '!';
            last;
         }
         #($data, $rest) = unpack "C${size}a", $rest;
         if($kind == 2){
            ($mss, $rest) = unpack("n a*", $rest);
            $optstr .= "M$mss,";
            print "$size MSS: $mss\n" if $DEBUG & 8;
         }elsif($kind == 3){
            ($scale, $rest) = unpack("C a*", $rest);
            $optstr .= "W$scale,";
            print "WSOPT$size: $scale\n" if $DEBUG & 8;
         }elsif($kind == 4){
            # allsacks are OK.
            $optstr .= "S,";
            print "SACKOK\n" if $DEBUG & 8;
            $sackok++;
         }elsif($kind == 8){
            # Timestamp.
            # Fields: TSTAMP LEN T0 T1 T2 T3 A0 A1 A2 A3
            # T(0-3) = our timestamp...
            # A(0-3) = Acked timestamp (the ts of the recieved package)
            # See http://tools.ietf.org/html/rfc1323 :
            # Kind: 8
            # Length: 10 bytes
            #  +-------+-------+---------------------+---------------------+
            #  |Kind=8 |  10   |   TS Value (TSval)  |TS Echo Reply (TSecr)|
            #  +-------+-------+---------------------+---------------------+
            #      1       1              4                     4
            # The Timestamp Echo Reply field (TSecr) is only valid if the ACK
            # bit is set in the TCP header; if it is valid, it echos a times-
            # tamp value that was sent by the remote TCP in the TSval field
            # of a Timestamps option.  When TSecr is not valid, its value
            # must be zero.
            my ($c, $t, $ter, $tsize) = (0,0,0,$size);
            ($t, $ter, $rest) = unpack("NN a*", $rest);
            ## while($tsize > 0){
               ## ($c, $rest) = unpack("C a*", $rest);
               ## # hack HACK: ts is 64bit and wraps our 32bit perl ints.
               ## # it's ok tho: we don't care what the value is, as long as it's not 0
               ## $t <<= 1;
               ## $t |= $c;
               ## $tsize--;
            ##}
            print "TSLen: $c\n" if $DEBUG & 8;
            print "TSval: $t\n" if $DEBUG & 8;
            print "TSecr: $ter\n" if $DEBUG & 8;
            print "TS$size: $t\n" if $DEBUG & 8;
            if($t != 0){
               $optstr .= "T,";
               $ts = $t;
            }else{
               $optstr .= "T0,";
            }
            #if(defined $ts and $t){ 
            if(defined $ter and $ter > 0){
               # non-zero second timestamp
               # This is only cool on a syn packet.. 
               # as a syn+ack it depends on the syn, see rfc1323 
               push @quirks, 'T';
            } #else{
              # $ts = $t;
            #}
         }else{
            # unrecognized
            # option 76: (weird router shit)
            # eg: 4c 0a 0101ac1438060005 01 00
            #     K  SZ ------WEIRD-----NOP EOL
            # option  5: (SACK field)
            $optstr .= "?$kind,";
            print "hex weird options: ". unpack("H*", $rest)."\n";
            #($rest) = eval unpack("x$size a*", $rest) or print "unpack:$!";
            # apparently skipping bytes with x$size is a no-go
            $rest = substr $rest, $size;
         }
         print "rest: ". unpack("B*", $rest)."\n" if $DEBUG & 8;
      }
      $opts = $rest;
      last if not defined $opts;
   }
   chop $optstr;
   $optstr = '.' if $optstr eq '';

   # MSS may be undefined
   $mss = '*' if not $mss;

   return ($count, $scale, $mss, $sackok, $ts, $optstr, @quirks);
}

=head2 icmp_os_find_match

 Try to match OS from IP/ICMP package
 input: $fpstring = "$type:$code:$gttl:$df:$ipopts:$len:$ipflags:$foffset";
 returns: ($OS)
 or undef on fail

=cut

sub icmp_os_find_match {
    my ($itype,$icode,$ttl,$df,$io,$il,$if,$fo,$tos) = @_;
    my $IOS = 'UNKNOWN';
    my $DETAILS = 'UNKNOWN';
    my $ipopts = $io;
    my $ifp = "$itype:$icode:$ttl:$df:$ipopts:$il:$if:$fo:$tos";

    if($io eq '.'){
       $io = 0;
    }
    my $matches = $ICMP_SIGS;
    my $j = 0;
    # $itype,$icode,$il,$ttl,$df,$if,$fo,$io, $tos
    for($itype, $icode, $il, $ttl, $df, $if, $fo, $io, $tos){
       if($matches->{$_}){
          $matches = $matches->{$_};
          #print "REDUCE: $j:$_: " . Dumper($matches). "\n";
          $j++;
       }elsif($matches->{'*'}){
          $matches = $matches->{'*'};
          $_='*';
          $j++;
       }else{
          print "ERR: [$itype:$icode:$ttl:$df:$ipopts:$il:$if:$fo:$tos] Packet has no ICMP match for $j:$_\n" if $DEBUG;
          return ($IOS, $DETAILS, $ifp);
       }
    }

    my ($os, $details) = %$matches if $matches;
    $os  = $os || $IOS;
    $details = $details || $DETAILS;
    my $fp = "$itype:$icode:$ttl:$df:$ipopts:$il:$if:$fo:$tos";

    return ($os, $details, $fp);
}

=head2 udp_os_find_match

 Try to match OS from IP/UDP package
 input: $fpstring = "$type:$code:$gttl:$df:$ipopts:$len:$ipflags:$foffset";
 returns: ($OS)
 or undef on fail

=cut

sub udp_os_find_match {
    my ($fplen,$ttl,$df,$io,$if,$fo) = @_;
    if($io eq '.'){
       $io = 0;
    }
    my $matches = $UDP_SIGS;
    my $j = 0;
    # $fplen,$ttl,$df,$if,$fo,$io
    for($fplen,$ttl,$df,$if,$fo,$io){
       if($matches->{$_}){
          $matches = $matches->{$_};
          #print "REDUCE: $j:$_: " . Dumper($matches). "\n";
          $j++;
       }elsif($matches->{'*'}){
          $matches = $matches->{'*'};
       }else{
          print "ERR: [$fplen,$ttl,$df,$if,$fo,$io] Packet has no ICMP match for $j:$_\n" if $DEBUG;
          return;
       }
    }
    return ($matches);
}

=head2 load_signatures

 Loads signatures from file

 File format:
 <service>,<version info>,<signature>

 Example:
 www,v/Apache/$1/$2/,Server: Apache\/([\S]+)[\s]+([\S]+)

=cut

sub load_signatures {
    my $file = shift;
    my %signatures;

    open(my $FH, "<", $file) or die "Could not open '$file': $!";

    LINE:
    while (my $line = readline $FH) {
        chomp $line;
        $line =~ s/\#.*//;
        next LINE unless($line); # empty line
        # One should check for a more or less sane signature file.
        my($service, $version, $signature) = split /,/, $line, 3;

        $version =~ s"^v/"";
        #print "$line\n";
        $signatures{$signature} = [$service, qq("$version"), qr{$signature}];
    }

    return map { $signatures{$_} }
            sort { length $b <=> length $a }
             keys %signatures;
}

=head2 load_mtu

 Loads MTU signatures from file

 File format:
 <MTU>,<info>

 Example:
 1492,"pppoe (DSL)"

=cut

sub load_mtu {
    my $file = shift;
    my $signatures = {};

    open(my $FH, "<", $file) or die "Could not open '$file': $!";

    LINE:
    while (my $line = readline $FH) {
        chomp $line;
        $line =~ s/\#.*//;
        next LINE unless($line); # empty line
        # One should check for a more or less sane signature file.
        my($mtu, $info) = split /,/, $line, 2;
        $info =~ s/^"(.*)" ?/$1/;
        $signatures->{$mtu} = $info;
    }
    return $signatures;
}

=head2 load_mac

 Loads MAC signatures from file

 File format:
 AB:CD:EE   Vendor   # DETAILS

 hash->{'byte'}->{'byte'}->...

 on conflicts, if we have two sigs
 00-E0-2B          Extreme
 00-E0-2B-00-00-01 Extreme-EEP
 hash->{00}->{E0}->{2B}->{00}->{00}->{01} = Extreme-EEP
 hash->{00}->{E0}->{2B}->{_} = Extreme

 if you know of a more efficient way of looking up these things,
     look me up and we'll discuss it. - kwy

=cut

sub load_mac {
    my $file = shift;
    my $signatures = {};

    open(my $FH, "<", $file) or die "Could not open '$file': $!";

    LINE:
    while (my $line = readline $FH) {
        chomp $line;
        $line =~ s/^\s*\#.*//;
        next LINE unless($line); # empty line

        # One should check for a more or less sane signature file.
        my($mac, $info, $details) = split /\s/, $line, 3;
        $details ||= '';
        $details =~ /\# (.*)$/;
        $details = $1;
        $details ||= $info;

        # handle mac bitmask (in)sanely
        my ($prefix, $mask) = split /\//, $mac, 2;
        $mask ||= 48;

        # chop off bytes outside of bitmask
        # Sigs of the form 00:50:C2:00:70:00/36
        # become $s->{00}->{50}->{C2}->{00}->{70/4}
        my ($max, $rem) = (int($mask / 8)+1, $mask % 8);
        my @bytes = split /[:\.\-]/, $prefix;
        $max = ($max > @bytes)? @bytes: $max;
        splice @bytes, $max;

        # create remainder mask for last byte
        if($rem){
            if($max == @bytes){
                push(@bytes, sprintf "%s/%d", pop @bytes, $rem);
            }else{
                push @bytes, sprintf "00/%d", $rem;
            }
        }
        my $ptr = $signatures;
        for my $i (0..@bytes-1){
            my $byte = lc $bytes[$i];
            $ptr->{$byte} ||= {};
            if(not ref $ptr->{$byte}){
                $ptr->{$byte} = { _ => $ptr->{$byte} };
            }
            if($i == @bytes-1){
                if($ptr->{$byte}->{_}){
                    print "XXX: $info $mac crashes with ".Dumper($ptr->{$byte}->{_});
                    last;
                }
                $ptr->{$byte}->{_} = [$mac, $info, $details];
                last;
            }
           $ptr = $ptr->{$byte};
        }

    }
    return $signatures;
}

=head2 mac_byte_mask

 Match a byte with a byte/mask

 meditate:
 perl -e 'print unpack("b8", pack("H2","08") | pack("h2", '02'))'
 01010000

 byte & mask == $key
 except mask is bigendian while byte is littleendian

=cut

sub mac_byte_mask {
   my ($byte, $mask) = @_;

   my ($key, $bits) = split /\//, $mask, 2;
   my $shift = 8-$bits;
   return (hex($byte) >> $shift == hex($key) >> $shift);
}

=head2 mac_map_mask

 check if $byte matches any mask in $ptr

 for all keys with a slash in them
   check that byte matches key/mask
   return $ptr->{key}

=cut

sub mac_map_mask {
   my ($byte, $ptr) = @_;
   map { return $ptr->{$_}->{_} }
   grep { /\// and mac_byte_mask($byte,$_)} keys %$ptr;
}

=head2 mac_find_match

 Match the MAC address with our vendor prefix hash.

=cut

sub mac_find_match {
    my ($mac,$ptr) = @_;
    $ptr ||= $MAC_SIGS;

    my ($byte, $rest) = split /[:\.-]/, $mac,2;
    if(ref $ptr->{$byte}){
        #print "recurse\n";
        return
            # most specific match first (recurse)
            mac_find_match($rest,$ptr->{$byte}) ||
            # see if this node has a complete match
            $ptr->{$byte}->{_} ||
            # match on bitmask
            mac_map_mask($byte,$ptr);
    }else{
       # node leads to a leaf.
       return $ptr->{$byte} || mac_map_mask($byte, $ptr);
    }
}

=head2 load_os_syn_fingerprints

 Loads SYN signatures from file
 optimize for lookup matching

 if you know of a more efficient way of looking up these things,
 look me up and we'll discuss it. -kwy

=cut

sub load_os_syn_fingerprints {
    my @files = @_;
    # Fingerprint entry format:
    # WindowSize : InitialTTL : DontFragmentBit : Overall Syn Packet Size : Ordered Options Values : Quirks : OS : Details
    #my $re   = qr{^ ([0-9%*()ST]+) : (\d+) : (\d+) : ([0-9()*]+) : ([^:]+) : ([^\s]+) : ([^:]+) : ([^:]+) }x; # suuure, validate this!
    my $rules = {};
    for my $file (@files) {
       open(my $FH, "<", $file) or die "Could not open '$file': $!";

       my $lineno = 0;
       while (my $line = readline $FH) {
          $lineno++;
          chomp $line;
          $line =~ s/\#.*//;
          next unless($line); # empty line

          my @elements = split/:/,$line;
          unless(@elements == 8) {
             die "Error: Not valid fingerprint format in: '$file'";
          }
          my ($wss,$ttl,$df,$ss,$oo,$qq,$os,$detail) = @elements;
          my $oc = 0;
          my $t0 = 0;
          my ($mss, $wsc) = ('*','*');
          if($oo eq '.'){
             $oc = 0;
          }else{
             my @opt = split /[, ]/, $oo;
             $oc = scalar @opt;
             for(@opt){
                if(/([MW])([\d%*]*)/){
                    if($1 eq 'M'){
                        $mss = $2;
                    }else{
                        $wsc = $2;
                    }
                }elsif(/T0/){
                    $t0 = 1;
                }
            }
        }

        my($details, $human) = splice @elements, -2;
        my $tmp = $rules;

        for my $e ($ss,$oc,$t0,$df,$qq,$mss,$wsc,$wss,$oo,$ttl){
            $tmp->{$e} ||= {};
            $tmp = $tmp->{$e};
        }
        if($tmp->{$details}){
            print "$file:$lineno:Conflicting signature: '$line' overwrites earlier signature '$details:$tmp->{$details}'\n\n" if ($DEBUG);
        }
        $tmp->{$details} = $human;
       }
    }# for files loop
    return $rules;
}

=head2 load_os_udp_fingerprints

 Loads UDP OS signatures from file
 optimize for lookup matching

=cut

sub load_os_udp_fingerprints {
    # Format 20:64:1:.:2:0:@Linux:2.6
    # $fplen:$gttl:$df:$ipopts:$ipflags:$foffset:$os:$details
    my @files = @_;
    my $rules = {};
    for my $file (@files) {
       open(my $FH, "<", $file) or die "Could not open '$file': $!";

       my $lineno = 0;
       while (my $line = readline $FH) {
          $lineno++;
          chomp $line;
          $line =~ s/\#.*//;
          next unless($line); # empty line

          my @elements = split/:/,$line;
          unless(@elements == 8) {
             die "Error: Not valid fingerprint format in: '$file'";
          }
          # Sanitize from here and down... Examples of UDP sigs we see:
          # $fplen:$gttl:$df:$ipopts:$ipflags:$foffset:$os:$details
          # 20:128:0:.:0:0
          # 20:128:1:.:2:0
          # 20:255:0:.:0:0
          # 20:255:1:.:2:0
          # 20:32:0:.:0:0
          # 20:64:0:.:0:0
          # 20:64:1:.:2:0
          # Strange:
          # 0:64:0:.:1:1480

          my ($fplen,$ttl,$df,$io,$if,$fo,$os,$detail) = @elements;
          if($io eq '.'){
             $io = 0;
          }
          my($details, $human) = splice @elements, -2;
          my $tmp = $rules;
          for my $e ($fplen,$ttl,$df,$if,$fo,$io){
              $tmp->{$e} ||= {};
              $tmp = $tmp->{$e};
          }
          if($tmp->{$details}){
              print "$file:$lineno:Conflicting signature: '$line' overwrites earlier signature '$details:$tmp->{$details}'\n\n" if ($DEBUG);
          }
          $tmp->{$details} = $human;
       }
    }# for files loop
    return $rules;
}

=head2 load_os_icmp_fingerprints

 Loads icmp os fingerprints from file
 optimize for lookup matching

=cut

sub load_os_icmp_fingerprints {
    # Format 8:0:64:1:.:84:2:0:*:@Linux:2.6
    # icmp_type:icmp_code:initial_ttl:dont_fragment:ip_options:ip_length:ip_flags:fragment_offset:ip_TOS
    my @files = @_;
    my $rules = {};
    for my $file (@files) {
       open(my $FH, "<", $file) or die "Could not open '$file': $!";

       my $lineno = 0;
       while (my $line = readline $FH) {
          $lineno++;
          chomp $line;
          $line =~ s/\#.*//;
          next unless($line); # empty line

          my @elements = split/:/,$line;
          unless(@elements == 11) {
             die "Error: Not valid fingerprint format in: '$file'";
          }
          # Sanitize from here and down...
          my ($itype,$icode,$ttl,$df,$io,$il,$if,$fo,$tos,$os,$detail) = @elements;
          if($io eq '.'){
             $io = 0;
          }

        my($details, $human) = splice @elements, -2;
        my $tmp = $rules;

        for my $e ($itype,$icode,$il,$ttl,$df,$if,$fo,$io,$tos){
            $tmp->{$e} ||= {};
            $tmp = $tmp->{$e};
        }
        if($tmp->{$details}){
            print "$file:$lineno:Conflicting signature: '$line' overwrites earlier signature '$details:$tmp->{$details}'\n\n" if ($DEBUG);
        }
        $tmp->{$details} = $human;
       }
    }# for files loop
    return $rules;
}

=head2 init_dev

 Use network device passed in program arguments or if no
 argument is passed, determine an appropriate network
 device for packet sniffing using the
 Net::Pcap::lookupdev method

=cut

sub init_dev {
    my $dev = shift;
    my $err;

    unless (defined $dev) {
       $dev = Net::Pcap::lookupdev(\$err);
       die sprintf $ERROR{'init_dev'}, $err if defined $err;
    }

    return $dev;
}

=head2 lookup_net

 Look up network address information about network
 device using Net::Pcap::lookupnet - This also acts as a
 check on bogus network device arguments that may be
 passed to the program as an argument

=cut

sub lookup_net {
    my $dev = shift;
    my($err, $address, $netmask);

    Net::Pcap::lookupnet(
        $dev, \$address, \$netmask, \$err
    ) and die sprintf $ERROR{'lookup_net'}, $dev, $err;

    warn "lookup_net : $address, $netmask\n" if($DEBUG>0);
    return $address, $netmask;
}

=head2 create_object

 Create packet capture object on device

=cut

sub create_object {
    my $dev = shift;
    my($err, $object);
    my $promisc = 1;

    $object = Net::Pcap::open_live($dev, 65535, $promisc, 500, \$err)
              or die sprintf $ERROR{'create_object'}, $dev, $err;
    warn "create_object : $dev\n" if($DEBUG>0);
    return $object;
}

=head2 filter_object

 Compile and set packet filter for packet capture
 object - For the capture of TCP packets with the SYN
 header flag set directed at the external interface of
 the local host, the packet filter of '(dst IP) && (tcp
 [13] & 2 != 0)' is used where IP is the IP address of
 the external interface of the machine. Here we use 'tcp'
 as a default BPF filter.

=cut

sub filter_object {
    my $object = shift;
    my $filter;
    my $netmask = q(0);

    Net::Pcap::compile(
        $object, \$filter, $BPF, 0, $netmask
    ) and die $ERROR{'compile_object_compile'};

    Net::Pcap::setfilter($object, $filter)
        and die $ERROR{'compile_object_setfilter'};
    warn "filter_object : $filter\n" if($DEBUG>0);
}

=head2 normalize_wss

 Computes WSS respecive of MSS

=cut

sub normalize_wss {
    my ($winsize, $mss) = @_;
    my $wss = $winsize;
    if ($mss =~ /^[+-]?\d+$/) {
        if (not $winsize % $mss){
            $wss = $winsize / $mss;
            $wss = "S$wss";
        }elsif(not $winsize % ($mss +40)){
            $wss = $winsize / ($mss + 40);
            $wss = "T$wss";
        }
    }
    return $wss;
}

=head2 normalize_ttl

 Takes a ttl value as input, and guesses intial ttl

=cut

sub normalize_ttl {
    my $ttl = shift;
    my $gttl = 255;
    # Only aiming for 255,128,64,60,32. But some strange ttls like
    # 200,30 exist, but are rare
    $gttl = 255 if (($ttl >=  128) && (255  > $ttl));
    $gttl = 128 if ((128  >=  $ttl) && ($ttl >   64));
    $gttl =  64 if (( 64  >=  $ttl) && ($ttl >   32));
    $gttl =  32 if (( 32  >=  $ttl));
    return $gttl;
}

=head2 tcp_service_check

 Takes input: $tcp->{'data'}, $ip->{'src_ip'}, $tcp->{'src_port'}, $pradshosts{"tstamp"}
 Prints out service if found.

=cut

sub tcp_service_check {
    my ($tcp_data, $src_ip, $src_port,$tstamp) = @_;

    # Check content(tcp_data) against signatures
    SIGNATURE:
    for my $s (@TCP_SERVICE_SIGNATURES) {
        my $re = $s->[2];

        if($tcp_data =~ /$re/) {
            my($vendor, $version, $info) = split m"/", eval $s->[1];
            add_asset('SERVICE_TCP', $src_ip, $src_port, $vendor, $version, $info);
            last SIGNATURE;
        }
    }
}

=head2 udp_service_check

 Takes input: $udp->{'data'}, $ip->{'src_ip'}, $udp->{'src_port'}, $pradshosts{"tstamp"}
 Prints out service if found.

=cut

sub udp_service_check {
    my ($udp_data, $src_ip, $src_port,$tstamp) = @_;

       #warn "Detecting UDP asset...\n" if($DEBUG);
       if ($src_port == 53){
          add_asset('SERVICE_UDP', $src_ip, $src_port, "-","-","DNS");
       }
       elsif ($src_port == 1194){
          add_asset('SERVICE_UDP', $src_ip, $src_port, "OpenVPN","-","-");
       }
       else {
        warn "UDP ASSET DETECTION IS NOT IMPLEMENTED YET...\n" if($DEBUG>20);
       }

#    # Check content(udp_data) against signatures
#    SIGNATURE:
#    for my $s (@UDP_SERVICE_SIGNATURES) {
#        my $re = $s->[2];
#
#        if($udp_data =~ /$re/) {
#            my($vendor, $version, $info) = split m"/", eval $s->[1];
#            printf("SERVICE: ip=%s port=%i -> \"%s %s %s\" timestamp=%i\n",
#                $src_ip, $src_port,
#                $vendor  || q(),
#                $version || q(),
#                $info    || q(),
#                $tstamp || q()
#            );
#            last SIGNATURE;
#        }
#    }
}

=head2 arp_check

 Takes 'NetPacket::Ethernet->decode($packet)' and timestamp as input and prints out arp asset.

=cut

sub arp_check {
    my ($eth,$tstamp) = @_;

    my $arp = NetPacket::ARP->decode($eth->{data}, $eth);
    my $aip = $arp->{spa};
    my $h1 = hex(substr( $aip,0,2));
    my $h2 = hex(substr( $aip,2,2));
    my $h3 = hex(substr( $aip,4,2));
    my $h4 = hex(substr( $aip,6,2));
    my $ip = "$h1.$h2.$h3.$h4";

    my $ash = $arp->{sha};
    # more human readable
    # join(':', split(/([0-9a-fA-F][0-9a-fA-F])/, $ash);
    my $mac =
        substr($ash,0,2) .':'.
        substr($ash,2,2) .':'.
        substr($ash,4,2) .':'.
        substr($ash,6,2) .':'.
        substr($ash,8,2) .':'.
        substr($ash,10,2);
    my $matchref = mac_find_match($mac);
    my @match = ( );
    if(ref $matchref){
       @match = @{$matchref};
    }
    add_asset('ARP', $mac, $ip, @match);
    return;
}

=head2 get_mtu_link

 Takes MSS as input, and returns a guessed Link for that MTU.

=cut

sub get_mtu_link {
    my $mss = shift;
    my $link = "UNKNOWN";
    if ($mss =~ /^[+-]?\d+$/) {
       my $mtu = $mss + 40;
       if (my $link = $MTU_SIGNATURES->{ $mtu }) {return $link}
    }
    return $link;
}

=head2 load_config

 Reads the configuration file and loads variables.
 Takes the config file as input, and returns a hash of config options.

=cut

sub load_config {
    my $file = shift;
    my $config = {};
    if(not -r "$file"){
        warn "Config '$file' not readable\n";
        return $config;
    }
    open(my $FH, "<",$file) or die "Could not open '$file': $!\n";
    while (my $line = <$FH>) {
        chomp($line);
        $line =~ s/\#.*//;
        next unless($line); # empty line
        if (my ($key, $value) = ($line =~ m/(\w+)\s*=\s*(.*)$/)) {
           warn  "$key:$value\n" if $DEBUG > 0;
           $config->{$key} = $value;
        }else {
          die "Error: Not valid configfile format in: '$file'";
        }
    }
    close $FH;
    return $config;
}

=head2 add_db

 Add an asset record to the asset table;

# optimizations: $stm = "select foo from bar where baz = :baz"
# $sth->bind_param(':baz', $baz)
# in-mem db + persistence + merge records.

=cut
{
   # store prepared statements for re-execution
   my $h_select;
   my $h_update;
   my $h_insert;
   my $records;
   my $table;
sub add_db {
    my $db = $OS_SYN_DB;
    warn "Prads::add_db: ERROR: Database not set up, check prads.conf" and return if not $db;
    my ($ip, $service, $time, $fp, $mac, $os, $details, $link, $dist, $host) = @_;
    $table = 'asset';
    my $sql = "SELECT $SQL_IP,$SQL_FP,$SQL_TIME FROM $table WHERE service = ? AND $SQL_IP = $SQL_NTOA AND $SQL_FP = ?";
    #print "$sql,$ip,$service,$time,$fp,$mac,$os,$details,$link,$dist,$host\n" if $service eq 'ARP';

    # convert time() to timestamp
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday) = gmtime($time);
    $year += 1900;
    $mon += 1;
    $mday += 1;
    my $ftime = "$year-$mon-$mday $hour:$min:$sec";

    $h_select = $db->prepare_cached($sql) or die "Failed:$!" if not $h_select;
    $h_select->execute($service, $ip, $fp);
    my ($o_ip, $o_fp, $o_time) = $h_select->fetchrow_array();

    # update record if fp matches, otherwise insert
    # XXX: link, distance may have changed
    if($o_time){
       $h_update = $db->prepare_cached("UPDATE $table SET $SQL_TIME=?,os=?,$SQL_DETAILS=? WHERE $SQL_IP=$SQL_ATON AND $SQL_FP=?") or die "$!" if not $h_update;
       $h_update->execute($ftime,$os,$details,$ip,$fp);
    }else{
       $h_insert = $db->prepare_cached(
         "INSERT INTO $table ".
         "($SQL_IP, service, $SQL_TIME, $SQL_FP, $SQL_MAC, os, $SQL_DETAILS,".
          "link, distance, $SQL_HOSTNAME)".
         "VALUES ($SQL_ATON,?,?,?,?,?,?,?,?,?)") if not $h_insert;
         #('$ip', '$service', '$time', '$fp', '$mac', '$os', '$details', '$link', '$dist', '$host')") if not $h_insert;
       $h_insert->execute($ip,$service,$ftime,$fp,$mac,$os,$details,
                          $link,$dist,$host);
       $records++;
    }
}
sub commit_db {
   return if not $records;
   print "Commiting $records records to database..\n" if $DEBUG;
   $OS_SYN_DB->commit;
   $records = 0;
}
}

sub print_asset {
   my ($time, $service, $ip, $os, $details, $fp, $dist, $link)= @_;

   printf "%11d [%-8s] ip:%-15s %s - %s [%s] distance:%d link:%s\n",
          $time, $service, $ip, $os, $details, $fp, $dist, $link;
}

=head2 update_asset

 Update the in-memory asset cache.

=cut
sub update_asset {
   my ($ip, $service, $time, $fp, $mac, $os, $details, $link, $dist) = @_;
   if(not $os or uc $os eq 'UNKNOWN'){
      ($os, $details) = ('?','?');
   }
   if(not $fp){
      $fp = '?';
   }

   my $entry = {
      'ip' => $ip,
      'service' => $service,
      'time' => $time,
      'fingerprint' => $fp,
      'mac' => $mac,
      'os' => $os,
      'details' => $details,
      'link' => $link,
      'dist' => $dist,
   };
   my $key = "$service:$ip:$fp";
   if(not $ASSET{$key}){
      # new asset
      print_asset ($time, $service, $ip, $os, $details, $fp, $dist, $link);
   }
   $ASSET{$key} = $entry;

   return $ASSET{$key};
}

=head2 asset_db

 Go through in-memory asset cache and poke updated records
 into the persistent database.

=cut
sub asset_db {
   my $e;
   for my $key (keys %ASSET){
      $e = $ASSET{$key};
      next if $e->{'time'} < $DB_LAST_UPDATE;
      add_db($e->{'ip'}, $e->{'service'}, $e->{'time'},
         $e->{'fingerprint'},
         $e->{'mac'},
         $e->{'os'}, $e->{'details'},
         $e->{'link'}, $e->{'dist'},
         $PRADS_HOSTNAME);
   }
   $DB_LAST_UPDATE = time;
}


=head2 add_asset

 Takes input: type, type-specific args, ...
 Adds the asset to the internal list of assets,
    or if it exists, just updates the timestamp.

=cut

sub add_asset {
    my ($service, @rest) = @_;

    if($service eq 'SYN'){
        my ($src_ip, $fingerprint, $dist, $link, $os, $details, @more) = @rest;
        if(not $os){
            $os = 'UNKNOWN';
            $details = 'UNKNOWN';
        }
        update_asset($src_ip, $service, $pradshosts{'tstamp'}, $fingerprint, '', $os, $details, $link, $dist, $PRADS_HOSTNAME);

    }elsif($service eq 'SYNACK'){
        my ($src_ip, $fingerprint, $dist, $link, $os, $details, @more) = @rest;
        if(not $os){
            $os = 'UNKNOWN';
            $details = 'UNKNOWN';
        }
        update_asset($src_ip, $service, $pradshosts{'tstamp'}, $fingerprint, '', $os, $details, $link, $dist, $PRADS_HOSTNAME);

    }elsif($service eq 'ARP'){
        my ($mac, $ip, $prefix, $vendor, $details, @more) = @rest;
        update_asset($ip, $service, $pradshosts{'tstamp'}, $prefix, $mac, $vendor, $details, 'ethernet', 1, $PRADS_HOSTNAME);

    }elsif($service eq 'SERVICE_TCP'){
        my ($ip, $port, $vendor, $version, $info, @more) = @rest;
        update_asset($ip, $service, $pradshosts{'tstamp'}, "$ip:$port", '', $vendor, "$info; $version","SERVICE", 1, $PRADS_HOSTNAME);

    }elsif($service eq 'SERVICE_UDP'){
        my ($ip, $port, $vendor, $version, $info, @more) = @rest;
        update_asset($ip, $service, $pradshosts{'tstamp'}, "$ip:$port", '', $vendor, "$info; $version","SERVICE", 1, $PRADS_HOSTNAME);

    }elsif($service eq 'ICMP'){
        my ($src_ip, $fingerprint, $dist, $link, $os, $details, @more) = @rest;
        update_asset($src_ip, $service, $pradshosts{'tstamp'}, $fingerprint,'', $os, $details, $link, $dist, $PRADS_HOSTNAME );

    }elsif($service eq 'UDP'){
         my ($src_ip, $fingerprint, $dist, $link, $os, $details, @more) = @rest;
         update_asset($src_ip, $service, $pradshosts{'tstamp'}, $fingerprint, '', $os, $details, $link, $dist, $PRADS_HOSTNAME)
    }
}

=head2 inpacket_dump_stats

 unsets the inpacket flag and calls dump_stats if dodump flag is set.

=cut

sub inpacket_dump_stats {
    $inpacket = 0;
    dump_stats () if ($dodump);
}

=head2 prepare_stats_dump

 A sub that checks if packet is beeing processed. Waits for for it to be finnished
 and then calls dump_stats.

=cut

sub prepare_stats_dump {
    # If a packet is being processed, wait until it is done
    if ($inpacket) {
       $dodump = 1;
       return;
    }
    dump_stats ();
}

=head2 dump_stats

 Prints out statistics from Net::Pcap

=cut

sub dump_stats {
    $dodump = 0;
    print "\n Packet capture stats:\n";
    my %d = %info;

    my $stamp = time;
    my %ds = %stats;

    Net::Pcap::stats ($PCAP, \%stats);
    $stats{"timestamp"} = $stamp;
    my $droprate = 0;
    $droprate = ( ($stats{ps_drop} * 100) / $stats{ps_recv}) if $stats{ps_recv} > 0;
    print " $stats{timestamp} [Packages received:$stats{ps_recv}]  [Packages dropped:$stats{ps_drop}] [Droprate:$droprate%]  [Packages dropped by interface:$stats{ps_ifdrop}]\n";
}

=head2 game_over

 Closing the pcap device, unlinks the pid file and exits.

=cut

sub game_over {
    print "Exiting\n";
    dump_stats();
    if($PERSIST){
      asset_db();
      commit_db();
    }
    warn "Closing device\n" if ($DEBUG>0);
    Net::Pcap::close($PCAP);
    unlink ($PIDFILE);
    exit 0;
}

=head1 AUTHOR

 Edward Fjellskaal

 Kacper Wysocki

 Jan Henning Thorsen

=head1 COPYRIGHT

 This library is free software, you can redistribute it and/or modify
 it under the same terms as Perl itself.

=cut
#   ҈  ☃  ☠  ҉
