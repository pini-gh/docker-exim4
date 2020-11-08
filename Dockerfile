FROM pinidh/baseimage-debian-buster:1.0.0

# Use baseimage-docker's init system.
CMD ["/sbin/my_init"]

# Depends on mkfifo (coreutils) to redirect logs
# Depends on iproute2 (coreutils) to discover network
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends exim4 coreutils iproute2
# Depends on jq for templates configuration processing
RUN DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends jq
# Depends on ruby for the redmine template
RUN DEBIAN_FRONTEND=noninteractive apt-get -y install --no-install-recommends ruby
# Redirect syslog-ng mail logs to stdout
#RUN sed -i 's/(d_mail)/(d_stdout)/' /etc/syslog-ng/syslog-ng.conf

# Clean up APT when done.
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Our scripts
COPY exim4-config /var/spool/exim4/
COPY init-exim4.sh /etc/my_init.d/
COPY run-exim4.sh /etc/service/exim4/run
