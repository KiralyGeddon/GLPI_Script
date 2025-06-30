#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


# Source les fonctions utilitaires
# Assurez-vous que le chemin est correct, relative au script appelant
script_dir=$(dirname "$(realpath "$0")")
source "$script_dir/utils.sh"

set -euo pipefail

exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
# Fonctions spécifiques à la sécurisation (comme dans install_glpi_new.sh)
# =============================================================================
secure_glpi_web() {
    print_step "Application des mesures de sécurité GLPI (après installation web)..."
    sudo chmod -R o-rwx "$WEB_ROOT/config"
    sudo chmod -R o-rwx "$WEB_ROOT/files/_log"
    sudo chmod -R o-rwx "$WEB_ROOT/files/_sessions"
    sudo chmod -R o-rwx "$WEB_ROOT/files/_dumps"
    sudo chmod -R o-rwx "$WEB_ROOT/files/_graphs"
    sudo chmod -R o-rwx "$WEB_ROOT/files/_lock"
    sudo chmod -R o-rwx "$WEB_ROOT/files/_tmp"
    sudo chmod -R o-rwx "$WEB_ROOT/files/_uploads"
    sudo chmod -R o-rwx "$WEB_ROOT/install"

    print_success "Mesures de sécurité GLPI appliquées."
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

# =============================================================================
# Logique Principale pour la Sécurisation de GLPI
# =============================================================================
main() {
    display_header
    print_step "Démarrage de la sécurisation de GLPI..."

    # Pré-vérifications critiques
    check_whiptail || exit 1
    check_bc || true
    check_curl || exit 1
    check_and_prepare_sudo_access || exit 1
    check_hostname_resolution || exit 1

    secure_glpi_web || show_error_and_return_to_menu "La sécurisation de GLPI a échoué."
    restart_apache || show_error_and_return_to_menu "Échec du redémarrage d'Apache après sécurisation."

    print_success "GLPI sécurisé avec succès."
    whiptail --title "Sécurisation GLPI" --msgbox "La sécurisation de votre installation GLPI a été appliquée." 10 70
}

main "$@"