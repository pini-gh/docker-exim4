#!/bin/bash

set -ex

join_by () {
  local d=${1-} f=${2-}
  if shift 2; then
    printf %s "$f" "${@/#/$d}"
  fi
}

#### Main configuration ####

# Process network relay list
export EXIM4_RELAY_NETS="${EXIM4_RELAY_NETS:-}"
declare -a networks
for network in $EXIM4_RELAY_NETS; do
  if [[ "$network" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9](/[0-9]+)?$ ]]; then
    # IPv4
    networks+=( "$network" )
  elif [[ "$network" =~ ^.*:.*$ ]]; then
    # IPv6
    networks+=( "$network" )
  else
    # hostname
    ip="$(host "$network" | grep -Ev 'IPv6|not found' | awk '{print $4}')"
    if [ -n "$ip" ]; then
      network=$(ip -br -4 a sh | grep " $ip/" | awk '{print $3}')
      if [ -n "$network" ]; then
        # local network from local hostname
        networks+=( "$network" )
      else
        # external hostname
        networks+=( "$ip" )
      fi
    fi
  fi
done
IFS=$'\n' sorted_networks=($(sort -u <<<"${networks[*]}")); unset IFS
EXIM4_RELAY_NETS="$(join_by " ; " "${sorted_networks[@]}")"

# Exim4 configuration the Debian way
cat <<EOF >/etc/exim4/update-exim4.conf.conf
dc_eximconfig_configtype='internet'
dc_other_hostnames='$LOCAL_DOMAINS'
dc_local_interfaces=''
dc_readhost=''
dc_relay_domains=''
dc_minimaldns='false'
dc_relay_nets='$EXIM4_RELAY_NETS'
dc_smarthost=''
CFILEMODE='644'
dc_use_split_config='true'
dc_hide_mailname=''
dc_mailname_in_oh='true'
dc_localdelivery='mail_spool'
dc_postmaster='root'
EOF

echo "$SERVER_MAILNAME" >/etc/mailname

# /etc/aliases

sed -i '/# CHANGES BELOW THIS LINE ARE NOT PERSISTENT/,$d' /etc/aliases
echo '# CHANGES BELOW THIS LINE ARE NOT PERSISTENT' >>/etc/aliases
if [ -n "$EXIM4_BLACKHOLE" ]; then
  for alias in $EXIM4_BLACKHOLE; do
    echo "$alias: :blackhole:"
  done >>/etc/aliases
fi

# Redirect logs to syslog-ng and configure it to forward them to stdout
echo 'log_file_path = syslog' >/etc/exim4/conf.d/main/00_logs
sed -i 's/(d_mail)/(d_stdout)/' /etc/syslog-ng/syslog-ng.conf
# Tell syslog-ng to reload conf
killall -SIGHUP syslog-ng

# TLS defaults to FALSE
export EXIM4_TLS_ENABLE="${EXIM4_TLS_ENABLE:-FALSE}"

# DKIM signature defaults to FALSE
export EXIM4_DKIM_SIGNATURE_ENABLE="${EXIM4_DKIM_SIGNATURE_ENABLE:-FALSE}"

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
