#!/bin/bash

# Demande du nom de la machine à l'utilisateur
read -p "Veuillez entrer le nom de la machine (ou appuyez sur Entrée pour passer) : " hostname

echo "###############################"
echo "Commençons par la configuration réseau"

# Récupérer les paramètres réseau actuels
CURRENT_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
CURRENT_MASK=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | cut -d/ -f2 | head -n 1)
CURRENT_GATEWAY=$(ip route | grep default | awk '{print $3}')
CURRENT_DNS=$(nmcli dev show | grep 'IP4.DNS' | awk '{print $2}' | head -n 1)

# Fonction pour demander confirmation ou changement de chaque paramètre
function ask_user {
    local prompt="$1"
    local default_value="$2"
    local user_input

    read -p "$prompt (actuel: $default_value) [Appuyez sur Entrée pour conserver, ou entrez un nouveau] : " user_input

    if [ -z "$user_input" ]; then
        echo "$default_value"
    else
        echo "$user_input"
    fi
}

# Demander à l'utilisateur de vérifier ou de changer les paramètres
IP=$(ask_user "Voulez-vous changer l'adresse IP ?" $CURRENT_IP)
MASK=$(ask_user "Voulez-vous changer le masque de sous-réseau ?" $CURRENT_MASK)
GATEWAY=$(ask_user "Voulez-vous changer la passerelle par défaut ?" $CURRENT_GATEWAY)
DNS=$(ask_user "Voulez-vous changer l'adresse DNS ?" $CURRENT_DNS)

# Afficher les paramètres choisis
echo -e "\nLes paramètres réseau configurés sont :"
echo "IP : $IP"
echo "Masque : $MASK"
echo "Passerelle : $GATEWAY"
echo "DNS : $DNS"

# Configurer les paramètres réseau
echo "Configuration des paramètres réseau..."
sudo nmcli con mod "Wired connection 1" ipv4.addresses "$IP/$MASK"
sudo nmcli con mod "Wired connection 1" ipv4.gateway "$GATEWAY"
sudo nmcli con mod "Wired connection 1" ipv4.dns "$DNS"
sudo nmcli con mod "Wired connection 1" ipv4.method manual

# Appliquer les changements
sudo nmcli con up "Wired connection 1"

echo "Configuration réseau mise à jour avec succès."

# Mise à jour du nom de la machine et du fichier /etc/hosts
if [ -z "$hostname" ]; then
    echo "Aucun nom de machine fourni. La configuration de l'hôte est passée."
else
    # Changer le nom de la machine
    sudo hostnamectl set-hostname "$hostname"
    echo "Le nom de la machine a été changé en : $hostname"

    # Mettre à jour le fichier /etc/hosts
    if grep -q "127.0.1.1" /etc/hosts; then
        sudo sed -i "s/^127.0.1.1.*/127.0.1.1 $hostname/g" /etc/hosts
    else
        echo "127.0.1.1 $hostname" | sudo tee -a /etc/hosts > /dev/null
    fi

    # Ajouter l'entrée pour la nouvelle adresse IP
    if grep -q "$IP" /etc/hosts; then
        sudo sed -i "s/^$IP.*/$IP $hostname/g" /etc/hosts
    else
        echo "$IP $hostname" | sudo tee -a /etc/hosts > /dev/null
    fi
    
    echo "Le fichier /etc/hosts a été mis à jour."
fi
echo "###############################"
echo "Mise à jour"
sudo yum update -y 

echo "###############################"
echo "Installation des prerequis Docker"
sudo yum install yum-utils device-mapper-persistent-data lvm2 -y 

echo "###############################"
echo "Configuration du repository Docker"
sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 

echo "###############################"
echo "Test si OS==Rocky"
if [ -f /etc/os-release ] && grep -q 'Rocky Linux' /etc/os-release; then
    sudo dnf remove -y podman containers-common.x86_64
else
    echo "Ce système d'exploitation n'est pas Rocky Linux."
fi

echo "###############################"
echo "Désactivation de la SWAPP"
sudo swappoff --all
sudo cp /etc/fstab /etc/fstab.bak
echo "Modification du fichier /etc/fstab pour désactiver la swap de manière permanente..."
sudo sed -i.bak '/\sswap\s/d' /etc/fstab
grep swap /etc/fstab

if [ $? -ne 0 ]; then
    echo "La swap a été désactivée de manière permanente."
else
    echo "Erreur : La swap n'a pas été correctement désactivée."
fi

echo "###############################"
echo "Installation Docker runtime"
sudo yum install docker-ce -y

echo "###############################"
echo "Personalisation cgroupdriver=systemd + config service"
sudo mkdir /etc/docker
# Set up the Docker daemon
sudo cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
  
}
EOF
sudo systemctl start docker
sudo systemctl enable docker

echo "###############################"
echo "Config SElinux"
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

echo "###############################"
echo "Installation Repo + yum install K8s"
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

sudo yum install -y kubelet kubeadm kubectl --disableexcludes=kubernetes

# Demande à l'utilisateur s'il souhaite redémarrer
read -p "Voulez-vous redémarrer la VM maintenant ? (o/n) : " choix

case "$choix" in
    o|O|oui|OUI )
        echo "Redémarrage de la VM..."
        sudo reboot
        ;;
    n|N|non|NON )
        echo "Vous avez choisi de ne pas redémarrer la VM. Les changements prendront effet au prochain redémarrage."
        ;;
    * )
        echo "Réponse invalide. Aucune action n'a été effectuée."
        ;;
esac
