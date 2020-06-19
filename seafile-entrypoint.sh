#!/bin/bash

# TODO config autogeneration or seperate config volume using ConfigMaps
# TODO allow to run as arbitrary user - currently uid 1000 is required
# TODO cleanup env vars

# MYSQL_SERVER 
# MYSQL_PORT
# SEAFILE_NAME
# MYSQL_USER
# MYSQL_USER_PASSWORD
# MYSQL_USER_HOST
# MYSQL_OPTIONAL_PARAMS x
# SEAFILE_INITIALIZED x
# DOCKERIZE_TIMEOUT x
# SEAFILE_PUBLIC_URL x
# SEAFILE_ADDRESS x
# SEAFILE_PORT x


DATADIR=/seafile
BASEPATH=/opt/haiwen
INSTALLPATH=${INSTALLPATH:-"${BASEPATH}/$(ls -1 ${BASEPATH} | grep -E '^seafile-server-[0-9.-]+')"}
VERSION=$(echo $INSTALLPATH | grep -oE [0-9.]+)
MAJOR_VERSION=$(echo $VERSION | cut -d. -f 1-2)

if [ -f "$DATADIR/version" ]; then
  OLD_VERSION=$(cat $DATADIR/version)
else
  OLD_VERSION=$VERSION
fi

OLD_MAJOR_VERSION=$(echo $OLD_VERSION | cut -d. -f 1-2)

if [ ! -w "$DATADIR" ]; then
  echo "$DATADIR not writable, unable to continue"
  exit 1
fi

set -e
set -u
set -o pipefail

autorun() {
  init_only
  control_seafile "start"
  control_seahub "start"
  keep_in_foreground
}

init_only() {
  if [ -e "$DATADIR/seafile-initialized" ] || [ "${SEAFILE_INITIALIZED:-}" == "true" ]; then
    link_files

    # Update if neccessary
    if [ $OLD_VERSION != $VERSION ]; then
      full_update
    fi

    collect_garbage
  else
    rm -rf ${DATADIR}/*
    choose_setup
    update_config
    echo $VERSION > $DATADIR/version
    touch "$DATADIR/seafile-initialized"
  fi
}

run_only() {
  # Linking must always be done
  link_files
  control_seafile "start"
  control_seahub "start"
  keep_in_foreground
}

choose_setup() {
  set +u
  # If $MYSQL_SERVER is set, we assume MYSQL setup is intended,
  # otherwise sqlite
  if [ -n "${MYSQL_SERVER}" ]
  then
    set -u
    setup_mysql
  else
    set -u
    setup_sqlite
  fi
}

setup_mysql() {
  echo "setup_mysql"

  # Wait for MySQL to boot up
  DOCKERIZE_TIMEOUT=${DOCKERIZE_TIMEOUT:-"60s"}
  dockerize -timeout ${DOCKERIZE_TIMEOUT} -wait tcp://${MYSQL_SERVER}:${MYSQL_PORT:-3306}

  "${INSTALLPATH}/setup-seafile-mysql.sh" auto \
    -n "${SEAFILE_NAME}" \
    -i "${SEAFILE_ADDRESS:-"127.0.0.1"}" \
    -p "${SEAFILE_PORT}" \
    -d "${SEAFILE_DATA_DIR}" \
    -o "${MYSQL_SERVER}" \
    -t "${MYSQL_PORT:-3306}" \
    -u "${MYSQL_USER}" \
    -w "${MYSQL_USER_PASSWORD}" \
    -q "${MYSQL_USER_HOST:-"%"}" \
    ${MYSQL_OPTIONAL_PARAMS:-""}

  move_and_link
  setup_seahub
}

setup_sqlite() {
  echo "setup_sqlite"
  # Setup Seafile
  "${INSTALLPATH}/setup-seafile.sh" auto \
    -n "${SEAFILE_NAME}" \
    -i "${SEAFILE_ADDRESS}" \
    -p "${SEAFILE_PORT}" \
    -d "${SEAFILE_DATA_DIR}"

  move_and_link
  setup_seahub
}

setup_seahub() {
  # Setup Seahub

  # From https://github.com/haiwen/seafile-server-installer-cn/blob/master/seafile-server-ubuntu-14-04-amd64-http
  sed -i 's/= ask_admin_email()/= '"\"${SEAFILE_ADMIN}\""'/' ${INSTALLPATH}/check_init_admin.py
  sed -i 's/= ask_admin_password()/= '"\"${SEAFILE_ADMIN_PW}\""'/' ${INSTALLPATH}/check_init_admin.py

  control_seafile "start"

  bash -c ". /tmp/seafile.env; python3 -t ${INSTALLPATH}/check_init_admin.py"

  control_seafile "stop"
}

move_and_link() {
  # Stop Seafile/hub instances if running
  control_seahub "stop"
  control_seafile "stop"

  move_files
  link_files
}

update_config() {
  # gunicorn
  OLD="bind = \"127.0.0.1:8000\""
  NEW="bind = \"0.0.0.0:8000\""
  sed -i "s/${OLD}/${NEW}/g" /seafile/conf/gunicorn.conf.py

  # ccnet
  sed -i "s#SERVICE_URL.*#SERVICE_URL = ${SEAFILE_PUBLIC_URL}#" /seafile/conf/ccnet.conf

  # seahub
  sed -i "/FILE_SERVER_ROOT.*/ d" /seafile/conf/seahub_settings.py
  echo "FILE_SERVER_ROOT = '${SEAFILE_PUBLIC_URL}/seafhttp'" >> /seafile/conf/seahub_settings.py
}

move_files() {
  for SEADIR in "ccnet" "conf" "seafile-data" "seahub-data"
  do
    if [ -e "${BASEPATH}/${SEADIR}" -a ! -L "${BASEPATH}/${SEADIR}" ]
    then
      cp -a ${BASEPATH}/${SEADIR} ${DATADIR}
      rm -rf "${BASEPATH}/${SEADIR}"
    fi
  done

  if [ -e "${BASEPATH}/seahub.db" -a ! -L "${BASEPATH}/seahub.db" ]
  then
    mv ${BASEPATH}/seahub.db ${DATADIR}/
  fi
}

link_files() {
  for SEADIR in "ccnet" "conf" "seafile-data" "seahub-data" "seahub.db"
  do
    if [ -e "${DATADIR}/${SEADIR}" ]
    then
      rm -rf "${BASEPATH}/${SEADIR}"
      ln -sf ${DATADIR}/${SEADIR} ${BASEPATH}/${SEADIR}
    fi
  done

  # avatars are stored in seahub/media for some reason so let's link that to seahub-data
  rm -rf "${INSTALLPATH}/seahub/media/avatars"
  ln -sf "${DATADIR}/seahub-data/avatars" "${INSTALLPATH}/seahub/media/avatars"
}

prepare_env() {
  cat << _EOF_ > /tmp/seafile.env
  export CCNET_CONF_DIR="${BASEPATH}/ccnet"
  export SEAFILE_CONF_DIR="${SEAFILE_DATA_DIR}"
  export SEAFILE_CENTRAL_CONF_DIR="${BASEPATH}/conf"
  export SEAFILE_RPC_PIPE_PATH="${INSTALLPATH}/runtime"
  export PYTHONPATH=${INSTALLPATH}/seafile/lib/python3.6/site-packages:${INSTALLPATH}/seafile/lib64/python3.6/site-packages:${INSTALLPATH}/seahub:${INSTALLPATH}/seahub/thirdpart:${PYTHONPATH:-}

_EOF_
}

trapped() {
  control_seahub "stop"
  control_seafile "stop"
  exit 0
}

keep_in_foreground() {
  # As there seems to be no way to let Seafile processes run in the foreground we
  # need a foreground process. This has a dual use as a supervisor script because
  # as soon as one process is not running, the command returns an exit code >0
  # leading to a script abortion thanks to "set -e".
  while true
  do
    for SEAFILE_PROC in "seafile-control" "ccnet-server" "seaf-server" "gunicorn"
    do
      pkill -0 -f "${SEAFILE_PROC}"
      sleep 1
    done
    sleep 5
  done
}

control_seafile() {
  "${INSTALLPATH}/seafile.sh" "$@"
}

control_seahub() {
  "${INSTALLPATH}/seahub.sh" "$@"
}

collect_garbage() {
  "${INSTALLPATH}/seaf-gc.sh" "$@"
}

full_update() {
  EXECUTE=""
  echo ""
  echo "---------------------------------------"
  echo "Upgrading from $OLD_VERSION to $VERSION"
  echo "---------------------------------------"
  echo ""
  # Iterate through all the major upgrade scripts and apply them
  for i in `ls ${INSTALLPATH}/upgrade/`; do
    if [ `echo $i | grep "upgrade_${OLD_MAJOR_VERSION}"` ]; then
      EXECUTE=1
    fi
    if [ $EXECUTE ] && [ `echo $i | grep upgrade` ]; then
      echo "Running update $i"
      update $i || exit
    fi
  done
  # When all the major upgrades are done, perform a minor upgrade
  if [ -z $EXECUTE ]; then
    update minor-upgrade.sh
  fi

  echo $VERSION > $DATADIR/version
}

update() {
  "${INSTALLPATH}/upgrade/$@"
  local RET=$?
  sleep 1
  return ${RET}
}

# Fill vars with defaults if empty
if [ -z ${MODE+x} ]; then
  MODE=${1:-"run"}
fi

SEAFILE_DATA_DIR="${DATADIR}/seafile-data"
SEAFILE_PORT=${SEAFILE_PORT:-8082}
SEAFILE_PUBLIC_URL=${SEAFILE_PUBLIC_URL:-"http://localhost:8000"}

prepare_env
trap trapped SIGINT SIGTERM

case $MODE in
  "autorun" | "run")
    autorun
  ;;
  "setup" | "setup_mysql")
    setup_mysql
  ;;
  "setup_sqlite")
    setup_sqlite
  ;;
  "setup_seahub")
    setup_seahub
  ;;
  "setup_only")
    choose_setup
  ;;
  "run_only")
    run_only
  ;;
  "init_only")
    init_only
  ;;
  "update")
    full_update
  ;;
  "debug")
    link_files
    exec bash
  ;;
esac
