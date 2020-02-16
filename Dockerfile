FROM debian:stretch-slim

ARG VCS_REF
ARG VCS_VERSION

LABEL maintainer="Thomas VIAL"  \
    org.label-schema.name="docker-mailserver" \
    org.label-schema.description="A fullstack but simple mailserver (smtp, imap, antispam, antivirus, ssl...)" \
    org.label-schema.url="https://github.com/tomav/docker-mailserver" \
    org.label-schema.vcs-ref=$VCS_REF \
    org.label-schema.vcs-url="https://github.com/tomav/docker-mailserver" \
    org.label-schema.version=$VCS_VERSION \
    org.label-schema.schema-version="1.0"

ARG DEBIAN_FRONTEND=noninteractive
ENV VIRUSMAILS_DELETE_DELAY=7
ENV ONE_DIR=0
ENV ENABLE_POSTGREY=0
ENV FETCHMAIL_POLL=300
ENV POSTGREY_DELAY=300
ENV POSTGREY_MAX_AGE=35
ENV POSTGREY_AUTO_WHITELIST_CLIENTS=5
ENV POSTGREY_TEXT="Delayed by postgrey"

ENV SASLAUTHD_MECHANISMS=pam
ENV SASLAUTHD_MECH_OPTIONS=""

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Packages
# hadolint ignore=DL3015
RUN echo "deb http://http.debian.net/debian stretch-backports main" | tee -a /etc/apt/sources.list.d/stretch-bp.list && \
  apt-get update -q --fix-missing && \
  apt-get -y install postfix && \
  # TODO installing postfix with --no-install-recommends makes "checking ssl: generated default cert works correctly" fail
  apt-get -y install --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    curl \
    ed \
    file \
    gnupg \
    iproute2 \
    locales \
    logwatch \
    libdate-manip-perl \
    libmail-spf-perl \
    libnet-dns-perl \
    libsasl2-modules \
    netcat-openbsd \
    opendkim \
    opendkim-tools \
    opendmarc \
    pflogsumm \
    postfix-ldap \
    postfix-pcre \
    postfix-policyd-spf-python \
    rsyslog \
    sasl2-bin \
    supervisor \
    postgrey \
    whois \
    && \
  # use Dovecot community repo to react faster on security updates
  curl https://repo.dovecot.org/DOVECOT-REPO-GPG | gpg --import && \
  gpg --export ED409DA1 > /etc/apt/trusted.gpg.d/dovecot.gpg && \
  echo "deb https://repo.dovecot.org/ce-2.3-latest/debian/stretch stretch main" > /etc/apt/sources.list.d/dovecot-community.list && \
  apt-get update -q --fix-missing && \
  apt-get -y install --no-install-recommends \
    dovecot-core \
    dovecot-imapd \
    dovecot-ldap \
    dovecot-lmtpd \
    dovecot-managesieved \
    dovecot-pop3d \
    dovecot-sieve \
    dovecot-solr \
    && \
  apt-get autoclean && \
  rm -rf /var/lib/apt/lists/* && \
  rm -rf /usr/share/locale/* && \
  rm -rf /usr/share/man/* && \
  rm -rf /usr/share/doc/* && \
  touch /var/log/auth.log && \
  update-locale && \
  rm -f /etc/cron.weekly/fstrim && \
  rm -f /etc/cron.daily/00logwatch

# no syslog user in debian compared to ubuntu
RUN adduser --system syslog && \
  useradd -u 5000 -d /home/docker -s /bin/bash -p "$(echo docker | openssl passwd -1 -stdin)" docker

# Configures Dovecot
COPY target/dovecot/auth-passwdfile.inc target/dovecot/??-*.conf /etc/dovecot/conf.d/
WORKDIR /usr/share/dovecot
# hadolint ignore=SC2016,SC2086
RUN sed -i -e 's/include_try \/usr\/share\/dovecot\/protocols\.d/include_try \/etc\/dovecot\/protocols\.d/g' /etc/dovecot/dovecot.conf && \
  sed -i -e 's/#mail_plugins = \$mail_plugins/mail_plugins = \$mail_plugins sieve/g' /etc/dovecot/conf.d/15-lda.conf && \
  sed -i -e 's/^.*lda_mailbox_autocreate.*/lda_mailbox_autocreate = yes/g' /etc/dovecot/conf.d/15-lda.conf && \
  sed -i -e 's/^.*lda_mailbox_autosubscribe.*/lda_mailbox_autosubscribe = yes/g' /etc/dovecot/conf.d/15-lda.conf && \
  sed -i -e 's/^.*postmaster_address.*/postmaster_address = '${POSTMASTER_ADDRESS:="postmaster@domain.com"}'/g' /etc/dovecot/conf.d/15-lda.conf && \
  sed -i 's/#imap_idle_notify_interval = 2 mins/imap_idle_notify_interval = 29 mins/' /etc/dovecot/conf.d/20-imap.conf && \
  # Adapt mkcert for Dovecot community repo
  sed -i 's/CERTDIR=.*/CERTDIR=\/etc\/dovecot\/ssl/g' /usr/share/dovecot/mkcert.sh && \
  sed -i 's/KEYDIR=.*/KEYDIR=\/etc\/dovecot\/ssl/g' /usr/share/dovecot/mkcert.sh && \
  sed -i 's/KEYFILE=.*/KEYFILE=\$KEYDIR\/dovecot.key/g' /usr/share/dovecot/mkcert.sh && \
  # create directory for certificates created by mkcert
  mkdir /etc/dovecot/ssl && \
  chmod 755 /etc/dovecot/ssl  && \
  ./mkcert.sh  && \
  mkdir -p /usr/lib/dovecot/sieve-pipe /usr/lib/dovecot/sieve-filter /usr/lib/dovecot/sieve-global && \
  chmod 755 -R /usr/lib/dovecot/sieve-pipe /usr/lib/dovecot/sieve-filter /usr/lib/dovecot/sieve-global

# Enables Postgrey
COPY target/postgrey/postgrey /etc/default/postgrey
COPY target/postgrey/postgrey.init /etc/init.d/postgrey
RUN chmod 755 /etc/init.d/postgrey && \
  mkdir /var/run/postgrey && \
  chown postgrey:postgrey /var/run/postgrey

# Configure DKIM (opendkim)
# DKIM config files
COPY target/opendkim/opendkim.conf /etc/opendkim.conf
COPY target/opendkim/default-opendkim /etc/default/opendkim

# Configure DMARC (opendmarc)
COPY target/opendmarc/opendmarc.conf /etc/opendmarc.conf
COPY target/opendmarc/default-opendmarc /etc/default/opendmarc
COPY target/opendmarc/ignore.hosts /etc/opendmarc/ignore.hosts

# Configures Postfix
COPY target/postfix/main.cf target/postfix/master.cf target/postfix/recipient_access.pcre /etc/postfix/
COPY target/postfix/header_checks.pcre target/postfix/sender_header_filter.pcre target/postfix/sender_login_maps.pcre /etc/postfix/maps/
RUN echo "" > /etc/aliases

# Configuring Logs
RUN mkdir -p /var/log/mail && \
  chown syslog:root /var/log/mail && \
  sed -i -r 's|/var/log/mail|/var/log/mail/mail|g' /etc/rsyslog.conf && \
  sed -i -r 's|;auth,authpriv.none|;mail.none;mail.error;auth,authpriv.none|g' /etc/rsyslog.conf && \
  sed -i -r 's|/var/log/mail|/var/log/mail/mail|g' /etc/logrotate.d/rsyslog && \
  # prevent syslog logrotate warnings \
  sed -i -e 's/\(printerror "could not determine current runlevel"\)/#\1/' /usr/sbin/invoke-rc.d && \
  sed -i -e 's/^\(POLICYHELPER=\).*/\1/' /usr/sbin/invoke-rc.d && \
  # prevent email when /sbin/init or init system is not existing \
  sed -i -e 's/invoke-rc.d rsyslog rotate > \/dev\/null/invoke-rc.d rsyslog --quiet rotate > \/dev\/null/g' /etc/logrotate.d/rsyslog

# Get LetsEncrypt signed certificate
RUN curl -s https://letsencrypt.org/certs/lets-encrypt-x3-cross-signed.pem > /etc/ssl/certs/lets-encrypt-x3-cross-signed.pem

COPY ./target/bin /usr/local/bin
# Start-mailserver script
COPY ./target/helper_functions.sh ./target/check-for-changes.sh ./target/start-mailserver.sh ./target/postfix-wrapper.sh ./target/docker-configomat/configomat.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/*

# Configure supervisor
COPY target/supervisor/supervisord.conf /etc/supervisor/supervisord.conf
COPY target/supervisor/conf.d/* /etc/supervisor/conf.d/

WORKDIR /

EXPOSE 25 587 143 465 993 110 995 4190

CMD ["supervisord", "-c", "/etc/supervisor/supervisord.conf"]
