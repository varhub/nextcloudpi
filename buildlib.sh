#!/bin/bash

# Library to install software on Raspbian ARM through QEMU
#
# Copyleft 2017 by Ignacio Nunez Hernanz <nacho _a_t_ ownyourbits _d_o_t_ com>
# GPL licensed (see end of file) * Use at your own risk!
#
# More at ownyourbits.com
#

IMGNAME=$( basename "$IMGFILE" .img )_$( basename "$INSTALL_SCRIPT" .sh ).img
DBG=x

# $IMGOUT will contain the name of the last step
function launch_install_qemu()
{
  local IMG=$1
  local IP=$2
  [[ "$IP"      == ""  ]] && { echo "usage: launch_install_qemu <script> <img> <IP>"; return 1; }
  test -f "$IMG"          || { echo "input file $IMG not found";                      return 1; }

  local BASE=$( sed 's=-stage[[:digit:]]=='         <<< "$IMG" )
  local NUM=$(  sed 's=.*-stage\([[:digit:]]\)=\1=' <<< "$IMG" )
  [[ "$BASE" == "$IMG" ]] && NUM=0

  local NUM_REBOOTS=$( grep -c reboot "$INSTALL_SCRIPT" )
  while [[ $NUM_REBOOTS != -1 ]]; do
    NUM=$(( NUM+1 ))
    IMGOUT="$BASE-stage$NUM"
    cp -v "$IMG" "$IMGOUT" || return 1 # take a copy of the input image for processing ( append "-stage1" )

    pgrep qemu-system-arm &>/dev/null && { echo -e "QEMU instance already running. Abort..."; return 1; }
    launch_qemu "$IMGOUT" &
    sleep 10
    wait_SSH "$IP"
    launch_installation_qemu "$IP" || return 1
    wait 
    IMG="$IMGOUT"
    NUM_REBOOTS=$(( NUM_REBOOTS-1 ))
  done
  echo "$IMGOUT generated successfully"
}

function launch_qemu()
{
  local IMG=$1
  test -f "$1" || { echo "Image $IMG not found"; return 1; }
  test -d qemu-raspbian-network || git clone https://github.com/nachoparker/qemu-raspbian-network.git
  sed -i '30s/NO_NETWORK=1/NO_NETWORK=0/' qemu-raspbian-network/qemu-pi.sh
  sed -i '35s/NO_GRAPHIC=0/NO_GRAPHIC=1/' qemu-raspbian-network/qemu-pi.sh
  echo "Starting QEMU image $IMG"
  ( cd qemu-raspbian-network && sudo ./qemu-pi.sh ../"$IMG" 2>/dev/null )
}

function ssh_pi()
{
  local IP=$1
  local ARGS=${@:2}
  local PIUSER=${PIUSER:-pi}
  local PIPASS=${PIPASS:-raspberry}
  local SSH=( ssh -q  -o UserKnownHostsFile=/dev/null\
                      -o StrictHostKeyChecking=no\
                      -o ServerAliveInterval=20\
                      -o ConnectTimeout=20\
                      -o LogLevel=quiet                  )
  type sshpass &>/dev/null && local SSHPASS=( sshpass -p$PIPASS )
  if [[ "${SSHPASS[@]}" == "" ]]; then
    ${SSH[@]} ${PIUSER}@$IP $ARGS; 
  else
    ${SSHPASS[@]} ${SSH[@]} ${PIUSER}@$IP $ARGS 
    local RET=$?
    [[ $RET -eq 5 ]] && { ${SSH[@]} ${PIUSER}@$IP $ARGS; return $?; }
    return $RET
  fi
}

function wait_SSH()
{
  local IP=$1
  echo "Waiting for SSH to be up on $IP..."
  while true; do
    ssh_pi "$IP" : && break
    sleep 1
  done
  echo "SSH is up"
}

function launch_installation()
{
  local IP=$1
  [[ "$INSTALLATION_CODE"  == "" ]] && { echo "Need to run config first"    ; return 1; }
  [[ "$INSTALLATION_STEPS" == "" ]] && { echo "No installation instructions"; return 1; }
  local PREINST_CODE="
set -e$DBG
sudo su
set -e$DBG
"
  echo "Launching installation"
  echo -e "$PREINST_CODE\n$INSTALLATION_CODE\n$INSTALLATION_STEPS" | ssh_pi "$IP" || { echo "Installation to $IP failed" && return 1; }
}

function launch_installation_qemu()
{
  local IP=$1
  [[ "$NO_CFG_STEP"  != "1" ]] && local CFG_STEP=configure
  [[ "$NO_CLEANUP"   != "1" ]] && local CLEANUP_STEP="if [[ \$( type -t cleanup ) == function ]];then cleanup; fi"
  [[ "$NO_HALT_STEP" != "1" ]] && local HALT_STEP="nohup halt &>/dev/null &"
  local INSTALLATION_STEPS="
install
$CFG_STEP
$CLEANUP_STEP
$HALT_STEP
"
  launch_installation "$IP"
}

function launch_installation_online()
{
  local IP=$1
  [[ "$NO_CFG_STEP" != "1" ]]  && local CFG_STEP=configure
  local INSTALLATION_STEPS="
install
$CFG_STEP
"
  launch_installation "$IP"
}

function copy_to_image()
{
  local IMG=$1
  local DST=$2
  local SRC=${@: 3 }
  local SECTOR
  local OFFSET
  SECTOR=$( fdisk -l "$IMG" | grep Linux | awk '{ print $2 }' )
  OFFSET=$(( SECTOR * 512 ))

  [ -f "$IMG" ] || { echo "no image"; return 1; }
  mkdir -p tmpmnt
  sudo mount "$IMG" -o offset="$OFFSET" tmpmnt || return 1
  sudo cp -v "$SRC" tmpmnt/"$DST" || return 1
  sudo umount -l tmpmnt
  rmdir tmpmnt &>/dev/null
}

function deactivate_unattended_upgrades()
{
  local IMG=$1
  local SECTOR
  local OFFSET
  SECTOR=$( fdisk -l "$IMG" | grep Linux | awk '{ print $2 }' )
  OFFSET=$(( SECTOR * 512 ))

  [ -f "$IMG" ] || { echo "no image"; return 1; }
  mkdir -p tmpmnt
  sudo mount "$IMG" -o offset="$OFFSET" tmpmnt || return 1
  sudo rm -f tmpmnt/etc/apt/apt.conf.d/20nextcloudpi-upgrades
  sudo umount -l tmpmnt
  rmdir tmpmnt &>/dev/null
}

function download_resize_raspbian_img()
{
  local SIZE=$1
  local IMGFILE=$2
  local IMG=raspbian_lite_latest

  test -f "$IMGFILE" && \
    echo -e "INFO: $IMGFILE already exists. Skipping download ..." && return 0 

  test -f $IMG.zip || \
    wget https://downloads.raspberrypi.org/$IMG -O $IMG.zip || return 1

  unzip -o $IMG.zip && \
    mv *-raspbian-*.img "$IMGFILE" && \
    qemu-img resize -f raw "$IMGFILE" +"$SIZE"  && \
    return 0
}

function pack_image()
{
  local IMGOUT="$1"
  local IMGNAME="$2"
  local TARNAME=$( basename $IMGNAME .img ).tar.bz2
  echo "copying $IMGOUT → $IMGNAME"
  cp "$IMGOUT" "$IMGNAME" || return 1
  echo "packing $IMGNAME → $TARNAME"
  tar -I pbzip2 -cvf "$TARNAME" "$IMGNAME" &>/dev/null && \
    echo -e "$TARNAME packed successfully"
}

function create_torrent()
{
  [[ "$1" == "" ]] && { echo "No directory specified"; exit 1; }                                 
  test -d "$1" || { echo "$1 not found or is not a directory" ; exit 1; }                          

  md5sum "$1"/*.bz2 > "$1"/md5sum

  createtorrent -a udp://tracker.opentrackr.org -p 1337 -c "NextCloudPi. Nextcloud for Raspberry Pi image" "$1" "$1".torrent
}

function generate_changelog()
{
  git log --graph --oneline --decorate \
    --pretty=format:"[%<(13)%D](https://github.com/nextcloud/nextcloudpi/commit/%h) (%ad) %s" --date=short | \
    grep 'tag: v' | \
    sed '/HEAD ->\|origin/s|\[.*\(tag: v[0-9]\+\.[0-9]\+\.[0-9]\+\).*\]|[\1]|' | \
    sed 's|* \[tag: |\n[|' > changelog.md
}

function deactivate_unattended_upgrades()
{
  local IMG=$1
  local SECTOR
  local OFFSET
  SECTOR=$( fdisk -l "$IMG" | grep Linux | awk '{ print $2 }' )
  OFFSET=$(( SECTOR * 512 ))

  [ -f "$IMG" ] || { echo "no image"; return 1; }
  mkdir -p tmpmnt
  sudo mount "$IMG" -o offset="$OFFSET" tmpmnt || return 1
  sudo rm -f tmpmnt/etc/apt/apt.conf.d/20nextcloudpi-upgrades
  sudo umount -l tmpmnt
  rmdir tmpmnt &>/dev/null
}

function prepare_sshd()
{
  local SECTOR1=$( fdisk -l $IMG | grep FAT32 | awk '{ print $2 }' )
  local OFFSET1=$(( SECTOR1 * 512 ))
  mkdir -p tmpmnt
  mount $IMG -o offset=$OFFSET1 tmpmnt
  touch tmpmnt/ssh   # this enables ssh
  umount tmpmnt
}
