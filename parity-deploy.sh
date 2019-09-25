#!/bin/bash
# Copyright 2017 Parity Technologies (UK) Ltd.
CHAIN_NAME="parity"
CHAIN_NODES="1"
CLIENT="0"
DOCKER_INCLUDE="include/docker-compose.yml"
help() {

	echo "parity-deploy.sh OPTIONS
Usage:
REQUIRED:
        --config dev / aura / tendermint / validatorset / input.json / custom_chain.toml

OPTIONAL:
        --name name_of_chain. Default: parity
        --nodes number_of_nodes (if using aura / tendermint) Default: 2
        --ethstats - Enable ethstats monitoring of authority nodes. Default: Off
        --expose - Expose a specific container on ports 8180 / 8545 / 30303. Default: Config specific
	--entrypoint - Use custom entrypoint for docker container e.g. /home/parity/bin/parity

NOTE:
    input.json - Custom spec files can be inserted by specifiying the path to the json file.
    custom_chain.toml - Custom toml file defining multiple nodes. See customchain/config/example.toml for an example.
"

}

check_packages() {

	if [ $(grep -i debian /etc/*-release | wc -l) -gt 0 ]; then
		if [ ! -f /usr/bin/docker ]; then
			sudo apt-get -y install docker.io python-pip
		fi

		if [ ! -f /usr/local/bin/docker-compose ]; then
			sudo pip install docker-compose
		fi
	fi
}

genpw() {
	openssl rand -base64 12

}

create_node_params() {
	local DEST_DIR=deployment/$1
	if [ ! -d $DEST_DIR ]; then
		mkdir -p $DEST_DIR
	fi

	if [ ! -f $DEST_DIR/password ]; then
		openssl rand -base64 12 >$DEST_DIR/password
	fi
	./config/utils/keygen.sh $DEST_DIR

	# local SPEC_FILE=$(mktemp $DEST_DIR/spec.XXXXXXXXX)
	# gsed "s/CHAIN_NAME/$CHAIN_NAME/g" config/spec/example.spec >$SPEC_FILE
	# parity --chain $SPEC_FILE --keys-path $DEST_DIR/ account new --password $DEST_DIR/password >$DEST_DIR/address.txt
	# rm $SPEC_FILE
	PASSWORD=$(cat $DEST_DIR/password)
	PRIV_KEY=$(cat $DEST_DIR/key.priv)
	./ethstore insert ${PRIV_KEY} $DEST_DIR/password --dir $DEST_DIR/parity >$DEST_DIR/address.txt

	echo "NETWORK_NAME=$CHAIN_NAME" >.env

}

create_reserved_peers_poa() {
	PUB_KEY=$(cat deployment/$1/key.pub)
	echo "enode://$PUB_KEY@host$1:30303" >>deployment/chain/reserved_peers
}

create_reserved_peers_instantseal() {
	PUB_KEY=$(cat deployment/$1/key.pub)
	echo "enode://$PUB_KEY@127.0.0.1:30303" >>deployment/chain/reserved_peers

}

build_spec() {
	display_header
	display_name
	display_engine
	display_params
	display_genesis
	display_accounts
	display_footer

}

build_docker_config_poa() {
	echo "version: '2.0'" >docker-compose.yml
	echo "services:" >>docker-compose.yml

	for x in $(seq 1 $CHAIN_NODES); do
		cat config/docker/authority.yml | gsed -e "s/NODE_NAME/$x/g" | gsed -e "s@-d /home/parity/data@-d /home/parity/data $PARITY_OPTIONS@g" >>docker-compose.yml
		mkdir -p data/$x
	done

	build_docker_config_ethstats

	#cat $DOCKER_INCLUDE >>docker-compose.yml

	chown -R $USER data/

}

build_docker_config_ss() {
	for x in $(seq 1 $SECRETSTORE); do
		cat config/docker/ss.yml | gsed -e "s/IP/$x/g" | gsed -e "s/NODE_NAME/ss$x/g" | gsed -e "s@-d /home/parity/data@-d /home/parity/data $PARITY_OPTIONS@g" >>docker-compose.yml
		mkdir -p data/ss$x
	done

	chown -R $USER data/
}

build_docker_config_ethstats() {

	if [ "$ETHSTATS" == "1" ]; then
		cat include/ethstats.yml >>docker-compose.yml
	fi
}

build_docker_config_instantseal() {

	cat config/docker/instantseal.yml | gsed -e "s@-d /home/parity/data@-d /home/parity/data $PARITY_OPTIONS@g" >docker-compose.yml

	build_docker_config_ethstats

        cat $DOCKER_INCLUDE >>docker-compose.yml

        mkdir -p data/is_authority

        chown -R $USER data/
}

build_docker_client() {
	if [ "$CLIENT" == "1" ]; then
		create_node_params client
		cp config/spec/client.toml deployment/client/
		cat config/docker/client.yml >>docker-compose.yml

		# writing client dependencies
		if [ "$CHAIN_NODES" -gt "0" ]; then
			echo "       depends_on:" >>docker-compose.yml

			for x in $(seq 1 $CHAIN_NODES); do
				echo "       - \"host${x}\"" >>docker-compose.yml
			done
		fi
	fi
}

build_custom_chain() {

	if [ -z "$CUSTOM_CHAIN" ]; then
		echo "Must specify argument for custom chain option."
		exit 1
	fi

	./customchain/generate.py "$CUSTOM_CHAIN"

	exit 0
}

display_header() {

	cat config/spec/chain_header

}

display_footer() {

	cat config/spec/chain_footer
}

display_name() {

	cat config/spec/name | gsed -e "s/CHAIN_NAME/$CHAIN_NAME/g"
}

create_node_config_poa() {
	ENGINE_SIGNER=$(cat deployment/$1/address.txt)
	cat config/spec/authority_round.toml | gsed -e "s/ENGINE_SIGNER/$ENGINE_SIGNER/g" >deployment/$1/authority.toml

}

create_node_config_instantseal() {

	ENGINE_SIGNER=$(cat deployment/$1/address.txt)
	cat config/spec/instant_seal.toml | gsed -e "s/ENGINE_SIGNER/$ENGINE_SIGNER/g" >deployment/$1/authority.toml

}

expose_container() {

	gsed -i "s@container_name: $1@&\n       ports:\n       - 8080:8080\n       - 8180:8180\n       - 8545:8545\n       - 8546:8546\n       - 30303:30303@g" docker-compose.yml

}

expose_ss() {

	gsed -i "s@container_name: $1@&\n       ports:\n       - 8010:8010@g" docker-compose.yml

}

select_exposed_container() {

	if [ -n "$EXPOSE_CLIENT" ]; then
		expose_container $EXPOSE_CLIENT
	else
		if [ "$CLIENT" == "0" ]; then
			expose_container host1
		fi
	fi

}

display_engine() {

	case $CHAIN_ENGINE in
	dev)
		cat config/spec/engine/instantseal
		;;
	aura | validatorset | tendermint)
		for x in $(seq 1 $CHAIN_NODES); do
			VALIDATOR=$(cat deployment/$x/address.txt)
			RESERVED_PEERS="$RESERVED_PEERS $VALIDATOR"
			VALIDATORS="$VALIDATORS \"$VALIDATOR\","
		done
		# Remove trailing , from validator list
		VALIDATORS=$(echo $VALIDATORS | gsed 's/\(.*\),.*/\1/')
		cat config/spec/engine/$CHAIN_ENGINE | gsed -e "s/0x0000000000000000000000000000000000000000/$VALIDATORS/g"
		;;
	*)
		echo "Unknown engine: $CHAIN_ENGINE"
		;;
	esac

}

display_params() {

	cat config/spec/params/$CHAIN_ENGINE

}

display_genesis() {

	cat config/spec/genesis/$CHAIN_ENGINE

}

display_accounts() {

	#cat config/spec/accounts/$CHAIN_ENGINE
	echo '"accounts": {
			"0x0000000000000000000000000000000000000001": { "balance": "1", "builtin": { "name": "ecrecover", "pricing": { "linear": { "base": 3000, "word": 0 } } } },
			"0x0000000000000000000000000000000000000002": { "balance": "1", "builtin": { "name": "sha256", "pricing": { "linear": { "base": 60, "word": 12 } } } },
			"0x0000000000000000000000000000000000000003": { "balance": "1", "builtin": { "name": "ripemd160", "pricing": { "linear": { "base": 600, "word": 120 } } } },
			"0x0000000000000000000000000000000000000004": { "balance": "1", "builtin": { "name": "identity", "pricing": { "linear": { "base": 15, "word": 3 } } } },
			"0x0000000000000000000000000000000000000005": { "builtin": { "name": "modexp", "activate_at": "0x0", "pricing": { "modexp": { "divisor": 20 } } } },
			"0x0000000000000000000000000000000000000006": { "builtin": { "name": "alt_bn128_add", "activate_at": "0x0", "pricing": { "linear": { "base": 500, "word": 0 } } } },
			"0x0000000000000000000000000000000000000007": { "builtin": { "name": "alt_bn128_mul", "activate_at": "0x0", "pricing": { "linear": { "base": 40000, "word": 0 } } } },
			"0x0000000000000000000000000000000000000008": { "builtin": { "name": "alt_bn128_pairing", "activate_at": "0x0", "pricing": { "alt_bn128_pairing": { "base": 100000, "pair": 80000 } } } },
			"0x00Ea169ce7e0992960D3BdE6F5D539C955316432": { "balance": "1606938044258990275541962092341162602522202993782792835301376" },'
		
	for x in $(seq $CHAIN_NODES); do
		ADDR=$(cat deployment/$x/address.txt)
		BAL='"'$ADDR'": { "balance": "1606938044258990275541962092341162602522202993782792835301376" }'
		if [ $x -ne $CHAIN_NODES ]; then
			echo '			'$BAL","
		else
			echo '			'$BAL
		fi
	done
	echo "	}"

}

ARGS="$@"

while [ "$1" != "" ]; do
	case $1 in
	--name)
		shift
		CHAIN_NAME=$1
		;;
	-c | --config)
		shift
		CHAIN_ENGINE=$1
		;;
	-n | --nodes)
		shift
		CHAIN_NODES=$1
		;;
	-r | --release)
		shift
		PARITY_RELEASE=$1
		;;
	-e | --ethstats)
		ETHSTATS=1
		;;
	--enable-client)
		CLIENT=1
		;;
	--expose)
		shift
		EXPOSE_CLIENT="$1"
		;;
	--chain)
		shift
		CHAIN_NETWORK=$1
		;;
	--entrypoint)
		shift
		ENTRYPOINT=$1
		;;
	--secretstore)
		shift
		SECRETSTORE=$1
		;;
	-h | --help)
		help
		exit
		;;
	*) PARITY_OPTIONS="$PARITY_OPTIONS $1 " ;;
	esac
	shift
done

if [ -z "$CHAIN_ENGINE" ] && [ -z "$CHAIN_NETWORK" ]; then
	echo "No chain argument, exiting..."
	exit 1
fi

# Get a copy of the parity binary, overwriting if release is set

if [ ! -f /usr/bin/parity ] || [ -n "$PARITY_RELEASE" ]; then

	if [ -z "$PARITY_RELEASE" ]; then
		echo "NO custom parity build set, downloading stable"
		#bash <(curl https://get.parity.io -Lk -r stable)
	else
		echo "Custom parity build set: $PARITY_RELEASE"
		#curl -o parity-download.sh https://get.parity.io -Lk
		#bash parity-download.sh -r $PARITY_RELEASE
	fi
fi

mkdir -p deployment/chain
#check_packages
echo $CHAIN_ENGINE | grep -q toml
if [ $? -eq 0 ]; then
	./customchain/generate.py "$CHAIN_ENGINE"
	exit 0
fi

if [ ! -z "$CHAIN_NETWORK" ]; then
	if [ ! -z "$PARITY_OPTIONS" ]; then
		cat config/docker/chain.yml | gsed -e "s/CHAIN_NAME/$CHAIN_NETWORK/g" | gsed -e "s@-d /home/parity/data@-d /home/parity/data $PARITY_OPTIONS@g" >docker-compose.yml

	else
		cat config/docker/chain.yml | gsed -e "s/CHAIN_NAME/$CHAIN_NETWORK/g" >docker-compose.yml
	fi

elif [ "$CHAIN_ENGINE" == "dev" ]; then
	echo "using instantseal"
	create_node_params is_authority
	create_reserved_peers_instantseal is_authority
	create_node_config_instantseal is_authority
	build_docker_config_instantseal

elif [ "$CHAIN_ENGINE" == "aura" ] || [ "$CHAIN_ENGINE" == "validatorset" ] || [ "$CHAIN_ENGINE" == "tendermint" ] || [ -f "$CHAIN_ENGINE" ]; then
	if [ $CHAIN_NODES ]; then
		for x in $(seq $CHAIN_NODES); do
			create_node_params $x
			create_reserved_peers_poa $x
			create_node_config_poa $x
		done
		build_docker_config_poa
		build_docker_client
		if [ ! -z $SECRETSTORE ]; then
			build_docker_config_ss
		fi
		cat $DOCKER_INCLUDE >>docker-compose.yml
	fi

	if [ "$CHAIN_ENGINE" == "aura" ] || [ "$CHAIN_ENGINE" == "validatorset" ] || [ "$CHAIN_ENGINE" == "tendermint" ]; then
		build_spec >deployment/chain/spec.json
	else
		mkdir -p deployment/chain
		cp $CHAIN_ENGINE deployment/chain/spec.json
	fi

else

	echo "Could not find spec file: $CHAIN_ENGINE"
fi

if [ ! -z $SECRETSTORE ]; then
	for x in $(seq $SECRETSTORE); do
		create_node_params ss$x
	done

	declare -a loc mm mmE mmlog
	for (( i=1; i<=$SECRETSTORE; i++ ))
	do
		# generating good config files 
		DEST_DIR=deployment/ss$i
		loc[$i]=$DEST_DIR/ss$i.toml
		cp config/secret/ss.bak.toml ${loc[$i]}
		ss[$i]=$(cat $DEST_DIR/address.txt)
		ssx[$i]=$(echo ${ss[$i]}|cut -d "x" -f 2)
		gsed -i -e  s,"accountx","${ssx[$i]}",g -e "/self_secret/s/^#//g" ${loc[$i]}
		ssp[$i]=$(cat deployment/ss$i/key.pub)
		ssE[$i]=$(cat deployment/ss$i/key.pub)
	done

	for (( i=1; i<=$SECRETSTORE; i++ ))
	do
		# accounts
		gsed -i -e "/bootnodes/s/^#//g"   -e "/nodes/s/^#//g" ${loc[$i]}
		en=
		max=$((SECRETSTORE-1))
		count=1
		for (( j=1; j<=$SECRETSTORE; j++ ))
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

	#gsed -i -e "s@image: parity/parity:stable@image: zean00/parity:ss@g" docker-compose.yml
	expose_ss ss1
fi

if [ ! -z $PARITY_RELEASE ]; then
    echo "Custom release ${PARITY_RELEASE} selected. WARNING: This may not be compatible with all parity docker images"
	DOCKER_TMP=$(mktemp)
	cat docker-compose.yml | sed -e "s@image: parity/parity:stable@image: parity/parity:${PARITY_RELEASE}@g" > $DOCKER_TMP
	mv $DOCKER_TMP docker-compose.yml
fi

if [ ! -z $ENTRYPOINT ]; then
    ENTRYPOINT_TMP=$(mktemp)
	cat docker-compose.yml | sed -e "s@user: root@user: root\n       entrypoint: ${ENTRYPOINT}@g" > $ENTRYPOINT_TMP
	mv $ENTRYPOINT_TMP docker-compose.yml
fi

select_exposed_container
