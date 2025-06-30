#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

#=============================================================================
# Script d'orchestration avec menu interactif Whiptail
# Permet de lancer différents scripts via un menu.
#=============================================================================

# La directive 'set -euo pipefail' assure que le script :
# - E: sort immédiatement si une commande échoue (exit non-zéro).
# - U: sort si une variable non définie est utilisée.
# - O pipefail: renvoie le statut de la dernière commande non-zéro dans un pipe.
set -euo pipefail


#=============================================================================
# Couleurs pour l'affichage dans le terminal
#=============================================================================
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly RED='\033[0;31m'
readonly BOLD='\033[1m'
readonly RESET='\033[0m'

# Variables globales du script
WEB_ROOT="/var/www/html/glpi"
LOG_FILE="/tmp/install_glpi.log"
GLPI_VERSION=""
GLPI_URL=""
fqdn=""
db_name=""
db_user=""
db_pass=""


display_header() {
    # ASCII Art GLPI - version alignée
    local header_lines=(
        ""
        ""
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
        "========================================="
        "     Menu d'installation de GLPI"
        "========================================="
        ""
        "  Bienvenue dans l'installateur GLPI"
        ""
        ""
        ""
        ""
        ""
    )

    # Effacer l'écran du terminal
    clear

    # Calculer la largeur du terminal pour centrer l'affichage
    local term_width=$(tput cols)
    
    # Afficher chaque ligne centrée avec les couleurs définies
    for line in "${header_lines[@]}"; do
        # Appliquer le padding (espacement) seulement si la ligne n'est pas vide
        if [[ -n "$line" ]]; then
            # Calculer la longueur de la ligne en ignorant les codes de couleur ANSI
            local line_length=$(echo "$line" | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g" | wc -c)
            line_length=$((line_length - 1)) # wc -c compte le caractère de nouvelle ligne
            local padding=$(( (term_width - line_length) / 2 ))
            if [[ $padding -lt 0 ]]; then padding=0; fi # Éviter un padding négatif
            printf "%${padding}s" ""
        fi

        # Appliquer les couleurs spécifiques au texte
        if [[ "$line" == *"GLPI"* ]]; then
            echo -e "${CYAN}${BOLD}$line${RESET}"
        elif [[ "$line" == *"===="* ]]; then
            echo -e "${YELLOW}$line${RESET}"
        else
            echo -e "${GREEN}$line${RESET}"
        fi
        sleep 0.1 # Petite pause pour un effet d'animation
    done

    # Pause finale après l'affichage de l'entête
    sleep 1
}


# Fichier de log pour toutes les sorties du script
LOG_FILE="/tmp/orchestration_menu.log"
exec > >(tee -a "$LOG_FILE") 2>&1 

print_step() { echo -e "${CYAN}${BOLD}➤ $1${RESET}"; }
print_success() { echo -e "${GREEN}✓ $1${RESET}"; }
print_error() { echo -e "${RED}✗ Erreur: $1${RESET}" >&2; }
# Fonction d'affichage d'erreurs
show_error() {
    local error_message="$1"
    echo -e "${RED}✗ Erreur: $error_message${RESET}" >&2
    whiptail --title "Erreur" --msgbox "Une erreur est survenue : $error_message\n\nAppuyez sur OK pour revenir au menu." 12 70
}

# Fonction pour vérifier et installer whiptail
check_whiptail() {
    if ! command -v whiptail &> /dev/null; then
        echo -e "${YELLOW}Whiptail n'est pas installé. Tentative d'installation...${RESET}"
        if ! sudo apt update -qq > /dev/null 2>&1; then
             show_error "Échec de la mise à jour des dépôts APT avant l'installation de whiptail."
             return 1
        fi
        if ! sudo apt install -y whiptail -qq > /dev/null 2>&1; then
            show_error "Échec de l'installation de whiptail. Le menu ne peut pas fonctionner sans lui."
            return 1
        else
            echo -e "${GREEN}Whiptail installé avec succès.${RESET}"
        fi
    fi
    return 0
}

# Fonction pour exécuter le script GLPI
run_glpi_install() {
    local script_path="glpi_install_v10.5.sh" # Assurez-vous que le script est dans le même répertoire ou spécifiez le chemin complet.
    
    if [[ ! -f "$script_path" ]]; then
        show_error "Le script d'installation GLPI '$script_path' est introuvable."
        return 1
    fi

    if [[ ! -x "$script_path" ]]; then
        echo -e "${YELLOW}Le script GLPI n'est pas exécutable. Tentative de rendre exécutable...${RESET}"
        if ! chmod +x "$script_path"; then
            show_error "Échec de rendre le script GLPI exécutable. Vérifiez les permissions."
            return 1
        fi
        echo -e "${GREEN}Script GLPI rendu exécutable.${RESET}"
    fi

    whiptail --title "Lancement de l'Installation GLPI" --msgbox "Lancement du script d'installation de GLPI. Suivez les instructions qui apparaîtront.\n\nAppuyez sur OK pour continuer." 12 70

    # Exécuter le script GLPI. Le 'main()' est appelé par défaut dans glpi_install_v10.5.sh
    # Si le script GLPI a sa propre fonction main_menu, il gérera son interactivité.
    # Nous utilisons 'bash' pour l'exécuter, car c'est un script Bash.
    bash "$script_path"
    
    if [[ $? -eq 0 ]]; then
        whiptail --title "Installation GLPI Terminée" --msgbox "Le script d'installation de GLPI s'est terminé avec succès." 10 60
    else
        show_error "Le script d'installation GLPI s'est terminé avec des erreurs."
    fi
}

# Fonction du menu principal
main_menu() {
    while true; do # Boucle infinie pour afficher le menu tant que l'utilisateur ne quitte pas
        choice=$(whiptail --title "Installation GLPI - Menu Principal" \
            --menu "Choisissez une option pour gérer votre installation GLPI :" 20 90 10 \
            "1" "🆕 Nouvelle installation de GLPI (sans sauvegarde)" \
            "2" "♻️ Réinstaller GLPI (avec sauvegarde et nettoyage)" \
            "3" "🔒 Sécuriser GLPI (post-installation web)" \
            "4" "🔧 Réparer configuration GLPI" \
            "5" "🗑️ Désinstaller GLPI complètement" \
            "6" "💾 Sauvegarder l'installation GLPI actuelle" \
            "7" "🗑️ Supprimer manuellement une base de données GLPI" \
            "8" "📊 Informations système" \
            "9" "📋 Voir les logs" \
            "10" "❌ Quitter" \
            3>&1 1>&2 2>&3)

        # Vérifier si l'utilisateur a appuyé sur Annuler ou Échap (choice sera vide)
        if [[ -z "$choice" ]]; then
            print_success "Au revoir et merci d'avoir utilisé le script !"
            exit 0 # Quitter proprement si l'utilisateur annule le menu principal
        fi

        local result=0 # Variable pour stocker le résultat de l'exécution de la fonction (0 pour succès, 1 pour échec contrôlé)
        case "$choice" in
            1) 
            chmod +x ./glpi/install_glpi_new.sh
            ./glpi/install_glpi_new.sh || result=$?
            ;;
            2) 
            chmod +x ./glpi/reinstall_glpi.sh
            ./glpi/reinstall_glpi.sh || result=$? 
            ;;
            3) 
            chmod +x ./glpi/secure_glpi.sh
            ./glpi/secure_glpi.sh || result=$? 
            ;;
            4) 
            chmod +x ./glpi/repair_glpi_config.sh
            ./glpi/repair_glpi_config.sh || result=$? 
            ;;
            5) 
            chmod +x ./glpi/uninstall_glpi.sh
            ./glpi/uninstall_glpi.sh || result=$? 
            ;;
            6) 
            chmod +x ./glpi/backup_glpi.sh
            ./glpi/backup_glpi.sh || result=$? 
            ;;
            7) 
            chmod +x ./glpi/delete_glpi_db_manual.sh
            ./glpi/delete_glpi_db_manual.sh || result=$? 
            ;;
            8) 
            chmod +x ./glpi/system_info.sh
            ./glpi/system_info.sh || result=$? 
            ;;
            9)
            chmod +x ./glpi/view_logs.sh
            ./glpi/view_logs.sh || result=$? 
            ;;
            10)
                print_success "Au revoir et merci d'avoir utilisé le script !"
                exit 0 # Quitter le script proprement
                ;;
            *)
                whiptail --msgbox "Option invalide. Veuillez choisir une option valide dans le menu." 10 60
                ;;
        esac
        # Si une fonction a retourné 1 (indiquant une erreur non récupérable pour cette action),
        # la fonction show_error_and_return_to_menu aura déjà été appelée.
        # Le script continue alors la boucle pour afficher à nouveau le menu principal.
    done
}

# Point d'entrée du script
if ! check_whiptail; then
    echo -e "${RED}Impossible de continuer sans whiptail. Le script va s'arrêter.${RESET}"
    exit 1
fi

main() {
    chmod +x ./glpi/utils.sh
    display_header
    main_menu
}

main "@"