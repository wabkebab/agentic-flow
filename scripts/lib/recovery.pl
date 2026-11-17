#!/usr/bin/env perl
# Git snapshots and process identity, using argument arrays and temporary indexes only.
use strict;
use warnings;
use JSON::PP;
use Digest::SHA qw(sha256_hex);
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);
use File::Temp qw(tempfile);
use File::Copy qw(copy);
use File::Spec;
use Errno qw(ESRCH);
my $json=JSON::PP->new->utf8->canonical;
sub fail { die "recovery: $_[0]\n"; }
sub command {
  my (@args)=@_; my $err=gensym;
  my $pid=open3(my $in,my $out,$err,$^X,'-MPOSIX=setsid','-e','setsid() or die $!; exec @ARGV',@args);
  close $in; my $select=IO::Select->new($out,$err); my ($stdout,$stderr)=('','');
  my $ok=eval {
    local $SIG{ALRM}=sub { die "command timed out\n"; };
    local $SIG{INT}=sub { die "command interrupted\n"; };
    local $SIG{TERM}=sub { die "command terminated\n"; };
    alarm 30;
    while ($select->count) {
      for my $fh ($select->can_read(1)) {
        my $n=sysread($fh,my $chunk,65536); defined($n) or die "read: $!\n";
        if (!$n) { $select->remove($fh); close $fh; next; }
        if ($fh==$out) { $stdout.=$chunk; } else { $stderr.=$chunk; }
        length($stdout)+length($stderr)<=33554432 or die "command output exceeds cap\n";
      }
    }
    waitpid($pid,0); my $status=$?; alarm 0;
    kill 'KILL',-$pid;
    $status==0 or die "command failed: $stderr\n";
    1;
  };
  if (!$ok) { my $error=$@; alarm 0; kill 'KILL',-$pid; waitpid($pid,0); die $error; }
  return $stdout;
}
sub git { my ($root,@args)=@_; local $ENV{GIT_OPTIONAL_LOCKS}=0; command('git','-C',$root,'-c','core.hooksPath=/dev/null','-c','core.fsmonitor=false','-c','commit.gpgsign=false',@args) }
sub trim { my $s=$_[0]; $s=~s/\s+\z//; $s }
sub process_start {
  local $ENV{LC_ALL}='C'; local $ENV{TZ}='UTC';
  my ($pid)=@_; $pid=~/^[1-9][0-9]*$/ or fail('invalid pid');
  if (!kill(0,$pid)) { return '' if $! == ESRCH; fail('cannot inspect controller process'); }
  my $start=trim(command('ps','-p',$pid,'-o','lstart='));
  length($start) or fail('cannot read live process start time');
  return $start;
}
sub paths {
  my ($root)=@_; my $status=git($root,'status','--porcelain=v2','-z','--untracked-files=all');
  length($status)<=1048576 or fail('worktree status too large');
  my @parts=split /\0/,$status; my @paths;
  while (@parts) {
    my $row=shift @parts; my ($path,$state);
    if ($row=~/^1 (\S+) (?:\S+ ){6}(.+)\z/s) { ($state,$path)=($1,$2); }
    elsif ($row=~/^2 (\S+) (?:\S+ ){7}(.+)\z/s) {
      ($state,$path)=($1,$2); my $old=shift @parts; defined($old) or fail('truncated rename');
      push @paths,{path=>$old,status=>'rename-source'};
    } elsif ($row=~/^\? (.+)\z/s) { ($state,$path)=('??',$1); }
    else { fail('unmerged or malformed worktree status'); }
    push @paths,{path=>$path,status=>$state}; @paths<=10000 or fail('too many changed paths');
  }
  # File names are UTF-8 in the ledger. Reject invalid byte sequences before recording.
  require Encode;
  for (@paths) { $_->{path}=Encode::decode('UTF-8',$_->{path},Encode::FB_CROAK()); }
  return \@paths;
}
sub snapshot {
  my ($root)=@_; my $head=trim(git($root,'rev-parse','HEAD')); my $paths=paths($root);
  my $index=trim(git($root,'rev-parse','--git-path','index'));
  $index=File::Spec->rel2abs($index,$root);
  my ($fh,$temp)=tempfile('agentic-index.XXXXXX',DIR=>File::Spec->rel2abs(trim(git($root,'rev-parse','--git-dir')),$root),UNLINK=>1);
  close $fh;
  if (-e $index) { -s $index<=33554432 or fail('index exceeds snapshot cap'); copy($index,$temp) or fail("copy index: $!"); } else { unlink $temp; }
  local $ENV{GIT_INDEX_FILE}=$temp;
  git($root,'read-tree',$head) unless -e $temp;
  my $index_tree=trim(git($root,'write-tree'));
  git($root,'add','--all','--','.');
  my $worktree_tree=trim(git($root,'write-tree'));
  unlink $temp;
  return {head=>$head,index_tree=>$index_tree,worktree_tree=>$worktree_tree,paths=>$paths,dirty=>@$paths?JSON::PP::true:JSON::PP::false};
}
sub commit_tree {
  my ($root,$tree,@parents)=@_;
  return trim(git($root,'-c','user.name=agentic-flow salvage','-c','user.email=salvage@example.invalid','commit-tree',$tree,(map { ('-p',$_) } @parents),'-m','Preserve interrupted station work'));
}
my $ok=eval {
  my ($op,@args)=@ARGV;
  if ($op eq 'process' && @args==1) { print process_start($args[0]),"\n"; }
  elsif ($op eq 'host' && @args==1) { print substr(sha256_hex(trim(command('hostname'))."\n".$args[0]),0,12),"\n"; }
  elsif ($op eq 'snapshot' && @args==1) { print $json->encode(snapshot($args[0])),"\n"; }
  elsif ($op eq 'salvage' && @args==3) {
    my ($root,$run,$file)=@args;
    $run=~m{^[a-z0-9][a-z0-9._-]*/[1-9][0-9]{0,8}/[0-9]{1,9}/(executor|reviewer)/[1-9][0-9]{0,8}/[1-9][0-9]{0,8}$} || $run=~m{^[a-z0-9][a-z0-9._-]*/unowned/[a-f0-9]{24}$} or fail('invalid salvage run');
    open my $fh,'<',$file or fail('missing snapshot'); my $n=read($fh,my $bytes,2097153); defined($n) or fail('cannot read snapshot'); close $fh;
    length($bytes)<=2097152 or fail('oversized snapshot'); my $s=$json->decode($bytes);
    for (qw(head index_tree worktree_tree)) { ($s->{$_}//'')=~/^[a-f0-9]{40}$/ or fail('invalid snapshot hash'); }
    my $ref="refs/agentic-flow/salvage/$run";
    my $existing=eval { trim(git($root,'rev-parse','--verify',$ref)) };
    if (defined($existing)) {
      my $index=trim(git($root,'rev-parse',"$ref^2"));
      trim(git($root,'rev-parse',"$ref^{tree}")) eq $s->{worktree_tree} &&
        trim(git($root,'rev-parse',"$ref^2^{tree}")) eq $s->{index_tree} &&
        trim(git($root,'rev-parse',"$ref^1")) eq $s->{head} or fail('worktree changed after salvage');
      print $json->encode({%$s,index_commit=>$index,worktree_commit=>$existing,ref=>$ref}),"\n";
      exit 0;
    }
    my $index=commit_tree($root,$s->{index_tree},$s->{head});
    my $worktree=commit_tree($root,$s->{worktree_tree},$s->{head},$index);
    git($root,'update-ref',$ref,$worktree,'0'x40);
    print $json->encode({%$s,index_commit=>$index,worktree_commit=>$worktree,ref=>$ref}),"\n";
  } else { fail('invalid recovery command'); }
  1;
};
if (!$ok) { print STDERR $@; exit 2; }
