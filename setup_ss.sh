#!/bin/bash

declare -a loc mm mmE mmlog

green=`tput setaf 2`
reset=`tput sgr0`

# cleanup any previous attempts of running this script
docker-compose down

# get up to speed
#docker-compose pull ss1 alice

# setup of 3 secret nodes
node_num=3

for (( i=1; i<=$node_num; i++ ))
do
    # generating good config files 
    DEST_DIR=deployment/ss$i
    loc[$i]=$DEST_DIR/ss$i.toml
    cp config/secret/ss.bak.toml ${loc[$i]}

    # create secret accounts
    #ss[$i]=$(docker run --rm -i -v $PWD/parity/config:/parity/config zean00/parity:ss --config /${loc[$i]} account new)
    #echo ${ss[$i]}
    # cutting the 0x 
    ss[$i]=$(cat $DEST_DIR/address.txt)
    ssx[$i]=$(echo ${ss[$i]}|cut -d "x" -f 2)
    # echo ${ssx[$i]}
    # # replacing dummy variables with accounts
    gsed -i -e  s,"accountx","${ssx[$i]}",g -e "/self_secret/s/^#//g" ${loc[$i]}

    # # grabbing the enode and server public key from the logs

    sslog[$i]=$(gtimeout 10s docker-compose up ss$i)
    ssp[$i]=$(echo "${sslog[$i]}"|grep "SecretStore node:"|cut -d "x" -f 2)
    #echo ${ssp[$i]}
    ssE[$i]=$(echo "${sslog[$i]}"|grep "Public node URL:"|cut -d "/" -f 3)
    #ip=$(echo "${ssE[$i]}"|egrep -o '([0-9]{1,3}\.){3}[0-9]{1,3}')
    #echo $ip
    #ssp[$i]=${ssp[$i]}@$ip:8011
    #echo ${ssE[$i]}
    #docker kill $(docker ps -q)
    #docker-compose rm -f -s ss$i
done

for (( i=1; i<=$node_num; i++ ))
do
    # accounts
    gsed -i -e "/bootnodes/s/^#//g"   -e "/nodes/s/^#//g" ${loc[$i]}
                # echo $i
                # echo ${loc[$i]}
    en=
    max=$((node_num-1))
    count=1
    for (( j=1; j<=$node_num; j++ ))
    do
        gsed -i -e s,ssp$j,${ssp[$j]},g  ${loc[$i]}
        if [ $j -ne $i ];then
            en=${en}enode://${ssE[j]}
            if [ $count -lt $max ];then
                en=${en},
            fi
            count=$((count+1))
        fi
    done

    gsed -i -e "s#ENODES#$en#g" ${loc[$i]}
done

docker-compose down