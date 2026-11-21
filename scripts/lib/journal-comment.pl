#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use JSON::PP;
use Encode qw(encode);
use MIME::Base64 qw(encode_base64);

my $limit=60_000;
my $json=JSON::PP->new->utf8->canonical;
my $input=do { local $/; <STDIN> };
my $c=$json->decode($input);
my %headings=(
  submit=>'📦 Submitted', bounce=>'🔁 Changes requested', approve=>'✅ Approved',
  ask=>'❓ Decision requested', resume=>'▶️ Resumed', notify=>'📣 Ready for final review',
  close=>'🏁 Closed', hold=>'🛑 On hold', 'hold-clear'=>'▶️ Hold cleared',
  'final-approve'=>'✅ Final approval',
);

sub neutralize_markers {
  my ($s)=@_;
  $s =~ s/agentic(?=-flow(?:-transition|-review|-run|-hold|-hold-clear)?:)/agentic\x{200d}/g;
  $s =~ s/Implemented(?= in [a-fA-F0-9]{40})/Implemented\x{200d}/g;
  return $s;
}

sub outside_code {
  my ($s)=@_;
  $s =~ s/<!--/&lt;!--/g;
  $s =~ s/-->/--&gt;/g;
  $s =~ s{<(/?[A-Za-z][A-Za-z0-9_-]*)>}{&lt;$1&gt;}g;
  $s =~ s/\@/\@\x{200d}/g;
  return $s;
}

sub escape_inline_chunk {
  my ($s)=@_;
  # Only equally long runs of backticks delimit an inline code span.
  $s =~ s{(.*?)(?:(?<![`\\])(`+)(?!`)(.+?)(?<!`)\2(?!`)|\z)}
         {outside_code($1).(defined($2) ? "$2$3$2" : '')}gse;
  return $s;
}

sub inline_markdown {
  my ($s)=@_;
  return join('',map { escape_inline_chunk($_) } split /(\n[ \t]*\r?\n)/,$s);
}

sub markdown {
  my ($s)=@_;
  my ($out,$prose,$fence)=('','','');
  for my $line (split /(?<=\n)/, neutralize_markers($s)) {
    if (length $fence) {
      $out.=$line;
      $fence='' if $line =~ /^ {0,3}(\Q$fence\E[$fence]*)[ \t]*\r?\n?$/;
    } elsif ($line =~ /^ {0,3}(?:(`{3,})[^`\n]*|(~{3,})[^\n]*)\n?$/) {
      $fence=$1//$2;
      $out.=inline_markdown($prose).$line;
      $prose='';
    } else {
      $prose.=$line;
    }
  }
  $out.=inline_markdown($prose);
  # Keep subsequent sections and the run block outside an unfinished fence.
  $out.="\n$fence" if length $fence;
  return $out;
}

sub flatten { my ($s)=@_; $s =~ s/[\r\n]+/ /g; return $s; }
sub cell { my ($s)=@_; $s =~ s/(\\*)\|/$1$1\\|/g; return $s; }
sub code {
  my ($s)=@_;
  my $width=1;
  while ($s =~ /(`+)/g) { $width=length($1)+1 if length($1)>=$width; }
  my $ticks='`' x $width;
  $s=" $s " if $s =~ /^(?:\s|`)|(?:\s|`)$/;
  return "$ticks$s$ticks";
}
sub shortened { my ($s,$max)=@_; return length($s)>$max ? substr($s,0,$max-1).'…' : $s; }

sub render_pull_request {
  my ($pr)=@_;
  my $title=outside_code(neutralize_markers(flatten(shortened($pr->{title},1000))));
  my $goal=markdown(flatten(shortened($pr->{goal},4000)));
  my @lines=("## $title", '', $goal, '',
    '[Approved brief]('.$pr->{brief}.') · [Tracking issue]('.$pr->{tracker}.')', '',
    '| Step | Issue | Approved head | Bounces |', '| --- | --- | --- | --- |');
  for my $step (@{$pr->{steps}}) {
    my $label=cell(outside_code(neutralize_markers(flatten(shortened($step->{title},300)))));
    my $issue=$step->{issue};
    push @lines, '| '.join(' | ',$label,'[#'.$issue.']('.$pr->{issue_root}.'/'.$issue.')',
      code(substr($step->{head},0,12)),$step->{bounces}).' |';
  }
  return join("\n",@lines)."\n";
}

if (exists $c->{pull_request}) {
  my $body=render_pull_request($c->{pull_request});
  if (length($body)>65_536) { print STDERR "PR body exceeds 65,536 characters\n"; exit 2; }
  print encode('UTF-8',$body);
  exit 0;
}

sub evidence_item {
  my $s=markdown($_[0]);
  $s =~ s/\n(?!\z)/\n  /g;
  return "- $s";
}

my $event=$c->{event};
my $r=$c->{result};
my $structured=$event eq 'bounce' && defined $r->{findings};
my @findings=$structured ? @{$r->{findings}} : ();
my @evidence=@{$r->{evidence}//[]};
my ($finding_count,$evidence_count)=(scalar @findings,scalar @evidence);
my ($summary_cut,$rows_cut)=(0,0);
my @rows=map { +{severity=>$_->{severity},
  location=>$_->{file}.':'.($_->{line}//'?'), text=>$_->{text}} } @findings;

sub render {
  my $completeness='';
  if ($structured) {
    my $status=$rows_cut ? 'false' : 'true';
    $completeness="\nfindings-complete=$status; findings-shown=".scalar(@rows)."/$finding_count";
    # The table is lossy even without truncation (e.g. newlines). Carry the
    # original JSON in a delimiter-safe line when the comment is the source.
    $completeness.="\nfindings-json: ".encode_base64($json->encode(\@findings),'') unless $rows_cut;
  }
  my $first=$event eq 'final-approve' ? "<!--\n" : '<!-- ';
  my $heading=$headings{$event};
  $heading.=' · '.outside_code(flatten(neutralize_markers($c->{subject})));
  my $out=$first.$c->{markers}.$completeness."\n-->\n### $heading\n";
  my @parts;
  push @parts,$c->{facts} if length($c->{facts}//'');
  if ($event eq 'submit') {
    my $checks=$c->{checks}//[];
    push @parts,'Checks: '.(@$checks ? join(' · ',map {
      ($_->{passed} ? '✅ ' : '❌ ').($_->{role} eq 'red-first' ? 'Red-first ' : '').code(flatten(neutralize_markers($_->{cmd})))
    } @$checks) : 'not recorded');
  }
  push @parts,markdown($r->{summary}) if length($r->{summary}//'');
  push @parts,'Summary shortened to 1,000 characters.' if $summary_cut;
  push @parts,"Question\n\n".markdown($r->{question}) if length($r->{question}//'');
  push @parts,markdown($c->{diagnostic}) if length($c->{diagnostic}//'');
  push @parts,markdown('Warnings: '.join('; ',@{$c->{warnings}})) if @{$c->{warnings}//[]};
  if ($rows_cut) {
    push @parts,"Showing ".scalar(@rows)." of $finding_count findings." if @rows<$finding_count;
    push @parts,'Finding locations or text shortened.' if $c->{locations_or_text_cut};
  }
  if (@rows) {
    my @table=('| Severity | Location | Finding |', '| --- | --- | --- |');
    for my $row (@rows) {
      push @table,'| '.join(' | ',$row->{severity},
        cell(code(flatten(neutralize_markers($row->{location})))),
        cell(inline_markdown(flatten(neutralize_markers($row->{text}))))).' |';
    }
    push @parts,join("\n",@table);
  }
  push @parts,"<details>\n<summary>Evidence</summary>\n\n".
    join("\n",map { evidence_item($_) } @evidence)."\n\n</details>" if @evidence;
  push @parts,'Showing '.scalar(@evidence)." of $evidence_count evidence items." if @evidence<$evidence_count;

  if (length($c->{owner}//'')) {
    push @parts,'@'.$c->{owner}.' needs a decision: '.markdown($c->{andon_reason});
  }
  $out.="\n".join("\n\n",@parts)."\n" if @parts;
  $out.="\n<!--\n$c->{run_marker}\n-->\n" if length($c->{run_marker}//'');
  return $out;
}

my $comment=render();
if (length($comment)>$limit && $c->{station}) {
  while (@evidence && length($comment)>$limit) { pop @evidence; $comment=render(); }
  if (length($comment)>$limit && length($r->{summary}//'')>1000) {
    $r->{summary}=shortened($r->{summary},1000); $summary_cut=1; $comment=render();
  }
  if (length($comment)>$limit) {
    for my $row (@rows) {
      $rows_cut=1 if length($row->{location})>200 || length($row->{text})>600;
      $row->{location}=shortened($row->{location},200);
      $row->{text}=shortened($row->{text},600);
    }
    $c->{locations_or_text_cut}=$rows_cut;
    $comment=render();
  }
  if (length($comment)>$limit && @rows) {
    @rows=sort { $a->{severity} cmp $b->{severity} } @rows;
    while (@rows && length($comment)>$limit) {
      pop @rows; $rows_cut=1; $comment=render();
    }
  }
}
if (length($comment)>$limit) { print STDERR "journal comment exceeds 60,000 characters\n"; exit 2; }
print encode('UTF-8',$comment);
