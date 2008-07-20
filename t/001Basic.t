use Test::More tests => 4;

use App::Daemon qw(daemonize cmd_line_parse);
use File::Temp qw(tempfile);

my($fh, $tempfile) = tempfile();
my($pf, $pidfile) = tempfile();

ok(1, "loaded ok");

open(OLDERR, ">&STDERR");
open(STDERR, ">$tempfile");

@ARGV = ("-X", "-p", $pidfile);
daemonize();

close STDERR;
open(STDERR, ">&OLDERR");

ok(1, "running in foreground with -X");

open PIDFILE, "<$pidfile";
my $pid = <PIDFILE>;
chomp $pid;
close PIDFILE;

is($pid, $$, "check pid");

open FILE, "<$tempfile";
my $data = join '', <FILE>;
close FILE;

like($data, qr/Written to $pidfile/, "log message");
