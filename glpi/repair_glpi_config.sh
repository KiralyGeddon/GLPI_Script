#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


# Source les fonctions utilitaires
# Assurez-vous que le chemin est correct, relative au script appelant
script_dir=$(dirname "$(realpath "$0")")
source "$script_dir/utils.sh"

set -euo pipefail

exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
# Fonction spécifique de réparation
# =============================================================================
repair_glpi_configuration() {
    print_step "Vérification et réparation des permissions des fichiers GLPI..."
    if ! sudo chown -R www-data:www-data "$WEB_ROOT"; then
        show_error_and_return_to_menu "Échec de la modification du propriétaire de $WEB_ROOT."
        return 1
    fi
    if ! sudo find "$WEB_ROOT" -type d -exec sudo chmod 755 {} \;; then
        show_error_and_return_to_menu "Échec de la modification des permissions des répertoires dans $WEB_ROOT."
        return 1
    fi
    if ! sudo find "$WEB_ROOT" -type f -exec sudo chmod 644 {} \;; then
        show_error_and_return_to_menu "Échec de la modification des permissions des fichiers dans $WEB_ROOT."
        return 1
    fi
    if ! sudo chmod -R 775 "$WEB_ROOT/config" && \
       ! sudo chmod -R 775 "$WEB_ROOT/files" && \
       ! sudo chmod -R 775 "$WEB_ROOT/marketplace" && \
       ! sudo chmod -R 775 "$WEB_ROOT/plugins" && \
       ! sudo chmod -R 775 "$WEB_ROOT/pics"; then
        show_error_and_return_to_menu "Échec de l'application des permissions spécifiques aux dossiers GLPI."
        return 1
    fi
    print_success "Permissions des fichiers GLPI réparées."

    local detected_fqdn=$(hostname) # Tentative de détection du FQDN

    # Tenter de réactiver le site Apache (s'il existe et est nommé avec le hostname)
    if ! sudo a2ensite "${detected_fqdn}.conf" > /dev/null 2>&1; then
        print_error "Impossible d'activer le site Apache pour $detected_fqdn. Il est possible que le fichier de conf n'existe pas ou ne soit pas nommé $detected_fqdn.conf."
    else
        print_success "Site Apache pour $detected_fqdn activé (si nécessaire)."
    fi

    print_step "Redémarrage du service Apache..."
    if ! sudo systemctl restart apache2; then
        show_error_and_return_to_menu "Échec du redémarrage d'Apache. Vérifiez les logs Apache."
        return 1
    fi
    print_success "Apache redémarré avec succès."
    return 0
}

# =============================================================================
# Logique Principale pour la Réparation de GLPI
# =============================================================================
main() {
    display_header
    print_step "Démarrage de la réparation de la configuration GLPI..."

    # Pré-vérifications critiques
    check_whiptail || exit 1
    check_bc || true
    check_curl || exit 1
    check_and_prepare_sudo_access || exit 1
    check_hostname_resolution || exit 1

    repair_glpi_configuration || exit 1

    whiptail --title "Réparation GLPI" --msgbox "La configuration de GLPI a été réparée (permissions, redémarrage Apache)." 10 70
}

main "$@"