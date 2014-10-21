
=head1 NAME

Text::Ispell.pm - a class encapsulating access to the Ispell program.

=cut


package Text::Ispell;
use Exporter;
@Text::Ispell::ISA = qw(Exporter);
@Text::Ispell::EXPORT_OK = qw(
  spellcheck
  add_word
  add_word_lc
  accept_word
  parse_according_to
  set_params_by_language
  save_dictionary
  terse_mode
  nonterse_mode
);


use FileHandle;
use IPC::Open2;
use Carp;

use strict;

use vars qw( $VERSION );
$VERSION = '0.01';


=head1 SYNOPSIS

 # Brief:
 use Text::Ispell;
 Text::Ispell::spellcheck( $string );
 # or
 use Text::Ispell qw( spellcheck ); # import the function
 spellcheck( $string );

 # Useful:
 use Text::Ispell qw( spellcheck );
 for my $r ( spellcheck( "hello hacking perl shrdlu 42" ) ) {
   print "$r->{'type'}: $r->{'term'}\n";
 }


=head1 DESCRIPTION

Text::Ispell::spellcheck() takes one argument.  It must be a
string, and it should contain only printable characters.
One allowable exception is a terminal newline, which will be
chomped off anyway.  The line is fed to a coprocess running
ispell for analysis.  The line is parsed on non-wordchars
into a sequence of terms.  By default, the set of wordchars
is defined in ispell as letters, digits, and the apostrophe.
In other words, the line is subjected the equivalent of

  split /[^a-zA-Z0-9']+/

(ispell has a means to add characters to the default set,
but currently Text::Ispell does not provide access to that
feature.)

The result of ispell's analysis of each term is a categorization
of the term into one of six types: ok, root, miss, none, compound,
and guess.  Some of these carry additional information.

Text::Ispell::spellcheck returns a list of objects, each
corresponding to a term in the spellchecked string.  Each object
is a hash (hash-ref) with at least two entries: 'term' and 'type'.
The former contains the term ispell is reporting on, and the latter
is ispell's determination of that term's type (see above).
For types 'ok' and 'none', that is all the information there is.
For the type 'root', an additional hash entry is present: 'root'.
Its value is the word which ispell identified in the dictionary
as being the likely root of the current term.
For the type 'miss', an additional hash entry is present: 'misses'.
Its value is a string of words, comma-separated, which ispell
identified as being "near-misses" of the current term, when
scanning the dictionary.

A quickie example:

 use Text::Ispell qw( spellcheck );
 for my $r ( spellcheck( "hello hacking perl shrdlu 42" ) ) {
   if ( $r->{'type'} eq 'ok' ) {
     # as in the case of 'hello'
     print "'$r->{'term'}' was found in the dictionary.\n";
   }
   elsif ( $r->{'type'} eq 'root' ) {
     # as in the case of 'hacking'
     print "'$r->{'term'}' can be formed from root '$r->{'root'}'\n";
   }
   elsif ( $r->{'type'} eq 'miss' ) {
     # as in the case of 'perl'
     print "'$r->{'term'}' was not found in the dictionary;\n";
     print "Near misses: $r->{'misses'}\n";
   }
   elsif ( $r->{'type'} eq 'none' ) {
     # as in the case of 'shrdlu'
     print "No match for term '$r->{'term'}'\n";
   }
 }

According to the ispell man page, there should be two more types:
compound and guess.  However, I have not figured out how to elicit
responses of these types from ispell.


=head2 ERRORS

C<Text::Ispell::spellcheck()> starts the ispell coprocess 
if the coprocess seems not to exist.  Ordinarily this is simply
the first time it's called.

ispell is spawned via the C<Open2::open2()> function, which
throws an exception (i.e. dies) if the spawn fails.  The caller
should be prepared to catch this exception -- unless, of course,
the default behavior of die is acceptable.

=head2 Nota Bene

The full location of the ispell executable is stored
in the variable C<$Text::Ispell::path>.  The default
value is F</usr/local/bin/ispell>.
If your ispell executable has some name other than
this, then you must set C<$Text::Ispell::path> accordingly
before you call C<Text::Ispell::spellcheck()> for the first
time.

=cut


sub _init {
  unless ( $Text::Ispell::pid ) {
    $Text::Ispell::path ||= '/usr/local/bin/ispell';

    $Text::Ispell::pid = undef; # so that it's still undef if open2 fails.
    $Text::Ispell::pid = open2( # if open2 fails, it throws, but doesn't return.
      *Reader,
      *Writer,
      $Text::Ispell::path,
      '-a', '-S',
    );

    my $hdr = scalar(<Reader>);

    $Text::Ispell::terse = 0;  # must be the same as ispell.
    $Text::Ispell::word_chars = "'0-9A-Za-z";
  }
  $Text::Ispell::pid
}

#
# we'll need this if we implement features that need to
# stop and re-start the coprocess.
#
sub _exit {
  if ( $Text::Ispell::pid ) {
    close Reader;
    close Writer;
    kill $Text::Ispell::pid;
    $Text::Ispell::pid = undef;
  }
}


sub spellcheck {
  _init() or return();  # caller should really catch the exception from a failed open2.
  my $line = shift;
  local $/ = "\n"; local $\ = '';
  chomp $line;
  $line =~ s/\r//g; # kill the hate
  $line =~ /\n/ and croak "newlines not allowed in arguments to Text::Ispell::spellcheck!";
  print Writer "^$line\n";
  my @commentary;
  local $_;
  while ( <Reader> ) {
    chomp;
    last unless $_ gt '';
    push @commentary, $_;
  }

#
# it doth appear that ispell simply skips, without comment,
# any terms that consist solely of digits.
#
  my $split_pattern = "[^$Text::Ispell::word_chars]+";
  my @terms = grep { /\D/ } split /$split_pattern/, $line;

  unless ( $Text::Ispell::terse ) {
    @terms == @commentary or die "terms: ".join(',',@terms)."\ncommentary:\n".join("\n",@commentary)."\n\n";
  }

  my %types = (
    '*' => 'ok',
    '-' => 'compound',
    '+' => 'root',
    '#' => 'none',
    '&' => 'miss',
    '?' => 'guess',
  );
  # and there's one more type, unknown, which is
  # used when the first char is not in the above set.

  my %modisp = (
      'root' => sub {
        my $h = shift;
        $h->{'root'} = shift;
      },
      'none' => sub {
        my $h = shift;
        $h->{'original'} = shift;
        $h->{'offset'} = shift;
      },
      'miss' => sub {
        my $h = shift;
        $h->{'original'} = shift;
        $h->{'count'} = shift; # count will always be 0, when $c eq '?'.
        $h->{'offset'} = shift;
        $h->{'offset'} =~ s/:$//; # offset has trailing colon.

        my @misses = map { s/,$//; $_ } splice @_, 0, $h->{'count'};
        my @guesses = map { s/,$//; $_ } @_;
        $h->{'misses'} = join ' ', @misses;
        $h->{'guesses'} = join ' ', @guesses;
      },
  );
  $modisp{'guess'} = $modisp{'miss'};

  my @results;
    for my $i ( 0 .. $#commentary ) {
      my %h = (
        'term' => $terms[$i],
        'commentary' => $commentary[$i],
      );
      my( $c, @args ) = split ' ', $h{'commentary'};
  
      my $type = $types{$c} || 'unknown';

      $modisp{$type} and $modisp{$type}->( \%h, @args );

      if ( $Text::Ispell::terse && $h{'offset'} ) {
        # need to recalculate the 'term':
        my @terms = grep { /\D/ } split /$split_pattern/, substr $line, $h{'offset'}-1;
	$h{'term'} = $terms[0];
      }

      $h{'type'} = $type;
      push @results, \%h;
    }

  @results
}

sub _send_command($$) {
  my( $cmd, $arg ) = @_;
  defined $arg or $arg = '';
  local $/ = "\n"; local $\ = '';
  chomp $arg;
  _init();
  print Writer "$cmd$arg\n";
}


#
# these add_word commands apparently add the word
# to the dictionary whose persistence is in the
# file "$HOME/.ispell_english".
# I'll bet the "english" part is variable, and
# depends on the current language.
#

=head1 AUX FUNCTIONS

=head2 add_word(word)

Adds a word to the dictionary.  Be careful of capitalization.
If you want the word to be added "case-insensitively", you should
call C<add_word_lc()>

=cut

sub add_word($) {
  _send_command "\*", $_[0];
}

=head2 add_word_lc(word)

Adds a word to the dictionary, in lower-case form.  This allows
ispell to match it in a case-insensitive manner.

=cut

sub add_word_lc($) {
  _send_command "\&", $_[0];
}

=head2 accept_word(word)

Similar to adding a word to the dictionary, in that it causes
ispell to accept the word as valid, but it does not actually
add it to the dictionary.  Presumably the effects of this only
last for the current ispell session.

=cut

sub accept_word($) {
  _send_command "\@", $_[0];
}

=head2 parse_according_to(formatter)

Causes ispell to parse subsequent input lines according to
the specified formatter.  As of ispell v. 3.1.20, only
'tex' and 'nroff' are supported.

=cut

sub parse_according_to($) {
  # must be one of 'tex' or 'nroff'
  _send_command "\-", $_[0];
}

=head2 set_params_by_language(language) 

Causes ispell to set its internal operational parameters
according to the given language.  Legal arguments to this
function, and its effects, are currently unknown by the
author of Text::Ispell.

=cut

sub set_params_by_language($) {
  _send_command "\~", $_[0];
}

=head2 save_dictionary() 

Causes ispell to save the current state of the dictionary
to its disk file.  Presumably ispell would ordinarily
only do this upon exit.

=cut

sub save_dictionary() {
  _send_command "\#", '';
}

=head2 terse_mode()

=head2 nonterse_mode()

In terse mode, ispell will not produce reports for "correct" words.
This means that the calling program will not receive results of the
types 'ok', 'root', and 'compound'.

ispell starts up in NON-terse mode, i.e. reports are produced for
all terms, not just "incorrect" ones.

=cut

sub terse_mode() {
  _send_command "\!", '';
  $Text::Ispell::terse = 1;
}

sub nonterse_mode() {
  _send_command "\%", '';
  $Text::Ispell::terse = 0;
}


1;


=head1 LIMITATIONS

Currently this package assumes, and only supports, the default language,
i.e. English.  It does not provide access to the features of ispell
which allow the selection of alternate languages or dictionaries.

=head1 FUTURE ENHANCEMENTS

Take advantage of these ispell options:

  -d file
       Specify an alternate dictionary file.
       For example, use -d deutsch to choose a German dictionary.

  -p file
       Specify an alternate personal dictionary.

  -w chars
       Specify additional characters that can be part of a word.

  -B   Report run-together words with missing  blanks  as
       spelling errors.

  -C   Consider run-together words as legal compounds.

  -P   Don't generate extra root/affix combinations.

  -m   Make possible root/affix combinations that  aren't
       in the dictionary.

I should consider allowing these kinds of options to be set at
any time; this would entail stopping and restarting the coprocess.

=head1 DEPENDENCIES

Text::Ispell uses the external program ispell, which is
the "International Ispell", available at

  http://fmg-www.cs.ucla.edu/geoff/ispell.html

as well as various archives and mirrors, such as 

  ftp://ftp.math.orst.edu/pub/ispell-3.1/

This is a very popular program, and may already be
installed on your system.

Text::Ispell also uses the standard perl modules FileHandle,
IPC::Open2, and Carp.

=head1 AUTHOR

jdporter@min.net (John Porter)

This module is free software; you may redistribute it and/or
modify it under the same terms as Perl itself.

=cut

