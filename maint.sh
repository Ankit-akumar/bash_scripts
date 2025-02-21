#!/bin/bash

LOG_FILE="/var/log/maint/maint.log"

log() {
    local message="$1"
    local output="$2"
    local exit_code="$3"

    if [[ -n "$output" ]]; then
        if [[ $exit_code -eq 0 ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $message: $output" >> "$LOG_FILE"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $message: $output" >> "$LOG_FILE"
        fi
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] $message" >> "$LOG_FILE"
    fi
}

get_server_creds() {
    read -p "Enter username: " username
    read -sp "Enter password: " password
    echo
}

get_server_knode1_ip() {
    server_knode1=$(grep -i 'knode1' /etc/hosts | awk '{print $1}' | head -n 1)
    echo -e "Knode1 Server IP - $server_knode1"
    if [ $? -ne 0 ]; then
        log "Knode1 Server IP -" "$server_knode1" 1
    else
        log "Knode1 Server IP -" "$server_knode1" 0
    fi
}

get_server_knode2_ip() {
    server_knode2=$(grep -i 'knode2' /etc/hosts | awk '{print $1}' | head -n 1)
    echo -e "Knode2 Server IP - $server_knode2"
    if [ $? -ne 0 ]; then
        log "Knode2 Server IP -" "$server_knode2" 1 
    else
        log "Knode2 Server IP -" "$server_knode2" 0
    fi
}

check_application_pods() {
    op=$(kubectl get pods  | grep -vi -E "Running|Completed")
    echo -e "Application Pods not in running or completed status - \n$op"
    if [ $? -ne 0 ]; then
        log "Application Pods not in running or completed status - \n" "$op" 1
    else
        log "Application Pods not in running or completed status - \n" "$op" 0
    fi
}

check_system_pods() {
    op=$(kubectl get pods -n kube-system | grep -vi -E "Running|Completed")
    echo -e "System Pods not in running or completed status - $op"
    if [ $? -ne 0 ]; then
        log "System Pods not in running or completed status - \n" "$op" 1
    else
        log "System Pods not in running or completed status - \n" "$op" 0
    fi
}

check_k8s_cert_expiry() {
    op1=$(kubeadm certs check-expiration)
    op2=$(sudo openssl x509 -noout -text -in /etc/kubernetes/pki/apiserver.crt | grep 'Not After')
    echo "$op1"
    echo "$op2"
    if [ $? -ne 0 ]; then
        log "Kubernetes certificates expiry dates - \n" "$op1" 1
        log "Kubernetes certificates expiry dates - \n" "$op2" 1
    else
        log "Kubernetes certificates expiry dates - \n" "$op1" 0
        log "Kubernetes certificates expiry dates - \n" "$op2" 0
    fi
}

check_rabbitmq_queues() {
    rabbitmq_pod=$(kubectl get pods | grep 'rabbitmq' | awk '{print $1}')

    if [ $? -ne 0 ]; then
        echo -e "$rabbitmq_pod"
        log "Rabbitmq pod -" "$rabbitmq_pod" 1
    else
        if [ -z "$rabbitmq_pod" ]; then
            echo "No rabbitmq pod was found" >> /dev/stderr
            log "No rabbitmq pod was found" "$rabbitmq_pod" 0
            return
        else 
            echo -e "$rabbitmq_pod"
            log "Rabbitmq pod - " "$rabbitmq_pod" 0
        fi
    fi

    op=$(kubectl exec -it "$rabbitmq_pod" -- rabbitmqctl list_queues)
    echo -e "Here are the rabbitmq queues -\n $op"
    if [ $? -ne 0 ]; then
        log "Here are the rabbitmq queues - \n" "$op" 1
    else
        log "Here are the rabbitmq queues - \n" "$op" 0
    fi
}

load_avg_knode1() {
    command="echo '$password' | sudo -S uptime | awk -F 'load average: ' '{print \$2}'"
    load=$(sshpass -p "$password" ssh -o StrictHostKeyChecking=no "$username"@"$server_knode1" "$command" 2>&1)
    echo -e "Average Load on knode1 server -> $load"
    if [ $? -ne 0 ]; then
        log "Average Load on knode1 server - \n" "$load" 1
    else
        log "Average Load on knode1 server - \n" "$load" 0
    fi
}

load_avg_knode2() {
    command="echo '$password' | sudo -S uptime | awk -F 'load average: ' '{print \$2}'"
    load=$(sshpass -p "$password" ssh -o StrictHostKeyChecking=no "$username"@"$server_knode2" "$command" 2>&1)
    echo -e "Average Load on knode2 server -> $load"
    if [ $? -ne 0 ]; then
        log "Average Load on knode2 server - \n" "$load" 1
    else
        log "Average Load on knode2 server - \n" "$load" 0
    fi
}

check_load_avg() {
    load_average=$(uptime | awk -F 'load average: ' '{print $2}')
    echo -e "Average Load on Kmaster server -> $load_average"
    if [ $? -ne 0 ]; then
        log "Average Load on Kmaster server - \n" "$load_average" 1
    else
        log "Average Load on Kmaster server - \n" "$load_average" 0
    fi

    load_avg_knode1
    load_avg_knode2
}

check_postgres_promoted() {
    op=$(kubectl get pods | grep 'postgres-promoted')

    if [ $? -ne 0 ]; then
        echo -e "No pods found for 'postgres-promoted'"
        log "Postgres promoted status - No pods found" "" 1
    else
        if [ -z "$op" ]; then
            echo -e "Postgres not promoted"
            log "Postgres not promoted - " "" 0
        else 
            echo -e "Postgres is promoted:\n$op"
            log "Postgres is promoted - " "$op" 0
        fi
    fi
}


check_postgres_replication() {
    postgres_pods=$(kubectl get pods | awk '/postgres/ && !/manager/ && !/postgres12/ {print $1}')

    if [ $? -ne 0 ]; then
        log "Postgres pods - /n" "$postgres_pods" 1
    else
        log "Postgres pods - /n" "$postgres_pods" 0
    fi

    postgres_pod=$(echo "$postgres_pods" | grep -v 'slave')
    postgres_slave_pod=$(echo "$postgres_pods" | grep 'slave')

    log "Postgres pod - " "$postgres_pod" 0
    log "Postgres slave pod - " "$postgres_slave_pod" 0

    replication_state_postgres=$(kubectl exec -it $postgres_pod bash -- su - postgres -c 'psql -c "SELECT state FROM pg_stat_replication;"')

    if [ $? -ne 0 ]; then
        echo -e "$replication_state_postgres" >> /dev/stderr
        log "Postgres pod replication state - " "$replication_state_postgres" 1
        return
    else 
        if ! grep -q "streaming" <<< "$replication_state_postgres"; then
            echo -e "Postgres Replication is not streaming in master"
            log "Postgres Replication is not streaming in master" "$replication_state_postgres" 0
        else 
            echo -e "Postgres Replication is streaming in master"
            log "Postgres Replication is streaming in master" "$replication_state_postgres" 0
        fi
    fi

    replication_state_postgres_slave=$(kubectl exec -it $postgres_slave_pod bash -- su - postgres -c 'psql -c "SELECT state FROM pg_stat_replication;"')

    if [ $? -ne 0 ]; then
        echo -e "$replication_state_postgres_slave" >> /dev/stderr
        log "Postgres slave pod replication state - " "$replication_state_postgres_slave" 1
        return
    else 
        if ! grep -q "streaming" <<< "$replication_state_postgres_slave"; then
            echo -e "Postgres Replication is not streaming in slave"
            log "Postgres Replication is not streaming in slave" "$replication_state_postgres_slave" 0
        else 
            echo -e "Postgres Replication is streaming in slave"
            log "Postgres Replication is streaming in slave" "$replication_state_postgres_slave" 0
        fi
    fi

    get_base_file_size="ls -ld /opt/data/postgres/base | cut -d' ' -f5"
    command="echo '$password' | sudo -S $get_base_file_size"
    
    base_file_size_knode1=$(sshpass -p "$password" ssh -o StrictHostKeyChecking=no "$username"@"$server_knode1" "$command" 2>&1)
    base_file_size_knode1=$(echo "$base_file_size_knode1" | awk -F': ' '{print $2}')

    if [ $? -ne 0 ]; then
        echo -e "$base_file_size_knode1" >> /dev/stderr
        log "Getting base file size from knode1 - " "$base_file_size_knode1" 1
        return
    fi

    base_file_size_knode2=$(sshpass -p "$password" ssh -o StrictHostKeyChecking=no "$username"@"$server_knode2" "$command" 2>&1)
    base_file_size_knode2=$(echo "$base_file_size_knode2" | awk -F': ' '{print $2}')

    if [ $? -ne 0 ]; then
        echo -e "$base_file_size_knode2" >> /dev/stderr
        log "Getting base file size from knode2 - " "$base_file_size_knode2" 1
        return
    fi

    base_file_size_knode1="$(echo -e "${base_file_size_knode1}" | tr -d '[:space:]')"
    base_file_size_knode2="$(echo -e "${base_file_size_knode2}" | tr -d '[:space:]')"

    if [ "$base_file_size_knode1" = "$base_file_size_knode2" ]; then
        echo -e "Postgres base file sizes on both knodes is same. Base file size on knode1 is $base_file_size_knode1 and on knode2 it is $base_file_size_knode2"
        log "Postgres base file sizes on both knodes is same. Base file size on knode1 is $base_file_size_knode1 and on knode2 it is $base_file_size_knode2" "" 0
    else
        echo -e "Postgres base file sizes on both knodes is different. Base file size on knode1 is $base_file_size_knode1 and on knode2 it is $base_file_size_knode2"
        log "Postgres base file sizes on both knodes is different. Base file size on knode1 is $base_file_size_knode1 and on knode2 it is $base_file_size_knode2" "" 0
    fi
}

check_nfs_status() {
    op=$(df -h | grep 'knode1:/mnt')

    if [ $? -ne 0 ]; then
        echo -e "$op"
        log "NFS service status - " "$op" 1
    else
        if [ -z "$op" ]; then
            echo -e "NFS is not mounted"
            log "NFS is not mounted" "$op" 0
        else 
            echo -e "NFS is mounted"
            log "NFS is mounted" "$op" 0
        fi
    fi

    get_service_status="service nfs-server status | grep 'Active: active'"
    command="echo '$password' | sudo -S $get_service_status"
    service_status=$(sshpass -p "$password" ssh -o StrictHostKeyChecking=no "$username"@"$server_knode1" "$command" 2>&1)
    if [ $? -ne 0 ]; then
        log "NFS service status" "$service_status" 1
    else
        log "NFS service status" "$service_status" 0
    fi
    echo -e "$service_status"
}


log "Starting the script" 

echo -e "Please provide the server credentials"
get_server_creds

echo -e "\nGetting Knode1 IP"
get_server_knode1_ip

echo -e "\nGetting Knode2 IP"
get_server_knode2_ip

echo -e "\nChecking Average Load on all servers"
check_load_avg

echo -e "\nChecking Application Pods"
check_application_pods

echo -e "\nChecking System Pods"
check_system_pods

echo -e "\nChecking Kubernetes certificates expiry dates"
check_k8s_cert_expiry

echo -e "\nChecking RabbitMQ queues (Queue sizes should be less than 5k)"
check_rabbitmq_queues

echo -e "\nChecking if Postgres is promoted"
check_postgres_promoted

echo -e "\nChecking if Postgres replication is working (Postgres replication is working when the status of replication is streaming in master and slave and base file sizes are same on both Knodes)"
check_postgres_replication

echo -e "\nChecking if NFS service is active"
check_nfs_status

log "Script execution ends"

