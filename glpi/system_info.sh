#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


# Source les fonctions utilitaires
# Assurez-vous que le chemin est correct, relative au script appelant
script_dir=$(dirname "$(realpath "$0")")
source "$script_dir/utils.sh"

set -euo pipefail

exec > >(tee -a "$LOG_FILE") 2>&1

#=============================================================================
# Fonction : Vérification des prérequis système (OS, RAM, Architecture)
# S'assure que le système répond aux exigences minimales pour GLPI.
#=============================================================================
check_system_requirements() {
    print_step "Vérification des prérequis système"
    
    # Vérification du système d'exploitation (Ubuntu ou Debian uniquement)
    if ! grep -E "Ubuntu|Debian" /etc/os-release &>/dev/null; then
        show_error_and_return_to_menu "Ce script est conçu pour Ubuntu et Debian uniquement."
        return 1
    fi
    
    local os_version
    os_version=$(lsb_release -rs 2>/dev/null || echo "unknown") # Obtenir la version de l'OS
    local os_id
    os_id=$(lsb_release -is 2>/dev/null) # Obtenir l'ID de l'OS (Ubuntu, Debian)

    case "$os_id" in
        "Ubuntu")
            # Utiliser printf pour la comparaison bc afin d'éviter les problèmes de séparateurs décimaux liés à la locale
            if (( $(echo "$os_version < 20.04" | bc -l) )); then # Vérifier version minimum Ubuntu
                show_error_and_return_to_menu "Ubuntu 20.04 ou supérieur requis. Version détectée: $os_version"
                return 1
            fi
            ;;
        "Debian")
            if (( $(echo "$os_version < 11" | bc -l) )); then # Vérifier version minimum Debian
                show_error_and_return_to_menu "Debian 11 ou supérieur requis. Version détectée: $os_version"
                return 1
            fi
            ;;
        *)
            show_error_and_return_to_menu "Système d'exploitation non supporté ou non détecté: $os_id"
            return 1
            ;;
    esac
    
    # Vérification de la mémoire RAM (minimum 1GB recommandé)
    local ram_mb
    ram_mb=$(free -m | awk 'NR==2{print $2}') # Obtenir la RAM totale en Mo
    if [[ $ram_mb -lt 1024 ]]; then
        if ! whiptail --title "Avertissement RAM" --yesno "Votre système dispose de moins de 1GB de RAM ($ram_mb MB).\n\nGLPI peut fonctionner lentement. Voulez-vous continuer ?" 12 60; then
            return 1 # L'utilisateur a choisi de ne pas continuer
        fi
    fi
    
    # Vérification de l'architecture du système
    local arch
    arch=$(uname -m) # Obtenir l'architecture du processeur
    if [[ "$arch" != "x86_64" ]] && [[ "$arch" != "aarch64" ]]; then
        show_error_and_return_to_menu "Architecture non supportée: $arch"
        return 1
    fi
    
    print_success "Prérequis système vérifiés."
    return 0
}

#=============================================================================
# Fonction : Vérification de l'espace disque disponible
# S'assure qu'il y a suffisamment d'espace pour l'installation de GLPI.
#=============================================================================
check_disk_space() {
    print_step "Vérification de l'espace disque"
    local available_space_kb
    available_space_kb=$(df -k / | tail -1 | awk '{print $4}') # Espace disponible en KB sur la partition racine

    # Vérifier au moins 5GB (5 * 1024 * 1024 KB) comme minimum raisonnable pour GLPI + OS
    if [[ $available_space_kb -lt 5242880 ]]; then # 5GB en KB
        show_error_and_return_to_menu "Espace disque insuffisant (< 5 Go). Espace disponible: $((available_space_kb / 1024 / 1024)) Go."
        return 1
    fi

    print_success "Espace disque suffisant."
    return 0
}

#=============================================================================
# Fonction : Vérification des ports requis (port 80 pour HTTP)
# S'assure que le port 80 n'est pas déjà utilisé par un autre service.
#=============================================================================
check_ports() {
    print_step "Vérification des ports requis (80)"
    if sudo lsof -i :80 | grep LISTEN &>/dev/null; then # Vérifier si le port 80 est en écoute
        if whiptail --title "Port 80 occupé" --yesno "Le port 80 est déjà utilisé. Cela peut indiquer qu'un autre serveur web est en cours d'exécution.\nVoulez-vous essayer d'arrêter Apache automatiquement si c'est lui ?" 12 60; then
            # Désactiver temporairement '-e' car cette commande peut échouer si apache2 n'est pas en cours d'exécution ou n'est pas le service occupant.
            set +e
            sudo systemctl stop apache2 2>/dev/null || true # Tenter d'arrêter Apache
            set -e
            if sudo lsof -i :80 | grep LISTEN &>/dev/null; then # Vérifier à nouveau après tentative d'arrêt
                show_error_and_return_to_menu "Le port 80 est toujours utilisé après tentative d'arrêt d'Apache. Libérez-le avant de continuer."
                return 1
            else
                print_success "Apache arrêté, le port 80 est maintenant disponible."
            fi
        else
            show_error_and_return_to_menu "Le port 80 est déjà utilisé. Libérez-le avant de continuer."
            return 1
        fi
    fi
    print_success "Le port 80 est disponible."
    return 0
}

display_system_info() {
    print_step "Collecte des informations système..."

    local os_info=""
    if grep -E "Ubuntu|Debian" /etc/os-release &>/dev/null; then
        os_info=$(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')
    else
        os_info="OS non supporté ou non détecté"
    fi

    local kernel_info=$(uname -r)
    local arch_info=$(uname -m)
    local ram_total=$(free -h | awk 'NR==2{print $2}')
    local ram_used=$(free -h | awk 'NR==2{print $3}')
    local cpu_info=$(lscpu | grep "Model name" | cut -d: -f2 | sed 's/^[ \t]*//')
    local disk_total=$(df -h / | tail -1 | awk '{print $2}')
    local disk_used=$(df -h / | tail -1 | awk '{print $3}')
    local disk_avail=$(df -h / | tail -1 | awk '{print $4}')
    local network_ip=$(hostname -I | awk '{print $1}')
    local apache_status="Non installé ou arrêté"
    local mariadb_status="Non installé ou arrêté"
    local php_version="Non installé"

    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet apache2; then apache_status="En cours d'exécution"; fi
        if systemctl is-active --quiet mariadb; then mariadb_status="En cours d'exécution"; fi
    fi

    if command -v php &>/dev/null; then
        php_version=$(php -v | head -n 1 | cut -d " " -f 2)
    fi

    local info_message="Informations Système :\n\n"
    info_message+="OS: ${os_info}\n"
    info_message+="Noyau: ${kernel_info}\n"
    info_message+="Architecture: ${arch_info}\n"
    info_message+="CPU: ${cpu_info}\n"
    info_message+="RAM Totale: ${ram_total}\n"
    info_message+="RAM Utilisée: ${ram_used}\n"
    info_message+="Espace Disque /: Total ${disk_total}, Utilisé ${disk_used}, Disponible ${disk_avail}\n"
    info_message+="Adresse IP Principale: ${network_ip}\n"
    info_message+="Statut Apache: ${apache_status}\n"
    info_message+="Statut MariaDB: ${mariadb_status}\n"
    info_message+="Version PHP: ${php_version}\n"

    whiptail --title "Informations Système" --msgbox "$info_message" 25 80
    print_success "Informations système affichées."
    return 0
}


# =============================================================================
# Logique Principale pour les Informations Système
# =============================================================================
main() {
    display_header
    print_step "Collecte des informations système..."

    # Pré-vérifications critiques (minimes pour cette option)
    check_whiptail || exit 1
    check_bc || true
    check_curl || true
    check_and_prepare_sudo_access || exit 1
    check_hostname_resolution || true

    display_system_info || show_error_and_return_to_menu "Échec de la collecte des informations système."
}

main "$@"