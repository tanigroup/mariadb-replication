#!/bin/sh
BASE_PATH=$(dirname $0)
MASTER_HOST=d-thoth
SLAVE_HOST=d-devdas

echo "Waiting for mysql to get up"
# Give 60 seconds for master and slave to come up
sleep 60

echo "Create MySQL Servers (master / slave repl)"
echo "-----------------"


echo "* Create replication user"

mysql --host $SLAVE_HOST -uroot -p$MYSQL_SLAVE_PASSWORD -AN -e 'STOP SLAVE;';
mysql --host $SLAVE_HOST -uroot -p$MYSQL_SLAVE_PASSWORD -AN -e 'RESET SLAVE ALL;';

mysql --host $MASTER_HOST -uroot -p$MYSQL_MASTER_PASSWORD -AN -e "CREATE USER '$MYSQL_REPLICATION_USER'@'%';"
mysql --host $MASTER_HOST -uroot -p$MYSQL_MASTER_PASSWORD -AN -e "GRANT REPLICATION SLAVE ON *.* TO '$MYSQL_REPLICATION_USER'@'%' IDENTIFIED BY '$MYSQL_REPLICATION_PASSWORD';"
mysql --host $MASTER_HOST -uroot -p$MYSQL_MASTER_PASSWORD -AN -e 'flush privileges;'


echo "* Set MySQL01 as master on MySQL02"

MYSQL01_Position=$(eval "mysql --host $MASTER_HOST -uroot -p$MYSQL_MASTER_PASSWORD -e 'show master status \G' | grep Position | sed -n -e 's/^.*: //p'")
MYSQL01_File=$(eval "mysql --host $MASTER_HOST -uroot -p$MYSQL_MASTER_PASSWORD -e 'show master status \G'     | grep File     | sed -n -e 's/^.*: //p'")
MASTER_IP=$(eval "getent hosts $MASTER_HOST|awk '{print \$1}'")

echo "Your Master Position is $MYSQL01_Position"
echo "Your Master Log File is $MYSQL01_File"
echo "Your Master IP is $MASTER_IP"

mysql --host $SLAVE_HOST -uroot -p$MYSQL_SLAVE_PASSWORD -AN -e "CHANGE MASTER TO MASTER_HOST='$MASTER_HOST', \
        MASTER_USER='$MYSQL_REPLICATION_USER', MASTER_PASSWORD='$MYSQL_REPLICATION_PASSWORD', MASTER_LOG_FILE='$MYSQL01_File', \
        MASTER_LOG_POS=$MYSQL01_Position;"

echo "* Start Slave on Slave Servers"
mysql --host $SLAVE_HOST -uroot -p$MYSQL_SLAVE_PASSWORD -AN -e "start slave;"

mysql --host $MASTER_HOST -uroot -p$MYSQL_MASTER_PASSWORD -e "show master status;"
mysql --host $SLAVE_HOST -uroot -p$MYSQL_SLAVE_PASSWORD -e "show slave status \G"

echo "MySQL servers created!"
echo "--------------------"
echo
echo Variables available fo you :-
echo
echo MYSQL01_IP       : $MASTER_HOST
echo MYSQL02_IP       : $SLAVE_HOST
exit 0