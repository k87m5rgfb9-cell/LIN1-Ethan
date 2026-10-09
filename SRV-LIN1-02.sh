#!/bin/bash
#
# ============================================================================
# SRV-LIN1-02.sh
# ----------------------------------------------------------------------------
# Script d'installation et de configuration automatisee de SRV-LIN1-02
# Module LIN1 - Infrastructure LIN1-LABO
# Auteur : Ethan - CPNV
#
# Ce script configure, sur une Debian 12 fraichement installee :
#   1. Le reseau (interface interne statique, passerelle SRV-LIN1-01)
#   2. Le partage : montage NFS du NAS, utilise comme repertoire de
#      donnees de Nextcloud (les fichiers sont physiquement sur le NAS)
#   3. Nextcloud 33 (Apache, MariaDB, PHP 8.2) en HTTP et HTTPS
#   4. L'integration LDAP, les dossiers de groupe et l'agenda
#
# PREREQUIS :
#   - Debian 12 (Bookworm), une interface ens33 sur VMnet2 (10.10.40.22).
#   - SRV-LIN1-01 operationnel (passerelle, DNS, LDAP) : sans lui, pas
#     d'acces Internet pour telecharger les paquets.
#   - NAS-LIN1-01 operationnel avec l'export NFS /export/nextcloud-data
#     autorise pour 10.10.40.22, options rw + no_root_squash.
#   - Execution en root :
#       su -
#       bash SRV-LIN1-02.sh
# ============================================================================

# ----------------------------------------------------------------------------
# 0. VARIABLES DE CONFIGURATION
# ----------------------------------------------------------------------------
ADMIN_USER="ethan"

IFACE_LAN="ens33"
IP_SRV02="10.10.40.22"
NETMASK="255.255.255.0"
GATEWAY="10.10.40.11"
DNS_SERVER="10.10.40.11"
DOMAIN="lin1-labo.local"

NAS_IP="10.10.40.33"
NAS_NFS_EXPORT="/export/nextcloud-data"
NFS_MOUNT_POINT="/mnt/nextcloud-data"     # = repertoire de donnees Nextcloud

DB_NAME="nextcloud"
DB_USER="nextcloud"
DB_PASSWORD="Pa\$\$w0rd"

NC_ADMIN_USER="admin"
NC_ADMIN_PASSWORD="Pa\$\$w0rd"
NC_URL="https://download.nextcloud.com/server/releases/latest-33.zip"
CALENDAR_VERSION="6.5.4"                  # compatible Nextcloud 32 a 35

LDAP_HOST="10.10.40.11"
LDAP_BASE_DN="dc=lin1-labo,dc=local"
LDAP_ADMIN_DN="cn=admin,dc=lin1-labo,dc=local"
LDAP_ADMIN_PASSWORD="Pa\$\$w0rd"

QUOTA_PERSO="1 GB"                        # quota par utilisateur (schema : 10 MB)
QUOTA_CLIENTS="20MB"
QUOTA_LOGICIELS="20MB"
QUOTA_COMMUN="30MB"

OCC="sudo -u www-data php /var/www/nextcloud/occ"

# ----------------------------------------------------------------------------
# 0bis. VERIFICATION DES DROITS
# ----------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit etre execute en tant que root : su - puis bash SRV-LIN1-02.sh"
    exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
    apt update
    apt install -y sudo
fi

set -e

echo "============================================================"
echo " SRV-LIN1-02 - Debut de l'installation automatisee"
echo "============================================================"

hostnamectl set-hostname srv-lin1-02
sed -i '/127.0.1.1/d' /etc/hosts
echo "127.0.1.1 srv-lin1-02.${DOMAIN} srv-lin1-02" >> /etc/hosts
echo "Nom de machine configure : srv-lin1-02"

if id "${ADMIN_USER}" >/dev/null 2>&1; then
    usermod -aG sudo "${ADMIN_USER}"
fi

# Si une carte NAT temporaire est presente (adresse 192.168.x.x), on prend l'autre
if ip -4 addr show "${IFACE_LAN}" 2>/dev/null | grep -q "inet 192\.168\."; then
    for IFACE in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do
        if [ "${IFACE}" != "${IFACE_LAN}" ]; then
            IFACE_LAN="${IFACE}"
            break
        fi
    done
fi
echo "Interface interne : ${IFACE_LAN}"

# ============================================================================
# 1. CONFIGURATION RESEAU
# ============================================================================
echo ""
echo "---- [1/4] Configuration reseau ----"

cat > /etc/network/interfaces <<EOF
source /etc/network/interfaces.d/*

# Interface loopback
auto lo
iface lo inet loopback

# Interface interne LIN1-LABO (VMnet2)
allow-hotplug ${IFACE_LAN}
iface ${IFACE_LAN} inet static
    address ${IP_SRV02}
    netmask ${NETMASK}
    gateway ${GATEWAY}
    dns-nameservers ${DNS_SERVER}
EOF

systemctl restart networking || true

cat > /etc/resolv.conf <<EOF
domain ${DOMAIN}
search ${DOMAIN}
nameserver ${DNS_SERVER}
EOF

if ! ping -c 2 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "Pas d'acces Internet : verifier que SRV-LIN1-01 (passerelle) est demarre."
    exit 1
fi
echo "Reseau configure : ${IFACE_LAN} = ${IP_SRV02}, passerelle ${GATEWAY}."

# ============================================================================
# 2. PARTAGE : MONTAGE NFS DU NAS
# ============================================================================
echo ""
echo "---- [2/4] Montage du partage NFS (NAS-LIN1-01) ----"

apt update
apt install -y vim curl wget unzip nfs-common ldap-utils

mkdir -p ${NFS_MOUNT_POINT}

if ! mountpoint -q ${NFS_MOUNT_POINT}; then
    mount -t nfs ${NAS_IP}:${NAS_NFS_EXPORT} ${NFS_MOUNT_POINT}
fi

if ! grep -q "${NFS_MOUNT_POINT}" /etc/fstab; then
    echo "${NAS_IP}:${NAS_NFS_EXPORT}  ${NFS_MOUNT_POINT}  nfs  defaults,_netdev  0  0" >> /etc/fstab
fi
systemctl daemon-reload

# Necessite no_root_squash cote NAS ; sinon : "Operation non permise"
chown www-data:www-data ${NFS_MOUNT_POINT} 2>/dev/null || chown 33:33 ${NFS_MOUNT_POINT}
chmod 770 ${NFS_MOUNT_POINT}

echo "Partage monte : ${NAS_IP}:${NAS_NFS_EXPORT} -> ${NFS_MOUNT_POINT}"

# ============================================================================
# 3. NEXTCLOUD (Apache, MariaDB, PHP)
# ============================================================================
echo ""
echo "---- [3/4] Installation de Nextcloud ----"

apt install -y apache2 mariadb-server php php-gd php-mysql php-curl \
    php-mbstring php-intl php-gmp php-bcmath php-xml php-imagick \
    php-zip php-ldap libapache2-mod-php

# --- Base de donnees ---
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# --- Nextcloud 33 (compatible avec PHP 8.2 de Debian 12) ---
if [ ! -d /var/www/nextcloud ]; then
    cd /tmp
    echo "Telechargement de Nextcloud 33 (environ 250 Mo)..."
    wget -q "${NC_URL}" -O nextcloud.zip
    unzip -q nextcloud.zip -d /var/www/
    rm -f nextcloud.zip
    cd - >/dev/null
fi
chown -R www-data:www-data /var/www/nextcloud

# --- Certificat auto-signe ---
mkdir -p /etc/apache2/ssl
if [ ! -f /etc/apache2/ssl/nextcloud.crt ]; then
    openssl req -x509 -nodes -days 825 -newkey rsa:2048 \
        -keyout /etc/apache2/ssl/nextcloud.key \
        -out /etc/apache2/ssl/nextcloud.crt \
        -subj "/C=CH/ST=Vaud/L=LeChenit/O=LIN1-LABO/CN=srv-lin1-02.${DOMAIN}"
fi

# --- Hotes virtuels HTTP et HTTPS ---
for PORT in 80 443; do
    if [ "${PORT}" = "443" ]; then
        CONF="nextcloud-ssl.conf"
        SSL_LINES="    SSLEngine on
    SSLCertificateFile /etc/apache2/ssl/nextcloud.crt
    SSLCertificateKeyFile /etc/apache2/ssl/nextcloud.key"
    else
        CONF="nextcloud.conf"
        SSL_LINES=""
    fi
    cat > /etc/apache2/sites-available/${CONF} <<EOF
<VirtualHost *:${PORT}>
    DocumentRoot /var/www/nextcloud
    ServerName srv-lin1-02.${DOMAIN}
${SSL_LINES}

    <Directory /var/www/nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF
done

a2enmod rewrite headers env dir mime ssl
a2dissite 000-default.conf || true      # sinon la page Apache par defaut s'affiche
a2ensite nextcloud.conf nextcloud-ssl.conf

# Limite memoire PHP pour Apache (et non pour le CLI)
PHP_INI="/etc/php/8.2/apache2/php.ini"
if [ -f "${PHP_INI}" ]; then
    sed -i 's/^memory_limit = .*/memory_limit = 512M/' "${PHP_INI}"
fi

systemctl restart apache2

# --- Installation non interactive, donnees directement sur le NAS ---
if ! ${OCC} status 2>/dev/null | grep -q "installed: true"; then
    ${OCC} maintenance:install \
        --database "mysql" \
        --database-name "${DB_NAME}" \
        --database-user "${DB_USER}" \
        --database-pass "${DB_PASSWORD}" \
        --admin-user "${NC_ADMIN_USER}" \
        --admin-pass "${NC_ADMIN_PASSWORD}" \
        --data-dir "${NFS_MOUNT_POINT}"
else
    echo "Nextcloud deja installe, etape ignoree."
fi

# Domaines de confiance (index 0 = localhost)
${OCC} config:system:set trusted_domains 1 --value=${IP_SRV02}
${OCC} config:system:set trusted_domains 2 --value=srv-lin1-02.${DOMAIN}

echo "Nextcloud installe. Donnees : ${NFS_MOUNT_POINT} (NAS)"

# ============================================================================
# 4. LDAP, DOSSIERS DE GROUPE, QUOTAS, AGENDA
# ============================================================================
echo ""
echo "---- [4/4] Integration LDAP et configuration applicative ----"

# --- Integration LDAP ---
${OCC} app:enable user_ldap
if ! ${OCC} ldap:show-config s01 >/dev/null 2>&1; then
    ${OCC} ldap:create-empty-config
fi

set_ldap() { ${OCC} ldap:set-config s01 "$1" "$2"; }
set_ldap ldapHost                   "${LDAP_HOST}"
set_ldap ldapPort                   "389"
set_ldap ldapAgentName              "${LDAP_ADMIN_DN}"
set_ldap ldapAgentPassword          "${LDAP_ADMIN_PASSWORD}"
set_ldap ldapBase                   "${LDAP_BASE_DN}"
set_ldap ldapBaseUsers              "ou=users,${LDAP_BASE_DN}"
set_ldap ldapBaseGroups             "ou=groupes,${LDAP_BASE_DN}"
set_ldap ldapUserFilterObjectclass  "inetOrgPerson"
set_ldap ldapUserFilter             "(objectclass=inetOrgPerson)"
set_ldap ldapLoginFilterUsername    "1"
set_ldap ldapLoginFilter            "(&(|(objectclass=inetOrgPerson))(uid=%uid))"
set_ldap ldapGroupFilterObjectclass "posixGroup"
set_ldap ldapGroupFilter            "(objectclass=posixGroup)"
set_ldap ldapGroupMemberAssocAttr   "gidNumber"
set_ldap ldapUserDisplayName        "displayName"
# Indispensable : sans cette ligne la configuration est valide mais ignoree
# a l'authentification ("Login failed" alors que le test de connexion passe)
set_ldap ldapConfigurationActive    "1"

${OCC} ldap:test-config s01

# Synchronisation des comptes et groupes LDAP
${OCC} user:list >/dev/null
${OCC} group:list >/dev/null

# --- Quota personnel (repertoire "perso") applique a tous les comptes ---
${OCC} config:app:set files default_quota --value "${QUOTA_PERSO}"

# --- Dossiers de groupe : Clients, Logiciels, Commun ---
${OCC} app:install groupfolders 2>/dev/null || ${OCC} app:enable groupfolders

create_folder() {
    # $1 = nom ; $2 = quota ; renvoie l'id du dossier (existant ou cree)
    local ID
    ID=$(${OCC} groupfolders:list 2>/dev/null | awk -F'|' -v n="$1" '$3 ~ " "n" " {gsub(/ /,"",$2); print $2}')
    if [ -z "${ID}" ]; then
        ID=$(${OCC} groupfolders:create "$1")
    fi
    ${OCC} groupfolders:quota "${ID}" "$2" >/dev/null
    echo "${ID}"
}

ID_CLIENTS=$(create_folder "Clients" "${QUOTA_CLIENTS}")
${OCC} groupfolders:group "${ID_CLIENTS}" manager read write share delete

ID_LOGICIELS=$(create_folder "Logiciels" "${QUOTA_LOGICIELS}")
${OCC} groupfolders:group "${ID_LOGICIELS}" ingenieur read write share delete
${OCC} groupfolders:group "${ID_LOGICIELS}" developpeur read write share delete

ID_COMMUN=$(create_folder "Commun" "${QUOTA_COMMUN}")
${OCC} groupfolders:group "${ID_COMMUN}" manager read                       # lecture seule
${OCC} groupfolders:group "${ID_COMMUN}" ingenieur read write share delete
${OCC} groupfolders:group "${ID_COMMUN}" developpeur read write share delete

echo "Dossiers de groupe : Clients(${ID_CLIENTS}) Logiciels(${ID_LOGICIELS}) Commun(${ID_COMMUN})"

# --- Agenda (POC point 20) ---
# L'App Store renvoie parfois HTTP 429 (Too Many Requests) : installation
# manuelle depuis GitHub en solution de repli.
if ! ${OCC} app:list | grep -q "calendar:"; then
    if ! ${OCC} app:install calendar; then
        cd /tmp
        wget -q "https://github.com/nextcloud-releases/calendar/releases/download/v${CALENDAR_VERSION}/calendar-v${CALENDAR_VERSION}.tar.gz" -O calendar.tar.gz
        tar -xzf calendar.tar.gz -C /var/www/nextcloud/apps/
        chown -R www-data:www-data /var/www/nextcloud/apps/calendar
        rm -f calendar.tar.gz
        cd - >/dev/null
        ${OCC} app:enable calendar
    fi
fi

# ============================================================================
# FIN
# ============================================================================
echo ""
echo "============================================================"
echo " SRV-LIN1-02 - Installation terminee avec succes"
echo "============================================================"
echo " Nextcloud  : https://${IP_SRV02}  (et http://${IP_SRV02})"
echo " Admin      : ${NC_ADMIN_USER}"
echo " Donnees    : ${NFS_MOUNT_POINT} -> ${NAS_IP}:${NAS_NFS_EXPORT}"
echo " LDAP       : ${LDAP_HOST} (configuration s01 active)"
echo " Dossiers   : Clients ${QUOTA_CLIENTS} | Logiciels ${QUOTA_LOGICIELS} | Commun ${QUOTA_COMMUN}"
echo " Quota perso: ${QUOTA_PERSO}"
echo ""
echo " ETAPE MANUELLE : cle SSH depuis le poste client, puis"
echo "                  PasswordAuthentication no dans sshd_config"
echo ""
echo " Tests : df -h | grep nextcloud-data"
echo "         sudo du -sh ${NFS_MOUNT_POINT}"
echo "         ${OCC} ldap:show-config s01 | grep -i active"
echo "         ${OCC} user:list"
echo "============================================================"
