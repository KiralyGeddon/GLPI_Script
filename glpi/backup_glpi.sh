#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


# Source les fonctions utilitaires
# Assurez-vous que le chemin est correct, relative au script appelant
script_dir=$(dirname "$(realpath "$0")")
source "$script_dir/utils.sh"

set -euo pipefail

exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
# Fonction spécifique de sauvegarde (comme dans reinstall_glpi.sh)
# =============================================================================
create_backup() {
    print_step "Vérification et création de la sauvegarde"
    if [[ -d "$WEB_ROOT" ]]; then
        local backup_dir="/tmp/glpi_backup_$(date +%Y%m%d_%H%M%S)"
        if whiptail --title "Sauvegarde" --yesno "Une installation GLPI existante est détectée dans $WEB_ROOT.\nVoulez-vous créer une sauvegarde avant de continuer ?" 10 70; then
            progress_bar "Création de la sauvegarde de $WEB_ROOT vers $backup_dir..." 5
            if ! sudo mkdir -p "$backup_dir"; then
                show_error_and_return_to_menu "Échec de la création du répertoire de sauvegarde : $backup_dir. Vérifiez les permissions ou l'espace disque."
                return 1
            fi
            if ! sudo cp -r "$WEB_ROOT" "$backup_dir/"; then
                show_error_and_return_to_menu "Échec de la création de la sauvegarde dans $backup_dir. Vérifiez les permissions ou l'espace disque."
                return 1
            fi
            print_success "Sauvegarde créée : $backup_dir"
            whiptail --title "Sauvegarde Réussie" --msgbox "Votre installation GLPI a été sauvegardée avec succès à :\n$backup_dir" 10 70
            return 0
        else
            whiptail --title "Sauvegarde ignorée" --msgbox "La sauvegarde de l'installation existante a été ignorée." 10 70
        fi
    else
        whiptail --title "Aucune Installation GLPI" --msgbox "Aucune installation GLPI détectée à $WEB_ROOT pour la sauvegarde." 10 70
    fi
    return 0
}

# =============================================================================
# Logique Principale pour la Sauvegarde de GLPI
# =============================================================================
main() {
    display_header
    print_step "Démarrage de la sauvegarde de GLPI..."

    # Pré-vérifications critiques
    check_whiptail || exit 1
    check_bc || true
    check_curl || exit 1
    check_and_prepare_sudo_access || exit 1
    check_hostname_resolution || exit 1

    create_backup
}

main "$@"