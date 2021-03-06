#! /bin/bash

set -eo pipefail

#usage: sudo ./docker-cleanup-volumes.sh [--dry-run]

dockerdir=$(readlink -f /var/lib/docker)
volumesdir=${dockerdir}/volumes
vfsdir=${dockerdir}/vfs/dir
allvolumes=()
dryrun=false

function delete_volumes() {
  targetdir=$1
  echo
  if [[ ! -d ${targetdir} ]]; then
        echo "Directory ${targetdir} does not exist, skipping."
        return
  fi
  echo "Delete unused volume directories from $targetdir"
  for dir in $(ls -d ${targetdir}/* 2>/dev/null)
  do
        dir=$(basename $dir)
        if [[ "${dir}" =~ [0-9a-f]{64} ]]; then
                if [[ ${allvolumes[@]} =~ "${dir}" ]]; then
                        echo In use ${dir}
                else
                        if [ "${dryrun}" = false ]; then
                                echo Deleting ${dir}
                                rm -rf ${targetdir}/${dir}
                        else
                                echo Would have deleted ${dir}
                        fi
                fi
        else
                echo Not a volume ${dir}
        fi
  done
}

if [ $UID != 0 ]; then
    echo "You need to be root to use this script."
    exit 1
fi

docker_bin=$(which docker.io 2> /dev/null || which docker 2> /dev/null)
if [ -z "$docker_bin" ] ; then
    echo "Please install docker. You can install docker by running \"wget -qO- https://get.docker.io/ | sh\"."
    exit 1
fi

if [ "$1" = "--dry-run" ]; then
        dryrun=true
else if [ -n "$1" ]; then
        echo "Cleanup docker volumes: remove unused volumes."
        echo "Usage: ${0##*/} [--dry-run]"
        echo "   --dry-run: dry run: display what would get removed."
        exit 1
fi
fi

# Make sure that we can talk to docker daemon. If we cannot, we fail here.
docker info >/dev/null

container_ids=$(${docker_bin} ps -a -q --no-trunc)

if [[ ${container_ids[@]} =~ "$HOSTNAME" ]]; then
    dockerdir_match=`${docker_bin} inspect -f '{{ index .Volumes "/var/lib/docker" }}' $HOSTNAME`
else
    dockerdir_match=${dockerdir}
fi

volumesdir_match=${dockerdir_match}/volumes
vfsdir_match=${dockerdir_match}/vfs/dir

#All volumes from all containers
for container in $container_ids; do
        #add container id to list of volumes, don't think these
        #ever exists in the volumesdir but just to be safe
        allvolumes+=${container}
        #add all volumes from this container to the list of volumes
        for volpath in `${docker_bin} inspect --format='{{range $vol, $path := .Volumes}}{{$path}}{{"\n"}}{{end}}' ${container}`; do
		#try to get volume id from the volume path
		vid=$(echo "${volpath}"|sed "s|${vfsdir_match}||;s|${volumesdir_match}||;s/.*\([0-9a-f]\{64\}\).*/\1/")
                # host daemon shows original dir path - this is why host_ variables are used:
                if [[ (${volpath} == ${vfsdir_match}* || ${volpath} == ${volumesdir_match}*) && "${vid}" =~ [0-9a-f]{64} ]]; then
                        allvolumes+=("${vid}")
                else
                        #check if it's a bindmount, these have a config.json file in the ${volumesdir} but no files in ${vfsdir} (docker 1.6.2 and below)
                        for bmv in `grep --include config.json -Rl "\"IsBindMount\":true" ${volumesdir} | xargs grep -l "\"Path\":\"${volpath}\""`; do
                                bmv="$(basename "$(dirname "${bmv}")")"
                                allvolumes+=("${bmv}")
                                #there should be only one config for the bindmount, delete any duplicate for the same bindmount.
                                break
                        done
                fi
        done
done

delete_volumes ${volumesdir}
delete_volumes ${vfsdir}

