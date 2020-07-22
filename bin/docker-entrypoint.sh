#!/bin/bash
set -eo pipefail
trap 'kill `jobs -p`' SIGTERM

: ${NETWORK:=testnet}
: ${LIGHTNINGD_OPT:=--log-level=debug}
: ${BITCOIND_OPT:=-debug=rpc --printtoconsole=0 --fallbackfee=0.00001}

[[ "$NETWORK" == "mainnet" ]] && NETWORK=beyondcoin

[[ "$NETWORK" != "beyondcoin" ]] && NETWORK_ARG="-$NETWORK"

if [ -d /etc/lightning ]; then
  echo -n "Using lightningd directory mounted in /etc/lightning... "
  LN_PATH=/etc/lightning

else

  # Setup beyondcoind (only needed when we're starting our own lightningd instance)
  if [ -d /etc/beyondcoin ]; then
    echo -n "Connecting to beyondcoind configured in /etc/beyondcoin... "

    RPC_OPT="-datadir=/etc/beyondcoin $([[ -z "$BITCOIND_RPCCONNECT" ]] || echo "-rpcconnect=$BITCOIND_RPCCONNECT")"

  elif [ -n "$BITCOIND_URI" ]; then
    [[ "$BITCOIND_URI" =~ ^[a-z]+:\/+(([^:/]+):([^@/]+))@([^:/]+:[0-9]+)/?$ ]] || \
      { echo >&2 "ERROR: invalid beyondcoind URI: $BITCOIND_URI"; exit 1; }

    echo -n "Connecting to beyondcoind at ${BASH_REMATCH[4]}... "

    RPC_OPT="-rpcconnect=${BASH_REMATCH[4]}"

    if [ "${BASH_REMATCH[2]}" != "__cookie__" ]; then
      RPC_OPT="$RPC_OPT -rpcuser=${BASH_REMATCH[2]} -rpcpassword=${BASH_REMATCH[3]}"
    else
      RPC_OPT="$RPC_OPT -datadir=/tmp/beyondcoin"
      [[ "$NETWORK" == "beyondcoin" ]] && NET_PATH=/tmp/beyondcoin || NET_PATH=/tmp/beyondcoin/$NETWORK
      mkdir -p $NET_PATH
      echo "${BASH_REMATCH[1]}" > $NET_PATH/.cookie
    fi

  else
    echo -n "Starting beyondcoind... "

    mkdir -p /data/beyondcoin
    RPC_OPT="-datadir=/data/beyondcoin"

    beyondcoind $NETWORK_ARG $RPC_OPT $BITCOIND_OPT &
  fi

  echo -n "waiting for RPC... "
  beyondcoin-cli $NETWORK_ARG $RPC_OPT -rpcwait getblockchaininfo > /dev/null
  echo "ready."

  # Setup lightning
  echo -n "Starting lightningd... "

  LN_PATH=/data/lightning
  mkdir -p $LN_PATH

  lnopt=($LIGHTNINGD_OPT --network=$NETWORK --lightning-dir="$LN_PATH" --log-file=debug.log)
  [[ -z "$LN_ALIAS" ]] || lnopt+=(--alias="$LN_ALIAS")

  lightningd "${lnopt[@]}" $(echo "$RPC_OPT" | sed -r 's/(^| )-/\1--beyondcoin-/g') > /dev/null &
fi

LN_NET_PATH=$LN_PATH/$NETWORK
mkdir -p $LN_NET_PATH

if [ ! -S $LN_NET_PATH/lightning-rpc ]; then
  echo -n "waiting for RPC unix socket... "
  sed --quiet '/^lightning-rpc$/ q' <(inotifywait -e create,moved_to --format '%f' -qm $LN_NET_PATH)
fi
sleep 0.5

if command -v lightning-cli > /dev/null; then
  lightning-cli --rpc-file=$LN_NET_PATH/lightning-rpc --network=$NETWORK getinfo > /dev/null
  echo -n "c-lightning RPC ready."
fi

echo -e "\nStarting Beyondcoin Lightning Charge"

if [ -z "$STANDALONE"  ]; then
    # when not in standalone mode, run spark-wallet as an additional background job
  charged -d /data/charge.db -l $LN_NET_PATH -i 0.0.0.0 "$@" $CHARGED_OPTS &

  # shutdown the entire process when any of the background jobs exits (even if successfully)
  wait -n
  kill -TERM $$
else
  exec charged -d /data/charge.db -l $LN_NET_PATH -i 0.0.0.0 "$@" $CHARGED_OPTS
fi
