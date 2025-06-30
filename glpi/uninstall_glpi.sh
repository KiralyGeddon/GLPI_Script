#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


# Source les fonctions utilitaires
# Assurez-vous que le chemin est correct, relative au script appelant
script_dir=$(dirname "$(realpath "$0")")
source "$script_dir/utils.sh"

set -euo pipefail

exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
# Fonctions spécifiques à la désinstallation
# =============================================================================
clean_previous_installation() {
    print_step "Nettoyage d'une ancienne installation GLPI..."

    set +e
    sudo systemctl stop apache2 2>/dev/null || true
    set -e

    progress_bar "Suppression des fichiers GLPI existants..." 3
    set +e
    sudo rm -rf /etc/glpi /var/lib/glpi /var/log/glpi "$WEB_ROOT" 2>/dev/null || true
    set -e

    if [[ -n "${fqdn:-}" && -f "/etc/apache2/sites-available/${fqdn}.conf" ]]; then
        progress_bar "Désactivation et suppression de la configuration Apache pour $fqdn..." 2
        set +e
        sudo a2dissite "${fqdn}.conf" > /dev/null 2>&1 || true
        sudo rm -f "/etc/apache2/sites-available/${fqdn}.conf" 2>/dev/null || true
        set -e
    fi

    if [[ -n "${fqdn:-}" ]]; then
        progress_bar "Nettoyage de l'entrée dans /etc/hosts pour $fqdn..." 1
        set +e
        sudo sed -i "/$fqdn/d" /etc/hosts 2>/dev/null || true
        set -e
    fi

    set +e
    sudo systemctl start apache2 2>/dev/null || true
    set -e

    print_success "Ancienne installation nettoyée (fichiers, configurations Apache, et entrée hosts)."
    return 0
}

delete_glpi_database() {
    print_step "Suppression de la base de données et de l'utilisateur GLPI..."
    if ! sudo mysqladmin ping --silent; then
        show_error_and_return_to_menu "Impossible de se connecter à MariaDB. Vérifiez le service et les identifiants."
        return 1
    fi

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

collect_fqdn_info() {
    print_step "Collecte du FQDN GLPI à désinstaller"

    fqdn=$(whiptail --inputbox "Nom de domaine complet (FQDN) de l'ancienne installation GLPI (ex: glpi.mondomaine.local) :" 10 60 --title "Désinstallation FQDN" 3>&1 1>&2 2>&3)
    while [[ -z "$fqdn" ]]; do
        whiptail --msgbox "Le FQDN ne peut pas être vide." 10 60
        fqdn=$(whiptail --inputbox "Nom de domaine complet (FQDN) de l'ancienne installation GLPI (ex: glpi.mondomaine.local) :" 10 60 --title "Désinstallation FQDN" 3>&1 1>&2 2>&3)
    done
    print_success "FQDN à désinstaller configuré : $fqdn"
    return 0
}

# =============================================================================
# Logique Principale pour la Désinstallation Complète de GLPI
# =============================================================================
main() {
    display_header
    print_step "Démarrage de la désinstallation complète de GLPI..."

    # Pré-vérifications critiques
    check_whiptail || exit 1
    check_bc || true
    check_curl || exit 1
    check_and_prepare_sudo_access || exit 1
    check_hostname_resolution || exit 1

    if ! whiptail --title "Confirmation Désinstallation" --yesno "ATTENTION : Ceci va supprimer COMPLÈTEMENT GLPI, ses fichiers et sa base de données.\n\nSouhaitez-vous vraiment continuer ?" 12 70; then
        print_success "Désinstallation annulée par l'utilisateur."
        return 0
    fi

    # Demander le FQDN si non défini
    if [[ -z "$fqdn" ]]; then
        if whiptail --yesno "Le FQDN de votre installation GLPI n'est pas défini. Voulez-vous le saisir pour une meilleure suppression de la configuration Apache ?" 10 70; then
            collect_fqdn_info || true # Permettre de continuer même si l'utilisateur annule
        fi
    fi

    # Demander les infos DB si non définies
    if [[ -z "$db_name" || -z "$db_user" || -z "$db_pass" ]]; then
        if whiptail --yesno "Les informations de la base de données GLPI ne sont pas définies. Voulez-vous les saisir pour supprimer la base de données ?" 10 70; then
            collect_database_info || true # Permettre de continuer même si l'utilisateur annule
        fi
    fi

    clean_previous_installation || show_error_and_return_to_menu "Échec du nettoyage des fichiers GLPI et Apache."

    if [[ -n "$db_name" && -n "$db_user" && -n "$db_pass" ]]; then
        delete_glpi_database || show_error_and_return_to_menu "Échec de la suppression de la base de données GLPI. Vous devrez peut-être le faire manuellement."
    else
        whiptail --msgbox "Les informations de la base de données n'ont pas été fournies ou ont été annulées. La base de données GLPI ne sera pas supprimée automatiquement." 10 70
    fi

    print_success "Désinstallation de GLPI terminée (fichiers, Apache, et si fourni, la base de données)."
    whiptail --title "Désinstallation GLPI" --msgbox "GLPI a été désinstallé. Veuillez vérifier manuellement que tous les composants sont bien supprimés." 12 70
}

main "$@"