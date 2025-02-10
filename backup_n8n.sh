#!/bin/bash

# Configuration
BACKUP_DIR="<chemin_vers_le_dossier_de_sauvegarde>"
DATA_FOLDER="<chemin_vers_le_dossier_de_donnees>"  # Le même que dans votre .env
RETENTION_DAYS=30
DATE=$(date +%Y-%m-%d_%H-%M-%S)

# Configuration SFTP
SFTP_USER="<nom_utilisateur_sftp>"
SFTP_HOST="<adresse_ip_ou_nom_de_domaine_du_serveur_distant>"
SFTP_PORT="<port_sftp>"
SSH_KEY="<chemin_vers_la_cle_ssh>"
REMOTE_DIR="<chemin_vers_le_dossier_distant_sur_le_serveur>"


# Charger les variables d'environnement depuis le fichier .env
if [ -f "$DATA_FOLDER/.env" ]; then
    source "$DATA_FOLDER/.env"
fi

# Création du dossier de backup s'il n'existe pas
mkdir -p "$BACKUP_DIR"

# Fonction pour logger les messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Vérification de l'espace disque disponible
check_disk_space() {
    local available_space=$(df -P "$BACKUP_DIR" | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 1048576 ]; then  # 1 GB en KB
        log_message "ERREUR: Espace disque insuffisant (moins de 1GB disponible)"
        exit 1
    fi
}

# Fonction de nettoyage en cas d'erreur
cleanup() {
    log_message "Nettoyage des fichiers temporaires..."
    rm -f "$BACKUP_DIR/temp_*"
}

trap cleanup EXIT

# Se déplacer dans le répertoire du docker-compose.yml
cd "$DATA_FOLDER"

# Vérification de l'espace disque
check_disk_space

# Arrêt des conteneurs
log_message "Arrêt des conteneurs n8n..."
docker compose down

# 1. Sauvegarde des volumes Docker
log_message "Sauvegarde des volumes Docker..."

log_message "Sauvegarde du volume n8n_data..."
docker run --rm \
    -v n8n_data:/source:ro \
    -v "$BACKUP_DIR:/backup" \
    ubuntu tar czf "/backup/n8n_data_$DATE.tar.gz" -C /source .

log_message "Sauvegarde du volume caddy_data..."
docker run --rm \
    -v caddy_data:/source:ro \
    -v "$BACKUP_DIR:/backup" \
    ubuntu tar czf "/backup/caddy_data_$DATE.tar.gz" -C /source .

# 2. Sauvegarde des dossiers du DATA_FOLDER
log_message "Sauvegarde des dossiers du DATA_FOLDER..."
tar -czf "$BACKUP_DIR/data_folder_$DATE.tar.gz" \
    -C "$DATA_FOLDER" \
    caddy_config \
    local_files

# Redémarrage des conteneurs
log_message "Redémarrage des conteneurs..."
docker compose up -d

# Vérification des sauvegardes
if [ -f "$BACKUP_DIR/n8n_data_$DATE.tar.gz" ] && \
   [ -f "$BACKUP_DIR/caddy_data_$DATE.tar.gz" ] && \
   [ -f "$BACKUP_DIR/data_folder_$DATE.tar.gz" ]; then
    log_message "Toutes les sauvegardes ont été créées avec succès"
else
    log_message "ERREUR: Au moins une sauvegarde a échoué"
    exit 1
fi

# Suppression des anciennes sauvegardes
log_message "Nettoyage des anciennes sauvegardes..."
find "$BACKUP_DIR" -name "*_*.tar.gz" -mtime +$RETENTION_DAYS -delete

# Vérification du statut de n8n
log_message "Attente du démarrage complet de n8n..."
for i in {1..12}; do  # Attendre jusqu'à 2 minutes (12 x 10 secondes)
    if [ -n "$SUBDOMAIN" ] && [ -n "$DOMAIN_NAME" ]; then
        if curl -s -f "https://$SUBDOMAIN.$DOMAIN_NAME/healthz" > /dev/null; then
            log_message "N8N est opérationnel"
            break
        fi
    else
        # Si les variables d'environnement ne sont pas disponibles, vérifier le port local
        if curl -s -f "http://localhost:5678/healthz" > /dev/null; then
            log_message "N8N est opérationnel (vérifié sur le port local)"
            break
        fi
    fi
    
    if [ $i -eq 12 ]; then
        log_message "ATTENTION: N8N n'est pas complètement opérationnel après 2 minutes"
    else
        sleep 10
    fi
done

# Envoi des sauvegardes via SFTP
log_message "Envoi des sauvegardes vers le serveur distant..."

lftp <<EOF
open -u $SFTP_USER, sftp://$SFTP_HOST:$SFTP_PORT
set sftp:connect-program "ssh -o StrictHostKeyChecking=accept-new -a -x -i $SSH_KEY"
mirror -R $BACKUP_DIR/ $REMOTE_DIR/
quit
EOF


log_message "Processus de sauvegarde terminé"
