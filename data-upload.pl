#!/usr/bin/perl -T
#
# This script should be run with the permissions of the user that
# is uploading files.
#
# Arguments are :-separated and URL-escaped.
#
# It accepts the following commands:
#
# DATA byte-count
#	- receives a new data blob (follows immediately)
# TAR git-tree:tree-ish:prefix
#	- generate a data blob from a git tree (git archive)
# DIFF git-tree:tree-ish:tree-ish
#	- generate a data blob as a git tree diff
# SIGN byte-count
#	- updates the current signature blob (follows immediately)
# PUT pathname
#	- installs the current data blob as <pathname>
# MKDIR pathname
#	- creates a new directory
# MOVE old-path:new-path
#	- moves <old-path> to <new-path>
#
# For future consideration:
#
# LINK old-path:new-path
#	- hard links <old-path> to <new-path>
# SYMLINK old-path:new-path
#	- symlinks <old-path> to <new-path>
# DELETE old-path
#	- removes <old-path>
#

use strict;
use warnings;
use bytes;

use File::Temp qw(tempdir);
use IO::Uncompress::AnyUncompress qw(anyuncompress $AnyUncompressError) ;
use BSD::Resource;
use Fcntl qw(:flock);

my $data_path = '/home/hpa/kernel.org/test/pub';
my $sign_path = '/home/hpa/kernel.org/test/sign';
my $lock_file = '/home/hpa/kernel.org/test/lock';
my $tmp_path  = '/var/tmp/upload';
my $max_data  = 1*1024*1024*1024;
my $bufsiz    = 1024*1024;

umask(077);
setrlimit(RLIMIT_FSIZE, $max_data, RLIM_INFINITY);

my $tmpdir = tempdir(DIR => $tmp_path, CLEANUP => 1);

my $have_data = 0;
my $have_sign = 0;

my $lock_fd   = undef;

sub lock_tree()
{
    if (!defined($lock_fd)) {
	open($lock_fd, '<', $lock_file)
	    or die "Cannot open lock file\n";
	flock($lock_fd, LOCK_EX)
	    or die "Cannot get file tree lock\n";
    } else {
	die "File tree is already locked\n";
    }
}

sub unlock_tree()
{
    if (defined($lock_fd)) {
	close($lock_fd);
	undef $lock_fd;
    }
}

sub url_unescape($)
{
    my($s) = @_;
    my $c, $i, $o;

    for ($i = 0; $i < length($s); $i++) {
	$c = substr($s, $i, 1);
	if ($c eq '%') {
	    $c = substr($s, $i+1, 2);
	    return undef if (length($c) != 2);
	    $o .= chr(hex $c);
	    $i += 2;
	} else {
	    $o .= $c;
	}
    }

    return $o;
}

sub parse_line($)
{
    my($line) = @_;
    chomp $line;

    if ($line !~ /^([A-Z0-9_]+)\s+(\S*)$/) {
	return undef;		# Invalid syntax
    }

    my $cmd = $1;
    my @rawargs = split(/\:/, $2);

    my @args = ();
    foreach my $ra (@rawargs) {
	my $a = url_unescape($ra);
	return undef if (!defined($a));
	push(@args, $a);
    }

    return @args;
}

# This returns true if the given argument is a valid filename in its
# canonical form.  Double slashes, relative paths, and control
# characters are not permitted.
sub is_valid_file_name($)
{
    my($f) = @_;

    return 0 if ($f !~ m:^/:);
    return 0 if ($f =~ m:[\0-\x1f\x7f-\x9f]:);
    return 0 if ($f =~ m:/$:);
    return 0 if ($f =~ m://:);
    return 0 if ($f =~ m:/(\.|\.\.)(/|$):);

    return 1;
}

sub get_raw_data(@)
{
    my @args = @_;

    if (scalar(@args) != 1 || $args[0] !~ /^[0-9]+$/) {
	die "400 Bad DATA command\n";
	exit 1;
    }

    my $output = $tmpdir.'/data';
    anyuncompress(STDIN => $output,
		  BinModeOut => 1,
		  InputLength => ($args[0] + 0),
		  Append => 0,
		  AutoClose => 0,
		  Transparent => 1,
		  BlockSize => $bufsiz)
	or die "400 DATA decompression error: $AnyUncompressError\n";
		  
    $have_data = 1;
}

sub get_tar_data(@)
{
    die "TAR not yet implemented\n";
}

sub get_diff_data(@)
{
    die "DIFF not yet implemented\n";
}

sub get_sign_data(@)
{
    my @args = @_;

    if (scalar(@args) != 1 || $args[0] !~ /^[0-9]+$/) {
	die "400 Bad SIGN command\n";
	exit 1;
    }

    my $output = $tmpdir.'/sign';
    anyuncompress STDIN => $output,
		  BinModeOut => 1,
		  InputLength => ($args[0] + 0),
		  Append => 0,
		  AutoClose => 0,
		  Transparent => 1,
		  BlockSize => $bufsiz
	or die "400 SIGN decompression error: $AnyUncompressError\n";
		  
    if ((-s $output) >= 65536) {
	die "400 SIGN output impossibly large\n";
    }

    $have_sign = 1;
}

sub make_compressed_data()
{
    die if (!$have_data);

    my %workers;
    my @jobs =
	("/bin/gzip -9 < \Q${tmpdir}/data\E > \Q${tmpdir}/data.gz\E",
	 "/usr/bin/bzip2 -9 < \Q${tmpdir}/data\E > \Q${tmpdir}/data.bz2\E",
	 "/usr/bin/xz -9 < \Q${tmpdir}/data\E > \Q${tmpdir}/data.xz\E");
    my $nworkers = 0;

    foreach my $j (@jobs) {
	my $w = fork();

	if (!defined($w)) {
	    die "Fork failed\n";
	}

	if ($w == 0) {
	    exec($j);
	    exit 127;
	}

	$workers{$w}++;
	$nworkers++;
    }

    while ($nworkers) {
	my $w = wait();
	my $status = $?;

	if ($workers{$w}) {
	    undef $workers{$w};
	    if ($status) {
		foreach my $c (keys %workers) {
		    kill('TERM', $c);
		}
		die "Failed to compress output data\n";
	    }
	}

	$nworkers--;
    }
}

sub cleanup()
{
    unlink($tmpdir.'/data');
    unlink($tmpdir.'/data.gz');
    unlink($tmpdir.'/data.bz2');
    unlink($tmpdir.'/data.xz');
    unlink($tmpdir.'/sign');
    $have_data = 0;
    $have_sign = 0;
}

sub signature_valid()
{
    # GPG verify an authorized signature here
    return 1;
}

sub put_file(@)
{
    my @args = @_;

    if (scalar(@args) != 1) {
	die "400 Bad PUT command\n";
    }

    my($file) = @args;

    if (!$have_data) {
	die "400 PUT without DATA\n";
    }
    if (!$have_sign) {
	die "400 PUT without SIGN\n";
    }

    if (!signature_valid()) {
	die "400 Signature invalid\n";
    }

    if (!is_valid_filename($file)) {
	die "400 Invalid filename in PUT command\n";
    }

    lock_tree();

    if ($file =~ /^(.*)\.gz$/) {
	my $stem = $1;
	make_compressed_data();
	if (!rename($tmpdir.'/data.gz',  $data_path.$stem.'.gz') ||
	    !rename($tmpdir.'/data.bz2', $data_path.$stem.'.bz2') ||
	    !rename($tmpdir.'/data.xz',  $data_path.$stem.'.xz') ||
	    !rename($tmpdir.'/sign',     $data_path.$stem.'.sign')) {
	    unlink($data_path.$stem.'.gz');
	    unlink($data_path.$stem.'.bz2');
	    unlink($data_path.$stem.'.xz');
	    unlink($data_path.$stem.'.sign');
	    die "400 Failed to install files\n";
	}
    } elsif ($file =~ /\.(sign|bz2|xz)$/) {
	die "400 Cannot install .sign, .bz2 or .xz files directly\n";
    } else {
	if (!rename($tmpdir.'/data', $data_path.$file) ||
	    !rename($tmpdir.'/sign', $data_path.$file.'.sign')) {
	    unlink($data_path.$file);
	    unlink($data_path.$file.'.sign');
	    die "400 Failed to install files\n";
	}
    }

    unlock_tree();
    cleanup();
}

sub do_mkdir(@)
{
    my @args = @_;

    if (scalar(@args) != 1) {
	die "400 Bad MKDIR command\n";
    }

    my($file) = @args;

    if (!is_valid_filename($file)) {
	die "400 Invalid filename in MKDIR command\n";
    }

    if ($file =~ /\.(gz|bz2|xz|sign)$/) {
	die "400 Protected filename space\n";
    }

    # No need to lock/unlock around a single atomic operation
    if (!mkdir($file, 002)) {
	die "400 Failed to MKDIR\n";
    }
}

sub move_file(@)
{
    my @args = @_;

    if (scalar(@args) != 2) {
	die "400 Bad MOVE command\n";
    }

    my($from, $to) = @args;

    if (!is_valid_filename($from) || !is_valid_filename($to)) {
	die "400 Invalid filename in MOVE command\n";
    }

    if ($from =~ /\.(bz2|xz|sign)$/) {
	die "MOVE of individual .bz2, .xz, or .sign files not supported\n";
    }
    if ($to =~ /\.(bz2|xz|sign)$/) {
	die "MOVE to filename ending in .bz2, .xz or .sign\n";
    }
    
    if ($from =~ /\.gz$/ && $to !~ /\.gz$/) {
	die "MOVE of .gz file must itself end in .gz\n";
    }
    if ($from !~ /\.gz$/ && $to =~ /\.gz$/) {
	die "MOVE of non-.gz file must not end in .gz\n";
    }

    lock_tree();

    if (-d $data_path.$from) {
	if (!rename($data_path.$from, $data_path.$to)) {
	    die "MOVE of directory failed\n";
	}
    } elsif (-f $data_path.$from) {
	if (-d $data_path.$to) {
	    $from =~ m:^(|.*/)([^/]+)$:;
	    my $fname = $2;
	    $to .= '/'.$fname;
	}

	if (!rename($data_path.$from, $data_path.$to)) {
	    die "MOVE of plain file failed\n";
	}
	if ($from =~ /^(.*)\.gz$/) {
	    my $from_stem = $1;

	    die if ($to !~ /^(.*)\.gz$/); # Should already be checked
	    my $to_stem = $1;

	    if (!rename($data_path.$from_stem.'.bz2',  $data_path.$to_stem.'.bz2') ||
		!rename($data_path.$from_stem.'.xz',   $data_path.$to_stem.'.xz') ||
		!rename($data_path.$from_stem.'.sign', $data_path.$to_stem.'.sign')) {
		die "MOVE of auxilliary file failed\n";
	    }
	}
    } else {
	die "MOVE of non-directory/non-file not currently supported\n";
    }

    unlock_tree();
}

my $line;
while (defined($line = <STDIN>)) {
    my($cmd, @args) = parse_line($line);

    if (!defined($cmd)) {
	die "400 Syntax error\n";
	exit 1;
    }

    if ($cmd eq 'DATA') {
	get_raw_data(@args);
    } elsif ($cmd eq 'TAR') {
	get_tar_data(@args);
    } elsif ($cmd eq 'DIFF') {
	get_diff_data(@args);
    } elsif ($cmd eq 'SIGN') {
	get_sign_data(@args);
    } elsif ($cmd eq 'PUT') {
	put_file(@args);
    } elsif ($cmd eq 'MKDIR') {
	do_mkdir(@args);
    } elsif ($cmd eq 'MOVE') {
	move_file(@args);
    } else {
	die "400 Invalid command\n";
	exit 1;
    }
}
