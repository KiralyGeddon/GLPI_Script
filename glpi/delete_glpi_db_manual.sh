#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


# Source les fonctions utilitaires
# Assurez-vous que le chemin est correct, relative au script appelant
script_dir=$(dirname "$(realpath "$0")")
source "$script_dir/utils.sh"

set -euo pipefail

exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
# Fonctions spécifiques à la suppression de base de données
# =============================================================================
collect_database_info() {
    print_step "Collecte des informations de la base de données GLPI à supprimer"

    db_name=$(whiptail --inputbox "Nom de la base de données GLPI à supprimer :" 10 60 --title "Suppression de la base de données" 3>&1 1>&2 2>&3)
    while [[ -z "$db_name" ]]; do
        whiptail --msgbox "Le nom de la base de données ne peut pas être vide." 10 60
        db_name=$(whiptail --inputbox "Nom de la base de données GLPI à supprimer :" 10 60 --title "Suppression de la base de données" 3>&1 1>&2 2>&3)
    done

    db_user=$(whiptail --inputbox "Nom d'utilisateur MySQL pour la base de données (généralement root ou un utilisateur avec DROP PRIVILEGES) :" 10 60 --title "Suppression de la base de données" "root" 3>&1 1>&2 2>&3)
    while [[ -z "$db_user" ]]; do
        whiptail --msgbox "Le nom d'utilisateur ne peut pas être vide." 10 60
        db_user=$(whiptail --inputbox "Nom d'utilisateur MySQL pour la base de données (généralement root ou un utilisateur avec DROP PRIVILEGES) :" 10 60 --title "Suppression de la base de données" "root" 3>&1 1>&2 2>&3)
    done

    db_pass=$(whiptail --passwordbox "Mot de passe MySQL pour l'utilisateur '$db_user' :" 10 60 --title "Suppression de la base de données" 3>&1 1>&2 2>&3)
    while [[ -z "$db_pass" ]]; do
        whiptail --msgbox "Le mot de passe ne peut pas être vide." 10 60
        db_pass=$(whiptail --passwordbox "Mot de passe MySQL pour l'utilisateur '$db_user' :" 10 60 --title "Suppression de la base de données" 3>&1 1>&2 2>&3)
    done
    print_success "Informations de la base de données collectées pour suppression."
    return 0
}

delete_glpi_database() {
    print_step "Suppression de la base de données et de l'utilisateur GLPI..."
    if ! sudo mysqladmin ping --silent; then
        show_error_and_return_to_menu "Impossible de se connecter à MariaDB. Vérifiez le service et les identifiants."
        return 1
    fi

    # Utilisation des identifiants fournis pour la suppression
    if ! sudo mysql -e "DROP DATABASE IF EXISTS \`${db_name}\`;" -u"${db_user}" -p"${db_pass}" > /dev/null 2>&1; then
        show_error_and_return_to_menu "Échec de la suppression de la base de données '${db_name}'. Vérifiez les permissions."
        return 1
    fi
    if ! sudo mysql -e "DROP USER IF EXISTS '${db_user}'@'localhost';" -u"${db_user}" -p"${db_pass}" > /dev/null 2>&1; then
        show_error_and_return_to_menu "Échec de la suppression de l'utilisateur '${db_user}'. Vérifiez les permissions."
        return 1
    fi
    sudo mysql -e "FLUSH PRIVILEGES;" > /dev/null 2>&1
    print_success "Base de données '${db_name}' et utilisateur '${db_user}' supprimés."
    return 0
}

# =============================================================================
# Logique Principale pour la Suppression Manuelle de la Base de Données GLPI
# =============================================================================
main() {
    display_header
    print_step "Démarrage de la suppression manuelle de la base de données GLPI..."

    # Pré-vérifications critiques
    check_whiptail || exit 1
    check_bc || true
    check_curl || exit 1
    check_and_prepare_sudo_access || exit 1
    check_hostname_resolution || exit 1

    whiptail --title "Information" --msgbox "Cette option vous permettra de supprimer une base de données GLPI. Vous devrez saisir les informations de connexion à la base de données." 10 70

    collect_database_info || exit 1

    if ! whiptail --title "Confirmation Suppression DB" --yesno "ATTENTION : Ceci va supprimer la base de données '${db_name}' et l'utilisateur '${db_user}'.\n\nSouhaitez-vous vraiment continuer ?" 12 70; then
        print_success "Suppression de la base de données annulée par l'utilisateur."
        return 0
    fi

    delete_glpi_database || show_error_and_return_to_menu "Échec de la suppression de la base de données GLPI. Vérifiez les identifiants et les logs."

    print_success "Base de données GLPI supprimée avec succès (si les informations étaient correctes)."
    whiptail --title "Suppression DB GLPI" --msgbox "La base de données GLPI a été supprimée." 10 70
}

main "$@"