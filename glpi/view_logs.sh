#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


# Source les fonctions utilitaires
# Assurez-vous que le chemin est correct, relative au script appelant
script_dir=$(dirname "$(realpath "$0")")
source "$script_dir/utils.sh"

set -euo pipefail

exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
# Logique Principale pour Voir les Logs
# =============================================================================
main() {
    display_header
    print_step "Affichage des logs d'installation GLPI..."

    check_whiptail || exit 1

    if [[ ! -f "$LOG_FILE" ]]; then
        whiptail --title "Logs" --msgbox "Le fichier de log '$LOG_FILE' n'existe pas encore ou est vide." 10 60
        print_error "Fichier de log introuvable: $LOG_FILE"
        return 1
    fi

    # Utiliser 'less' pour permettre le défilement et la recherche dans les logs
    less "$LOG_FILE"

    print_success "Affichage des logs terminé."
    whiptail --title "Logs GLPI" --msgbox "Le contenu du fichier de log a été affiché." 10 70
}

main "$@"