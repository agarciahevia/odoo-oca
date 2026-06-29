#!/bin/bash
set -e

CONF=/etc/odoo/odoo.conf

# Inyecta la master password (admin_passwd) desde la variable de entorno,
# sin volcarla en la imagen. Si no se define, se deja la que haya.
if [ -n "${ODOO_MASTER_PASSWORD}" ]; then
    if grep -q '^admin_passwd' "$CONF"; then
        sed -i "s|^admin_passwd.*|admin_passwd = ${ODOO_MASTER_PASSWORD}|" "$CONF"
    else
        sed -i "/^\[options\]/a admin_passwd = ${ODOO_MASTER_PASSWORD}" "$CONF"
    fi
fi

# Permite sobreescribir nº de workers por env (cada servidor su tamaño)
if [ -n "${ODOO_WORKERS}" ]; then
    sed -i "s|^workers.*|workers = ${ODOO_WORKERS}|" "$CONF"
fi

# --- Addons a medida desde un repo Git (privado opcional) ------------
# CUSTOM_ADDONS_REPO  = https://github.com/tu-cuenta/tu-modulos.git
# CUSTOM_ADDONS_BRANCH= rama (por defecto main)
# CUSTOM_ADDONS_TOKEN = PAT de GitHub (solo lectura) si el repo es privado
if [ -n "${CUSTOM_ADDONS_REPO}" ]; then
    BRANCH="${CUSTOM_ADDONS_BRANCH:-main}"
    URL="${CUSTOM_ADDONS_REPO}"
    if [ -n "${CUSTOM_ADDONS_TOKEN}" ]; then
        # Inyecta el token en la URL https sin dejarlo en logs de git
        URL=$(echo "$URL" | sed -E "s#https://#https://${CUSTOM_ADDONS_TOKEN}@#")
    fi
    if [ -d /mnt/extra-addons/.git ]; then
        echo "[custom-addons] Actualizando ${CUSTOM_ADDONS_REPO}#${BRANCH}"
        git -C /mnt/extra-addons remote set-url origin "$URL"
        git -C /mnt/extra-addons fetch --depth 1 origin "$BRANCH" \
            && git -C /mnt/extra-addons reset --hard "origin/${BRANCH}" \
            || echo "[custom-addons] WARN: no se pudo actualizar"
    else
        echo "[custom-addons] Clonando ${CUSTOM_ADDONS_REPO}#${BRANCH}"
        git clone --depth 1 -b "$BRANCH" "$URL" /mnt/extra-addons \
            || echo "[custom-addons] WARN: no se pudo clonar (¿token/rama correctos?)"
    fi
fi

# Delega en el entrypoint oficial de la imagen odoo:18
exec /entrypoint.sh "$@"
