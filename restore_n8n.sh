#!/bin/bash

# Configuration
BACKUP_DIR="<chemin_vers_le_dossier_de_sauvegarde>"
DATA_FOLDER="<chemin_vers_le_dossier_de_donnees>"

# Fonction pour logger les messages
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Fonction pour trouver le fichier de backup le plus récent
get_latest_backup() {
    local prefix="$1"
    ls -t "$BACKUP_DIR/${prefix}_"*.tar.gz 2>/dev/null | head -n1
}

# Se déplacer dans le répertoire du docker-compose.yml
cd "$DATA_FOLDER"

# Trouver les dernières sauvegardes
N8N_BACKUP=$(get_latest_backup "n8n_data")
CADDY_BACKUP=$(get_latest_backup "caddy_data")
DATA_BACKUP=$(get_latest_backup "data_folder")

# Vérifier que toutes les sauvegardes existent
if [ -z "$N8N_BACKUP" ] || [ -z "$CADDY_BACKUP" ] || [ -z "$DATA_BACKUP" ]; then
    log_message "ERREUR: Impossible de trouver toutes les sauvegardes nécessaires"
    exit 1
fi

log_message "Sauvegardes trouvées :"
log_message "- N8N: $(basename "$N8N_BACKUP")"
log_message "- Caddy: $(basename "$CADDY_BACKUP")"
log_message "- Data: $(basename "$DATA_BACKUP")"

# Demander confirmation
read -p "Voulez-vous restaurer ces sauvegardes ? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_message "Restauration annulée"
    exit 1
fi

# 1. Arrêter les conteneurs
log_message "Arrêt des conteneurs..."
docker compose down

# 2. Restaurer les volumes Docker
log_message "Restauration du volume n8n_data..."
docker run --rm \
    -v n8n_data:/destination \
    -v "$BACKUP_DIR:/backup" \
    ubuntu bash -c "cd /destination && tar xzf /backup/$(basename "$N8N_BACKUP")"

log_message "Restauration du volume caddy_data..."
docker run --rm \
    -v caddy_data:/destination \
    -v "$BACKUP_DIR:/backup" \
    ubuntu bash -c "cd /destination && tar xzf /backup/$(basename "$CADDY_BACKUP")"

# 3. Restaurer les dossiers du DATA_FOLDER
log_message "Restauration des dossiers du DATA_FOLDER..."
cd "$DATA_FOLDER"
tar xzf "$DATA_BACKUP"

# 4. Redémarrer les conteneurs
log_message "Redémarrage des conteneurs..."
docker compose up -d

# 5. Vérifier que n8n démarre correctement
log_message "Attente du démarrage complet de n8n..."
for i in {1..12}; do  # Attendre jusqu'à 2 minutes
    if curl -s -f "http://localhost:5678/healthz" > /dev/null; then
        log_message "N8N est opérationnel"
        exit 0
    fi
    
    if [ $i -eq 12 ]; then
        log_message "ATTENTION: N8N n'est pas complètement opérationnel après 2 minutes"
    else
        sleep 10
    fi
done

log_message "Restauration terminée"
