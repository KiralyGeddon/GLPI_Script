#!/bin/bash

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"


# Source les fonctions utilitaires
# Assurez-vous que le chemin est correct, relative au script appelant
script_dir=$(dirname "$(realpath "$0")")
source "$script_dir/utils.sh"

set -euo pipefail

exec > >(tee -a "$LOG_FILE") 2>&1

# =============================================================================
# Fonctions d'installation/réinstallation (comme dans install_glpi_new.sh, plus sauvegarde et nettoyage)
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


# =============================================================================
# Fonctions de vérification des prérequis système
# =============================================================================
check_system_requirements() {
    print_step "Vérification des prérequis système"

    if ! grep -E "Ubuntu|Debian" /etc/os-release &>/dev/null; then
        show_error_and_return_to_menu "Ce script est conçu pour Ubuntu et Debian uniquement."
        return 1
    fi

    local os_version
    os_version=$(lsb_release -rs 2>/dev/null || echo "unknown")
    local os_id
    os_id=$(lsb_release -is 2>/dev/null)

    case "$os_id" in
        "Ubuntu")
            if (( $(echo "$os_version < 20.04" | bc -l) )); then
                show_error_and_return_to_menu "Ubuntu 20.04 ou supérieur requis. Version détectée: $os_version"
                return 1
            fi
            ;;
        "Debian")
            if (( $(echo "$os_version < 11" | bc -l) )); then
                show_error_and_return_to_menu "Debian 11 ou supérieur requis. Version détectée: $os_version"
                return 1
            fi
            ;;
        *)
            show_error_and_return_to_menu "Système d'exploitation non supporté ou non détecté: $os_id"
            return 1
            ;;
    esac

    local ram_mb
    ram_mb=$(free -m | awk 'NR==2{print $2}')
    if [[ $ram_mb -lt 1024 ]]; then
        if ! whiptail --title "Avertissement RAM" --yesno "Votre système dispose de moins de 1GB de RAM ($ram_mb MB).\n\nGLPI peut fonctionner lentement. Voulez-vous continuer ?" 12 60; then
            return 1
        fi
    fi

    local arch
    arch=$(uname -m)
    if [[ "$arch" != "x86_64" ]] && [[ "$arch" != "aarch64" ]]; then
        show_error_and_return_to_menu "Architecture non supportée: $arch"
        return 1
    fi

    print_success "Prérequis système vérifiés."
    return 0
}

check_disk_space() {
    print_step "Vérification de l'espace disque"
    local available_space_kb
    available_space_kb=$(df -k / | tail -1 | awk '{print $4}')

    if [[ $available_space_kb -lt 5242880 ]]; then # 5GB en KB
        show_error_and_return_to_menu "Espace disque insuffisant (< 5 Go). Espace disponible: $((available_space_kb / 1024 / 1024)) Go."
        return 1
    fi

    print_success "Espace disque suffisant."
    return 0
}

check_ports() {
    print_step "Vérification des ports requis (80)"
    if sudo lsof -i :80 | grep LISTEN &>/dev/null; then
        if whiptail --title "Port 80 occupé" --yesno "Le port 80 est déjà utilisé. Cela peut indiquer qu'un autre serveur web est en cours d'exécution.\nVoulez-vous essayer d'arrêter Apache automatiquement si c'est lui ?" 12 60; then
            set +e
            sudo systemctl stop apache2 2>/dev/null || true
            set -e
            if sudo lsof -i :80 | grep LISTEN &>/dev/null; then
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

# =============================================================================
# Fonctions de collecte d'informations et d'installation
# =============================================================================
get_latest_glpi_version() {
    print_step "Récupération de la dernière version de GLPI"

    local default_glpi_version="10.0.15"
    local latest_version_api=""

    local api_response
    set +e
    api_response=$(curl -s --connect-timeout 10 --max-time 30 \
        https://api.github.com/repos/glpi-project/glpi/releases/latest 2>/dev/null || true)
    set -e

    if [[ -n "$api_response" ]]; then
        latest_version_api=$(echo "$api_response" | grep 'tag_name' | cut -d '"' -f4)
        if [[ -n "$latest_version_api" ]]; then
            latest_version_api="${latest_version_api#v}"
        fi
    fi

    if [[ -n "$latest_version_api" ]]; then
        if whiptail --title "Version GLPI" --yesno "Installer la dernière version de GLPI ?\n\nVersion détectée : $latest_version_api" 12 60; then
            GLPI_VERSION=$latest_version_api
        else
            if ! select_custom_version; then
                return 1
            fi
        fi
    else
        whiptail --title "Erreur" --msgbox "Impossible de récupérer la version via l'API GitHub.\nSaisie manuelle requise ou utilisation de la version par défaut ($default_glpi_version)." 10 60
        if whiptail --title "Version GLPI" --yesno "Voulez-vous tenter une saisie manuelle de la version de GLPI ?" 12 60; then
            if ! select_custom_version; then
                return 1
            fi
        else
            GLPI_VERSION="$default_glpi_version"
            whiptail --title "Version GLPI" --msgbox "La version par défaut $default_glpi_version sera utilisée." 10 60
        fi
    fi

    GLPI_URL="https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz"
    print_success "Version GLPI sélectionnée : $GLPI_VERSION"
    return 0
}

select_custom_version() {
    while true; do
        GLPI_VERSION=$(whiptail --inputbox "Entrez la version de GLPI (ex: 10.0.15) :" 10 60 --title "Version personnalisée" 3>&1 1>&2 2>&3)

        if [[ -z "$GLPI_VERSION" ]]; then
            whiptail --title "Erreur" --msgbox "La version ne peut pas être vide." 8 50
            continue
        fi

        local glpi_url_test="https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz"
        set +e
        if curl --head --silent --fail --connect-timeout 10 "$glpi_url_test" > /dev/null 2>&1; then
            set -e
            break
        else
            set -e
            whiptail --title "Erreur" --msgbox "Version non trouvée ou inaccessible : $GLPI_VERSION\nVérifiez la version sur GitHub (e.g., https://github.com/glpi-project/glpi/releases)." 10 70
        fi
    done
    return 0
}

collect_database_info() {
    print_step "Configuration de la base de données GLPI"

    db_name=$(whiptail --inputbox "Nom de la base de données GLPI :" 10 60 --title "Configuration de la base de données" "glpi_db" 3>&1 1>&2 2>&3)
    while [[ -z "$db_name" ]]; do
        whiptail --msgbox "Le nom de la base de données ne peut pas être vide." 10 60
        db_name=$(whiptail --inputbox "Nom de la base de données GLPI :" 10 60 --title "Configuration de la base de données" "glpi_db" 3>&1 1>&2 2>&3)
    done

    db_user=$(whiptail --inputbox "Nom d'utilisateur MySQL pour GLPI :" 10 60 --title "Configuration de la base de données" "glpi_user" 3>&1 1>&2 2>&3)
    while [[ -z "$db_user" ]]; do
        whiptail --msgbox "Le nom d'utilisateur ne peut pas être vide." 10 60
        db_user=$(whiptail --inputbox "Nom d'utilisateur MySQL pour GLPI :" 10 60 --title "Configuration de la base de données" "glpi_user" 3>&1 1>&2 2>&3)
    done

    db_pass=$(whiptail --passwordbox "Mot de passe MySQL pour l'utilisateur GLPI :" 10 60 --title "Configuration de la base de données" 3>&1 1>&2 2>&3)
    while [[ -z "$db_pass" ]]; do
        whiptail --msgbox "Le mot de passe ne peut pas être vide." 10 60
        db_pass=$(whiptail --passwordbox "Mot de passe MySQL pour l'utilisateur GLPI :" 10 60 --title "Configuration de la base de données" 3>&1 1>&2 2>&3)
    done
    print_success "Informations de la base de données collectées."
    return 0
}

collect_fqdn_info() {
    print_step "Configuration du nom de domaine (FQDN) pour Apache"

    fqdn=$(whiptail --inputbox "Nom de domaine complet (FQDN) pour accéder à GLPI (ex: glpi.mondomaine.local) :" 10 60 --title "Configuration FQDN" "glpi.local" 3>&1 1>&2 2>&3)
    while [[ -z "$fqdn" ]]; do
        whiptail --msgbox "Le FQDN ne peut pas être vide." 10 60
        fqdn=$(whiptail --inputbox "Nom de domaine complet (FQDN) pour accéder à GLPI (ex: glpi.mondomaine.local) :" 10 60 --title "Configuration FQDN" "glpi.local" 3>&1 1>&2 2>&3)
    done
    print_success "FQDN configuré : $fqdn"
    return 0
}

summary_confirmation() {
    if ! whiptail --title "Résumé de la configuration" --yesno "Résumé de l'installation GLPI :\n\nVersion GLPI : ${GLPI_VERSION:-Non définie}\nNom de domaine (FQDN) : ${fqdn:-Non défini}\nBase de données : ${db_name:-Non définie}\nUtilisateur MySQL : ${db_user:-Non défini}\n\nSouhaitez-vous continuer l'installation avec ces paramètres ?" 15 60; then
        return 1
    fi
    return 0
}

update_system() {
    print_step "Mise à jour du système et nettoyage des paquets..."
    progress_bar "Mise à jour et nettoyage du système..." 5
    if ! sudo apt update -qq > /dev/null 2>&1; then
        show_error_and_return_to_menu "Échec de la mise à jour des dépôts APT."
        return 1
    fi
    if ! sudo apt upgrade -y -qq > /dev/null 2>&1; then
        show_error_and_return_to_menu "Échec de la mise à niveau des paquets."
        return 1
    fi
    set +e
    sudo apt autoremove -y -qq > /dev/null 2>&1 || true
    sudo apt clean -qq > /dev/null 2>&1 || true
    set -e
    print_success "Système mis à jour et nettoyé."
    return 0
}

install_dependencies() {
    print_step "Installation des dépendances requises (LAMP et PHP extensions)..."
    progress_bar "Installation des paquets requis..." 10

    local packages=(
        apache2
        mariadb-server
        php
        php-curl
        php-common
        php-json
        php-imap
        php-gd
        php-intl
        php-mbstring
        php-xml
        php-zip
        php-bz2
        php-mysql
        php-apcu
        php-cli
        php-ldap
        php-xmlrpc
        php-cas
        libapache2-mod-php
        unzip
        tar
        wget
        curl
        lsof
        lsb-release
    )

    if ! sudo apt install -y "${packages[@]}" -qq > /dev/null 2>&1; then
        show_error_and_return_to_menu "Échec de l'installation de certaines dépendances. Vérifiez la connexion internet ou les dépôts."
        return 1
    fi

    print_success "Dépendances installées."
    return 0
}

install_glpi() {
    print_step "Téléchargement et installation des fichiers GLPI..."
    progress_bar "Téléchargement de GLPI..." 8

    if ! sudo mkdir -p "$WEB_ROOT"; then
        show_error_and_return_to_menu "Échec de la création du répertoire web GLPI : $WEB_ROOT. Vérifiez les permissions."
        return 1
    fi

    if ! wget -q "$GLPI_URL" -O /tmp/glpi.tgz; then
        show_error_and_return_to_menu "Échec du téléchargement de GLPI depuis $GLPI_URL. Vérifiez la version ou la connexion."
        return 1
    fi

    progress_bar "Extraction des fichiers GLPI..." 5
    if ! tar -xzf /tmp/glpi.tgz -C /tmp > /dev/null; then
        show_error_and_return_to_menu "Échec de l'extraction des fichiers GLPI."
        return 1
    fi
    if ! sudo cp -r /tmp/glpi/* "$WEB_ROOT/"; then
        show_error_and_return_to_menu "Échec de la copie des fichiers GLPI vers $WEB_ROOT."
        return 1
    fi
    set +e
    rm -rf /tmp/glpi /tmp/glpi.tgz
    set -e

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

    if ! sudo chmod -R 775 "$WEB_ROOT/config"; then show_error_and_return_to_menu "Échec chmod config"; return 1; fi
    if ! sudo chmod -R 775 "$WEB_ROOT/files"; then show_error_and_return_to_menu "Échec chmod files"; return 1; fi
    if ! sudo chmod -R 775 "$WEB_ROOT/marketplace"; then show_error_and_return_to_menu "Échec chmod marketplace"; return 1; fi
    if ! sudo chmod -R 775 "$WEB_ROOT/plugins"; then show_error_and_return_to_menu "Échec chmod plugins"; return 1; fi
    if ! sudo chmod -R 775 "$WEB_ROOT/pics"; then show_error_and_return_to_menu "Échec chmod pics"; return 1; fi
    print_success "Fichiers GLPI installés avec permissions temporaires pour l'installation web."
    return 0
}

configure_database() {
    print_step "Configuration de la base de données MariaDB pour GLPI..."
    if ! sudo systemctl enable mariadb -qq > /dev/null 2>&1; then
        show_error_and_return_to_menu "Échec de l'activation du service MariaDB."
        return 1
    fi
    if ! sudo systemctl start mariadb; then
        show_error_and_return_to_menu "Échec du démarrage du service MariaDB."
        return 1
    fi
    if ! sudo mysqladmin ping --silent; then
        show_error_and_return_to_menu "Impossible de démarrer ou de se connecter à MariaDB. Vérifiez le service."
        return 1
    fi
    progress_bar "Sécurisation de MariaDB et création de la base de données GLPI..." 7
    set +e
    sudo mysql -e "UPDATE mysql.user SET Password=PASSWORD('') WHERE User='root' AND Host='localhost';" > /dev/null 2>&1 || true
    sudo mysql -e "DELETE FROM mysql.user WHERE User='';" > /dev/null 2>&1 || true
    sudo mysql -e "DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');" > /dev/null 2>&1 || true
    sudo mysql -e "DROP DATABASE IF EXISTS test;" > /dev/null 2>&1 || true
    sudo mysql -e "DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';" > /dev/null 2>&1 || true
    sudo mysql -e "FLUSH PRIVILEGES;" > /dev/null 2>&1 || true
    set -e
    if ! sudo mysql -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" > /dev/null 2>&1; then
        show_error_and_return_to_menu "Échec de la création de la base de données GLPI."
        return 1
    fi
    if ! sudo mysql -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';" > /dev/null 2>&1; then
        show_error_and_return_to_menu "Échec de la création de l'utilisateur MySQL pour GLPI."
        return 1
    fi
    if ! sudo mysql -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';" > /dev/null 2>&1; then
        show_error_and_return_to_menu "Échec de l'octroi des privilèges à l'utilisateur GLPI."
        return 1
    fi
    if ! sudo mysql -e "FLUSH PRIVILEGES;" > /dev/null 2>&1; then
        show_error_and_return_to_menu "Échec du rechargement des privilèges MySQL."
        return 1
    fi
    print_success "Base de données GLPI configurée."
    return 0
}

configure_apache() {
    print_step "Configuration d'Apache pour GLPI..."
    progress_bar "Création du VirtualHost Apache..." 3
    if ! sudo tee "/etc/apache2/sites-available/${fqdn}.conf" > /dev/null <<EOF
<VirtualHost *:80>
    ServerName $fqdn
    DocumentRoot $WEB_ROOT/public

    <Directory $WEB_ROOT>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <Directory $WEB_ROOT/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
        RewriteEngine On
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^(.*)$ index.php [QSA,L]
    </Directory>

    # Sécurité supplémentaire (empêche l'accès direct aux dossiers sensibles)
    <Directory $WEB_ROOT/config>
        Require all denied
    </Directory>
    <Directory $WEB_ROOT/files>
        Require all denied
    </Directory>

    <FilesMatch "\.(log|ini|conf|sh|sql|json|yml|yaml|env)$">
        Require all denied
    </FilesMatch>

    # Configuration PHP recommandée pour GLPI (Override VirtualHost level)
    php_value memory_limit 512M
    php_value post_max_size 50M
    php_value upload_max_filesize 50M
    php_value max_execution_time 600
    php_value date.timezone "Europe/Paris" # Ou votre fuseau horaire
</VirtualHost>
EOF
    then
        show_error_and_return_to_menu "Échec de la création du VirtualHost Apache pour GLPI."
        return 1
    fi

    if ! sudo a2ensite "${fqdn}.conf" > /dev/null; then
        show_error_and_return_to_menu "Échec de l'activation du site Apache pour GLPI."
        return 1
    fi
    if ! sudo a2enmod rewrite > /dev/null; then
        show_error_and_return_to_menu "Échec de l'activation du module rewrite d'Apache."
        return 1
    fi
    if ! sudo a2enmod php* > /dev/null; then
        show_error_and_return_to_menu "Échec de l'activation du module PHP d'Apache."
        return 1
    fi

    print_success "Configuration Apache pour GLPI créée et activée."
    return 0
}

configure_php() {
    print_step "Configuration de PHP pour GLPI..."
    local php_ini_path="/etc/php/$(php -r 'echo PHP_VERSION;' | cut -d. -f1-2)/apache2/php.ini"

    if [[ ! -f "$php_ini_path" ]]; then
        show_error_and_return_to_menu "Fichier php.ini introuvable à $php_ini_path. Vérifiez votre installation PHP."
        return 1
    fi

    # Mettre à jour les paramètres PHP dans php.ini
    sudo sed -i "s/^memory_limit = .*/memory_limit = 512M/" "$php_ini_path"
    sudo sed -i "s/^post_max_size = .*/post_max_size = 50M/" "$php_ini_path"
    sudo sed -i "s/^upload_max_filesize = .*/upload_max_filesize = 50M/" "$php_ini_path"
    sudo sed -i "s/^max_execution_time = .*/max_execution_time = 600/" "$php_ini_path"
    sudo sed -i "s/^;date.timezone =/date.timezone = \"Europe\/Paris\"/" "$php_ini_path" # Définir le fuseau horaire

    print_success "PHP configuré pour GLPI."
    return 0
}

post_install_glpi_setup() {
    print_step "Finalisation post-installation de GLPI..."
    # GLPI nécessite que ces dossiers soient accessibles en écriture pour le serveur web (www-data)
    # Après l'installation web, GLPI recommandera de restreindre certains accès.
    # Pour l'instant, on s'assure que www-data peut écrire pendant l'installation via le navigateur.
    if ! sudo chown -R www-data:www-data "$WEB_ROOT/files" "$WEB_ROOT/config" "$WEB_ROOT/marketplace" "$WEB_ROOT/plugins" "$WEB_ROOT/pics"; then
        show_error_and_return_to_menu "Échec de l'ajustement des permissions post-installation de GLPI."
        return 1
    fi
    print_success "Finalisation post-installation GLPI effectuée."
    return 0
}

secure_glpi_web() {
    print_step "Application des mesures de sécurité GLPI (après installation web)..."
    # GLPI recommande de définir des permissions plus restrictives après l'installation web.
    # https://glpi-install.readthedocs.io/en/latest/install.html#step-12-secure-the-folders
    # Ces commandes sont idempotentes.
    sudo chmod -R o-rwx "$WEB_ROOT/config"
    sudo chmod -R o-rwx "$WEB_ROOT/files/_log"
    sudo chmod -R o-rwx "$WEB_ROOT/files/_sessions"
    sudo chmod -R o-rwx "$WEB_ROOT/files/_dumps"
    sudo chmod -R o-rwx "$WEB_ROOT/files/_graphs"
    sudo chmod -R o-rwx "$WEB_ROOT/files/_lock"
    sudo chmod -R o-rwx "$WEB_ROOT/files/_tmp"
    sudo chmod -R o-rwx "$WEB_ROOT/files/_uploads"
    sudo chmod -R o-rwx "$WEB_ROOT/install" # Supprimer l'accès au dossier d'installation si GLPI >= 9.2

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
# Logique Principale pour la Réinstallation
# =============================================================================
main() {
    display_header
    print_step "Démarrage de la réinstallation GLPI (avec sauvegarde et nettoyage)..."

    # Pré-vérifications critiques
    check_whiptail || exit 1
    check_bc || true
    check_curl || exit 1
    check_and_prepare_sudo_access || exit 1
    check_hostname_resolution || exit 1

    # Sauvegarde et nettoyage
    create_backup # Cette fonction gère l'interaction utilisateur
    clean_previous_installation || exit 1

    # Re-exécuter les étapes d'installation
    get_latest_glpi_version || exit 1
    collect_database_info || exit 1
    collect_fqdn_info || exit 1
    summary_confirmation || exit 1

    update_system || exit 1
    install_dependencies || exit 1
    install_glpi || exit 1
    configure_database || exit 1
    configure_apache || exit 1
    configure_php || exit 1
    post_install_glpi_setup || exit 1

    print_success "Réinstallation de GLPI terminée avec succès !"
    secure_glpi_web
    restart_apache

    whiptail --title "Réinstallation GLPI Réussie" --msgbox "GLPI a été réinstallé avec succès.\n\nAccédez à votre GLPI via : http://${fqdn}\n\nIdentifiants par défaut : glpi / glpi" 15 70
}

main "$@"