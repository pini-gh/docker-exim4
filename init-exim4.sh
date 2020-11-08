#!/bin/bash

set -ex

#### Main configuration ####

# Exim4 configuration the Debian way
cat <<EOF >/etc/exim4/update-exim4.conf.conf
dc_eximconfig_configtype='internet'
dc_other_hostnames='$LOCAL_DOMAINS'
dc_local_interfaces=''
dc_readhost=''
dc_relay_domains=''
dc_minimaldns='false'
dc_relay_nets='$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | xargs echo | tr ' ' ';')'
dc_smarthost=''
CFILEMODE='644'
dc_use_split_config='true'
dc_hide_mailname=''
dc_mailname_in_oh='true'
dc_localdelivery='mail_spool'
dc_postmaster='root'
EOF

echo "$SERVER_MAILNAME" >/etc/mailname

# Redirect logs to syslog-ng and configure it to forward them to stdout
echo 'log_file_path = syslog' >/etc/exim4/conf.d/main/00_logs
sed -i 's/(d_mail)/(d_stdout)/' /etc/syslog-ng/syslog-ng.conf
# Tell syslog-ng to reload conf
killall -SIGHUP syslog-ng

# TLS defaults to FALSE
export EXIM4_TLS_ENABLE="${EXIM4_TLS_ENABLE:-FALSE}"

#### Custom configuration files ####
# Substitute every @EXIM4_*@ placeholder with the corresponding environment variable value
exim4_vars=$(env | sed -En '/^(EXIM4_[^=]+)=.*$/{s//\1/;p}')
subst=()
for varname in $exim4_vars; do
  value="${!varname}"
  subst+=(-e "s/@${varname}@/${value//\//\\\/}/g")
done
cd /var/spool/exim4/conf.d
for conf in $(find * -type f -print); do
  sed "${subst[@]}" /var/spool/exim4/conf.d/$conf >/etc/exim4/conf.d/$conf
done

#### Plugins configuration ####

# Plugin spec example
# PLUGIN_SPEC_MAILMAN={"plugin": "mailman", "instances": [{"domainlist": "lists1.example.com", "host": "mailman-core1"}, {"domainlist": "lists2.example.com", "host": "mailman-core2"}]}
#                        plugin name^ 
#                               array of instances for this plugin^             
# Each instance is a flat json object with key/value definitions for the corresponding plugin configuration

# Collect the PLUGIN_SPEC_* environment variables
plugin_specs=$(env | sed -En '/^(PLUGIN_SPEC_[^=]+)=.*$/{s//\1/;p}')

# Set current directory to the plugins' parent dir
cd /var/spool/exim4/plugins

# For each PLUGIN_SPEC_* environment variable
for spec in $plugin_specs; do
  plugin=
  while read line; do
    # First line of the jq command's output is the plugin name
    [ -n "$plugin" ] || {
      # Retrieve the file list for this plugin and reset the instance index
      plugin="$line"
      plugin_files=$(find "$plugin/conf.d" -type f -print)
      for file in $plugin_files; do
        rm -f "/etc/exim4/${file#*/}"
      done
      idx=0
      continue
    }
    # Current line is a sed substitution command for an instance of the
    # plugin
    # For each file from the plugin's dir do the key/value substitutions
    #  + the one for the instance index (idx) and put the result into the
    # corresponding exim4 configuration path
    for file in $plugin_files; do
      sed -e "$line" -e "s/@idx@/$idx/g" "$file" >>"/etc/exim4/${file#*/}"
    done
    # Don't forget to increment the instance index before looping
    idx=$((idx+1))
  done < <(echo "${!spec}" |
    # jq program to build the input for the above shell loop
    # The first output line is the plugin's name
    # Then one output line per instance, being the sed substitution command
    # to use for this instance. Constructed from the key/value pairs defined
    # into the instance
    # Use <tab> "\t" as separator in substitution expressions
    # For the above PLUGIN_SPEC_MAILMAN example, the output would be:
    #  mailman
    #  s	@domainlist@	lists1.example.com	g;s	@host@	mailman-core1	g
    #  s	@domainlist@	lists2.example.com	g;s	@host@	mailman-core2	g
    #   ^tab                ^tab                  ^tab     ^tab       ^tab           ^tab
    jq -r '
      .plugin + "\n" +
      (
        [
          .instances[] |
          [
            to_entries[] | "s\t@" + .key + "@\t" + .value + "\tg"
          ] | join(";")
        ] | join("\n")
      )
    '
  )
done

#### Finalize config and run ####

# Update exim4 configuration
/usr/sbin/update-exim4.conf
