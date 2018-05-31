#!/usr/bin/env bash
# dependencies: mysqldump, mailutils
# version: 0.1.9
#
# default directory structure:
# ~/mysqldump
#            ├── conf
#            │   └── dump.cnf            <- mysqldump configuration
#            ├── dumps
#            │   └── ${HOSTNAME}-${UUID} <- MySQL dumps location
#            ├── uuid                    <- file with unique ID for the current host
#            └── logs                    <- main (also debug) and error logs
#                ├── main.log
#                └── error.log
#

set -o pipefail

DATE=$(date +%Y_%m_%d)
DAY=$(date +%A)

MAIL_SUBJ="Something goes wrong with MySQL backup on host: $HOSTNAME"
MAIL=$MAIL_REC                                   # ENV: email notifications recepient
MAIL_FROM=$MAIL_SENDER                           # ENV: send emails from 
DELTA=$TIME_DELTA                                # ENV: time delta for cleaning-up old archives

REMOTE_DIR='/var/storage/mysqldump'              # directory on the remote host for storing dumps
HOMEDIR="$HOME/scripts/mysqldump"                # script's home directory
MLOG="$HOMEDIR/logs/main.log"                    # main log location
SUCC_MSG='MySQL backup was succesfully done'     # success message for logging
ERLOG="$HOMEDIR/logs/error.log"                  # error log location
ERMSG='MySQL backup failed at '                  # error message for logging
PRESERVE_LINES=100                               # remove lines, bigger (older) than $NUMBER from log files

CNF="$HOMEDIR/conf/dump.cnf"                     # mysqldump config
BDIR="$HOMEDIR/dumps"                            # where to store MySQL dumps
UUID=$(echo $RANDOM|md5sum|cut -c -8)            # get unique host identificator

# extract MySQL password from mysqldump configuration file
get_password() {
  password_str=$(grep 'password=' $CNF 2>&1 | sed 's/password=//g')
  if [ ! ${PIPESTATUS[0]} == 0 ];then
    err_msg="Got an error while extracting password from $CNF, message: $password_str"
    logger "$err_msg" "$ERLOG"
    mailer "$err_msg"
    exit 1
  fi
  PSWD=$password_str
}

backup() {
 check
 prepare
 sqldump || mailer "General error with sqldump()"
}

sqldump() {
 for db in `mysql -u root -p$PSWD -e 'show databases;' | egrep -v 'information_schema|performance_schema' | tail -n +2`;
   do makedump $db && logger "$SUCC_MSG, db: $db" "$MLOG"
   done && copy
}

# check for hostname, MySQL credentials, check for environment variables
check() {
  for variable in {MAIL_REC,MAIL_SENDER,TIME_DELTA}
   do
    if [ -z "${!variable}" ]; then
      logger "ERROR $variable environment variable can not be empty" "$ERLOG"
      exit 1
    fi
  done

  if [[ $HOSTNAME == 'localhost' ||  $HOSTNAME == '127.0.0.1' ]]; then
   logger "ERROR: hostname: \"$HOSTNAME\" is not allowed" "$ERLOG"
   exit 1
  fi

  mysqltest=$(mysql -u root -p$PSWD -e 'show databases;' 2>&1)
  if [ ! $? -eq 0 ]; then
    logger "ERROR: $mysqltest" "$ERLOG"
    mailer "Got an error while connecting to the database server: $mysqltest, at $(date)"
    exit 1
  fi
}

# create/check necessary directories, check for UUID
prepare() {
  for directory in {dumps,logs,conf}
   do mkdir -p $HOMEDIR/$directory
  done

  if [ ! -f $HOMEDIR/uuid ];then
    echo $UUID > $HOMEDIR/uuid
    logger "Machine Id: $UUID created" "$MLOG"
    MACHINEID=$UUID
  else MACHINEID=$(cat $HOMEDIR/uuid)
  fi
  mkdir -p $BDIR/$HOSTNAME-$MACHINEID/$DAY
  # for the remote host
  ssh storage "mkdir -p $REMOTE_DIR/$HOSTNAME-$MACHINEID/$DAY"
}

# create dumps and compress piped output
# @param $1 - database name
makedump() {
  mysqldump --defaults-extra-file=$CNF --events $1 | gzip -c > $BDIR/$HOSTNAME-$MACHINEID/$DAY/$1.$DATE.dump.sql.gz 
  if [ ! "${PIPESTATUS[0]}" == 0 ];then
    logger "ERROR: mysqldump error" "$ERLOG"
    mailer "got an error in makedump()"
    exit 1
  fi
}

# copy dumps to the storage server
copy() {
 copy_output=$(cd $BDIR/$HOSTNAME-$MACHINEID && scp -qrp $DAY storage:$REMOTE_DIR/$HOSTNAME-$MACHINEID 2>&1)
 if [ ! ${PIPESTATUS[0]} == 0 ];then
   copy_error="Remote side rejected transfer, message: \`$copy_output\`"
   logger "ERROR: $copy_error" "$ERLOG"
   mailer "$copy_error"
   exit 1
 fi
 logger "copying \"$DAY\" (size: $(du --null -hs $BDIR/$HOSTNAME-$MACHINEID/$DAY | cut -f 1)) direcory from local: $BDIR/$HOSTNAME-$MACHINEID to remote: $REMOTE_DIR/$HOSTNAME-$MACHINEID" "$MLOG"
 removeold
}

# clean-up dumps older than $DELTA minutes, purge old log's lines bigger than $PRESERVE_LINES number
removeold() {
 cd $BDIR && find $BDIR -type f -iname '*.sql.gz' -mmin +$DELTA -exec rm -f {} \;

 for log in {$MLOG,$ERLOG}
  do
   if [ -f "$log" ];then
     log_lines=$(cat $log | wc -l)
     if [ $log_lines -gt $PRESERVE_LINES ]; then
      echo "$(tail -n $PRESERVE_LINES $log)" > $log
     fi
   fi
  done
}

# send emails when something goes wrong
# @param $1 - message body
# @return - exit code
mailer() {
 mail_text_lim=300
 mail_text=$1
 mail_text_len=$(echo -n $mail_text | wc -c)

 if [ $mail_text_len -gt $mail_text_lim ];then
  mail_text=$(echo $mail_text | cut -c -$mail_text_lim)
  mail_text=$(echo -e "$mail_text ...\n\n[The output has reached the limit of $mail_text_lim characters and was truncated]")
 fi

 echo "$mail_text" | mail -a "From: $MAIL_FROM" -s "$MAIL_SUBJ" $MAIL_REC
}

# write some logs
# @param $1 - message to write
# @param $2 - log file
# @return - exit code
logger() {
  if [ "$DEBUG" == 1 ]; then
    echo -e "\033[32m[$(date)] DEBUG: $1\033[0m"
    echo -e "[$(date)] DEBUG: $1 " >> $2
  else echo -e "[$(date)] $1" >> $2
  fi
}

get_password
backup
