# WhoisFreaksNRD.pm — SpamAssassin plugin for WhoisFreaks NRD Feed
#
# Loads the NRD domain list at startup (and on SIGHUP) and adds a
# configurable score to any message whose sender domain appears on it.
#
# Install:
#   sudo cp WhoisFreaksNRD.pm /etc/spamassassin/
#
# Configure (in local.cf or wf-nrd.cf):
#   loadplugin Mail::SpamAssassin::Plugin::WhoisFreaksNRD /etc/spamassassin/WhoisFreaksNRD.pm
#   wf_nrd_list_file  /var/lib/spamassassin/nrd/nrd_domains.list
#
# Rules (in wf-nrd.cf):
#   header   WF_NRD_SENDER  eval:check_wf_nrd_sender()
#   describe WF_NRD_SENDER  Sender domain is a newly registered domain (WhoisFreaks NRD)
#   score    WF_NRD_SENDER  3.5

package Mail::SpamAssassin::Plugin::WhoisFreaksNRD;

use strict;
use warnings;
use Mail::SpamAssassin::Plugin;
use Mail::SpamAssassin::Logger;

our @ISA = qw(Mail::SpamAssassin::Plugin);

# ── Constructor ────────────────────────────────────────────────────────────────

sub new {
  my ($class, $mailsa) = @_;
  $class = ref($class) || $class;
  my $self = $class->SUPER::new($mailsa);
  bless $self, $class;

  # Register the eval rule
  $self->register_eval_rule('check_wf_nrd_sender');

  # Register config options
  $self->set_config($mailsa->{conf});

  # Load the domain list now
  $self->{nrd_domains} = {};
  $self->_load_domain_list();

  return $self;
}

# ── Config options ─────────────────────────────────────────────────────────────

sub set_config {
  my ($self, $conf) = @_;
  my @cmds = (
    {
      setting  => 'wf_nrd_list_file',
      default  => '/var/lib/spamassassin/nrd/nrd_domains.list',
      type     => $Mail::SpamAssassin::Conf::CONF_TYPE_STRING,
    },
  );
  $self->{main}->{conf}->{parser}->register_commands(\@cmds);
}

# ── Domain list loader ─────────────────────────────────────────────────────────

sub _load_domain_list {
  my ($self) = @_;
  my $conf     = $self->{main}->{conf};
  my $listfile = $conf->{wf_nrd_list_file}
                 // '/var/lib/spamassassin/nrd/nrd_domains.list';

  unless (-f $listfile) {
    dbg("whoisfreaks-nrd: list file not found: $listfile");
    return;
  }

  my %domains;
  open(my $fh, '<', $listfile)
    or do { dbg("whoisfreaks-nrd: cannot open $listfile: $!"); return; };

  while (<$fh>) {
    chomp;
    s/#.*//;         # strip comments
    s/^\s+|\s+$//g;  # trim whitespace
    next unless length;
    $domains{lc($_)} = 1;
  }
  close($fh);

  $self->{nrd_domains} = \%domains;
  my $count = scalar keys %domains;
  dbg("whoisfreaks-nrd: loaded $count domains from $listfile");
}

# ── Eval rule ─────────────────────────────────────────────────────────────────
#
# Checks the sender domain extracted from:
#   1. EnvelopeFrom (Return-Path / MAIL FROM)
#   2. From: header (fallback)

sub check_wf_nrd_sender {
  my ($self, $pms) = @_;

  my $domains = $self->{nrd_domains};
  return 0 unless $domains && %$domains;

  # Try EnvelopeFrom first (most authoritative)
  my $envfrom = $pms->get('EnvelopeFrom:addr') // '';
  my $domain  = _extract_domain($envfrom);

  # Fall back to From: header
  unless ($domain) {
    my $from = $pms->get('From:addr') // '';
    $domain  = _extract_domain($from);
  }

  return 0 unless $domain;

  $domain = lc($domain);
  dbg("whoisfreaks-nrd: checking sender domain '$domain'");

  if (exists $domains->{$domain}) {
    dbg("whoisfreaks-nrd: HIT — '$domain' is on the NRD list");
    return 1;
  }

  return 0;
}

# ── Helper: extract domain from an email address ──────────────────────────────

sub _extract_domain {
  my ($addr) = @_;
  return '' unless defined $addr && $addr =~ /\@([\w.\-]+)/;
  return $1;
}

1;