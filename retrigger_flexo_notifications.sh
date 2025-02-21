#!/bin/bash

# Resend all unsuccessful notifications of a selected date
getPayloadByDate() {
    read -r -p "Enter the date (YYYY-MM-DD): " day
    echo "Entered date: $day"

    if [[ -z "$day" ]]; then
        echo "Error: No date entered. Exiting."
        return 1
    fi

    # Removing headers and whitespaces from var day
    op=$(sudo -u postgres psql soap_server --tuples-only --no-align -c "
        SELECT jsonb_agg(barcodes) AS "payload" FROM flexo_notification, LATERAL jsonb_array_elements(payload::jsonb) AS barcodes where status != 'SUCCESS' and created_date::DATE = '$day';
    ")

    if [[ -z "$op" ]]; then
        echo "No failed notifications found for the given date."
        return 1
    fi

    echo "Payload: $op"

    #curl --location --request PUT 'http://172.22.134.13/sorter/api/v1/installations/1/shipment/reference/' \
        #--header 'Content-Type: application/json' \
       # --data "$op"
    
    curl --location --request PUT 'https://aa3c58be-b0a1-4d98-8f9d-661e7b519875.mock.pstmn.io/shipment_reference' \
        --header 'Content-Type: application/json' \
       --data "$op"
}

# User has the list of AWBs need to be resend
getPayloadByList() {
    strings=()

    echo "Enter AWBs (Press Ctrl+D to finish):"
    
    while IFS= read -r line; do
        strings+=("$line")  
    done

    # Joining array into a properly formatted SQL IN clause
    awb_string=""
    for i in "${strings[@]}"; do
        awb_string+=" '$i',"
    done
    awb_string="${awb_string%,}"  # Remove the trailing comma

     if [[ -z "$awb_string" ]]; then
        echo "No AWBs entered. Exiting."
        return 1
    fi

    op=$(sudo -u postgres psql soap_server -t -c "
        SELECT jsonb_agg(barcodes) AS payload FROM flexo_notification, LATERAL jsonb_array_elements(payload::jsonb) AS barcodes WHERE barcodes->>'awb' IN ($awb_string);
    ")

    # Trim leading/trailing whitespace
    op=$(echo "$op" | xargs)

    if [[ -z "$op" || "$op" == "null" ]]; then
        echo "No matching records found. Exiting."
        return 1
    fi

    echo "Payload: $op"

    # curl --location --request PUT 'http://172.22.134.13/sorter/api/v1/installations/1/shipment/reference/' \
    #     --header 'Content-Type: application/json' \
    #     --data "$op"
}

if [[ $# -ne 1 ]]; then
    echo "ERROR: Please provide an execution method. Usage: $0 [-d | -l]"
    exit 1
fi

case $1 in
    -d) getPayloadByDate;;
    -l) getPayloadByList;;
    *) echo "Invalid argument: $1. Usage: $0 [-d | -l]"; exit 1;;
esac

exit 0