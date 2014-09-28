#!/bin/sh
set -x
set -e
cd $(dirname $0)

myuser=root
mydb=isu4_qualifier
myhost=127.0.0.1
myport=3306
mysql -h ${myhost} -P ${myport} -u ${myuser} -e "DROP DATABASE IF EXISTS ${mydb}; CREATE DATABASE ${mydb}"
mysql -h ${myhost} -P ${myport} -u ${myuser} ${mydb} < /home/isucon/sql/schema.sql
mysql -h ${myhost} -P ${myport} -u ${myuser} ${mydb} < /home/isucon/sql/dummy_users.sql
mysql -h ${myhost} -P ${myport} -u ${myuser} ${mydb} < /home/isucon/sql/dummy_log.sql

carton exec perl /home/isucon/webapp/perl/script/initialize.pl >> /tmp/initialize.log
