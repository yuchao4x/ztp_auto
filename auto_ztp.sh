#!/bin/bash

function print_green(){
    GREEN=$(printf '\033[32m')
    RESET=$(printf '\033[m')
    printf "%s%s%s\n" "$GREEN" "$*" "$RESET"
}

function print_red(){
    RED=$(printf '\033[31m')
    RESET=$(printf '\033[m')
    printf "%s%s%s\n" "$RED" "$*" "$RESET"
}

if [ "$EUID" -ne 0 ]; then
    print_red "error: need root user to run!!!"
    exit 1
fi

function install_yq(){
    if ! [ -x "$(command -v yq)" ]; then
        echo 'Info: Install yq version 4.13.4'
        wget https://github.com/mikefarah/yq/releases/download/v4.13.4/yq_linux_amd64.tar.gz
        tar -xvf yq_linux_amd64.tar.gz
        mv yq_linux_amd64 /usr/local/bin/yq
    fi
}

function install_helm(){
    if ! [ -x "$(command -v helm)" ]; then
        echo 'Info: Install helm version 3.10.1'
        curl -k   https://get.helm.sh/helm-v3.10.1-linux-amd64.tar.gz -o /home/ocp/helm-v3.10.1-linux-amd64.tar.gz  || exit
        tar zvxf /home/ocp/helm-v3.10.1-linux-amd64.tar.gz -C /home/ocp/
        cp /home/ocp/linux-amd64/helm  /usr/local/sbin/helm
        chmod +x /usr/local/sbin/helm
    fi
}

print_green "================AUTO_HUB_CLUSTER START TO RUN=================="
###variable define
value_file="values.yaml"
export Work_Root_Dir=/opt/ocp
export nic2_name=$(yq e '.nic2_name' "$value_file")
export nic2_ip=$(yq e '.nic2_ip' "$value_file")
export http_proxy=$(yq e '.http_proxy' "$value_file")
export https_proxy=$(yq e '.https_proxy' "$value_file")
export base_domain=$(yq e '.base_domain' "$value_file")
export hub_nic1_ip=$(yq e '.hub_nic1_ip' "$value_file")
export no_proxy=".${base_domain},${hub_nic1_ip}"

#setting proxy
print_green "setting /etc/environment"
> /etc/environment
cat > /etc/environment << EOF
export http_proxy=${http_proxy}
export https_proxy=${https_proxy}
export no_proxy=${no_proxy}
EOF
source /etc/environment
print_green "setting /etc/environment ok...below is the content of /etc/environment: " 
cat /etc/environment
sleep 10

#install basic packages
print_green "install yq..."
install_yq
[[ -x "$(command -v yq)" ]] && print_green "install yq ok..."

print_green "install helm..."
install_helm
[[ -x "$(command -v helm)" ]] && print_green "install helm ok..."

print_green "setting network..."
nmcli connection modify $nic2_name ipv4.never-default yes
ip route del default via $nic2_ip
systemctl enable --now firewalld
print_green "setting network ok..."

#non-password login setting
print_green "enter your root login password..."
[ -f ~/.ssh/id_rsa.pub ] || ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa -q
ssh-copy-id -o StrictHostKeyChecking=no 127.0.0.1

#create Work_Root_Dir
[ ! -d ${Work_Root_Dir} ] && mkdir -p ${Work_Root_Dir}

#git clone code and download requirements
print_green "Now start to git clone code and download requirements"
print_green "Pls entering your github email and token..."
cd ${Work_Root_Dir}
git clone https://github.com/intel-restricted/networking.wireless.flexcore-2-0.deployment.git

cd ${Work_Root_Dir}/networking.wireless.flexcore-2-0.deployment/xaas/ocp/automation/crucible
ansible-galaxy collection install -r requirements.yml
scp -r root@10.67.127.210:/root/yuchao/auto_ztp/* /opt/ocp/networking.wireless.flexcore-2-0.deployment/xaas/ocp/automation/crucible
yq e '.pull-secret' $value_file > pull-secret.txt

#render file
print_green "Now start to generate yaml files"
helm template ./ --show-only templates/inventory.vault.yml > inventory.vault.yml
helm template ./ --show-only templates/inventory.yml > inventory.yml

print_green "Now start to run ansible-palybook"
ansible-playbook -i inventory.yml prereq_facts_check.yml -e "@inventory.vault.yml" -e skip_interactive_prompts=true
ansible-playbook -i inventory.yml playbooks/validate_inventory.yml -e "@inventory.vault.yml" -e skip_interactive_prompts=true
#ansible-playbook -i inventory.yml site.yml -e "@inventory.vault.yml" -e skip_interactive_prompts=true
