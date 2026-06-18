# wf-spamassassin-nrd-feed

**Block phishing and spam from newly registered domains in SpamAssassin using the WhoisFreaks NRD Feed.**

[![Linux](https://img.shields.io/badge/Linux-any%20distro-FCC624?logo=linux&logoColor=black)](https://kernel.org)
[![SpamAssassin](https://img.shields.io/badge/SpamAssassin-3.4%2B-orange)](https://spamassassin.apache.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://github.com/WhoisFreaks/wf-spamassassin-nrd-feed/blob/main/LICENSE)

---

## What this does

This repository integrates the [WhoisFreaks Newly Registered Domains (NRD) Feed](https://whoisfreaks.com/products/newly-registered-domains.html) into Apache SpamAssassin as a custom Perl plugin. Every message whose sender domain appears on the NRD list receives an additional spam score, raising the bar for freshly registered, zero-reputation domains before any blocklist knows they exist.

Newly registered domains are disproportionately weaponized for phishing, business email compromise, and malware staging. Palo Alto Networks' Unit 42 [found that more than 70% of newly registered domains are malicious, suspicious, or not safe for work](https://unit42.paloaltonetworks.com/newly-registered-domains-malicious-abuse-by-bad-actors/), using a 32-day window as the period when an NRD is most likely to be flagged. This plugin gives SpamAssassin a signal for that window.

The integration has four moving parts:

| Component    | File                             | Purpose                                                                                                     |
| ------------ | -------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Fetch script | `fetch/wf-nrd-fetch.sh`          | Downloads daily NRD data from the WhoisFreaks API, maintains a rolling cache, rebuilds the domain list file |
| Perl plugin  | `spamassassin/WhoisFreaksNRD.pm` | Loads the domain list at startup, checks each message's sender domain                                       |
| Plugin loader | `spamassassin/wf-nrd.pre`       | The `loadplugin` directive that tells SpamAssassin to load the plugin                                       |
| Rules file   | `spamassassin/wf-nrd.cf`         | Defines the `WF_NRD_SENDER` rule, score, and list path                                                      |
| Cron job     | `cron/wf-nrd-spamassassin`       | Runs the fetch script daily at 05:00 UTC                                                                    |

> **Note on the fetch script name:** the script ships in the repo as `fetch/wf-nrd-fetch.sh` and is installed to `/usr/local/bin/wf-nrd-sa-fetch.sh`. The `-sa-` suffix in the installed name keeps it distinct from the fetch scripts used by the other NRD integrations if you run more than one on the same host.

---

## How it works

```
WhoisFreaks NRD API
        │  gzip, daily gTLD + ccTLD
        ▼
wf-nrd-sa-fetch.sh  (cron 05:00 UTC)
  • fetches last WINDOW_DAYS days
  • maintains rolling cache in /var/cache/wf-nrd/
  • atomic rename → /var/lib/spamassassin/nrd/nrd_domains.list
  • sends SIGHUP to spamd to reload without restart
        │
        ▼
WhoisFreaksNRD.pm  (loaded by spamd at startup / SIGHUP)
  • reads domain list into memory hash at load time
  • check_wf_nrd_sender() looks up EnvelopeFrom / From domain
        │
        ▼
WF_NRD_SENDER rule  (+3.5 score on match)
        │
        ▼
SpamAssassin composite score
  • WF_NRD_SENDER   +3.5
  • BAYES_99        +3.5   (if Bayes trained)
  • RCVD_IN_DNSWL   −1.0   (if on whitelist)
  • ...etc
        │
        ▼
Postfix content filter
  score < 5.0  → deliver normally
  score ≥ 5.0  → add X-Spam-Flag: YES header  → Dovecot moves to Junk
  score ≥ 15   → reject at SMTP (if spamass-milter -r 15 is set)
```

The key design choice: `WF_NRD_SENDER` adds a **score**, not a hard block. A legitimate company that registered its domain two weeks ago and sends well-formed mail with good SPF/DKIM will score around 3.5, not enough to be flagged. That same NRD sender with missing DKIM, a suspicious body, and a Bayes hit will score 9 to 12 and land in Junk or get rejected outright.

---

## Requirements

- Any modern Linux distribution (see supported distros below)
- SpamAssassin 3.4+ (`spamd` daemon)
- Postfix (any recent version)
- A [WhoisFreaks API key](https://whoisfreaks.com) (free tier available)
- `curl` (for the fetch script)

### Supported distributions

| Distro family                | Tested on                             | Package manager | spamd service  | spamd user     |
| ---------------------------- | ------------------------------------- | --------------- | -------------- | -------------- |
| Debian / Ubuntu              | Ubuntu 22.04+, Debian 12+             | `apt`           | `spamassassin` | `debian-spamd` |
| RHEL / CentOS / Rocky / Alma | Rocky 9, AlmaLinux 9, CentOS Stream 9 | `dnf` / `yum`   | `spamassassin` | `spamd`        |
| Fedora                       | Fedora 39+                            | `dnf`           | `spamassassin` | `spamd`        |
| openSUSE / SLES              | openSUSE Leap 15+                     | `zypper`        | `spamd`        | `spamd`        |
| Arch Linux                   | Arch, Manjaro, EndeavourOS            | `pacman`        | `spamassassin` | `spamd`        |

> **Note on spamass-milter:** Available in standard repos on Debian/Ubuntu. On RHEL-family, install EPEL first (`dnf install epel-release`). On Arch, it is in the AUR. The installer warns and skips gracefully if not found.

---

## Quick install

```
git clone https://github.com/WhoisFreaks/wf-spamassassin-nrd-feed.git
cd wf-spamassassin-nrd-feed
sudo ./install.sh
```

Done in under 5 minutes. The installer automatically detects your Linux distribution and uses the correct package manager, service name, and spamd user. It will prompt for your WhoisFreaks API key.

**Optional environment variables:**

```
sudo WINDOW_DAYS=30 REJECT_SCORE=15 ./install.sh
```

| Variable       | Default | Description                                           |
| -------------- | ------- | ----------------------------------------------------- |
| `WINDOW_DAYS`  | `10`    | Days of NRD history to keep in the rolling window     |
| `REJECT_SCORE` | `15`    | Score above which spamass-milter rejects at SMTP time |

---

## Manual install

If you prefer to install each piece yourself:

### 1. Install packages

```
# Debian / Ubuntu
sudo apt update && sudo apt install spamassassin spamass-milter postfix curl

# RHEL / CentOS / Rocky / AlmaLinux (install EPEL first for spamass-milter)
sudo dnf install epel-release
sudo dnf install spamassassin spamass-milter postfix curl

# Fedora
sudo dnf install spamassassin spamass-milter postfix curl

# openSUSE / SLES
sudo zypper install spamassassin postfix curl

# Arch Linux
sudo pacman -Sy spamassassin postfix curl
# spamass-milter is in AUR: yay -S spamass-milter
```

### 2. Store your API key

```
sudo mkdir -p /etc/whoisfreaks
echo "YOUR_API_KEY_HERE" | sudo tee /etc/whoisfreaks/apikey > /dev/null
sudo chmod 600 /etc/whoisfreaks/apikey
```

### 3. Copy config files

```
# Fetch script
sudo install -m 755 fetch/wf-nrd-fetch.sh /usr/local/bin/wf-nrd-sa-fetch.sh

# SpamAssassin plugin + rules
sudo install -m 644 spamassassin/WhoisFreaksNRD.pm /etc/spamassassin/WhoisFreaksNRD.pm
sudo install -m 644 spamassassin/wf-nrd.pre        /etc/spamassassin/wf-nrd.pre
sudo install -m 644 spamassassin/wf-nrd.cf         /etc/spamassassin/wf-nrd.cf

# Cron job
sudo install -m 644 cron/wf-nrd-spamassassin /etc/cron.d/wf-nrd-spamassassin
```

### 4. Create the list directory

```
sudo mkdir -p /var/lib/spamassassin/nrd
sudo mkdir -p /var/cache/wf-nrd
```

### 5. Seed the domain list

```
sudo WINDOW_DAYS=10 /usr/local/bin/wf-nrd-sa-fetch.sh
```

### 6. Configure Postfix content filter

Edit `/etc/postfix/master.cf`. Find the `smtp inet` line and add the `-o` option:

```
smtp      inet  n       -       y       -       -       smtpd
    -o content_filter=spamassassin
```

Then append the transport at the bottom of the file:

```
spamassassin unix  -       n       n       -       -       pipe
  user=spamd argv=/usr/bin/spamc -f -e /usr/sbin/sendmail -oi -f ${sender} ${recipient}
```

### 7. Enable and start services

```
sudo systemctl enable spamassassin --now
sudo systemctl enable spamass-milter --now
sudo systemctl reload postfix
```

---

## Tuning the score

Edit `/etc/spamassassin/wf-nrd.cf` and change the `score` line:

```
score WF_NRD_SENDER  3.5   # default: adds 3.5 to messages from NRD senders
```

Common tuning options:

| Score | Behaviour                                                 |
| ----- | --------------------------------------------------------- |
| `1.0` | Gentle signal, rarely tips into spam on its own           |
| `3.5` | Default, meaningful boost that stacks with other signals  |
| `5.0` | Aggressive, NRD sender alone triggers the spam threshold  |
| `0.0` | Disables the rule without removing it                     |

After changing the score, reload spamd:

```
sudo systemctl kill --kill-who=main --signal=SIGHUP spamassassin
```

---

## Adjusting the rolling window

The `WINDOW_DAYS` setting in `/etc/cron.d/wf-nrd-spamassassin` controls how many days of NRD data are kept. Wider windows catch domains registered further in the past at the cost of a larger list file.

Typical list sizes:

| WINDOW_DAYS | Approx. domain count | File size |
| ------------ | -------------------- | --------- |
| 1            | ~50-80K              | ~2 MB     |
| 10           | ~500K-800K           | ~20 MB    |
| 30           | ~1.5M-2M             | ~60 MB    |

SpamAssassin loads the list into a Perl hash at startup. Even at 2M domains this takes under 2 seconds and uses ~150 MB of RAM, acceptable for a dedicated mail server, but worth monitoring if resources are tight.

---

## Verifying the integration

**Check the plugin loaded:**

```
spamassassin --lint -D 2>&1 | grep -i whoisfreaks
# Expected: whoisfreaks-nrd: loaded XXXXXX domains from /var/lib/spamassassin/nrd/nrd_domains.list
```

**Check the rule fires on a test domain:**

```
# Create a test email from a domain you know is on the NRD list
cat <<EOF | spamassassin -D 2>&1 | grep -i 'WF_NRD\|nrd'
From: test@<nrd-domain-here>
To: user@example.com
Subject: Test

Test message
EOF
```

**Inspect headers on real mail:**

```
X-Spam-Status: Yes, score=7.8 required=5.0
  tests=BAYES_50,WF_NRD_SENDER autolearn=spam
X-Spam-Flag: YES
```

**Watch the fetch log:**

```
tail -f /var/log/wf-nrd-spamassassin.log
```

---

## Dovecot / Sieve: auto-move to Junk

If you use Dovecot with Sieve, add this rule to move flagged messages automatically:

```
require ["fileinto"];

if header :contains "X-Spam-Flag" "YES" {
  fileinto "Junk";
  stop;
}
```

---

## Repo structure

```
wf-spamassassin-nrd-feed/
├── install.sh                          # Single-command installer
├── fetch/
│   └── wf-nrd-fetch.sh                 # NRD feed fetch + list rebuild script
├── spamassassin/
│   ├── WhoisFreaksNRD.pm               # Perl plugin (loads list, eval rule)
│   ├── wf-nrd.pre                      # loadplugin directive
│   └── wf-nrd.cf                       # Rule definition + score + list path
├── postfix/
│   └── master.cf.snippet               # Content filter + milter configuration
├── cron/
│   └── wf-nrd-spamassassin             # Daily cron job
├── .gitignore
└── README.md
```

---

## Coexistence with Rspamd

If you are running Rspamd + Postfix (see [wf-rspamd-postfix-nrd-feed](https://github.com/WhoisFreaks/wf-rspamd-postfix-nrd-feed)), you do **not** need SpamAssassin as well. Rspamd is faster and uses less memory. This integration is for servers already running SpamAssassin as their primary filter, or legacy setups where switching to Rspamd isn't an option.

If you are running both (uncommon but possible via Amavis), make sure the NRD score is only applied once. Configure the `WF_NRD_SENDER` score in SpamAssassin or the `WF_NRD_SENDER` multimap rule in Rspamd, not both.

---

## Troubleshooting

**Plugin not loading:**

```
spamassassin --lint -D 2>&1 | grep -i 'error\|whoisfreaks'
# Check paths in wf-nrd.pre match the actual .pm file location
```

**List file empty after install:**

```
cat /var/log/wf-nrd-spamassassin.log
# Look for API key errors or HTTP failures
```

**spamd not reloading after cron:**

```
systemctl status spamassassin
# If inactive, the SIGHUP in the fetch script won't find it
# Fix: systemctl enable spamassassin --now
```

**Score not appearing in headers:**

```
spamassassin --lint
# Check for syntax errors in wf-nrd.cf or wf-nrd.pre
```

---

## Related integrations

- [wf-pihole-nrd-feed](https://github.com/WhoisFreaks/wf-pihole-nrd-feed): DNS-level blocking via Pi-hole
- [wf-adguard-nrd-feed](https://github.com/WhoisFreaks/wf-adguard-nrd-feed): DNS-level blocking via AdGuard Home
- [wf-rspamd-postfix-nrd-feed](https://github.com/WhoisFreaks/wf-rspamd-postfix-nrd-feed): High-performance email filtering via Rspamd + Postfix

---

*Part of the WhoisFreaks NRD Tools series.*
