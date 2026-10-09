# LIN1 — Infrastructure réseau sur solutions libres

Scripts d'automatisation de l'infrastructure **LIN1-LABO** réalisée dans le cadre du module LIN1 (CPNV — Technicien ES en Exploitation et Infrastructure).

Auteur : Ethan

## Contenu

| Script | Machine | Rôle |
|---|---|---|
| [`SRV-LIN1-01.sh`](SRV-LIN1-01.sh) | SRV-LIN1-01 (`10.10.40.11`) | Réseau et passerelle (routage + NAT), DNS (BIND9), DHCP (isc-dhcp-server), annuaire LDAP (OpenLDAP) avec peuplement, LDAP Account Manager |
| [`SRV-LIN1-02.sh`](SRV-LIN1-02.sh) | SRV-LIN1-02 (`10.10.40.22`) | Réseau, montage NFS du NAS, Nextcloud 33 (Apache, MariaDB, PHP 8.2) en HTTP/HTTPS, intégration LDAP, dossiers de groupe, quotas, agenda |

## Architecture

```
                 Internet
                    │ (NAT VMware, VMnet8)
            ┌───────┴────────┐
            │  SRV-LIN1-01   │  passerelle · DNS · DHCP · LDAP · LAM
            │  10.10.40.11   │
            └───────┬────────┘
                    │  réseau interne 10.10.40.0/24 (VMnet2)
   ┌────────────────┼─────────────────┬──────────────────┐
┌──┴───────────┐ ┌──┴───────────┐ ┌───┴──────────┐ ┌─────┴──────────┐
│ SRV-LIN1-02  │ │ NAS-LIN1-01  │ │ Client Linux │ │ Client Windows │
│ 10.10.40.22  │ │ 10.10.40.33  │ │   DHCP .11x  │ │   DHCP .11x    │
│  Nextcloud   │ │ RAID 1 · NFS │ └──────────────┘ └────────────────┘
└──────────────┘ └──────────────┘
```

Domaine : `lin1-labo.local` — Base LDAP : `dc=lin1-labo,dc=local`

## Prérequis

- **Debian 12 (Bookworm)** fraîchement installée (image netinst, uniquement « serveur SSH » + « utilitaires usuels du système »).
- **SRV-LIN1-01** : deux cartes réseau — `ens33` en NAT (accès Internet), `ens34` sur le réseau interne.
- **SRV-LIN1-02** : une carte `ens33` sur le réseau interne.
- Le service DHCP intégré de VMware doit être **désactivé** sur le réseau interne.
- Pour SRV-LIN1-02 : SRV-LIN1-01 opérationnel, et NAS-LIN1-01 (OpenMediaVault) exportant `/export/nextcloud-data` vers `10.10.40.22` avec les options `rw,no_root_squash`.

## Utilisation

Ordre d'exécution : **SRV-LIN1-01** → NAS-LIN1-01 (configuré via son interface web) → **SRV-LIN1-02**.

```bash
# copie depuis le poste d'administration
scp SRV-LIN1-01.sh ethan@<ip-de-la-vm>:~/

# sur la VM, en root
su -
cd /home/ethan
sed -i 's/\r$//' SRV-LIN1-01.sh      # retire les fins de ligne Windows éventuelles
nohup bash SRV-LIN1-01.sh > install.log 2>&1 &
tail -f install.log
```

Les scripts redémarrent le réseau : une session SSH peut être coupée en cours d'exécution, d'où l'usage de `nohup`. Sur SRV-LIN1-02, l'adresse passe de l'IP DHCP à `10.10.40.22` : se reconnecter sur la nouvelle adresse et reprendre le suivi du journal.

## Caractéristiques

- **Arrêt sur erreur** (`set -e`) et contrôles syntaxiques (`named-checkconf`, `named-checkzone`, `dhcpd -t`) avant chaque redémarrage de service.
- **Rejouables** : les étapes déjà effectuées sont détectées (entrées LDAP existantes, Nextcloud déjà installé, dossiers de groupe existants) ; les règles NAT et les zones DNS sont réécrites sans doublon.
- **Mots de passe LDAP hachés** (SSHA via `ldappasswd`), et non stockés en clair dans les fichiers LDIF.
- **Variables regroupées en tête de script** : adresses, interfaces, redirecteurs DNS, mots de passe, quotas.

## Étapes manuelles

Volontairement non automatisées :

- **Profil LAM** (`http://10.10.40.11/lam`) : adresse du serveur, suffixe de l'arbre et suffixes `ou=users` / `ou=groupes`. La marche à suivre est affichée à la fin de `SRV-LIN1-01.sh`.
- **Authentification SSH par clé** : la clé privée appartient au poste client ; elle est déposée dans `~/.ssh/authorized_keys` avant de passer `PasswordAuthentication no`.

## Avertissements

- Les **redirecteurs DNS** (`10.229.60.22`, `10.229.28.22`) sont ceux du réseau CPNV, qui filtre le DNS sortant. Les adapter hors de ce réseau.
- Les mots de passe définis dans les variables (`Pa$$w0rd`) sont des **valeurs de test** : à remplacer avant tout usage réel.
- L'option NFS `no_root_squash` est nécessaire au fonctionnement du script mais affaiblit l'isolation entre le serveur et le NAS ; elle est compensée par la restriction de l'export à une seule adresse IP.
- Le certificat HTTPS de Nextcloud est **auto-signé** : le navigateur affiche un avertissement.

## Tests de validation

```bash
# SRV-LIN1-01
dig @127.0.0.1 srv-lin1-02.lin1-labo.local +short     # 10.10.40.22
dig @127.0.0.1 -x 10.10.40.11 +short                  # srv-lin1-01.lin1-labo.local.
systemctl is-active named isc-dhcp-server slapd apache2
ldapwhoami -x -D "uid=man01,ou=users,dc=lin1-labo,dc=local" -w 'Pa$$w0rd'

# SRV-LIN1-02
df -h | grep nextcloud-data
sudo -u www-data php /var/www/nextcloud/occ ldap:show-config s01 | grep -i active
sudo -u www-data php /var/www/nextcloud/occ groupfolders:list
```

Les deux scripts ont été validés sur des machines Debian 12 vierges.
