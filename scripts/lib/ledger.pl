#!/usr/bin/env perl
# Bounded, durable ledger I/O and pure chain/metric derivation. Core Perl only.
use strict;
use warnings;
use JSON::PP;
use Fcntl qw(:DEFAULT :flock SEEK_SET);
use IO::Handle;
use File::Basename qw(dirname);
use File::Spec;
use File::Temp qw(tempfile);
use Digest::SHA qw(sha256_hex);
use Time::HiRes qw(time sleep);
use Time::Local qw(timegm);
use POSIX qw(strftime);
use Encode qw(decode encode FB_CROAK);

my $json=JSON::PP->new->utf8->canonical;
@ARGV=map { decode('UTF-8',$_,FB_CROAK) } @ARGV;
my ($base,$command,@args)=@ARGV;
my $MAX_BYTES=32*1024*1024;
my $MAX_LINE=256*1024;
sub fail { die "ledger: $_[0]\n"; }
sub object { ref($_[0]) eq 'HASH' }
sub text { defined($_[0]) && !ref($_[0]) && $json->encode($_[0]) =~ /^"/ }
sub number { defined($_[0]) && !ref($_[0]) && $json->encode($_[0]) =~ /^-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?$/ }
sub integer { number($_[0]) && $_[0]>=($_[1]//0) && $_[0]<=4_000_000_000_000 && int($_[0])==$_[0] }
sub string { text($_[0]) && length($_[0])<=($_[1]//4096) }
sub identifier { string($_[0],128) && $_[0] =~ /^[a-z0-9][a-z0-9._-]*$/ }
sub hold_id { identifier($_[0]) || (string($_[0],256) && $_[0] =~ m{^[a-z0-9][a-z0-9._-]*/hold/[1-9][0-9]{0,5}$}) }
sub plan_id { identifier($_[0]) or fail('invalid plan id'); return $_[0]; }
sub sha { string($_[0],64) && $_[0] =~ /^[a-f0-9]{$_[1]}$/ }
sub member { my ($x,@values)=@_; return defined($x) && !ref($x) && scalar grep { $_ eq $x } @values; }
sub epoch {
  my ($value)=@_;
  return 0+$value if integer($value);
  if (text($value) && $value =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/) {
    my ($y,$m,$d,$h,$min,$s)=($1,$2,$3,$4,$5,$6);
    my $t=eval { timegm($s,$min,$h,$d,$m-1,$y) };
    return $t if defined($t) && strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($t)) eq $value;
  }
  fail('timestamp must be a UTC epoch or ISO UTC time');
}
sub required { my ($r,@keys)=@_; for (@keys) { exists($r->{$_}) or fail("$r->{kind}: missing $_"); } }
sub run_parts {
  my ($run,$plan)=@_;
  string($run,512) && $run =~ /^([a-z0-9][a-z0-9._-]*)\/([1-9][0-9]{0,8})\/([0-9]{1,9})\/(executor|reviewer)\/([1-9][0-9]{0,8})\/([1-9][0-9]{0,8})$/ or fail('invalid run id');
  my @parts=($1,$2,$3,$4,$5,$6);
  $parts[0] eq $plan or fail('run belongs to another plan');
  return @parts;
}
sub bounded_read {
  my ($fh,$limit)=@_; my $data='';
  while (length($data)<=$limit) {
    my $n=read($fh,my $chunk,65536);
    defined($n) or fail("read: $!"); return $data if $n==0;
    $data.=$chunk;
  }
  fail($_[2]//'file exceeds size cap');
}
sub read_path {
  my ($path,$limit)=@_; sysopen(my $fh,$path,O_RDONLY|O_NONBLOCK) or fail("cannot read $path: $!");
  -f $fh or fail('input must be a regular file'); binmode $fh;
  my $data=bounded_read($fh,$limit); close $fh; return $data;
}
sub parse_json { my $v=eval { $json->decode($_[0]) }; $@ and fail('malformed JSON'); return $v; }
sub lock_file {
  my ($fh,$mode)=@_; my $until=time()+5;
  while (!flock($fh,$mode|LOCK_NB)) { time()<$until or fail('ledger lock timed out'); sleep 0.02; }
}
sub prepare_directory {
  my ($path,$create)=@_; my $root=dirname(dirname($base));
  my @parts=File::Spec->splitdir(File::Spec->abs2rel($path,$root));
  @parts<=32 && !grep { $_ eq '..' || $_ eq '.' || $_ eq '' } @parts or fail('invalid ledger directory');
  my $current=$root;
  for my $part (@parts) {
    $current=File::Spec->catdir($current,$part);
    !-l $current or fail('symlink ledger directory refused');
    if (!-e $current) {
      $create or fail('missing ledger directory');
      mkdir($current,0700) || (!-l $current && -d $current) or fail('cannot create ledger directory');
    }
    -d $current or fail('ledger directory is not a directory');
  }
}
sub sync_directories {
  my ($directory)=@_; my $root=dirname(dirname($base));
  for (1..32) {
    sysopen(my $dh,$directory,O_RDONLY) or fail('cannot open ledger directory for fsync');
    $dh->sync or fail('cannot fsync ledger directory'); close $dh;
    return if $directory eq $root;
    $directory=dirname($directory);
  }
  fail('ledger directory ancestry exceeds cap');
}
sub result_valid {
  my ($r,$station)=@_;
  object($r) && integer($r->{v},1) && $r->{v}==1 && ($r->{station}//'') eq $station or fail('invalid station result');
  member($r->{outcome},$station eq 'executor' ? qw(submitted ask) : qw(approve bounce ask)) or fail('invalid station outcome');
  string($r->{summary},2000) or fail('invalid result summary');
  if ($r->{outcome} eq 'ask') { string($r->{question},1200) && length($r->{question}) or fail('ask requires question'); }
  else { sha($r->{head},40) or fail('result requires head'); }
  if (exists($r->{findings})) {
    ref($r->{findings}) eq 'ARRAY' && @{$r->{findings}}<=100 or fail('invalid findings');
    for my $f (@{$r->{findings}}) {
      object($f) && member($f->{severity},qw(P1 P2 P3)) && string($f->{file}) && string($f->{text},1200) && (!defined($f->{line}) || integer($f->{line},1)) or fail('invalid finding');
    }
  }
  $r->{outcome} ne 'bounce' || (ref($r->{findings}) eq 'ARRAY' && @{$r->{findings}}) or fail('bounce requires findings');
}
sub validate {
  my ($r,$plan)=@_;
  object($r) && integer($r->{v},1) && $r->{v}==1 or fail('invalid record version/object');
  my $k=$r->{kind}//'';
  member($k,qw(intent session station verify decision handoff salvage end hold clear ship takeover)) or fail('unknown record kind');
  exists($r->{plan}) && ($r->{plan}//'') ne $plan and fail('record belongs to another plan');
  !exists($r->{orphan}) || JSON::PP::is_bool($r->{orphan}) or fail('invalid unowned salvage flag');
  if (exists($r->{rebaseline})) {
    ($k eq 'clear' && JSON::PP::is_bool($r->{rebaseline})) ||
      ($k eq 'salvage' && hold_id($r->{rebaseline})) or fail('invalid rebaseline');
  }
  my $orphan=$k eq 'salvage' && $r->{orphan};
  if ($orphan) { ($r->{run}//'') =~ m{^\Q$plan\E/unowned/[a-f0-9]{24}$} && !defined($r->{chain}) or fail('invalid unowned salvage'); }
  run_parts($r->{run},$plan) if !$orphan && $k =~ /^(intent|session|station|verify|decision|handoff|salvage)$/;
  my $time_key=$k eq 'intent' ? 'started' : $k eq 'station' ? 'ended' : 'at';
  required($r,$time_key); epoch($r->{$time_key});
  !exists($r->{reason}) || string($r->{reason},1200) or fail('invalid record reason');
  if ($k eq 'intent') {
    required($r,qw(chain replaces reason plan issue step station cli model resume_of session session_mode reassigned_from seq_before base_head packet_sha256 host));
    my @p=run_parts($r->{run},$plan);
    $r->{chain} eq join('/',@p[0..4]) && integer($r->{issue},1) && $r->{issue}==$p[1] && integer($r->{seq_before}) && $r->{seq_before}==$p[2] && $r->{station} eq $p[3] or fail('intent identity disagrees with run');
    identifier($r->{step}) && member($r->{cli},qw(claude codex opencode)) && string($r->{model},256) && string($r->{host},256) or fail('invalid intent assignment');
    member($r->{reason},qw(initial relaunch resume-result resume-packet fresh-result resume-valid fix resume-dirty fresh-dirty)) or fail('invalid launch reason');
    member($r->{session_mode},qw(new resume fresh-reassigned fresh-dead fresh-launcher-changed)) or fail('invalid session mode');
    for (qw(resume_of session)) { !defined($r->{$_}) || (string($r->{$_},256) && length($r->{$_})) or fail('invalid session'); }
    !defined($r->{reassigned_from}) || member($r->{reassigned_from},qw(claude codex opencode)) or fail('invalid reassigned CLI');
    sha($r->{base_head},40) && sha($r->{packet_sha256},64) or fail('invalid intent hashes');
    run_parts($r->{replaces},$plan) if defined($r->{replaces});
    !exists($r->{profile}) || string($r->{profile}) or fail('invalid profile');
    !exists($r->{contract_mode}) || member($r->{contract_mode},qw(native excluded overridden)) or fail('invalid contract mode');
    !exists($r->{fingerprint}) || sha($r->{fingerprint},64) or fail('invalid launcher fingerprint');
  } elsif ($k eq 'session') {
    required($r,'session'); string($r->{session},256) && length($r->{session}) or fail('invalid session id');
  } elsif ($k eq 'station') {
    required($r,qw(exit seconds usage result invalid_reason));
    integer($r->{exit}) && $r->{exit}<=255 && number($r->{seconds}) && $r->{seconds}>=0 && $r->{seconds}<=1e12 && object($r->{usage}) or fail('invalid station statistics');
    for (qw(input output cost_usd)) {
      exists($r->{usage}{$_}) && (!defined($r->{usage}{$_}) || (number($r->{usage}{$_}) && $r->{usage}{$_}>=0 && $r->{usage}{$_}<=1e12 && ($_ eq 'cost_usd' || integer($r->{usage}{$_})))) or fail('invalid usage');
    }
    !defined($r->{invalid_reason}) || (string($r->{invalid_reason},1200) && length($r->{invalid_reason})) or fail('invalid failure reason');
    !defined($r->{result}) || object($r->{result}) or fail('invalid result');
    defined($r->{result}) || defined($r->{invalid_reason}) or fail('missing result needs invalid_reason');
  } elsif ($k eq 'verify') {
    required($r,qw(head record status)); sha($r->{head},40) && string($r->{record}) && member($r->{status},qw(green red)) or fail('invalid verification');
    !exists($r->{tail}) || string($r->{tail},16384) or fail('invalid verification tail');
  } elsif ($k eq 'decision') {
    required($r,qw(action event head body_file body_sha256));
    member($r->{action},qw(submit approve bounce ask fix hold)) && (!defined($r->{event}) || member($r->{event},qw(submit approve bounce ask fix hold))) or fail('invalid decision');
    (!defined($r->{head}) || $r->{head} eq 'none' || sha($r->{head},40)) && string($r->{body_file}) && sha($r->{body_sha256},64) or fail('invalid decision body/head');
  } elsif ($k eq 'handoff') {
    required($r,qw(attempt event after exit seq_after));
    integer($r->{attempt},1) && member($r->{event},qw(submit approve bounce ask hold)) && integer($r->{after}) && integer($r->{exit}) && $r->{exit}<=255 && (!defined($r->{seq_after}) || integer($r->{seq_after})) or fail('invalid handoff');
  } elsif ($k eq 'salvage') {
    required($r,qw(chain ref head index_commit worktree_commit index_tree worktree_tree paths));
    ($orphan || string($r->{chain},512)) && string($r->{ref},1024) && ref($r->{paths}) eq 'ARRAY' && @{$r->{paths}}<=10000 or fail('invalid salvage');
    for (qw(head index_commit worktree_commit index_tree worktree_tree)) { sha($r->{$_},40) or fail('invalid salvage hash'); }
    for (@{$r->{paths}}) { object($_) && string($_->{path}) && string($_->{status},16) or fail('invalid salvage path'); }
  } elsif ($k eq 'end') {
    required($r,qw(chain how hold));
    string($r->{chain},512) && member($r->{how},qw(dropped held)) && (!defined($r->{hold}) || hold_id($r->{hold})) or fail('invalid chain end');
  } elsif ($k eq 'hold' || $k eq 'clear') {
    required($r,qw(plan hold)); hold_id($r->{hold}) or fail('invalid hold id');
    if ($k eq 'hold') {
      required($r,qw(issue reason run comment_id)); integer($r->{issue},1) && string($r->{reason},1200) && (!defined($r->{comment_id}) || integer($r->{comment_id},1)) or fail('invalid hold');
      run_parts($r->{run},$plan) if defined($r->{run});
    } else { required($r,qw(by note)); string($r->{by},256) && string($r->{note},1200) or fail('invalid clear'); }
  } elsif ($k eq 'takeover') {
    required($r,qw(plan host previous_host run)); string($r->{host},256) && $r->{host}=~/^[a-f0-9]{12}$/ && string($r->{previous_host},256) && $r->{previous_host}=~/^[a-f0-9]{12}$/ && string($r->{run},512) && $r->{run}=~m{^\Q$plan\E/controller/[1-9][0-9]*-[0-9]+$} or fail('invalid takeover');
  } else {
    required($r,qw(plan ship)); identifier($r->{ship}) or fail('invalid ship id');
  }
}
sub empty_state { return {runs=>{},chains=>{},generations=>{},holds=>{},ships=>{},records=>[]}; }
sub terminal { my ($run)=@_; return scalar grep { member($_->{exit},0,3,4,7) } @{$run->{handoffs}}; }
sub generation {
  my ($state,$prefix)=@_; return 1+($state->{generations}{$prefix}//0);
}
sub apply_record {
  my ($state,$r,$plan)=@_; validate($r,$plan);
  my $k=$r->{kind}; my $id=$r->{run};
  if ($k eq 'salvage' && exists($r->{rebaseline})) {
    my $hold=$state->{holds}{$r->{rebaseline}};
    $hold && $hold->{clear} && $hold->{clear}{rebaseline} && !$hold->{rebaseline}
      or fail('salvage requires an unused rebaseline clear');
    $hold->{rebaseline}=$r;
  }
  if ($k eq 'intent') {
    !exists($state->{runs}{$id}) or fail('duplicate intent');
    my @p=run_parts($id,$plan); my $chain=$r->{chain}; my $c=$state->{chains}{$chain};
    if (!$c) {
      !defined($r->{replaces}) && $p[5]==1 && $r->{reason} eq 'initial' or fail('new chain requires initial run 1 without replaces');
      $p[4]==generation($state,join('/',@p[0..3])) or fail('invalid chain generation');
      $c=$state->{chains}{$chain}={runs=>[],latest=>$id};
    } else {
      !$c->{end} && defined($r->{replaces}) && $r->{replaces} eq $c->{latest} && !terminal($state->{runs}{$c->{latest}}) or fail('intent replaces is not the open chain head');
      $p[5]==@{$c->{runs}}+1 && $r->{reason} ne 'initial' or fail('invalid replacement sequence');
    }
    $c->{latest}=$id; push @{$c->{runs}},$id;
    $state->{runs}{$id}={intent=>$r,handoffs=>[]};
  } elsif ($k eq 'end') {
    my $c=$state->{chains}{$r->{chain}}; $c && !$c->{end} or fail('unknown or already ended chain'); $c->{end}=$r;
    my @p=split '/', $r->{chain}; $state->{generations}{join('/',@p[0..3])}++;
  } elsif ($k eq 'hold') {
    !exists($state->{holds}{$r->{hold}}) or fail('duplicate hold'); $state->{holds}{$r->{hold}}={hold=>$r};
  } elsif ($k eq 'clear') {
    my $h=$state->{holds}{$r->{hold}}; $h && !$h->{clear} or fail('unknown or already cleared hold'); $h->{clear}=$r;
  } elsif ($k eq 'takeover' || ($k eq 'salvage' && $r->{orphan})) {
    # Ownership audit and unowned salvage never create a station run.
  } elsif ($k eq 'ship') {
    !exists($state->{ships}{$r->{ship}}) or fail('duplicate ship'); $state->{ships}{$r->{ship}}=$r;
  } else {
    my $run=$state->{runs}{$id}; $run or fail('record has no intent');
    my $c=$state->{chains}{$run->{intent}{chain}};
    # Salvage is an advisory snapshot, also useful when unexplained edits appear
    # after a run finished. Recording it never reopens that run or its chain.
    $k eq 'salvage' || (!$c->{end} && $c->{latest} eq $id && !terminal($run)) or fail('record belongs to a closed/replaced run');
    if ($k eq 'handoff') {
      $run->{decision} && $r->{event} eq ($run->{decision}{event}//'') && $r->{after}==$run->{intent}{seq_before} && $r->{attempt}==@{$run->{handoffs}}+1 or fail('handoff requires decision and next attempt');
      push @{$run->{handoffs}},$r;
    } else {
      # Each flagged clear may adopt another immutable snapshot of this run.
      # Earlier snapshots remain in records; ordinary duplicates still fail.
      !exists($run->{$k}) || ($k eq 'salvage' && exists($r->{rebaseline})) or fail("duplicate $k record");
      # Record captured ids before the station, including confirmation that
      # Claude actually started the caller-chosen session.
      if ($k eq 'session') { !$run->{station} or fail('session must precede station'); }
      if ($k eq 'station' && defined($r->{result})) { result_valid($r->{result},$run->{intent}{station}); }
      if ($k eq 'verify') { !$run->{decision} && $run->{station} && !defined($run->{station}{invalid_reason}) && ($run->{station}{result}{outcome}//'') eq 'submitted' && $r->{head} eq $run->{station}{result}{head} or fail('verify requires submitted station/head before decision'); }
      if ($k eq 'decision') {
        $run->{station} || member($r->{action},qw(ask hold)) or fail('decision requires station');
        if ($r->{action} eq 'submit') { $run->{verify} && $run->{verify}{status} eq 'green' && $r->{head} eq $run->{verify}{head} or fail('submit decision requires green verification/head'); }
      }
      if ($k eq 'salvage') { $r->{chain} eq $run->{intent}{chain} or fail('salvage chain mismatch'); }
      $run->{$k}=$r;
    }
  }
  push @{$state->{records}},$r;
}
sub decode_ledger {
  my ($data,$plan)=@_; length($data)<=$MAX_BYTES or fail('ledger too large');
  my @lines=split /\n/,$data,-1;
  pop @lines if @lines && $lines[-1] eq '';
  @lines<=50000 or fail('ledger too large');
  my (@objects,@invalid,@offsets,%at_offset,%discarded);
  my $offset=0;
  for my $i (0..$#lines) {
    length($lines[$i])<=$MAX_LINE or fail('oversized ledger record');
    $offsets[$i]=$offset; $at_offset{$offset}=$i; $offset+=length($lines[$i])+1;
    $objects[$i]=eval { $json->decode($lines[$i]) }; $invalid[$i]=$@ ? 1 : 0;
  }
  # A repaired append describes the exact discarded byte suffix. Resolve these
  # frames backwards, so a second crash during repair cannot revive an older
  # fragment or turn it into fatal interior corruption. Existing bytes stay put.
  for (my $i=$#lines;$i>=0;$i--) {
    next if $discarded{$i} || !object($objects[$i]);
    my $r=$objects[$i];
    next unless exists($r->{discarded_tail_sha256}) || exists($r->{discarded_tail_bytes});
    sha($r->{discarded_tail_sha256},64) && integer($r->{discarded_tail_bytes},1) && $r->{discarded_tail_bytes}<=$MAX_BYTES or fail('invalid torn-tail frame');
    my $start=$offsets[$i]-1-$r->{discarded_tail_bytes};
    $start>=0 && exists($at_offset{$start}) &&
      sha256_hex(substr($data,$start,$r->{discarded_tail_bytes})) eq $r->{discarded_tail_sha256} or fail('torn-tail frame hash mismatch');
    $discarded{$_}=1 for $at_offset{$start}..$i-1;
  }
  my $state=empty_state(); my $warned=0;
  for my $i (0..$#lines) {
    if ($discarded{$i}) { warn "ledger: ignoring sealed torn line in $plan\n" unless $warned++; next; }
    if ($invalid[$i]) {
      # Only a crash suffix may be ignored. A later unframed complete JSON
      # record makes this interior corruption, which must fail closed.
      for my $j ($i+1..$#lines) {
        !$discarded{$j} && !$invalid[$j] and fail('malformed interior ledger record');
      }
      warn "ledger: ignoring torn last line in $plan\n";
      return ($state,substr($data,$offsets[$i]));
    }
    apply_record($state,$objects[$i],$plan);
  }
  # A complete final JSON object without LF is still a complete record. The
  # next append adds its missing separator without discarding that record.
  return ($state,'');
}
sub load_plan {
  my ($plan)=@_; plan_id($plan); my $path=File::Spec->catfile($base,"$plan.jsonl");
  !-l $path or fail('symlink ledger refused');
  return empty_state() unless -e $path;
  prepare_directory($base,0);
  sysopen(my $fh,$path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW) or fail("cannot open ledger: $!");
  -f $fh or fail('ledger must be a regular file');
  lock_file($fh,LOCK_SH); my $data=bounded_read($fh,$MAX_BYTES,'ledger too large'); close $fh;
  return (decode_ledger($data,$plan))[0];
}
# Redact before taking the final byte window. Read one key-length of lookbehind
# so a value straddling the left boundary cannot leave a clear-text suffix.
sub redact {
  my ($bytes)=@_;
  my @keys=sort { length($b)<=>length($a) } grep { length } map { $ENV{$_}//'' } qw(ANTHROPIC_API_KEY OPENAI_API_KEY);
  if (@keys) { my $pattern=join('|',map { quotemeta($_) } @keys); $bytes =~ s/(?:$pattern)/[redacted]/g; }
  return $bytes;
}
sub output_tail {
  my ($path,$cap)=@_;
  my $look=0; for (qw(ANTHROPIC_API_KEY OPENAI_API_KEY)) { my $n=length($ENV{$_}//''); $look=$n if $n>$look; }
  $look<=1024*1024 or fail('provider value exceeds cap');
  sysopen(my $fh,$path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW) or fail('cannot open diagnostic output');
  -f $fh or fail('diagnostic input must be a regular file'); binmode $fh;
  my $size=-s $fh; my $offset=$size>$cap+$look ? $size-$cap-$look : 0;
  sysseek($fh,$offset,SEEK_SET); my $bytes=redact(bounded_read($fh,$cap+$look)); close $fh;
  return length($bytes)>$cap ? substr($bytes,-$cap) : $bytes;
}
sub store_tails {
  my ($plan,$run,$events,$stderr)=@_; plan_id($plan); my @p=run_parts($run,$plan);
  my $station=load_plan($plan)->{runs}{$run}{station} or fail('missing station for output');
  return unless defined($station->{invalid_reason});
  my $dir=File::Spec->catdir($base,'runs',@p); prepare_directory($dir,1);
  for my $input ([$events,'events.tail',256*1024],[$stderr,'stderr.tail',64*1024]) {
    my ($source,$name,$cap)=@$input; next unless length($source);
    my $path=File::Spec->catfile($dir,$name);
    !-l $path && (!-e $path || -f $path) or fail('unsafe diagnostic destination');
    my $bytes=output_tail($source,$cap);
    my ($fh,$temp)=tempfile('.tail.XXXXXX',DIR=>$dir,UNLINK=>0); binmode $fh;
    print {$fh} $bytes or fail('cannot write diagnostic tail'); $fh->sync or fail('cannot fsync diagnostic tail');
    close $fh or fail('cannot close diagnostic tail'); rename($temp,$path) or fail('cannot publish diagnostic tail');
  }
  sync_directories($dir);
}
sub utf8_text { return decode('UTF-8',$_[0]); }
sub clip_text { # UTF-8 byte ceiling, never split a code point
  my ($s,$limit)=@_; my $out='';
  for my $c (split //,$s) { last if length(encode('UTF-8',$out.$c))>$limit; $out.=$c; }
  return $out;
}
sub bounded_comment {
  my $body=utf8_text(redact(read_path($_[0],$MAX_LINE)));
  if (length(encode('UTF-8',$body))>4096) {
    # Keep the journal/hold marker and cause, plus the closing paths, retry and
    # owner mention. Redact before clipping so a cut cannot expose a key suffix.
    my $notice="\n[comment truncated to 4 KiB]\n";
    my $end=reverse clip_text(scalar reverse($body),4096-3072-length($notice));
    $body=clip_text($body,3072).$notice.$end;
  }
  return encode('UTF-8',$body);
}
sub diagnostic_note {
  my ($plan,$run,$issue,$cause_file,$records_file)=@_; plan_id($plan);
  run_parts($run,$plan) unless $run eq 'none';
  $issue=~/^[1-9][0-9]{0,9}$/ or fail('invalid diagnostic issue');
  my $records=parse_json(read_path($records_file,$MAX_BYTES)); ref($records) eq 'ARRAY' && @$records<=50000 or fail('invalid diagnostic records');
  my ($intent,$station,$verify);
  for my $r (@$records) { next unless ($r->{run}//'') eq $run;
    $intent=$r if $r->{kind} eq 'intent'; $station=$r if $r->{kind} eq 'station'; $verify=$r if $r->{kind} eq 'verify'; }
  my $cause=utf8_text(redact(read_path($cause_file,256*1024)));
  my ($preflight_exit,$preflight_seconds,$preflight_tail);
  if ($cause =~ /\A(station-infrastructure: Launch preflight failed before station start\. Exit: (\d+); seconds: (\d+)\.)\n(.*)\z/s) {
    ($cause,$preflight_exit,$preflight_seconds,$preflight_tail)=($1,$2,$3,$4);
  }
  $cause =~ s/\s+/ /g;
  my $header=clip_text($cause,300)."\nStation: ".($intent->{station}//'none')."; step: ".($intent->{step}//'none')."; run: $run; head: ".($station->{result}{head}//$intent->{base_head}//'none')."\n";
  $header.='Exit: '.($preflight_exit//$station->{exit}//'n/a').'; seconds: '.($preflight_seconds//$station->{seconds}//'n/a').'; usage: '.$json->encode($station->{usage}//{input=>undef,output=>undef,cost_usd=>undef})."\n";
  my @sections; my @paths=(File::Spec->catfile($base,"$plan.jsonl"));
  push @sections,['Launch stderr',$preflight_tail,20] if defined($preflight_tail);
  if ($verify) {
    my $path=$verify->{record}//'';
    my $dir=File::Spec->catdir(dirname($base),'verify');
    if ($path =~ /^\Q$dir\E\/[a-f0-9]{40}\.json$/ && -f $path && !-l $path) {
      my $record=parse_json(read_path($path,8*1024*1024));
      my @commands=(@{$record->{commands}//[]});
      unshift @commands,$record->{prepare} if !@commands && $record->{prepare} && $record->{prepare}{exit};
      @commands<=100 or fail('too many diagnostic commands');
      for my $c (@commands) { next unless $c->{exit};
        push @sections,["Command: $c->{cmd}; exit: $c->{exit}",utf8_text(redact(encode('UTF-8',$c->{output_tail}//''))),30]; }
    }
    push @sections,['Verifier output',utf8_text(redact(encode('UTF-8',$verify->{tail}//''))),30] unless @sections;
    push @paths,$path;
  }
  if ($station && defined($station->{invalid_reason}) && $run ne 'none') {
    my @p=run_parts($run,$plan); my $dir=File::Spec->catdir($base,'runs',@p);
    prepare_directory($dir,0) if -e $dir;
    for my $name ('events.tail','stderr.tail') {
      my $path=File::Spec->catfile($dir,$name); push @paths,$path;
      my $text=-e $path ? utf8_text(output_tail($path,$name eq 'events.tail' ? 256*1024 : 64*1024)) : '(not retained)';
      push @sections,[$name,$text,20];
    }
  }
  my $answer='<answer-file>';
  if ($run ne 'none') {
    my @p=run_parts($run,$plan); $answer=File::Spec->catfile($base,'runs',@p,'decision.md');
    $answer =~ s/'/'"'"'/g; $answer="'$answer'";
  }
  my $retry=$cause =~ /^station-infrastructure:/
    ? "scripts/agentic-flow handoff $issue hold-clear --as approver --hold-id <hold-id>; then run the plan again"
    : "scripts/agentic-flow handoff $issue resume --as approver --body-file $answer";
  my $footer="Ledger: ".join("\n",@paths)."\nRetry: $retry\n";
  # Leave room for the transition/hold markers and owner mention added by handoff.
  my $budget=3200-length(encode('UTF-8',$header.$footer));
  $budget>=0 or fail('diagnostic identity exceeds comment budget');
  my $each=@sections ? int($budget/@sections) : 0; my $body='';
  for my $section (@sections) {
    my ($title,$text,$lines)=@$section; my @lines=split /\n/,$text; splice(@lines,0,@lines-$lines) if @lines>$lines;
    my $title_text=utf8_text(redact(encode('UTF-8',$title)));
    my $suffix=$title_text =~ s/(; exit: [0-9]+)$// ? $1 : '';
    my $heading=clip_text($title_text,int($each/2)-length($suffix)).$suffix."\n";
    my $remaining=$each-length(encode('UTF-8',$heading))-48;
    my $per=@lines ? int(($remaining>0?$remaining:0)/@lines) : 0;
    $body.=$heading."[last $lines lines; bounded excerpt]\n".join("\n",map { length(encode('UTF-8',$_))<=$per ? $_ : ($per>=3 ? clip_text($_,$per-3).'...' : '') } @lines)."\n";
  }
  print redact(encode('UTF-8',$header.$body.$footer));
}
sub store_body {
  my ($r,$plan)=@_; my $body=read_path($r->{body_file},$MAX_LINE);
  sha256_hex($body) eq $r->{body_sha256} or fail('decision body hash mismatch');
  my @p=run_parts($r->{run},$plan); my $dir=File::Spec->catdir($base,'runs',@p);
  prepare_directory($dir,1); my $path=File::Spec->catfile($dir,'decision.md');
  if (-e $path || -l $path) { !-l $path && sha256_hex(read_path($path,$MAX_LINE)) eq $r->{body_sha256} or fail('stored decision body differs'); }
  else {
    my ($fh,$temp)=tempfile('.body.XXXXXX',DIR=>$dir,UNLINK=>0); binmode $fh;
    print {$fh} $body or fail('cannot write decision body'); $fh->sync or fail('cannot fsync decision body'); close $fh or fail('cannot close decision body');
    rename($temp,$path) or fail('cannot publish decision body');
  }
  sync_directories($dir);
  $r->{body_file}=$path;
}
sub append_record {
  # The controller handles interruption after its synchronous append completes.
  # A terminal process-group signal must not interrupt publication or fsync.
  local $SIG{INT}='IGNORE'; local $SIG{TERM}='IGNORE';
  my ($kind,$plan,$file)=@_; plan_id($plan);
  my $r=parse_json(read_path($file,$MAX_LINE)); object($r) && ($r->{kind}//'') eq $kind or fail('writer/record kind mismatch');
  !exists($r->{discarded_tail_sha256}) && !exists($r->{discarded_tail_bytes}) or fail('reserved recovery framing field');
  validate($r,$plan); prepare_directory($base,1); my $path=File::Spec->catfile($base,"$plan.jsonl");
  !-l $path or fail('symlink ledger refused');
  sysopen(my $fh,$path,O_RDWR|O_CREAT|O_APPEND|O_NONBLOCK|O_NOFOLLOW,0600) or fail("cannot open ledger: $!");
  -f $fh or fail('ledger must be a regular file');
  lock_file($fh,LOCK_EX); sysseek($fh,0,SEEK_SET); my $data=bounded_read($fh,$MAX_BYTES,'ledger too large');
  my ($state,$tail)=decode_ledger($data,$plan);
  apply_record($state,$r,$plan); store_body($r,$plan) if $kind eq 'decision';
  if (length($tail)) { $r->{discarded_tail_sha256}=sha256_hex($tail); $r->{discarded_tail_bytes}=length($tail); }
  my $line=$json->encode($r); length($line)<=$MAX_LINE or fail('oversized ledger record');
  my $separator=length($tail) || (length($data) && $data!~/\n\z/) ? "\n" : '';
  my $bytes=$separator.$line."\n";
  length($data)+length($bytes)<=$MAX_BYTES && scalar(()=$data=~/\n/g)+(length($separator)?1:0)+1<=50000 or fail('ledger too large');
  my $written=syswrite($fh,$bytes); defined($written) && $written==length($bytes) or fail('incomplete ledger append');
  $fh->sync or fail('cannot fsync ledger'); sync_directories($base); close $fh or fail('cannot close ledger');
  return $r;
}
sub summaries {
  my ($state,$context)=@_; my @out;
  for my $chain (sort { epoch($state->{runs}{$state->{chains}{$a}{runs}[0]}{intent}{started}) <=> epoch($state->{runs}{$state->{chains}{$b}{runs}[0]}{intent}{started}) || $a cmp $b } keys %{$state->{chains}}) {
    my $c=$state->{chains}{$chain}; my $id=$c->{latest}; my $r=$state->{runs}{$id}; my $intent=$r->{intent};
    my ($invalid,$fixes,$recoveries)=(0,0,0);
    for my $run (@{$c->{runs}}) {
      my $x=$state->{runs}{$run}; $invalid++ if $x->{station} && defined($x->{station}{invalid_reason}) && $x->{station}{invalid_reason} !~ /^pre-launch failure/;
      $fixes++ if $x->{intent}{reason} eq 'fix';
      $recoveries++ if member($x->{intent}{reason},qw(relaunch resume-result resume-packet fresh-result resume-dirty fresh-dirty));
    }
    my $closed=$c->{end} || terminal($r); my $pending; my $escalation;
    my $session=$r->{session} ? $r->{session}{session} : ($intent->{session}//$intent->{resume_of});
    my $ctx=$context->{$id}//{};
    if (!$closed) {
      if ($r->{decision}) { $pending='handoff'; }
      elsif ($r->{station} && ($r->{station}{invalid_reason}//'') =~ /^pre-launch failure/) { $pending='infrastructure'; }
      elsif ($r->{station} && $r->{station}{exit}==124) { $pending='decide'; $escalation='station timed out'; }
      elsif ($r->{station} && ($r->{station}{invalid_reason}//'') eq 'bad claimed head') { $pending='decide'; $escalation='bad claimed head'; }
      elsif ($r->{station} && defined($r->{station}{invalid_reason})) { $pending=$invalid<2 ? 'resume-valid' : 'decide'; $escalation='malformed station result' if $invalid>=2; }
      elsif ($r->{verify}) { $pending=$r->{verify}{status} eq 'red' && !$fixes ? 'fix' : 'decide'; $escalation='gate still red after fix' if $r->{verify}{status} eq 'red' && $fixes; }
      elsif ($r->{station}) { $pending=($r->{station}{result}{outcome}//'') eq 'submitted' ? 'verify' : 'decide'; }
      else {
        if ($intent->{station} eq 'reviewer') { $pending='relaunch'; }
        elsif ($ctx->{dirty}) { $pending=defined($session) ? 'resume-dirty' : 'fresh-dirty'; }
        elsif ($ctx->{commit}) { $pending=defined($session) ? 'resume-result' : 'fresh-result'; }
        else { $pending=defined($session) ? 'resume-packet' : 'relaunch'; }
        if ($recoveries>=3) { $pending='decide'; $escalation='station keeps failing to finish'; }
      }
    }
    my @closed_runs=grep { $_ ne $id || $closed } @{$c->{runs}};
    push @out,{chain=>$chain,head=>$closed ? undef : $id,latest=>$id,pending=>$pending,escalation=>$escalation,session=>$session,
      closed_runs=>\@closed_runs,counts=>{invalid_results=>$invalid,fixes=>$fixes,recoveries=>$recoveries},
      remaining=>{resume_valid=>$invalid<2 ? 1 : 0,fix=>$fixes ? 0 : 1,recovery=>$recoveries<3 ? 3-$recoveries : 0}};
  }
  return \@out;
}

sub cache_rows {
  my ($dir,$plan)=@_; my $path=File::Spec->catfile($dir,"$plan.metrics.json");
  return undef unless -e $path;
  my $c=parse_json(read_path($path,4*1024*1024));
  object($c) && integer($c->{v},1) && $c->{v}==1 && ($c->{plan}//'') eq $plan && ref($c->{rows}) eq 'ARRAY' && @{$c->{rows}}<=101 or fail('invalid metrics state cache');
  my %issues; my %events;
  for my $row (@{$c->{rows}}) {
    object($row) && integer($row->{issue},1) && identifier($row->{step}) && member($row->{state},qw(executing reviewing approved escalated open closing closed)) && member($row->{topology},qw(step-strict work-standard tracker)) && ref($row->{events}) eq 'ARRAY' && @{$row->{events}}<=100 or fail('invalid cache row');
    !$issues{$row->{issue}}++ or fail('duplicate cache issue');
    for my $e (@{$row->{events}}) {
      object($e) && string($e->{id},512) && member($e->{event},qw(submit bounce resume approve notify close ask)) && member($e->{role},qw(executor reviewer approver)) or fail('invalid cached event');
      $e->{id} =~ /^\Q$plan\E\/\Q$row->{step}\E\/[1-9][0-9]{0,8}\/\Q$e->{event}\E$/ or fail('cached event identity mismatch');
      !$events{$e->{id}}++ or fail('duplicate cached event');
      epoch($e->{at}) if defined($e->{at});
    }
  }
  return $c->{rows};
}
sub within { my ($at,$since)=@_; return !defined($since) || (defined($at) && epoch($at)>=$since); }
sub usage_sum {
  my ($stations)=@_; my (%usage,%unknown);
  for my $field (qw(input output cost_usd)) {
    my ($sum,$known,$missing)=(0,0,0);
    for my $s (@$stations) {
      if (defined($s->{usage}{$field})) { $sum+=$s->{usage}{$field}; $known++; }
      else { $missing++; }
    }
    $usage{$field}=$known ? $sum : undef;
    $unknown{$field}=$missing;
  }
  return (\%usage,\%unknown);
}
sub breakdown {
  my ($runs)=@_; my @stations=map { $_->{station} ? ($_->{station}) : () } @$runs;
  my @usage=map { $_->{station}//{usage=>{input=>undef,output=>undef,cost_usd=>undef}} } @$runs;
  my $seconds=0; $seconds+=$_->{seconds} for @stations;
  my ($usage,$unknown)=usage_sum(\@usage);
  return {runs=>scalar(@$runs),completed=>scalar(@stations),wall_seconds=>$seconds,usage=>$usage,usage_unknown=>$unknown};
}
sub plan_metrics {
  my ($plan,$state,$rows,$since)=@_; my @runs; my %station_runs; my %step_runs; my %station_issues; my %issue_quality;
  my $first; my %station_first;
  for my $r (values %{$state->{runs}}) {
    my $i=$r->{intent}; my $t=epoch($i->{started});
    $first=$t if !defined($first) || $t<$first;
    $station_first{$i->{station}}=$t if !exists($station_first{$i->{station}}) || $t<$station_first{$i->{station}};
    next unless within($i->{started},$since) || ($r->{station} && within($r->{station}{ended},$since));
    push @runs,$r; push @{$station_runs{$i->{station}}},$r; push @{$step_runs{$i->{step}}{$i->{station}}},$r;
    $station_issues{$i->{station}}{$i->{issue}}=1;
  }
  my ($approvals,$resumes,$bounces,$approved,$first_pass)=(0,0,0,0,0); my $closed;
  if (defined($rows)) {
    for my $row (@$rows) {
      my @e=@{$row->{events}}; my @b=grep { $_->{event} eq 'bounce' } @e;
      if ($row->{topology} ne 'tracker' && grep { $_->{event} eq 'approve' && within($_->{at},$since) } @e) {
        $approved++; $first_pass++ if !@b;
        $issue_quality{$row->{issue}}{approved}=1; $issue_quality{$row->{issue}}{first_pass}=@b ? 0 : 1;
      }
      for my $e (@e) {
        if ($e->{event} eq 'close' && defined($e->{at}) && ($row->{topology} eq 'tracker' || $row->{topology} eq 'work-standard')) {
          my $t=epoch($e->{at}); $closed=$t if !defined($closed) || $t>$closed;
        }
        next unless within($e->{at},$since);
        if ($e->{event} eq 'approve') { $approvals++; $issue_quality{$row->{issue}}{approvals}++; }
        if ($e->{event} eq 'resume') { $resumes++; }
        if ($e->{event} eq 'bounce') { $bounces++; $issue_quality{$row->{issue}}{bounces}++; }
      }
    }
  }
  my %andon; my %station_andon; my $ships=0;
  for my $r (@{$state->{records}}) {
    next unless $r->{kind} =~ /^(hold|decision|ship)$/ && within($r->{at},$since);
    $ships++ if $r->{kind} eq 'ship';
    my $reason;
    $reason=$r->{reason} if $r->{kind} eq 'hold';
    $reason=$r->{reason}//'ask' if $r->{kind} eq 'decision' && $r->{action} eq 'ask';
    if (defined($reason)) {
      $andon{$reason}++;
      my $run=defined($r->{run}) ? $state->{runs}{$r->{run}} : undef;
      $station_andon{$run->{intent}{station}}{$reason}++ if $run;
    }
  }
  my $m=breakdown(\@runs);
  $m->{plan}=$plan; $m->{journal_available}=defined($rows) ? JSON::PP::true : JSON::PP::false;
  $m->{lead_seconds}=defined($first) && defined($closed) && $closed>=$first ? $closed-$first : undef;
  $m->{first_pass_yield}=defined($rows) && $approved ? $first_pass/$approved : undef;
  $m->{bounce_rate}=defined($rows) && $bounces+$approvals ? $bounces/($bounces+$approvals) : undef;
  $m->{approved_steps}=defined($rows) ? $approved : undef;
  $m->{bounces}=defined($rows) ? $bounces : undef; $m->{andon}=\%andon;
  $m->{human_touches}={resumes=>defined($rows) ? $resumes : undef,approvals=>defined($rows) ? $approvals : undef,ships=>$ships,total=>defined($rows) ? $resumes+$approvals+$ships : undef};
  my %stations;
  for my $s (sort keys %station_runs) {
    my $b=breakdown($station_runs{$s});
    $b->{lead_seconds}=defined($closed) && $closed>=$station_first{$s} ? $closed-$station_first{$s} : undef;
    $b->{andon}=$station_andon{$s}//{};
    my ($approved_here,$first_here,$approvals_here,$bounces_here)=(0,0,0,0);
    for my $issue (keys %{$station_issues{$s}}) {
      my $q=$issue_quality{$issue}//{};
      $approved_here+=$q->{approved}//0; $first_here+=$q->{first_pass}//0;
      $approvals_here+=$q->{approvals}//0; $bounces_here+=$q->{bounces}//0;
    }
    $b->{first_pass_yield}=defined($rows) && $approved_here ? $first_here/$approved_here : undef;
    $b->{bounce_rate}=defined($rows) && $approvals_here+$bounces_here ? $bounces_here/($approvals_here+$bounces_here) : undef;
    $stations{$s}=$b;
  }
  $m->{stations}=\%stations;
  my @steps;
  for my $step (sort keys %step_runs) {
    for my $s (sort keys %{$step_runs{$step}}) { push @steps,{step=>$step,station=>$s,%{breakdown($step_runs{$step}{$s})}}; }
  }
  $m->{steps}=\@steps; return $m;
}
sub scan_plans {
  my ($dir,$suffix)=@_; return () unless -d $dir;
  opendir(my $dh,$dir) or fail("cannot scan $dir");
  my @plans; my $entries=0;
  while (defined(my $entry=readdir($dh))) {
    ++$entries<=5000 or fail('too many directory entries');
    if ($entry =~ /^([a-z0-9][a-z0-9._-]*)\Q$suffix\E$/) { push @plans,$1; @plans<=1000 or fail('too many plan ledgers'); }
  }
  closedir($dh); return @plans;
}
sub metrics {
  my ($plan,$date,$as_json,$state_dir)=@_; my $since;
  if (length($date)) { $date.='T00:00:00Z' if $date =~ /^\d{4}-\d{2}-\d{2}$/; $since=epoch($date); }
  my %plans;
  if (length($plan)) { $plans{plan_id($plan)}=1; }
  else { $plans{$_}=1 for (scan_plans($base,'.jsonl'),scan_plans($state_dir,'.metrics.json')); keys(%plans)<=1000 or fail('too many plans'); }
  my @result;
  for my $p (sort keys %plans) { push @result,plan_metrics($p,load_plan($p),cache_rows($state_dir,$p),$since); }
  if ($as_json eq 'true') { print $json->encode({v=>1,plans=>\@result}),"\n"; return; }
  sub show { defined($_[0]) ? $_[0] : 'n/a' }
  if (!@result) { print "No ledger records.\n"; }
  for my $m (@result) {
    print "Plan $m->{plan}\n";
    print "  Lead seconds: ",show($m->{lead_seconds}),"; first-pass yield: ",show($m->{first_pass_yield}),"; bounce rate: ",show($m->{bounce_rate}),"\n";
    print "  Human touches: ",show($m->{human_touches}{total}),"; runs: $m->{runs}; wall seconds: $m->{wall_seconds}\n";
    print "  Tokens input/output: ",show($m->{usage}{input}),"/",show($m->{usage}{output}),"; cost USD: ",show($m->{usage}{cost_usd}),"; unknown runs input/output/cost: ",join('/',@{$m->{usage_unknown}}{qw(input output cost_usd)}),"\n";
    print encode('UTF-8',"  Andon: ".join(', ',map { "$_=$m->{andon}{$_}" } sort keys %{$m->{andon}})),"\n";
    for my $step (@{$m->{steps}}) {
      print "  $step->{step} $step->{station}: runs=$step->{runs} wall=$step->{wall_seconds} input=",show($step->{usage}{input})," output=",show($step->{usage}{output})," cost=",show($step->{usage}{cost_usd})," unknown runs input/output/cost: ",join('/',@{$step->{usage_unknown}}{qw(input output cost_usd)}),"\n";
    }
  }
}
my $ok=eval {
  if ($command eq 'output-tail' && @args==2) {
    $args[1] =~ /^(65536|16384|262144|4096)$/ or fail('invalid tail cap');
    my $bytes=encode('UTF-8',utf8_text(output_tail(@args)));
    if (length($bytes)>$args[1]) { $bytes=substr($bytes,-$args[1]); $bytes =~ s/^[\x80-\xbf]+//; }
    print $bytes;
  }
  elsif ($command eq 'comment' && @args==1) { print bounded_comment($args[0]); }
  elsif ($command eq 'tails' && @args==4) { store_tails(@args); }
  elsif ($command eq 'diagnostic' && @args==5) { diagnostic_note(@args); }
  elsif ($command eq 'append' && @args==3) { print $json->encode(append_record(@args)),"\n"; }
  elsif ($command eq 'read' && @args==1) { print $json->encode(load_plan($args[0])->{records}),"\n"; }
  elsif ($command eq 'chains' && (@args==1 || @args==2)) {
    my $context=@args==2 ? parse_json(read_path($args[1],4*1024*1024)) : {};
    object($context) && keys(%$context)<=50000 or fail('invalid recovery context');
    for my $id (keys %$context) {
      run_parts($id,$args[0]); my $c=$context->{$id};
      object($c) && (!exists($c->{dirty}) || JSON::PP::is_bool($c->{dirty})) && (!exists($c->{commit}) || JSON::PP::is_bool($c->{commit})) or fail('invalid recovery context');
    }
    print $json->encode(summaries(load_plan($args[0]),$context)),"\n";
  } elsif ($command eq 'generation' && @args==4) {
    my ($p,$issue,$seq,$station)=@args; plan_id($p);
    $issue=~/^[1-9][0-9]{0,8}$/ && $seq=~/^[0-9]{1,9}$/ && member($station,qw(executor reviewer)) or fail('invalid generation identity');
    print generation(load_plan($p),"$p/$issue/$seq/$station"),"\n";
  } elsif ($command eq 'body' && @args==2) {
    my ($p,$id)=@args; run_parts($id,$p); my $r=load_plan($p)->{runs}{$id}{decision};
    $r or fail('missing decision'); my @parts=run_parts($id,$p);
    $r->{body_file} eq File::Spec->catfile($base,'runs',@parts,'decision.md') && !-l $r->{body_file} or fail('unexpected decision body path');
    prepare_directory(dirname($r->{body_file}),0);
    my $body=read_path($r->{body_file},$MAX_LINE); sha256_hex($body) eq $r->{body_sha256} or fail('decision body hash mismatch'); print $body;
  } elsif ($command eq 'metrics' && @args==4) { metrics(@args); }
  else { fail('invalid ledger operation/arguments'); }
  1;
};
if (!$ok) { my $error=$@||"ledger: unknown error\n"; print STDERR encode('UTF-8',$error); exit 2; }
