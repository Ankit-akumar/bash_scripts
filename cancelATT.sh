#!/bin/bash

# Checking if resource type of entered bin barcode is ROLLCAGE_BIN
verifyBinBarcode() {
    op=$(sudo -u postgres psql resources -t -c "
        select resourcetype from gresource where id in (select id from barcode where barcode = '$1');
    ")

    op=$(echo "$op" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    
    if [ "$op" != "ROLLCAGE_BIN" ]; then
        echo -e "ERROR:This barcode is not of type ROLLCAGE_BIN." >&2
        exit 1
    fi
    echo -e "$1 is a Rollcage Bin."
}

# Checking if height profile is pallet and resource type is rollcage
verifyRollBarcode() {
    resourceType=$(sudo -u postgres psql resources -t -c "
        select resourcetype from gresource where id in (select id from barcode where barcode = '$1');
    ")

    heightProfile=$(sudo -u postgres psql resources -t -c "
        select details->>'heightProfile' from gresource where id in (select id from barcode where barcode = '$1');
    ")

    resourceType=$(echo "$resourceType" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    heightProfile=$(echo "$heightProfile" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    if [ "$heightProfile" != "Pallet" ]; then
        echo -e "ERROR:The associated rollcage with id $1 is not of type Pallet." >&2
        exit 1
    else
        if [ "$resourceType" != "ROLLCAGE" ]; then
            echo -e "ERROR:The associated rollcage with id $1 is not of type ROLLCAGE." >&2
            exit 1
        fi
    fi
    echo -e "$1 is a rollcage of type Pallet."
}

# Getting all transfer tasks in processing state for this rollcage bin
getTransferTasks() {
    local opArray=()
    transferTasksArray=()
    readarray -t opArray < <(sudo -u postgres psql platform_srms -t -c "
        SELECT id FROM service_request WHERE external_service_request_id in (SELECT external_service_request_id FROM service_request WHERE attributes ->>'binBarcode' = '$1' AND type = 'TRANSFER' AND status = 'PROCESSING') AND type = 'TRANSFER';
    ")

    for element in "${opArray[@]}"; do
        if [ -n "$element" ]; then
            element=$(echo "$element" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            transferTasksArray+=("$element")
        fi
    done

    if [ "${#transferTasksArray[@]}" -eq 0 ]; then
        echo "ERROR: No transfer tasks in processing state for this rollcage bin." >&2
        exit 1
    fi

    echo -e "Transfer Tasks - "
    printf '%s\n' "${transferTasksArray[@]}"
}

# Getting srids of bin from gresource
getSrids() {
    op=$(sudo -u postgres psql resources -t -c "select srids from gresource where id in (select id from barcode where barcode='$1');")
    echo -e "$op"

    sridsArray=()
    while read -r line; do
        sridsArray+=("$line")
    done <<< "$(echo "$op" | grep -oE '"java\.lang\.Long", [0-9]+' | awk '{print $NF}')"

    printf '%s\n' "${sridsArray[@]}"
}

# Matching srids and transfer task ids
compareTransferAndSrids() {
    if [ "${#transferTasksArray[@]}" -ne "${#sridsArray[@]}" ]; then
        echo "ERROR: Transfer task IDs of rollcage bin in service_request table differ from the Transfer srids in gresource table. This needs to be handled manually." >&2
        exit 1
    fi

    for id in "${transferTasksArray[@]}"; do
        found=false
        for srid in "${sridsArray[@]}"; do
            if [[ $id == "$srid" ]]; then
                found=true
                break
            fi
        done

        if ! $found; then
            echo "ERROR: Transfer ID $id of rollcage bin in service_request table of platform_srms DB is not present in the Transfer srids in gresource table of resources DB. This needs to be handled manually." >&2
            exit 1
        fi
    done

    echo -e "All transfer srids matched for the rollcage bin."
}

# Getting Preput tasks
getPreputTasks() {
    local opArray=()
    preputTasksArray=()
    readarray -t opArray < <(sudo -u postgres psql platform_srms -t -c "
        SELECT id FROM service_request WHERE external_service_request_id in (SELECT external_service_request_id FROM service_request WHERE attributes ->>'binBarcode' = '$1' AND type = 'TRANSFER' AND status = 'PROCESSING') AND type = 'PRE_PUT';
    ")

    for element in "${opArray[@]}"; do
        if [ -n "$element" ]; then
            element=$(echo "$element" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
            preputTasksArray+=("$element")
        fi
    done

    if [ "${#preputTasksArray[@]}" -eq 0 ]; then
        echo "ERROR: NO preput tasks for this Rollcage bin." >&2
        exit 1
    fi

    echo -e "Preput Tasks - " 
    printf '%s\n' "${preputTasksArray[@]}"
}

# Checking if all preput tasks are in processed status
verifyPreputTasks() {
    op=$(sudo -u postgres psql platform_srms -t -c "SELECT count(id) FROM service_request WHERE external_service_request_id in (SELECT external_service_request_id FROM service_request WHERE attributes ->>'binBarcode' = '$1' AND type = 'TRANSFER' and status = 'PROCESSING') AND type = 'PRE_PUT' AND status not like 'PROCESSED';")

    op=$(echo "$op" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    if [ "$op" -ne 0 ]; then
        echo -e "ERROR:Preput tasks are not in PROCESSED status." >&2
        exit 1
    fi

    echo -e "All Preput tasks are in PROCESSED status."
}

# Generate Preput tasks string to put in sql query
generatePreputTasksString() {
    preputIdString=""
    for id in "${preputTasksArray[@]}"; do
        if [[ -n $id ]]; then 
            preputIdString+=" '$id',"    
        fi    
    done
    preputIdString="${preputIdString%,}"
}

# Deleting the Preput tasks
deletePreputTasksExecute() {
    commands=(
        "DELETE FROM service_request_expectations WHERE service_request_id IN ($1);" 
        "DELETE FROM service_request_children WHERE servicerequests_id IN ($1);" 
        "DELETE FROM service_request_actuals WHERE service_request_id IN ($1);" 
        "DELETE FROM service_request WHERE id IN ($1);"
    )

    op=""

    for cmd in "${commands[@]}"; do
        op+="$(sudo -u postgres psql platform_srms -t -c "$cmd")\n"
    done

    echo -e "Preput tasks deleted:\n$op"
}

# Printing delete Preput tasks commands
deletePreputTasksPrint() {
    echo -e "DELETE FROM service_request_expectations WHERE service_request_id IN ($1);"
    echo -e "DELETE FROM service_request_children WHERE servicerequests_id IN ($1);"
    echo -e "DELETE FROM service_request_actuals WHERE service_request_id IN ($1);"
    echo -e "DELETE FROM service_request WHERE id IN ($1);"
}

# Generate Tansfer tasks string to use in sql query (format - 'id',)
generateTransferTasksString() {
    local transferIdString=""
    for id in "${transferTasksArray[@]}"; do
        if [[ -n $id ]]; then 
            transferIdString+=" '$id',"    
        fi    
    done
    transferIdString="${transferIdString%,}"
    echo "$transferIdString"
}

# Printing Delete Transfer tasks queries
deleteTransferTasksPrint() {
    echo -e "delete from execution where unique_identity in ($1);"
    echo -e "update service_request set status ='CREATED',state='created' where id in ($1);"
}

# Deleting Transfer tasks
deleteTransferTasksExecute() {
    op=$(sudo -u postgres psql wms_process -t -c "delete from execution where unique_identity in ($1);")
    echo -e "$op\n"

    op=$(sudo -u postgres psql platform_srms -t -c "update service_request set status ='CREATED',state='created' where id in ($1);")
    echo -e "$op\n"
}

# Generate transfer task string for platform_core (format - id)
generateTransferTasksStringPlatformCore() {
    local transferIdString=""
    for id in "${transferTasksArray[@]}"; do
        if [[ -n $id ]]; then 
            transferIdString+=" $id"    
        fi    
    done
    echo "$transferIdString"
}

# Printing Delete transfer tasks command from platform core
deleteTransferTasksPlatformCorePrint() {
    local transferIdString=$1

    #command="for i in $transferIdString ; do curl -X POST "http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/cancel" -H "accept: */*" -H "Content-Type: application/json" -d "`curl -X GET "http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/$i" -H "accept: */*"`" ; done;"
    #command='for i in $1 ; do curl -X POST "http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/cancel" -H "accept: */*" -H "Content-Type: application/json" -d "$(curl -X GET "http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/$i" -H "accept: */*")" ; done;'
    #command="for i in $transferIdString ; do curl -X POST 'http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/cancel' -H \"accept: */*\" -H \"Content-Type: application/json\" -d \"\$(curl -X GET 'http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/\$i' -H 'accept: */*' -H 'Content-Type: application/json')\" ; done;"
    #command="for i in $transferIdString ; do curl -X POST 'http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/cancel' -H 'accept: */*' -H 'Content-Type: application/json' -d \"\$(curl -X GET 'http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/\$i' -H 'accept: */*')\" ; done;"
    command="for i in $1 ; do curl -X POST 'http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/cancel' -H 'accept: */*' -H 'Content-Type: application/json' -d \"\$(curl -X GET 'http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/\$i' -H 'accept: */*')\" ; done;"
    echo -e "$command"
}

# Deleting Transfer tasks from Platform Core
deleteTransferTasksPlatformCoreExecute() {
    local transferString=$1

    #command="for i in $transferString ; do curl -X POST "http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/cancel" -H "accept: */*" -H "Content-Type: application/json" -d "`curl -X GET "http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/$i" -H "accept: */*"`" ; done;"
    #command='for i in $1 ; do curl -X POST "http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/cancel" -H "accept: */*" -H "Content-Type: application/json" -d "$(curl -X GET "http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/$i" -H "accept: */*")" ; done;'
    #command="for i in $transferString ; do curl -X POST 'http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/cancel' -H \"accept: */*\" -H \"Content-Type: application/json\" -d \"\$(curl -X GET 'http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/\$i' -H 'accept: */*' -H 'Content-Type: application/json')\" ; done;"
    #command="for i in $transferString ; do curl -X POST 'http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/cancel' -H 'accept: */*' -H 'Content-Type: application/json' -d \"\$(curl -X GET 'http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/\$i' -H 'accept: */*')\" ; done;"
    #op=$(for i in $transferString; do curl -X POST "http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/cancel" -H "accept: */*" -H "Content-Type: application/json" -d "$(curl -X GET "http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/$i" -H "accept: */*")"; done)
    command="for i in $1 ; do curl -X POST 'http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/cancel' -H 'accept: */*' -H 'Content-Type: application/json' -d \"\$(curl -X GET 'http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/\$i' -H 'accept: */*')\" ; done;"

    op=$("for i in $transferString ; do curl -X POST "http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/cancel" -H "accept: */*" -H "Content-Type: application/json" -d "`curl -X GET "http://172.22.152.14:8080/api-gateway/sr-service/platform-srms/service-request/$i" -H "accept: */*"`" ; done;")
    echo -e "$op"
}

# Getting rollcage and rollcage bin id from resources database 
getRollcageBinIdFromResources() {
    local id
    id=$(sudo -u postgres psql resources -t -c "select id from gresource where id in (select id from barcode where barcode='$1');")
    id=$(echo "$id" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    echo -e "$id"
}

getRollcageIdFromResources() {
    local id
    id=$(sudo -u postgres psql resources -t -c "select mgresource_id from gresource_children where childresources_id = $1;")
    id=$(echo "$id" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    echo -e "$id"
}

# Printing rollcage and rollcage bin empty commands
setRollcageAndBinEmptyPrint() {
    echo -e "update gresource set state='EMPTY',resource_area = null where id ='$1';"
    echo -e "update gresource set data='{"@type": "java.util.HashMap"}' , srids='["java.util.ArrayList", []]' , state='EMPTY' where id ='$2';"
}

# Setting rollcage and rollcage bin to empty
setRollcageAndBinEmptyExecute() {
    op=$(sudo -u postgres psql resources -t -c "update gresource set state='EMPTY',resource_area = null where id ='$1';")
    echo "$op"

    op=$(sudo -u postgres psql resources -t -c "update gresource set data='{"@type": "java.util.HashMap"}' , srids='["java.util.ArrayList", []]' , state='EMPTY' where id ='$2';")
    echo "$op"
}

# Printing reset container command
resetContainerPrint() {
    #command="curl -X POST --url http://172.22.156.134:5002/lm/utility/reset_container -H 'content-type: application/json' -d '{"barcode":"$1"}'"
    command="curl -X POST --url http://172.22.156.134:5002/lm/utility/reset_container -H 'content-type: application/json' -d '{\"barcode\":\"$1\"}'"
    echo -e "$command"
}

# Resetting container
resetContainerExecute() {
    #command="curl -X POST --url http://172.22.156.134:5002/lm/utility/reset_container -H 'content-type: application/json' -d '{"barcode":"$1"}'"
    command="curl -X POST --url http://172.22.156.134:5002/lm/utility/reset_container -H 'content-type: application/json' -d '{\"barcode\":\"$1\"}'"

    op=$(ssh "$2"@172.22.152.14 "$command")
    echo -e "$op"
}


# Take bin barcode value from user   
read -r -p "Enter the bin barcode: (rollcage_id is even, rollcage_bin_id is odd (rollcage_bin_id = rollcage_id + 1); Example -> 90962-roll; 90963-bin)" binBarcode
echo -e "$binBarcode"

verifyBinBarcode "$binBarcode"

# Supposed rollcage Barcode
rollBarcode=$((binBarcode - 1))
echo -e "Supposed roll barcode - $rollBarcode"

verifyRollBarcode "$rollBarcode"

getTransferTasks "$binBarcode"

getSrids "$binBarcode"

compareTransferAndSrids

getPreputTasks "$binBarcode"

verifyPreputTasks "$binBarcode"

generatePreputTasksString

deletePreputTasksPrint "$preputIdString"

#deletePreputTasksExecute "$preputIdString"

transferIdString=$(generateTransferTasksString)
echo "$transferIdString"

deleteTransferTasksPrint "$transferIdString"

#deleteTransferTasksExecute "$transferIdString"

transferIdStringPlatformCore=$(generateTransferTasksStringPlatformCore)
echo "$transferIdStringPlatformCore"

deleteTransferTasksPlatformCorePrint "$transferIdStringPlatformCore"

#deleteTransferTasksPlatformCoreExecute "$transferIdStringPlatformCore"

rollcageBinResourceId=$(getRollcageBinIdFromResources "$binBarcode")

rollcageResourceId=$(getRollcageIdFromResources "$rollcageBinResourceId")

setRollcageAndBinEmptyPrint "$rollcageResourceId" "$rollcageBinResourceId"

#setRollcageAndBinEmptyExecute "$rollcageResourceId" "$rollcageBinResourceId"

echo -e "Tasks cleared. Now resetting the container..."
read -r -p "Enter the username to SSH on Application server: " username

resetContainerPrint "$rollBarcode"

#resetContainerExecute "$rollBarcode" "$username"

sudo -u postgres psql -c "\q"

