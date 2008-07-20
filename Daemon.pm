package App::Daemon;
use strict;
use warnings;

our $VERSION = '0.01';

use Getopt::Std;
use Pod::Usage;
use Log::Log4perl qw(:easy);
use File::Basename;
use Proc::ProcessTable;
use Log::Log4perl qw(:easy);
use POSIX;
use Exporter;
use Fcntl qw/:flock/;

our @ISA = qw(Exporter);
our @EXPORT_OK = qw(daemonize cmd_line_parse);

our ($pidfile, $logfile, $l4p_conf, $as_user, $background, 
     $loglevel, $action, $appname);
$action  = "";
$appname = appname();

###########################################
sub cmd_line_parse {
###########################################

    if( find_option("-h") ) {
        pod2usage();
    }

    $pidfile    = find_option('-p', 1) || ( '/tmp/' . $appname . ".pid" );

    $logfile    = find_option('-l', 1) || ( '/tmp/' . $appname . ".log" );

    $l4p_conf   = find_option('-l4p', 1);

    $as_user    = find_option('-u', 1) || "nobody";
    $background = find_option('-X') ? 0 : 1,
    $loglevel   = find_option('-v') ? $DEBUG : $INFO;
    $loglevel   = $DEBUG if !$background;

    for (qw(start stop status)) {
        if( find_option( $_ ) ) {
            $action = $_;
            last;
        }
    }
    
    if($action eq "stop" or $action eq "restart") {
        $background = 0;
    }

    if( $l4p_conf ) {
        Log::Log4perl->init( $l4p_conf );
    } elsif( !$background ) {
        Log::Log4perl->easy_init({ level => $loglevel, 
                                   layout => "%F{1}-%L: %m%n" });
    } elsif( $logfile ) {
        Log::Log4perl->easy_init({ level => $loglevel, file => ">>$logfile" });
    }

    if(!$background) {
        DEBUG "Running in foreground";
    }
}

###########################################
sub daemonize {
###########################################
    cmd_line_parse();

      # Check beforehand so the user knows what's going on.
    if(! -w dirname($pidfile) or -f $pidfile and ! -w  $pidfile) {
        my ($name,$passwd,$uid) = getpwuid($>);
        LOGDIE "$pidfile not writable by user $name";
    }
    
    if($action eq "status") {
        status();
        exit 0;
    }

    if($action eq "stop" or $action eq "restart") {
        if(-f $pidfile) {
            my $pid = pid_file_read();
            if(kill 0, $pid) {
                kill 2, $pid;
            } else {
                ERROR "Process $pid not running\n";
                unlink $pidfile or die "Can't remove $pidfile ($!)";
            }
        } else {
            ERROR "According to my pidfile, there's no instance ",
                  "of me running.";
        }
        if($action eq "restart") {
            sleep 1;
        } else {
            exit 0;
        }
    }
      
    if ( my $num = pid_file_process_running() ) {
        LOGDIE "Already running: $num (pidfile=$pidfile)\n";
    }

    if( $background ) {
        if( my $child = fork() ) {
            # parent doesn't do anything
            sleep 1;
            exit 0;
        }
    
            # child does all processing, but first needs to detach
            # from parent;
        user_switch();
        POSIX::setsid();
            # properly daemonize
        close(STDIN);
        close(STDOUT);
        close(STDERR);
    }

    $SIG{__DIE__} = sub { 
        if(! $^S) {
            unlink $pidfile or warn "Cannot remove $pidfile";
        }
    };
    
    INFO "Process ID is $$";
    pid_file_write($$);
    INFO "Written to $pidfile";

    return 1;
}

###########################################
sub user_switch {
###########################################
    if($> == 0) {
        # If we're root, become the user set as 'as_user';
        my ($name,$passwd,$uid) = getpwnam($as_user);
        if(! defined $name) {
            LOGDIE "Cannot switch to user $as_user";
        }
        $> = $uid;
    }
}
    
###########################################
sub status {
###########################################
    print "Pid file:    $pidfile\n";
    if(-f $pidfile) {
        my $pid = pid_file_read();
        print "Pid in file: $pid\n";
        print "Running:     ", process_running($pid) ? "yes" : "no", "\n";
    } else {
        print "No pidfile found\n";
    }
    my @cmdlines = processes_running_by_name( $appname );
    print "Name match:  ", scalar @cmdlines, "\n";
    for(@cmdlines) {
        print "    ", $_, "\n";
    }
    return 1;
}


###########################################
sub process_running {
###########################################
    my($pid) = @_;

    # kill(0,pid) doesn't work if we're checking a process running on
    # different uid, so we need this.

    my $t = Proc::ProcessTable->new();

    foreach my $p ( @{$t->table} ){
        return 1 if $p->pid() == $pid;
    }
    return 0;
}

###########################################
sub processes_running_by_name {
###########################################
    my($name) = @_;

    $name = basename($name);
    my @procs = ();

    my $t = Proc::ProcessTable->new();

    foreach my $p ( @{$t->table} ){
        if($p->cmndline() =~ /\b\Q${name}\E\b/) {
            next if $p->pid() == $$;
            DEBUG "Match: ", $p->cmndline();
            push @procs, $p->cmndline();
        }
    }
    return @procs;
}

###########################################
sub appname {
###########################################
    my $base = basename($0);
    return $base;
}

###########################################
sub find_option {
###########################################
    my($opt, $has_arg) = @_;

    my $idx = 0;

    for my $argv (@ARGV) {
        if($argv eq $opt) {
            if( $has_arg ) {
                my @args = splice @ARGV, $idx, 2;
                return $args[1];
            } else {
                return splice @ARGV, $idx, 1;
            }
        }

        $idx++;
    }

    return undef;
}

###########################################
sub def_or {
###########################################
    if(! defined $_[0]) {
        $_[0] = $_[1];
    }
}

###########################################
sub pid_file_write {
###########################################
    my($pid) = @_;

    open FILE, "+>$pidfile" or LOGDIE "Cannot open pidfile $pidfile";
    flock FILE, LOCK_EX;
    seek(FILE, 0, 0);
    print FILE "$pid\n";
    close FILE;
}

###########################################
sub pid_file_read {
###########################################
    open FILE, "<$pidfile" or LOGDIE "Cannot open pidfile $pidfile";
    flock FILE, LOCK_SH;
    my $pid = <FILE>;
    chomp $pid if defined $pid;
    close FILE;
    return $pid;
}

###########################################
sub pid_file_process_running {
###########################################
    if(! -f $pidfile) {
        return undef;
    }
    my $pid = pid_file_read();
    if(! $pid) {
        return undef;
    }
    if(process_running($pid)) {
        return $pid;
    }

    return undef;
}

1;

__END__

=head1 NAME

App::Daemon - Start an Application as a Daemon

=head1 SYNOPSIS

     # Program:
   use App::Daemon qw( daemonize );
   daemonize();

     # Then, in the shell:
 
     # start app in background
   $ app start

     # stop app
   $ app stop

     # start app in foreground (for testing)
   $ app -X

     # show if app is currently running
   $ app status

=head1 DESCRIPTION

C<App::Daemon> helps running an application as a daemon. Along with the
common features offered by similar modules on CPAN, it

=over 4

=item *

supports logging with Log4perl: In background mode, it logs to a 
logfile. In foreground mode, log messages go directly to the screen.

=item *

detects if another instance is already running and ends itself 
automatically in this case.

=item *

shows with the 'status' command if an instance is already running
and which PID it has:

    ./my-app status
    Pid file:    /tmp/tt.pid
    Pid in file: 14914
    Running:     no
    Name match:  0

=back

=head2 Actions

C<App::Daemon> recognizes three different actions:

=over 4

=item my-app start

will start up the daemon. "start" itself is optional, as this is the 
default action, 
        
        $ ./my-app
        
will also run the 'start' action. If the -X option is given, the program
is run in foreground mode for testing purposes.

=item stop

will find the daemon's PID in the pidfile and send it a kill signal. It
won't verify if this actually shut down the daemon or if it's immune to 
the kill signal.

=item status

will print out diagnostics on what the status of the daemon is. Typically,
the output look like this:

    Pid file:    /tmp/tt.pid
    Pid in file: 15562
    Running:     yes
    Name match:  1
        /usr/local/bin/perl -w test.pl

This indicates that the pidfile says that the daemon has PID 15562 and
that a process with this PID is actually running at this moment. Also,
a name grep on the process name in the process table results in 1 match,
according to the output above.

Note that the name match is unreliable, as it just looks for a command line
that looks approximately like the script itself. So if the script is
C<test.pl>, it will match lines like "perl -w test.pl" or 
"perl test.pl start", but unfortunately also lines like 
"vi test.pl".

If the process is no longer running, the status output might look like
this instead:

    Pid file:    /tmp/tt.pid
    Pid in file: 14914
    Running:     no
    Name match:  0

=head2 Command line options

=over 4

=item -X

Foreground mode. Log messages go to the screen.

=item -l logfile

Logfile to send Log4perl messages to in background mode. Defaults
to C</tmp/[appname].log>.

=item -u as_user

User to run as if started as root. Defaults to 'nobody'.

=item -l4p l4p.conf

Path to Log4perl configuration file.

=item -p pidfile

Where to save the pid of the started process.
Defaults to C</tmp/[appname].pid>.

=back

=head1 AUTHOR

Mike Schilli, cpan@perlmeister.com

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by Mike Schilli

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.5 or,
at your option, any later version of Perl 5 you may have available.

=cut
