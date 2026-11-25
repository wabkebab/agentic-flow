#!/usr/bin/env perl
# Check repository-relative Markdown links and HTML hrefs without network access.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Find qw(find);

my $root = abs_path(shift // die "usage: $0 <repo-root> [<file> ...]\n");
chdir $root or die "$root: $!\n";

my @files = @ARGV;
if (!@files) {
    @files = grep { -f } glob '*.md';
    find({ no_chdir => 1, wanted => sub { push @files, $_ if /\.(?:md|html)\z/i && -f } }, 'docs')
        if -d 'docs';
}

my (%documents, %anchors);
sub document {
    my ($path) = @_;
    return $documents{$path} if exists $documents{$path};
    open my $file, '<:encoding(UTF-8)', $path or die "$path: $!\n";
    my $body = do { local $/; <$file> } // '';
    # Keep line numbers when blanking comments and fenced code examples.
    $body =~ s{<!--.*?-->}{my $text = $&; $text =~ s/[^\n]/ /g; $text}gse;
    if ($path =~ /\.md\z/i) {
        $body =~ s{^([ ]{0,3})(`{3,}|~{3,})[^\n]*\n.*?^[ ]{0,3}\2[^\S\n]*$}
                  {my $text = $&; $text =~ s/[^\n]/ /g; $text}gmse;
    }
    return $documents{$path} = $body;
}

sub anchors {
    my ($path) = @_;
    return $anchors{$path} if exists $anchors{$path};
    my $body = document($path);
    my %ids = map { $_ => 1 } $body =~ /<[a-z][\w:-]*\b[^>]*?\s(?:id|name)\s*=\s*["']([^"']+)["']/gi;
    if ($path =~ /\.md\z/i) {
        for my $heading ($body =~ /^[ ]{0,3}\#{1,6}[ \t]+(.+)$/gm) {
            $heading =~ s/\[([^\]]*)\]\([^)]*\)/$1/g;
            $heading =~ s/<[^>]*>//g;
            $heading = lc $heading;
            $heading =~ s/[^\p{L}\p{M}\p{N}_ -]//g;
            $heading =~ s/^ +| +$//g;
            $heading =~ tr/ /-/;
            my $slug = $heading;
            my $suffix = 0;
            $slug = "$heading-" . ++$suffix while $ids{$slug};
            $ids{$slug} = 1;
        }
    }
    return $anchors{$path} = \%ids;
}

sub decode_url {
    my ($url) = @_;
    # Percent escapes represent UTF-8 bytes, including in fragments.
    utf8::encode($url);
    $url =~ s/%([0-9a-f]{2})/chr(hex($1))/egi;
    utf8::decode($url);
    return $url;
}

my $failed = 0;
sub link_resolves {
    my ($target, $fragment) = @_;
    my $resolved = abs_path($target);
    return 0 if !defined($resolved) || index("$resolved/", "$root/") != 0 || !-e $resolved;
    return 0 if $fragment && $resolved =~ /\.(?:md|html)\z/i && !anchors($resolved)->{decode_url($fragment)};
    return 1;
}

sub check_link {
    my ($source, $line, $url) = @_;
    return if $url =~ m{^(?:[a-z][a-z0-9+.-]*:|//)}i;
    my ($path, $fragment) = split /#/, $url, 2;
    $path =~ s/\?.*//;
    $path = decode_url($path);
    my $target = !$path ? $source
        : $path =~ s{^/}{} ? "$root/$path" : dirname($source) . "/$path";
    return if link_resolves($target, $fragment);
    # Close-out moves a plan from docs/inprogress/ to docs/done/ without editing it, so a
    # sibling link written for its old home must still resolve from there.
    if ($path && $source =~ m{^docs/done/} && $target !~ m{^/}) {
        (my $origin = $source) =~ s{^docs/done/}{docs/inprogress/};
        return if link_resolves(dirname($origin) . "/$path", $fragment);
    }
    print STDERR "$source:$line: broken local link: $url\n";
    $failed = 1;
}

for my $source (sort @files) {
    my $line_no = 0;
    for my $line (split /\n/, document($source)) {
        ++$line_no;
        if ($source =~ /\.md\z/i) {
            $line =~ s/(`+).*?\1//g;
            while ($line =~ /(?<!\\)\]\(\s*(?:<([^>]+)>|([^\s()<>]+))(?=[\s)])/g) {
                check_link($source, $line_no, $1 // $2);
            }
            if ($line =~ /^[ ]{0,3}\[[^\]]+\]:\s*(?:<([^>]+)>|(\S+))/) {
                check_link($source, $line_no, $1 // $2);
            }
        }
        while ($line =~ /<(?:a|img)\b[^>]*?\s(?:href|src)\s*=\s*["']([^"']+)["']/gi) {
            check_link($source, $line_no, $1);
        }
    }
}
exit $failed;
