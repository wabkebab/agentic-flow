#!/usr/bin/env perl
# Read Codex's effective merged config without starting a model turn.
use strict;
use warnings;
use IPC::Open2;
use JSON::PP qw(encode_json decode_json);
my $cwd = shift @ARGV;
my ($reader, $writer);
my $pid = open2($reader, $writer, 'codex', 'app-server', @ARGV);
sub finish { close $writer; kill 'TERM', $pid; waitpid($pid, 0); }
$SIG{ALRM} = sub { finish(); exit 6; };
alarm 15;
select((select($writer), $|=1)[0]);
print $writer encode_json({id=>1,method=>'initialize',params=>{clientInfo=>{name=>'agentic-station-preflight',version=>'1'},capabilities=>{}}}), "\n";
print $writer encode_json({method=>'initialized'}), "\n";
print $writer encode_json({id=>2,method=>'config/read',params=>{includeLayers=>JSON::PP::false,cwd=>$cwd}}), "\n";
my $bytes=0;
for (1..1000) {
    my $line=<$reader>;
    last unless defined $line;
    $bytes+=length $line;
    last if $bytes>4*1024*1024;
    my $reply=eval { decode_json($line) };
    next unless ref($reply) eq 'HASH' && defined($reply->{id}) && $reply->{id} eq '2';
    my $config=$reply->{result}{config};
    if (ref($config) eq 'HASH') { print encode_json($config), "\n"; finish(); alarm 0; exit 0; }
    last;
}
finish(); exit 6;
