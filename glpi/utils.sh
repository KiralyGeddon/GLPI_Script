# glpi/utils.sh

#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Couleurs pour l'affichage dans le terminal
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly RED='\033[0;31m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

# Variables globales du script (valeurs par défaut, peuvent être modifiées par les scripts)
WEB_ROOT="/var/www/html/glpi"
LOG_FILE="/tmp/install_glpi.log" # Fichier de log par défaut, chaque script peut le surcharger
GLPI_VERSION=""
GLPI_URL=""
fqdn=""
db_name=""
db_user=""
db_pass=""

# Fonctions d'affichage
display_header() {
    local header_lines=(
        ""
        ""
        "    .............................."
        "    .░██████╗░██╗░░░░░██████╗░██╗."
        "    .██╔════╝░██║░░░░░██╔══██╗██║."
        "    .██║░░██╗░██║░░░░░██████╔╝██║."
        "    .██║░░╚██╗██║░░░░░██╔═══╝░██║."
        "    .╚██████╔╝███████╗██║░░░░░██║."
        "    .░╚═════╝░╚══════╝╚═╝░░░░░╚═╝."
        "    ''''''''''''''''''''''''''''''"
        ""
        ""
        "========================================="
        "     Script: GLPI installation v12.3" # Entête générique
        "========================================="
        ""
        ""
        ""
        ""
        ""
        ""
        ""
    )
    clear
    local term_width=$(tput cols)
    for line in "${header_lines[@]}"; do
        if [[ -n "$line" ]]; then
            # Supprime les codes d'échappement ANSI pour calculer la longueur de la ligne
            local line_length=$(echo "$line" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g" | wc -c)
            line_length=$((line_length - 1)) # wc -c compte le caractère de nouvelle ligne
            local padding=$(( (term_width - line_length) / 2 ))
            if [[ $padding -lt 0 ]]; then padding=0; fi # Ne pas avoir de padding négatif
            printf "%${padding}s" ""
        fi
        if [[ "$line" == *"GLPI"* ]]; then
            echo -e "${CYAN}${BOLD}$line${RESET}"
        elif [[ "$line" == *"===="* ]]; then
            echo -e "${YELLOW}$line${RESET}"
        else
            echo -e "${GREEN}$line${RESET}"
        fi
        # sleep 0.05 # Envisager de supprimer ou de réduire cela pour une exécution plus rapide
    done
    # sleep 0.5 # Envisager de supprimer ou de réduire cela pour une exécution plus rapide
}

print_step() { echo -e "${CYAN}${BOLD}➤ $1${RESET}"; }
print_success() { echo -e "${GREEN}✓ $1${RESET}"; }
print_error() { echo -e "${RED}✗ Erreur: $1${RESET}" >&2; }

show_error_and_return_to_menu() {
    local error_message="$1"
    print_error "$error_message"
    whiptail --title "Erreur" --msgbox "Une erreur est survenue : $error_message\n\nAppuyez sur OK pour continuer." 12 70
    return 1 # Indique une erreur pour que le script appelant puisse réagir
}

# Fonctions de pré-vérification communes
check_whiptail() {
    if ! command -v whiptail &> /dev/null; then
        print_step "Installation de 'whiptail'..."
        if ! sudo apt update -qq > /dev/null 2>&1; then
             print_error "Échec de la mise à jour des dépôts APT avant l'installation de whiptail."
             return 1
        fi
        if ! sudo apt install -y whiptail -qq > /dev/null 2>&1; then
            print_error "Échec de l'installation de whiptail. L'affichage interactif des messages sera limité."
            return 1
        else
            print_success "Whiptail installé avec succès."
        fi
    fi
    return 0
}

check_bc() {
    if ! command -v bc &> /dev/null; then
        print_step "Installation de 'bc' (calculatrice en ligne de commande)..."
        if ! sudo apt install -y bc -qq > /dev/null 2>&1; then
            print_error "Échec de l'installation de bc. Certaines opérations nécessitant des calculs décimaux pourraient échouer."
            return 1
        else
            print_success "bc installé avec succès."
        fi
    fi
    return 0
}

check_curl() {
    if ! command -v curl &> /dev/null; then
        print_step "Installation de 'curl'..."
        if ! sudo apt install -y curl -qq > /dev/null 2>&1; then
            print_error "Échec de l'installation de curl. Le téléchargement de GLPI pourrait échouer."
            return 1
        else
            print_success "curl installé avec succès."
        fi
    fi
    return 0
}

check_and_prepare_sudo_access() {
    local current_user
    current_user=$(whoami)
    if [[ "$current_user" == "root" ]]; then
        show_error_and_return_to_menu "Le script ne doit pas être exécuté en tant que root. Veuillez le lancer avec un utilisateur standard disposant des droits sudo."
        return 1
    fi
    if groups "$current_user" | grep -qw "sudo"; then
        print_success "L'utilisateur '$current_user' appartient bien au groupe sudo."
        return 0
    else
        print_error "L'utilisateur '$current_user' n'appartient pas au groupe sudo."
        if id -u root &>/dev/null; then
            if whiptail --yesno "L'utilisateur '$current_user' n'est pas sudoer.\n\nVoulez-vous que le script génère une commande pour que root puisse ajouter les droits sudo ?" 12 60; then
                whiptail --msgbox "Connectez-vous en tant que root et exécutez cette commande :\n\nusermod -aG sudo $current_user\n\nPuis redémarrez votre machine et relancez le script." 15 70
                echo "Commande à exécuter en root : usermod -aG sudo $current_user"
                return 1
            else
                whiptail --msgbox "Vous devez ajouter manuellement l'utilisateur '$current_user' au groupe sudo :\n\nusermod -aG sudo $current_user\n\nPuis redémarrez votre machine et relancez le script." 12 70
                return 1
            fi
        else
            whiptail --msgbox "Impossible de trouver l'utilisateur root. Vous devez configurer manuellement les droits sudo pour '$current_user'." 10 70
            return 1
        fi
    fi
}

check_hostname_resolution() {
    print_step "Vérification de la résolution du nom d'hôte..."
    local fqdn_check=$(hostname -f)
    if [[ -z "$fqdn_check" ]] || ! ping -c 1 "$fqdn_check" &> /dev/null; then
        print_error "Le nom d'hôte complet (FQDN) n'est pas correctement défini ou résolu."
        show_error_and_return_to_menu "Veuillez vous assurer que votre système a un FQDN valide et résolvable (ex: hostname.example.com)."
        return 1
    fi
    print_success "Résolution du nom d'hôte vérifiée : $fqdn_check"
    # Stocke le FQDN globalement pour une utilisation ultérieure
    fqdn="$fqdn_check"
    return 0
}

restart_apache() {
    print_step "Redémarrage du service Apache..."
    if ! sudo systemctl restart apache2; then
        show_error_and_return_to_menu "Échec du redémarrage d'Apache. Vérifiez les logs Apache."
        return 1
    fi
    print_success "Apache redémarré avec succès."
    return 0
}

#=============================================================================
# Fonction : Barre de progression pour les opérations longues
# Affiche une barre de progression Whiptail pour améliorer l'expérience utilisateur.
#=============================================================================
progress_bar() {
    local message=$1
    local duration=${2:-3} # Durée par défaut de 3 secondes si non spécifiée

    {
        for ((i = 0 ; i <= 100 ; i+=20)); do # Incréments de 20%
            echo $i
            sleep "$((duration / 5))" # Diviser la durée totale en 5 étapes
        done
    } | whiptail --gauge "$message" 6 60 0 # Afficher la barre de progression
}

# Vous pouvez également déplacer des fonctions comme collect_database_info, collect_fqdn_info, etc., ici si elles sont véritablement des entrées communes pour plusieurs scripts.
# Par exemple:
collect_database_info() {
    db_name=$(whiptail --inputbox "Nom de la base de données GLPI (ex: glpidb)" 10 60 "glpidb" 3>&1 1>&2 2>&3 || echo "")
    if [[ -z "$db_name" ]]; then print_error "Nom de la base de données non fourni."; return 1; fi
    db_user=$(whiptail --inputbox "Nom d'utilisateur MySQL pour GLPI (ex: glpiuser)" 10 60 "glpiuser" 3>&1 1>&2 2>&3 || echo "")
    if [[ -z "$db_user" ]]; then print_error "Nom d'utilisateur non fourni."; return 1; fi
    db_pass=$(whiptail --passwordbox "Mot de passe MySQL pour l'utilisateur GLPI" 10 60 3>&1 1>&2 2>&3 || echo "")
    if [[ -z "$db_pass" ]]; then print_error "Mot de passe non fourni."; return 1; fi
    print_success "Informations de base de données collectées."
    return 0
}