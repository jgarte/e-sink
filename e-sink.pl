#!/usr/bin/env perl

## Use IO::Select to read STDIN without blocking

use strict;
use warnings;
use POSIX qw(ARG_MAX tmpnam);
use IO::Select;
use File::Spec;

use vars qw($EMACSCLIENT $BUFFER_TITLE $TEMP_FILE $TEMP_FILE_H $TEE $CPOUT);

sub esc_chars($) {
  # will change, for example, a!!a to a\!\!a
  my ($str) = @_;
  if ($str) {
    $str =~ s/([\\;<>\*\|`&\$!#\(\)\[\]\{\}:'"])/\\$1/g;
  } else {
    die "why no str?";
  }
  $str;
}

sub system_no_stdout(\@) {
  my ($params) = @_;
  open($CPOUT, ">&", "STDOUT");
  open(STDOUT, '>', File::Spec->devnull());
  my $ret_val;
  if (system @$params) {
    die "\n system call with parameters @$params failed: $!";
  }
  open(STDOUT, ">&", $CPOUT);
  $ret_val;
}

sub get_command_arr($) {
  my ($data) = @_;
  ($EMACSCLIENT, '--no-wait', '--eval', <<AARDVARK)
(e-sink-receive "$BUFFER_TITLE" "$data")
AARDVARK
}

sub push_data_to_emacs($) {
  my ($data) = @_;
  my @params= get_command_arr($data);

  if ($TEMP_FILE) {
    print $TEMP_FILE_H $data;
  } else {
    system_no_stdout(@params);
  }
}

sub emacs_start_e_sink() {
  my @arr= ($EMACSCLIENT, "--no-wait", "--eval", <<AARDVARK);
(progn (require 'e-sink) (e-sink-start "${BUFFER_TITLE}"))
AARDVARK
  system_no_stdout(@arr);
}

sub emacs_finish_e_sink($) {
  my $signal= shift;
  my @arr;

  $signal= $signal? "\"$signal\"" : "";
  if ($TEMP_FILE) {
    @arr= ($EMACSCLIENT, "--no-wait", "--eval", <<AARDVARK);
(e-sink-insert-and-finish "$BUFFER_TITLE" "$TEMP_FILE" $signal)
AARDVARK
  } else {
    @arr= ($EMACSCLIENT, "--no-wait", "--eval", <<AARDVARK);
(e-sink-finish "$BUFFER_TITLE" $signal)
AARDVARK
  }
  system_no_stdout(@arr);
}

sub print_help() {
  print <<AARDVARK
Usage: $0 [OPTION]... [buffer-name]

  --tee output to STDOUT as well
  --cmd use command-line instead of temporary file
  -h    this screen

AARDVARK
}

sub process_args() {

  $TEMP_FILE= tmpnam();

  for my $i ( 0..$#ARGV ) {
    if ( grep /$ARGV[$i]/, ("--help", "-h") ) {
      print_help();
      exit(0);
    } elsif ( $ARGV[$i] eq "--tee" ) {
      $TEE= 1;
      delete $ARGV[$i];
    } elsif ( $ARGV[$i] eq "--cmd" ) {
      $TEMP_FILE= undef;
      delete $ARGV[$i]
    } elsif ( $ARGV[$i] =~ /\A-/ ) {
      print STDERR "unexpected option '$ARGV[$i]'\n";
      exit(1);
    }
  }
  @ARGV= grep(defined, @ARGV);

  if ( scalar(@ARGV) > 1) {
    print STDERR "unexpected '$ARGV[1]'\n";
    exit(1);
  }
}

sub main() {

  process_args();

  ### start non-blocking read ASAP
  my $s = IO::Select->new;
  $s->add(\*STDIN);

  $EMACSCLIENT= "emacsclient";
  $BUFFER_TITLE= ($ARGV[0]? $ARGV[0] : '');

  # autoflush
  select(STDOUT);
  $|= 1;

  emacs_start_e_sink();

  my $arg_max;

  if ($TEMP_FILE) {
    $arg_max= 100_000;            #
  } else {
    my $temp= join('', get_command_arr(''));
    $arg_max= ARG_MAX - length($temp) - 1; # 1 for NULL string end
  }

  my ($data, $sig_name);
  $TEMP_FILE and open($TEMP_FILE_H, ">$TEMP_FILE");

  my $handler= sub {
    $sig_name= shift;
    $s->remove(\*STDIN);
    close(STDIN) or die "could not close STDIN";
    # if we don't reopen STDIN, we get a warning: "Filehandle STDIN reopened as
    # <> only for output." http://markmail.org/message/j76ed5ko3ouxtzl4
    open(STDIN, "<", File::Spec->devnull());
  };

  for my $s qw(HUP INT PIPE TERM) {
    $SIG{$s}= $handler;
  }

  while ( $s->can_read() ) {
    my $line= <STDIN>;

    if ( ! $line ) {
      last;
    }

    print $line if $TEE;

    unless ($TEMP_FILE) {
      $line= esc_chars( $line );
    }

    if ( $data && ( length($data) + length($line) > $arg_max) ) {
      push_data_to_emacs( $data );
      $data= $line;
    } else {
      $data .= $line;
    }
  }

  $data and push_data_to_emacs( $data );
  $TEMP_FILE_H and close($TEMP_FILE_H);
  emacs_finish_e_sink($sig_name);
  0;
}


main;
