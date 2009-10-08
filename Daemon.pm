package App::Daemon;
use strict;
use warnings;

our $VERSION = '0.07';

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
our @EXPORT_OK = qw(daemonize cmd_line_parse detach);

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

    if(!defined $pidfile) {
      $pidfile    = find_option('-p', 1) || ( '/tmp/' . $appname . ".pid" );
    }

    if(!defined $logfile) {
      $logfile    = find_option('-l', 1) || ( '/tmp/' . $appname . ".log" );
    }

    if(!defined $l4p_conf) {
      $l4p_conf   = find_option('-l4p', 1);
    }

    if(!defined $as_user) {
      $as_user    = find_option('-u', 1) || "nobody";
    }

    if($> != 0) {
          # Not root? Then we're ourselves
        ($as_user) = getpwuid($>);
    }

    if(!defined $background) {
      $background = find_option('-X') ? 0 : 1,
    }

    if(!defined $loglevel) {
      $loglevel   = find_option('-v') ? $DEBUG : $INFO;
      $loglevel   = $DEBUG if !$background;
    }

    for (qw(start stop status)) {
        if( find_option( $_ ) ) {
            $action = $_;
            last;
        }
    }
    
    if($action eq "stop" or $action eq "restart") {
        $background = 0;
    }

    if( Log::Log4perl->initialized() ) {
        DEBUG "Log4perl already initialized, doing nothing";
    } elsif( $l4p_conf ) {
        Log::Log4perl->init( $l4p_conf );
    } elsif( !$background ) {
        Log::Log4perl->easy_init({ level => $loglevel, 
                                   layout => "%F{1}-%L: %m%n" });
    } elsif( $logfile ) {
        my $levelstring = Log::Log4perl::Level::to_level( $loglevel );
        Log::Log4perl->init(\ qq{
            log4perl.logger = $levelstring, FileApp
            log4perl.appender.FileApp = Log::Log4perl::Appender::File
            log4perl.appender.FileApp.filename = $logfile
            log4perl.appender.FileApp.owner    = $as_user
            log4perl.appender.FileApp.layout   = PatternLayout
            log4perl.appender.FileApp.layout.ConversionPattern = %d %m%n
        });
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
        detach( $as_user );
    }

    $SIG{__DIE__} = sub { 
          # Make sure it's not an eval{} triggering the handler.
        if(defined $^S && $^S==0) {
            unlink $pidfile or warn "Cannot remove $pidfile";
        }
    };
    
    INFO "Process ID is $$";
    pid_file_write($$);
    INFO "Written to $pidfile";

    return 1;
}

###########################################
sub detach {
###########################################
    my($as_user) = @_;

    umask(0);
 
      # Make sure the child isn't killed when the uses closes the
      # terminal session before the child detaches from the tty.
    $SIG{'HUP'} = 'IGNORE';
 
    my $child = fork();
 
    if($child < 0) {
        LOGDIE "Fork failed ($!)";
    }
 
    if( $child ) {
        # parent doesn't do anything
        exit 0;
    }
 
        # Become the session leader of a new session, become the
        # process group leader of a new process group.
    POSIX::setsid();
 
    if($as_user) {
        user_switch();
    }
 
        # close std file descriptors
    close(STDIN);
    close(STDOUT);
    close(STDERR);
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
    my $appname = basename($0);

      # Make sure -T regards it as untainted now
    ($appname) = ($appname =~ /([\w-]+)/);

    return $appname;
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
   do_something_useful(); # your application

     # Then, in the shell: start application,
     # which returns immediately, but continues 
     # to run do_something_useful() in the background
   $ app start
   $

     # stop application
   $ app stop

     # start app in foreground (for testing)
   $ app -X

     # show if app is currently running
   $ app status

=head1 DESCRIPTION

C<App::Daemon> helps running an application as a daemon. The idea is
that you prepend your script with the 

    use App::Daemon qw( daemonize ); 
    daemonize();

and 'daemonize' it that way. That means, that if you write

    use App::Daemon qw( daemonize ); 

    daemonize();
    sleep(10);

you'll get a script that, when called from the command line, returns 
immediatly, but continues to run as a daemon for 10 seconds.

Along with the
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

=head2 Command Line Options

=over 4

=item -X

Foreground mode. Log messages go to the screen.

=item -l logfile

Logfile to send Log4perl messages to in background mode. Defaults
to C</tmp/[appname].log>.

=item -u as_user

User to run as if started as root. Defaults to 'nobody'.

=item -l4p l4p.conf

Path to Log4perl configuration file. Note that in this case the -v option 
will be ignored.

=item -p pidfile

Where to save the pid of the started process.
Defaults to C</tmp/[appname].pid>.

=item -v

Increase default Log4perl verbosity from $INFO to $DEBUG. Note that this
option will be ignored if Log4perl is initialized independently or if
a user-provided Log4perl configuration file is used.

=head2 Setting Parameters

Instead of setting paramteters like the logfile, the pidfile etc. from
the command line, you can directly manipulate App::Daemon's global
variables:

    use App::Daemon qw(daemonize);

    $App::Daemon::logfile    = "mylog.log";
    $App::Daemon::pidfile    = "mypid.log";
    $App::Daemon::l4p_conf   = "myconf.l4p";
    $App::Daemon::background = 1;
    $App::Daemon::as_user    = "nobody";

    use Log::Log4perl qw(:levels);
    $App::Daemon::loglevel   = $DEBUG;

    daemonize();

=head2 Application-specific command line options

If an application needs additional command line options, it can 
use whatever is not yet taken by App::Daemon, as described previously
in the L<Command Line Options> section.

However, it needs to make sure to remove these additional options before
calling daemonize(), or App::Daemon will complain. To do this, create 
an options hash C<%opts> and store application-specific options in there
while removing them from @ARGV:

    my %opts = ();

    for my $opt (qw(k P U)) {
        my $v = App::Daemon::find_option( $opt, 1 );
        $opts{ $opt } = $v if defined $v;
    }

After this, options C<-k>, C<-P>, and C<-U> will have disappeared from
@ARGV and can be checked in C<$opts{k}>, C<$opts{P}>, and C<$opts{U}>.

=head2 Gotchas

If the process is started as root but later drops permissions to a
non-priviledged user for security purposes, it's important that 
logfiles are created with correct permissions.

If they're created as root when the program starts, the non-priviledged
user won't be able to write to them later (unless they're world-writable
which is also undesirable because of security concerns).

The best strategy to handle this case is to specify the non-priviledged
user as the owner of the logfile in the Log4perl configuration:

    log4perl.logger = DEBUG, FileApp
    log4perl.appender.FileApp = Log::Log4perl::Appender::File
    log4perl.appender.FileApp.filename = /var/log/foo-app.log
    log4perl.appender.FileApp.owner    = nobody
    log4perl.appender.FileApp.layout   = PatternLayout
    log4perl.appender.FileApp.layout.ConversionPattern = %d %m%n

This way, the process starts up as root, creates the logfile if it 
doesn't exist yet, and changes its owner to 'nobody'. Later, when the
process assumes the identity of the user 'nobody', it will continue
to write to the logfile without permission problems.

=head2 Detach only

If you want to create a daemon without the fancy command line parsing
and PID file checking functions, use

    use App::Daemon qw(detach);
    detach();
    # ... some code here

This will fork a child, terminate the parent and detach the child from
the terminal. Issued from the command line, the program above will
continue to run the code following the detach() call but return to the
shell prompt immediately.

=back

=head1 AUTHOR

Mike Schilli, cpan@perlmeister.com

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2008 by Mike Schilli

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.5 or,
at your option, any later version of Perl 5 you may have available.

=cut
