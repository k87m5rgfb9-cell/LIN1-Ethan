#!/bin/bash
#
# ============================================================================
# SRV-LIN1-01.sh
# ----------------------------------------------------------------------------
# Script d'installation et de configuration automatisee de SRV-LIN1-01
# Module LIN1 - Infrastructure LIN1-LABO
# Auteur : Ethan - CPNV
#
# Ce script configure, sur une Debian 12 fraichement installee :
#   1. Le reseau (interface interne statique + routage/NAT = passerelle)
#   2. Le serveur DNS (BIND9) avec zones directe et inverse
#   3. Le serveur DHCP (isc-dhcp-server)
#   4. Le serveur LDAP (OpenLDAP), structure + groupes + utilisateurs
#   5. LDAP Account Manager (LAM), interface web de gestion de l'annuaire
#
# PREREQUIS :
#   - Debian 12 (Bookworm) fraichement installee, avec 2 interfaces reseau :
#       ens33 = NAT VMware (VMnet8, sortie Internet)
#       ens34 = Host-only (VMnet2, reseau interne 10.10.40.0/24)
#   - Le DHCP integre de VMware doit etre DESACTIVE sur VMnet2.
#   - Execution en root :
#       su -
#       bash SRV-LIN1-01.sh
#
# Le script peut etre rejoue : les etapes deja effectuees sont detectees.
# ============================================================================

# ----------------------------------------------------------------------------
# 0. VERIFICATION DES DROITS
# ----------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit etre execute en tant que root : su - puis bash SRV-LIN1-01.sh"
    exit 1
fi

if ! command -v sudo >/dev/null 2>&1; then
    apt update
    apt install -y sudo
fi

set -e

# ----------------------------------------------------------------------------
# 0. VARIABLES DE CONFIGURATION
# ----------------------------------------------------------------------------
ADMIN_USER="ethan"                 # Utilisateur d'administration (ajoute au groupe sudo)

IFACE_NAT="ens33"                  # Interface NAT (sortie Internet)
IFACE_LAN="ens34"                  # Interface interne (VMnet2)
IP_SRV01="10.10.40.11"
NETMASK="255.255.255.0"
NETWORK="10.10.40.0"
BROADCAST="10.10.40.255"
DOMAIN="lin1-labo.local"
BASE_DN="dc=lin1-labo,dc=local"
REVERSE_ZONE="40.10.10.in-addr.arpa"
REVERSE_FILE="db.10.10.40"

DHCP_RANGE_START="10.10.40.110"
DHCP_RANGE_END="10.10.40.119"

LDAP_ADMIN_PASSWORD="Pa\$\$w0rd"    # Mot de passe administrateur LDAP (cn=admin)
USER_DEFAULT_PASSWORD="Pa\$\$w0rd"  # Mot de passe des utilisateurs LDAP

CPNV_DNS_1="10.229.60.22"          # DNS internes du CPNV (port 53 sortant filtre)
CPNV_DNS_2="10.229.28.22"          # -> a adapter hors du reseau CPNV

LAM_VERSION="9.2"

echo "============================================================"
echo " SRV-LIN1-01 - Debut de l'installation automatisee"
echo "============================================================"
echo "Interface NAT (sortie internet)  : ${IFACE_NAT}"
echo "Interface interne (VMnet2)       : ${IFACE_LAN}"

for IFACE in "${IFACE_NAT}" "${IFACE_LAN}"; do
    if ! ip link show "${IFACE}" >/dev/null 2>&1; then
        echo "Interface ${IFACE} introuvable : verifier avec 'ip a' et adapter les variables."
        exit 1
    fi
done

hostnamectl set-hostname srv-lin1-01
sed -i '/127.0.1.1/d' /etc/hosts
echo "127.0.1.1 srv-lin1-01.${DOMAIN} srv-lin1-01" >> /etc/hosts
echo "Nom de machine configure : srv-lin1-01"

if id "${ADMIN_USER}" >/dev/null 2>&1; then
    usermod -aG sudo "${ADMIN_USER}"
fi

# ============================================================================
# 1. CONFIGURATION RESEAU + PASSERELLE
# ============================================================================
echo ""
echo "---- [1/5] Configuration reseau et passerelle ----"

cat > /etc/network/interfaces <<EOF
source /etc/network/interfaces.d/*

# Interface loopback
auto lo
iface lo inet loopback

# Interface NAT - sortie Internet (VMnet8)
allow-hotplug ${IFACE_NAT}
iface ${IFACE_NAT} inet dhcp

# Interface interne LIN1-LABO (VMnet2)
allow-hotplug ${IFACE_LAN}
iface ${IFACE_LAN} inet static
    address ${IP_SRV01}
    netmask ${NETMASK}
EOF

systemctl restart networking || true

# Routage IP (persistant)
if grep -q "^#net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    sed -i 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
elif ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p

apt update
apt install -y vim iptables curl

# iptables-persistent : reponses preconfigurees AVANT l'installation
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent

# On vide les chaines concernees pour eviter les doublons si le script est rejoue
iptables -t nat -F POSTROUTING
iptables -F FORWARD
iptables -t nat -A POSTROUTING -o ${IFACE_NAT} -j MASQUERADE
iptables -A FORWARD -i ${IFACE_LAN} -o ${IFACE_NAT} -j ACCEPT
iptables -A FORWARD -i ${IFACE_NAT} -o ${IFACE_LAN} -m state --state RELATED,ESTABLISHED -j ACCEPT
netfilter-persistent save

echo "Reseau configure : ${IFACE_LAN} = ${IP_SRV01}, routage NAT actif."

# ============================================================================
# 2. SERVEUR DNS (BIND9)
# ============================================================================
echo ""
echo "---- [2/5] Installation et configuration du DNS (BIND9) ----"

apt install -y bind9 bind9utils bind9-doc dnsutils

cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";

    recursion yes;
    allow-recursion { ${NETWORK}/24; 127.0.0.1; };
    listen-on { ${IP_SRV01}; 127.0.0.1; };
    allow-transfer { none; };

    forwarders {
        ${CPNV_DNS_1};
        ${CPNV_DNS_2};
    };

    dnssec-validation no;
    listen-on-v6 { none; };
};
EOF

# Ecriture complete (et non ajout) : evite les zones en double si le script est rejoue
cat > /etc/bind/named.conf.local <<EOF
zone "${DOMAIN}" {
    type master;
    file "/etc/bind/db.${DOMAIN}";
};

zone "${REVERSE_ZONE}" {
    type master;
    file "/etc/bind/${REVERSE_FILE}";
};
EOF

cat > /etc/bind/db.${DOMAIN} <<EOF
\$TTL    604800
@       IN      SOA     srv-lin1-01.${DOMAIN}. admin.${DOMAIN}. (
                              3         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@               IN      NS      srv-lin1-01.${DOMAIN}.
srv-lin1-01     IN      A       10.10.40.11
srv-lin1-02     IN      A       10.10.40.22
nas-lin1-01     IN      A       10.10.40.33
EOF

cat > /etc/bind/${REVERSE_FILE} <<EOF
\$TTL    604800
@       IN      SOA     srv-lin1-01.${DOMAIN}. admin.${DOMAIN}. (
                              3         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@       IN      NS      srv-lin1-01.${DOMAIN}.
11      IN      PTR     srv-lin1-01.${DOMAIN}.
22      IN      PTR     srv-lin1-02.${DOMAIN}.
33      IN      PTR     nas-lin1-01.${DOMAIN}.
EOF

named-checkconf
named-checkzone ${DOMAIN} /etc/bind/db.${DOMAIN}
named-checkzone ${REVERSE_ZONE} /etc/bind/${REVERSE_FILE}

systemctl restart named
systemctl enable named

echo "DNS configure : zones ${DOMAIN} et ${REVERSE_ZONE}."

# ============================================================================
# 3. SERVEUR DHCP (isc-dhcp-server)
# ============================================================================
echo ""
echo "---- [3/5] Installation et configuration du DHCP ----"

apt install -y isc-dhcp-server || true   # echec normal du demarrage avant configuration
systemctl stop isc-dhcp-server || true

cat > /etc/dhcp/dhcpd.conf <<EOF
# Configuration DHCP pour LIN1-LABO
option domain-name "${DOMAIN}";
option domain-name-servers ${IP_SRV01};

default-lease-time 600;
max-lease-time 7200;
ddns-update-style none;
authoritative;

subnet ${NETWORK} netmask ${NETMASK} {
    range ${DHCP_RANGE_START} ${DHCP_RANGE_END};
    option routers ${IP_SRV01};
    option domain-name-servers ${IP_SRV01};
    option domain-name "${DOMAIN}";
    option broadcast-address ${BROADCAST};
}
EOF

# Ecoute uniquement sur l'interface interne (jamais ens33 : conflit avec le NAT VMware)
sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"${IFACE_LAN}\"/" /etc/default/isc-dhcp-server

dhcpd -t -cf /etc/dhcp/dhcpd.conf
systemctl restart isc-dhcp-server
systemctl enable isc-dhcp-server

echo "DHCP configure : plage ${DHCP_RANGE_START} - ${DHCP_RANGE_END} sur ${IFACE_LAN}."

# ============================================================================
# 4. SERVEUR LDAP (OpenLDAP) + PEUPLEMENT
# ============================================================================
echo ""
echo "---- [4/5] Installation, configuration et peuplement de LDAP ----"

debconf-set-selections <<EOF
slapd slapd/internal/generated_adminpw password ${LDAP_ADMIN_PASSWORD}
slapd slapd/internal/adminpw password ${LDAP_ADMIN_PASSWORD}
slapd slapd/password2 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/password1 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/domain string ${DOMAIN}
slapd shared/organization string LIN1-LABO
slapd slapd/backend string MDB
slapd slapd/purge_database boolean false
slapd slapd/move_old_database boolean true
slapd slapd/no_configuration boolean false
EOF

DEBIAN_FRONTEND=noninteractive apt install -y slapd ldap-utils

# dpkg-reconfigure recree une base vide : on ne le lance que si l'annuaire
# n'a pas encore le bon suffixe (sinon un rejeu du script effacerait les comptes).
if ! slapcat 2>/dev/null | grep -q "^dn: ${BASE_DN}$"; then
    dpkg-reconfigure -f noninteractive slapd
fi

# Le preseed n'est pas toujours repris : on force le mot de passe admin
LDAP_ADMIN_HASH=$(slappasswd -s "${LDAP_ADMIN_PASSWORD}")
cat > /tmp/admin_pw.ldif <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: ${LDAP_ADMIN_HASH}
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/admin_pw.ldif
rm -f /tmp/admin_pw.ldif

# --- Structure : OU et groupes (memes noms que LAM et Nextcloud) ---
cat > /tmp/base.ldif <<EOF
dn: ou=users,${BASE_DN}
objectClass: organizationalUnit
ou: users

dn: ou=groupes,${BASE_DN}
objectClass: organizationalUnit
ou: groupes

dn: cn=manager,ou=groupes,${BASE_DN}
objectClass: posixGroup
cn: manager
gidNumber: 5000

dn: cn=ingenieur,ou=groupes,${BASE_DN}
objectClass: posixGroup
cn: ingenieur
gidNumber: 5001

dn: cn=developpeur,ou=groupes,${BASE_DN}
objectClass: posixGroup
cn: developpeur
gidNumber: 5002
EOF

# --- Utilisateurs ---
add_user() {
    # $1=uid  $2=sn  $3=givenName  $4=uidNumber  $5=gidNumber
    cat <<EOF

dn: uid=$1,ou=users,${BASE_DN}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: $1
sn: $2
givenName: $3
cn: $1
displayName: $1
uidNumber: $4
gidNumber: $5
userPassword: {CRYPT}x
gecos: $1
loginShell: /bin/bash
homeDirectory: /home/$1
EOF
}

{
    add_user man01 Manager01     Man 10000 5000
    add_user man02 Manager02     Man 10001 5000
    add_user ing01 Ingenieur01   Ing 10002 5001
    add_user ing02 Ingenieur02   Ing 10003 5001
    add_user dev01 Developpeur01 Dev 10004 5002
} > /tmp/users.ldif

# Injection idempotente : on n'ajoute que si l'entree n'existe pas
if ! ldapsearch -x -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" \
        -b "ou=groupes,${BASE_DN}" -s base >/dev/null 2>&1; then
    ldapadd -x -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/base.ldif
    echo "Structure et groupes crees."
else
    echo "Structure LDAP deja presente, etape ignoree."
fi

if ! ldapsearch -x -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" \
        -b "uid=man01,ou=users,${BASE_DN}" -s base >/dev/null 2>&1; then
    ldapadd -x -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/users.ldif
    echo "Utilisateurs crees."
else
    echo "Utilisateurs LDAP deja presents, etape ignoree."
fi

# Mots de passe haches (SSHA) via ldappasswd, plutot qu'en clair dans le LDIF
for USERID in man01 man02 ing01 ing02 dev01; do
    ldappasswd -x -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" \
        -s "${USER_DEFAULT_PASSWORD}" "uid=${USERID},ou=users,${BASE_DN}"
done

rm -f /tmp/base.ldif /tmp/users.ldif

NB_USERS=$(ldapsearch -x -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" \
    -b "ou=users,${BASE_DN}" "(objectClass=inetOrgPerson)" uid 2>/dev/null | grep -c "^uid:" || true)
echo "LDAP configure : 3 groupes, ${NB_USERS} utilisateurs."

# ============================================================================
# 5. LDAP ACCOUNT MANAGER (LAM)
# ============================================================================
echo ""
echo "---- [5/5] Installation de LDAP Account Manager ----"

apt install -y apache2 php php-ldap php-mbstring php-zip php-gd php-curl php-xml unzip wget

if ! dpkg -l | grep -q "^ii  ldap-account-manager"; then
    cd /tmp
    LAM_DEB="ldap-account-manager_${LAM_VERSION}-1_all.deb"
    wget -q "https://github.com/LDAPAccountManager/lam/releases/download/${LAM_VERSION}/${LAM_DEB}" -O "${LAM_DEB}"
    apt install -y "./${LAM_DEB}"
    rm -f "${LAM_DEB}"
    cd - >/dev/null
fi
systemctl enable --now apache2

echo "LAM installe : http://${IP_SRV01}/lam"

# ============================================================================
# RESOLVEUR DNS LOCAL (en dernier, une fois BIND fonctionnel)
# ============================================================================
echo ""
echo "---- Configuration finale du resolveur DNS local ----"

# Empeche le client DHCP de l'interface NAT d'ecraser resolv.conf
if ! grep -q "supersede domain-name-servers" /etc/dhcp/dhclient.conf; then
    cat >> /etc/dhcp/dhclient.conf <<EOF

# Forcer l'utilisation du DNS local (evite l'ecrasement par le DHCP du NAT)
supersede domain-name-servers ${IP_SRV01};
supersede domain-name "${DOMAIN}";
EOF
fi

cat > /etc/resolv.conf <<EOF
domain ${DOMAIN}
search ${DOMAIN}
nameserver ${IP_SRV01}
EOF

# ============================================================================
# FIN
# ============================================================================
echo ""
echo "============================================================"
echo " SRV-LIN1-01 - Installation terminee avec succes"
echo "============================================================"
echo " Reseau     : ${IFACE_LAN} = ${IP_SRV01} | passerelle NAT sur ${IFACE_NAT}"
echo " DNS        : zones ${DOMAIN} et ${REVERSE_ZONE}"
echo " DHCP       : ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
echo " LDAP       : ${BASE_DN} (ou=users, ou=groupes)"
echo " LAM        : http://${IP_SRV01}/lam"
echo ""
echo " ETAPES MANUELLES :"
echo "  - LAM > LAM configuration (mdp par defaut : lam) > profil 'lam' :"
echo "      Server address : ldap://localhost:389"
echo "      Tree suffix    : ${BASE_DN}"
echo "      Valid users    : cn=admin,${BASE_DN}"
echo "      Account types  : Users  = ou=users,${BASE_DN}"
echo "                       Groups = ou=groupes,${BASE_DN}"
echo "    (refuser la creation de ou=People / ou=group proposee par LAM)"
echo "  - Cle SSH : depuis le poste client, deposer id_rsa.pub dans"
echo "    ~/.ssh/authorized_keys, puis PasswordAuthentication no"
echo ""
echo " Tests : dig @127.0.0.1 srv-lin1-02.${DOMAIN}"
echo "         dig @127.0.0.1 -x ${IP_SRV01}"
echo "         systemctl status named isc-dhcp-server slapd"
echo "============================================================"
