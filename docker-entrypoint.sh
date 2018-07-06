#!/bin/sh

set -eo pipefail
# set -x

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
  set -- mysqld_safe "$@"
fi

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
  var=$1
  file_var="${var}_FILE"
  var_value=$(printenv $var || true)
  file_var_value=$(printenv $file_var || true)
  default_value=$2

  if [ -n "$var_value" -a -n "$file_var_value" ]; then
    echo >&2 "error: both $var and $file_var are set (but are exclusive)"
    exit 1
  fi

  if [ -z "${var_value}" ]; then
    if [ -z "${file_var_value}" ]; then
      export "${var}"="${default_value}"
    else
      export "${var}"="${file_var_value}"
    fi
  fi

  unset "$file_var"
}

# Fetch value from server config
# We use mysqld --verbose --help instead of my_print_defaults because the
# latter only show values present in config files, and not server defaults
_get_config() {
  conf="$1"
  mysqld --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null | awk '$1 == "'"$conf"'" { print $2; exit }'
}

DATA_DIR="$(_get_config 'datadir')"

# Initialize database if necessary
if [ ! -d "$DATA_DIR/mysql" ]; then
  file_env 'MYSQL_ROOT_PASSWORD'
  if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
    echo >&2 'error: database is uninitialized and password option is not specified '
    echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
    exit 1
  fi

  mkdir -p "$DATA_DIR"
  chown mysql: "$DATA_DIR"

  echo 'Initializing database'
  mysql_install_db --user=mysql --datadir="$DATA_DIR" --rpm
  chown -R mysql: "$DATA_DIR"
  echo 'Database initialized'

  # Start mysqld to config it
  mysqld_safe --skip-networking --nowatch

  mysql_options='--protocol=socket -uroot'

  # Execute mysql statement
  # statement can be passed directly or by HEREDOC
  execute() {
    statement="$1"
    if [ -n "$statement" ]; then
      mysql -ss $mysql_options -e "$statement"
    else
      cat /dev/stdin | mysql -ss $mysql_options
   fi
  }

  for i in `seq 30 -1 0`; do
    if execute 'SELECT 1' &> /dev/null; then
      break
    fi
    echo 'MySQL init process in progress...'
    sleep 1
  done
  if [ "$i" = 0 ]; then
    echo >&2 'MySQL init process failed.'
    exit 1
  fi

  if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
    # sed is for https://bugs.mysql.com/bug.php?id=20545
    mysql_tzinfo_to_sql /usr/share/zoneinfo | \
      sed 's/Local time zone must be set--see zic manual page/FCTY/' | \
      mysql $mysql_options mysql
  fi

  if [ -n "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
    export MYSQL_ROOT_PASSWORD="$(tr -dc _A-Z-a-z-0-9 < /dev/urandom | head -c10)"
    echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
  fi

  # Create root user, set root password, drop useless table
  # Delete root user except for
  execute <<SQL
    -- What's done in this file shouldn't be replicated
    --  or products like mysql-fabric won't work
    SET @@SESSION.SQL_LOG_BIN=0;

    DELETE FROM mysql.user WHERE user NOT IN ('mysql.sys', 'mysqlxsys', 'root') OR host NOT IN ('localhost') ;
    SET PASSWORD FOR 'root'@'localhost'=PASSWORD('${MYSQL_ROOT_PASSWORD}') ;
    GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION ;
    DROP DATABASE IF EXISTS test ;
    FLUSH PRIVILEGES ;
SQL

  # https://mariadb.com/kb/en/library/mariadb-environment-variables/
  export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
  
  # Create root user for $MYSQL_ROOT_HOST
  file_env 'MYSQL_ROOT_HOST' '%'
  if [ "$MYSQL_ROOT_HOST" != 'localhost' ]; then
    execute <<SQL
      CREATE USER 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
      GRANT ALL ON *.* TO 'root'@'${MYSQL_ROOT_HOST}' WITH GRANT OPTION ;
      FLUSH PRIVILEGES ;
SQL
  fi

  file_env 'MYSQL_USER'
  file_env 'MYSQL_PASSWORD'
  if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
    execute "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;"
  fi

  file_env 'MYSQL_DATABASE'
  if [ "$MYSQL_DATABASE" ]; then
    execute "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;"
    if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
      execute "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;"
    fi
  fi

  echo
  echo "Executing user define sql file"
  echo
  for f in $(ls /docker-entrypoint-initdb.d/); do
  myFile="/docker-entrypoint-initdb.d/$f"
    case "$f" in
      *.sh)     echo "$0: running $myFile"; . "$myFile" ;;
      *.sql)    echo "$0: running $myFile"; execute < "$myFile"; echo ;;
      *.sql.gz) echo "$0: running $myFile"; gunzip -c "$myFile" | execute; echo ;;
      *)        echo "$0: ignoring $myFile" ;;
    esac
    echo
  done

   #MASTER CONFIG
if [ "$MYSQL_ROLE" = 'master' ]; then

cat <<EOT >> /etc/mysql/conf.d/master.cnf
[mysqld]
server-id=1
log-bin=mysql-bin
log-slave-updates=1
datadir=/var/lib/mysql/
innodb_flush_log_at_trx_commit = 2
innodb_flush_method = O_DIRECT
skip-host-cache
skip-name-resolve
max_allowed_packet=100M
EOT

execute <<SQL
  CREATE USER '${MYSQL_REPLICATION_USER}'@'%';
  GRANT REPLICATION SLAVE ON *.* TO '${MYSQL_REPLICATION_USER}'@'%' IDENTIFIED BY '${MYSQL_REPLICATION_PASSWORD}';
  FLUSH PRIVILEGES ;
SQL
fi

#SLAVE CONFIG
if [ "$MYSQL_ROLE" = 'slave' ]; then
  if [[ -z "$MASTER_HOST" ]]; then
    echo 'Please specify your master information.'
    exit 0
  fi

cat <<EOT >> /etc/mysql/conf.d/slave.cnf
[mariadb]
server-id=2
log-bin=mysql-bin
log-slave-updates=1
auto_increment_increment=2
auto_increment_offset=2
datadir=/var/lib/mysql
read-only=1
slave-skip-errors = 1062
skip-host-cache
skip-name-resolve
max_allowed_packet=100M
replicate-ignore-db=mysql
EOT

mkdir -p /init_slave/
ExcludeDatabases="Database|information_schema|performance_schema|mysql"
databases=`mysql -u $MYSQL_MASTER_USER -p$MYSQL_MASTER_PASSWORD -h $MASTER_HOST -e "SHOW DATABASES;" | tr -d "| " | egrep -v $ExcludeDatabases`

for db in $databases; do
        echo "Dumping database: $db"
        mysqldump -u $MYSQL_MASTER_USER -p$MYSQL_MASTER_PASSWORD -h $MASTER_HOST --databases $db > /init_slave/$db.sql
		    echo "$0: running $db.sql"
        execute < "/init_slave/$db.sql"
        rm -rf /init_slave/$db.sql
        echo "replicate-do-db=$db" >> /etc/mysql/conf.d/slave.cnf
done

  MYSQL01_Position=$(eval "mysql --host $MASTER_HOST -u$MYSQL_MASTER_USER -p$MYSQL_MASTER_PASSWORD -e 'show master status \G' | grep Position | sed -n -e 's/^.*: //p'")
  MYSQL01_File=$(eval "mysql --host $MASTER_HOST -u$MYSQL_MASTER_USER -p$MYSQL_MASTER_PASSWORD -e 'show master status \G'     | grep File     | sed -n -e 's/^.*: //p'")
  
  echo "Your Master Position is $MYSQL01_Position"
  echo "Your Master Log File is $MYSQL01_File"

  execute <<SQL
    STOP SLAVE;
    RESET SLAVE ALL;
    CHANGE MASTER TO MASTER_HOST='${MASTER_HOST}', MASTER_USER='${MYSQL_REPLICATION_USER}', MASTER_PASSWORD='${MYSQL_REPLICATION_PASSWORD}', MASTER_LOG_FILE='${MYSQL01_File}', MASTER_LOG_POS=${MYSQL01_Position};
    start slave;
    show slave status \G
SQL

fi

  if ! mysqladmin -uroot --password="$MYSQL_PWD" shutdown; then
    echo >&2 'Shutdown failed'
    exit 1
  fi

  echo
  echo 'MySQL init process done. Ready for start up.'
  echo
fi

chown -R mysql: "$DATA_DIR"
exec "$@"
