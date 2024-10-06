#!/bin/bash

if [ "${PH_VERBOSE:-0}" -gt 0 ]; then
  set -x
fi

trap stop TERM INT QUIT HUP ERR

start() {

  local v5_volume=0

  # The below functions are all contained in bash_functions.sh
  # shellcheck source=/dev/null
  . /usr/bin/bash_functions.sh

  # If the file /etc/pihole/setupVars.conf exists, but /etc/pihole/pihole.toml does not, then we are migrating v5->v6
  # FTL Will handle the migration of the config files
  if [[ -f /etc/pihole/setupVars.conf && ! -f /etc/pihole/pihole.toml ]]; then
    echo "  [i] v5 files detected that have not yet been migrated to v6"
    echo "  [i] Deferring additional configuration until after FTL has started"
    echo "  [i] Note: It is normal to see \"Config file /etc/pihole/pihole.toml not available (r): No such file or directory\" in the logs at this point"
    echo ""
    # We need to migrate the dnsmasq.d contents so that FTL can read them in properly
    migrate_dnsmasq_d_contents
    v5_volume=1

  fi

  # ===========================
  # Initial checks
  # ===========================

  # If PIHOLE_UID is set, modify the pihole user's id to match
  set_uid_gid

  # Only run the next step if we are not migrating from v5 to v6
  if [[ ${v5_volume} -eq 0 ]]; then
    # Configure FTL with any environment variables if needed
    echo "  [i] Starting FTL configuration"
    ftl_config
  fi

  # Install additional packages inside the container if requested
  install_additional_packages

  # Start crond for scheduled scripts (logrotate, pihole flush, gravity update etc)
  start_cron

  # Install the logrotate config file
  install_logrotate

  #migrate Gravity Database if needed:
  migrate_gravity

  # Start pihole-FTL in the background
  start_ftl &

  # Wait until the log file exists before continuing
  while [ ! -f /var/log/pihole/FTL.log ]; do
    sleep 0.5
  done

  # If we are migrating from v5 to v6, we now need to run the basic configuration step that we deferred earlier
  # This is because pihole-FTL needs to migrate the config files before we can perform the basic configuration checks
  if [[ ${v5_volume} -eq 1 ]]; then
    echo "  [i] Starting deferred FTL Configuration"
    ftl_config
    echo ""
  fi

  pihole updatechecker
  pihole -v
  echo ""

  if [ "${TAIL_FTL_LOG:-1}" -eq 1 ]; then
    # Start tailing the FTL log from the most recent "FTL Started" message
    # Get the line number
    startFrom=$(grep -n '########## FTL started' /var/log/pihole/FTL.log | tail -1 | cut -d: -f1)
    # Start the tail from the line number and background it
    tail --follow=name -n +${startFrom} /var/log/pihole/FTL.log &
  else
    echo "  [i] FTL log output is disabled. Remove the Environment variable TAIL_FTL_LOG, or set it to 1 to enable FTL log output."
  fi

  # https://stackoverflow.com/a/49511035
  wait $!
}

stop() {

  # Only attempt to close pihole-FTL if it is running, it may already have crashed
  if pgrep pihole-FTL >/dev/null; then
    echo ""
    echo "  [i] Container stop requested..."
    echo "  [i] pihole-FTL is running - Attempting to shut it down cleanly"
    echo ""
    # Ensure pihole-FTL shuts down cleanly on SIGTERM/SIGINT
    ftl_pid=$(pgrep pihole-FTL)

    killall --signal 15 pihole-FTL

    # Wait for pihole-FTL to exit
    while test -d /proc/"${ftl_pid}"; do
      sleep 0.5
    done
  fi

  # Wait for a few seconds to allow the FTL log tail to catch up before exiting the container
  sleep 2  

  # read the FTL exit code from the file created in the `start_ftl` function
  FTL_EXIT_CODE=$(cat /pihole-FTL.exit)
  rm /pihole-FTL.exit

  # ensure the exit code is an integer, if not set it to 1
  if ! [[ "${FTL_EXIT_CODE}" =~ ^[0-9]+$ ]]; then
    FTL_EXIT_CODE=1
  fi

  echo ""
  echo "  [i] pihole-FTL exited with status $FTL_EXIT_CODE"
  echo ""
  echo "  [i] Container will now stop or restart depending on your restart policy"
  echo "      https://docs.docker.com/engine/containers/start-containers-automatically/#use-a-restart-policy"
  echo ""

  # # If we are running pytest, keep the container alive for a little longer
  # # to allow the tests to complete
  if [[ ${PYTEST} ]]; then
    sleep 10
  fi

  exit ${FTL_EXIT_CODE}

}

start
