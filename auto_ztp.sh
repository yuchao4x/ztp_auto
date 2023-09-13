#!/bin/bash

function print_green(){
    GREEN=$(printf '\033[36m')
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


function install_helm(){
    if ! [ -x "$(command -v helm)" ]; then
        echo 'Info: Install helm version 3.10.1'
        curl -k   https://get.helm.sh/helm-v3.10.1-linux-amd64.tar.gz -o helm-v3.10.1-linux-amd64.tar.gz  || exit
        tar zvxf helm-v3.10.1-linux-amd64.tar.gz
        cp linux-amd64/helm  /usr/local/sbin/helm
        chmod +x /usr/local/sbin/helm
    fi
}

print_green "================AUTO_HUB_CLUSTER START TO RUN=================="
###variable define
value_file="values.yaml"
export Work_Root_Dir=/opt/ocp
export http_proxy=$(grep -oP '(?<=http_proxy: ).*' $value_file)
export https_proxy=$(grep -oP '(?<=https_proxy: ).*' $value_file)

export nic2_name=$(grep -oP '(?<=nic2_name: ).*' $value_file)
export nic2_ip=$(grep -oP '(?<=nic2_ip: ).*' $value_file)
export base_domain=$(grep -oP '(?<=base_domain: ).*' $value_file)
export hub_nic1_ip=$(grep -oP '(?<=hub_nic1_ip: ).*' $value_file)
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
print_green "install helm..."
install_helm
[[ -x "$(command -v helm)" ]] && print_green "install helm ok..."

print_green "install ansible...need to enter your root redhat username and password:"
subscription-manager register
subscription-manager attach
subscription-manager repos --disable="*"
dnf config-manager --disable \*
subscription-manager repos --enable="rhel-8-for-x86_64-appstream-rpms"
subscription-manager repos --enable="rhel-8-for-x86_64-baseos-rpms"
subscription-manager repos --enable=rhocp-4.12-for-rhel-8-x86_64-rpms
subscription-manager repos --enable=ansible-2.9-for-rhel-8-x86_64-rpms
dnf -y install python3 git ansible python3-netaddr skopeo podman openshift-clients ipmitool python3-pyghmi python3-jmespath jq
print_green "install dependency ok..."
[[ -x "$(command -v ansible)" ]] && print_green "install dependency ok..." || { print_red "ERROR: install dependency failed!!!"; exit 1; }

#delete route on the nic2 interface
print_green "setting network..."
nmcli c show $nic2_name > /dev/null || { print_red "ERROR: interface $nic2_name is not exsit !!!"; exit 1; }
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
grep -oP '(?<=pull-secret: ).*' $value_file > pull-secret.txt

#render file
print_green "Now start to generate yaml files"
helm template ./ --show-only templates/inventory.vault.yml > inventory.vault.yml
helm template ./ --show-only templates/inventory.yml > inventory.yml

print_green "Now start to run ansible-palybook"
ansible-playbook -i inventory.yml prereq_facts_check.yml -e "@inventory.vault.yml" -e skip_interactive_prompts=true
ansible-playbook -i inventory.yml playbooks/validate_inventory.yml -e "@inventory.vault.yml" -e skip_interactive_prompts=true
if [ $? -eq 0 ]; then
  ansible-playbook -i inventory.yml site.yml -e "@inventory.vault.yml" -e skip_interactive_prompts=true
else
  exit 1
  print_red "ERROR: pre-install-check failed !!!"
fi
