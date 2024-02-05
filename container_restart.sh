#!/bin/bash
WDIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")

OUTPUT=$WDIR/output.csv

declare -A output

DESCRIBE_POD () {
    pod_desc=$(kubectl describe pod $bfs_pod | awk '/4000\/TCP, 5000\/TCP/{ f = 1; next } /:4000\/bfs\/api\/v1\/liveness/{ f = 0 } f')
    # Trim Data
    data=$(echo -e "$pod_desc" | grep 'Reason\|Exit Code\|Finished\|Restart Count')
    echo "$data"
}

PROCESS_DATA () {
    counter=1
    while [ $counter -le 4 ]
    do
    key_value=$(echo -e "$data" | awk -v cnt=$counter 'NR==cnt {print$0}')
    output[$(echo -e "$key_value" | cut -d ':' -f1 | xargs)]=$(echo -e "$key_value" | cut -d ':' -f2- | xargs)
    ((counter=counter+1))
    done
}

STORE_DATA () {
    # Data to be stored: Reason, Exit Code, Finished, Restart Count
    # Sequence of Data Storage: Finished, Exit Code, Reason, Restart Count
    finished=$(TZ=UTC date -d "${output['Finished']}" +'%Y-%m-%d %H:%M:%S')
    current=$(date -d "$finished" +%s)
    
    if [ $current -ne $last_value ]
    then
        output['Finished']=$finished
        echo -e "${output['Finished']}, ${output['Exit Code']}, ${output['Reason']}, ${output['Restart Count']}" >> $OUTPUT 2>&1
        echo -e "last_value=$current" > $WDIR/last_restart
    fi
}


# Get the running Bfs pod

if [ ! -f $WDIR/output.csv ]
then
    echo -e "Date, Exit Code, Reason, Restart Count" > $OUTPUT 2>&1
fi

if [ ! -f $WDIR/last_restart ]
then
    echo -e "last_value=0" > $WDIR/last_restart 2>&1
fi
source $WDIR/last_restart

bfs_pod=$(kubectl get pod --field-selector=status.phase=Running --output=custom-columns=NAME:.metadata.name | grep bfs)

# If required pod exists
if [[ $bfs_pod =~ bfs-* ]]
then
    echo "$bfs_pod"
    DESCRIBE_POD
    
    indexes=$(echo -e "$data" | wc -l)
    if [ $indexes -gt 1 ]
    then
        PROCESS_DATA
        STORE_DATA
        exit 0
    fi
fi