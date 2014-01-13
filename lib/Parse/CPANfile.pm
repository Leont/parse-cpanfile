package Parse::CPANfile;
use strict;
use warnings;

use Carp 'croak';
use CPAN::Meta::Prereqs;

sub load {
	my $class = shift;
	my $filename = shift || 'cpanfile';
	my $input = do { local (@ARGV, $/) = $filename; <> };
	return bless parse_string($input), $class;
}

sub prereqs {
	my $self = shift;
	return CPAN::Meta::Prereqs->new($self->{prereqs});
}

sub prereq_specs {
	my $self = shift;
	return $self->prereqs->as_string_hash;
}

sub feature {
	my ($self, $feature) = @_;
	require CPAN::Meta::Feature;
	my $spec = $self->{features}{$feature} || croak "Unknown feature '$feature'";
	return CPAN::Meta::Feature->new($feature => $spec);
}

sub features {
	my $self = shift;
	return map { $self->feature($_) } keys %{ $self->{features} };
}

sub effective_prereqs {
	my ($self, $features) = @_;
	return $self->prereqs_with(@{$features || []});
}

sub prereqs_with {
	my ($self, @features) = @_;
	my $prereqs = $self->prereqs;
	my @others = map { $self->feature($_)->prereqs } @features;
	return $prereqs->with_merged_prereqs(\@others);
}

sub to_string {
	my($self, $include_empty) = @_;
 
	my $prereqs = $self->{prereqs};
 
	my $code = '';
	$code .= $self->_dump_prereqs($prereqs, $include_empty);
 
	for my $feature (values %{ $self->{features} }) {
		$code .= sprintf "feature %s, %s => sub {\n", _dump($feature->{identifier}), _dump($feature->{description});
		$code .= $self->_dump_prereqs($feature->{spec}, $include_empty, 4);
		$code .= "}\n\n";
	}
 
	$code =~ s/\n+$/\n/s;
	$code;
}

sub _dump {
    my $str = shift;
    require Data::Dumper;
    chomp(my $value = Data::Dumper->new([$str])->Terse(1)->Dump);
    $value;
}
 
sub _dump_prereqs {
	my($self, $prereqs, $include_empty, $base_indent) = @_;
 
	my $code = '';
	for my $phase (qw(runtime configure build test develop)) {
		my $indent = $phase eq 'runtime' ? '' : '	';
		$indent = (' ' x ($base_indent || 0)) . $indent;
 
		my($phase_code, $requirements);
		$phase_code .= "on $phase => sub {\n" unless $phase eq 'runtime';
 
		for my $type (qw(requires recommends suggests conflicts)) {
			for my $mod (sort keys %{$prereqs->{$phase}{$type}}) {
				my $ver = $prereqs->{$phase}{$type}{$mod};
				$phase_code .= $ver eq '0'
							 ? "${indent}$type '$mod';\n"
							 : "${indent}$type '$mod', '$ver';\n";
				$requirements++;
			}
		}
 
		$phase_code .= "\n" unless $requirements;
		$phase_code .= "};\n" unless $phase eq 'runtime';
 
		$code .= $phase_code . "\n" if $requirements or $include_empty;
	}
 
	$code =~ s/\n+$/\n/s;
	$code;
}

my $version = qr/ \d+ (?: \. \d+ )* /x;
my $string = qr/ ' [^']* ' | " [^"]* " | \w+ /x;
my $value = qr/$version|$string/;
my ($type) = map { qr/$_/ } join '|', qw/requires recommends suggests conflicts/;
my ($phase) = map { qr/$_/ } join '|', qw/configure build test runtime develop author/;
my $comment = qr/\# .* $ /mx;
my $whitespace = qr/ (?> \s+ | $comment)* /mx;
my $comma = qr/ $whitespace (?: , | => ) $whitespace /x;
my $lineend = qr/ $whitespace ,? (?: ; | $whitespace (?= } ) ) $whitespace /x;
my $relationship = qr/ (?: ($phase) _ )? ($type) $whitespace ($string) (?: $comma ($string) )* $lineend /mx;
my $phase_begin = qr/ on $whitespace ($string) $comma sub $whitespace \{ /sx;
my $feature_begin = qr/ feature $whitespace ($string) $comma (?: ($string) $comma )? sub $whitespace \{ /sx;
my $block_end = qr/ } $lineend /x;

sub parse_string {
	my $input = shift;
	my %results;
	_parse_current(\$input, \%results, 'runtime', 1);
	croak "Not at end: " . substr $input, pos($input) if not $input =~ /\G\z/;
	return \%results;
}

sub _destring {
	my $value = shift;
	$value =~ s/\A (["']) ([^"']+) \1 \z/$2/x;
	return $value;
}

my %phase_for = (author => 'develop');

sub _parse_current {
	my ($string_ref, $results, $current, $top) = @_;

	for (${ $string_ref }) {
		while (1) {
			1 while /\G $whitespace /gcx;
			if (pos == length) {
				return;
			}
			elsif (!$top && /\G $block_end/gcx) {
				return;
			}
			elsif (/\G $relationship /gcx) {
				my $new_phase = $1 ? $phase_for{$1} || $1 : $current;
				# _destring(substr ${$string_ref}, $-[$_], $+[$_] - $-[$_])
				$results->{prereqs}{$new_phase}{$2}{ _destring($3) } = $4 ? _destring($4) : 0;
			}
			elsif (/\G $phase_begin/gcx) {
				_parse_current(\$_, $results, _destring($1), 0);
			}
			elsif (/\G $feature_begin/gcx) {
				my $ident = _destring($1);
				my $description = $2 ? _destring($2) : $ident;
				_parse_current(\$_, $results->{features}{$ident} ||= { description => $description }, $current, 0);
			}
			elsif (not /\G $comment/gcx) {
				croak "Parse error at: " . substr $_, pos $_;
			}
		}
	}
	return;
}

1;
