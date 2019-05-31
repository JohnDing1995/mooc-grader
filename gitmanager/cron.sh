#!/bin/bash

FLAG="/tmp/mooc-grader-manager-clean"
LOG="/tmp/mooc-grader-log"
SQL="sqlite3 -batch -noheader -column db.sqlite3"
TRY_PYTHON="/srv/grader/venv/bin/activate"

cd `dirname $0`/..
if [ -d exercises ]; then
  CDIR=exercises
else
  CDIR=courses
fi
CDIR=$(realpath $CDIR)
USER=$(stat -c '%U' $CDIR/)

if [ -e $FLAG ]; then
  exit 0
fi
touch $FLAG
chown $USER $FLAG

if [ -f $TRY_PYTHON ]; then
  source $TRY_PYTHON
fi

# Handle each scheduled course key.
keys="`$SQL "select r.key from gitmanager_courseupdate as u left join gitmanager_courserepo r on u.course_repo_id=r.id where u.updated=0;"`"
for key in $keys; do
  echo "Update $key" > $LOG
  vals=(`$SQL "select id,git_origin,git_branch from gitmanager_courserepo where key='$key';"`)
  id=${vals[0]}
  sudo -u $USER -H gitmanager/cron_pull_build.sh $TRY_PYTHON $key ${vals[@]} $DOCKER_HOST_PATH >> $LOG 2>&1 || continue

  # Update sandbox.
  if [ -d /var/sandbox_$key ]; then
    ./manage_sandbox.sh -d /var/sandbox_$key -q create $key >> $LOG 2>&1
  else
    if [ -d /var/sandbox ]; then
      ./manage_sandbox.sh -q create $key >> $LOG 2>&1
    fi
  fi

  # Write to database.
  $SQL "update gitmanager_courseupdate set log=readfile('$LOG'),updated_time=CURRENT_TIMESTAMP,updated=1 where course_repo_id=$id and updated=0;"

  # Clean up old entries.
  vals=(`$SQL "select request_time from gitmanager_courseupdate where id=$id order by request_time desc limit 4,1;"`)
  last=${vals[0]}
  if [ "$last" != "" ]; then
    $SQL "delete from gitmanager_courseupdate where id=$id and request_time > '$last';"
  fi
done

# Reload course configuration by restarting uwsgi processes
touch $CDIR
for f in /srv/grader/uwsgi-grader*.ini; do
    [ -e $f ] && touch $f
done
