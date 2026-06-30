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

# --- Inicialización de BD + instalación de módulos (opcional) --------
# ODOO_DB              = nombre de la base de datos Odoo a crear/usar
# ODOO_INSTALL_MODULES = lista separada por comas de módulos a instalar
# Se ejecuta en el primer arranque y cada vez que cambie la lista
# (instalar un módulo ya instalado es un no-op).
if [ -n "${ODOO_DB}" ]; then
    WANT="base${ODOO_INSTALL_MODULES:+,${ODOO_INSTALL_MODULES}}"
    DBARGS="--db_host=${HOST} --db_port=${PORT:-5432} --db_user=${USER} --db_password=${PASSWORD}"
    LANG_OPT=""
    [ -n "${ODOO_LANGUAGE}" ] && LANG_OPT="--load-language=${ODOO_LANGUAGE}"
    FLAG="/var/lib/odoo/.installed-${ODOO_DB}"
    STAMP="${WANT}|${ODOO_LANGUAGE}|${ODOO_COUNTRY}|${ODOO_TZ}"
    PREV="$(cat "$FLAG" 2>/dev/null || echo '')"
    if [ "${STAMP}" != "$PREV" ]; then
        echo "[init] BD '${ODOO_DB}': ${WANT} | idioma=${ODOO_LANGUAGE:-en_US} país=${ODOO_COUNTRY:-} tz=${ODOO_TZ:-}"
        if odoo -d "${ODOO_DB}" -i "${WANT}" ${LANG_OPT} ${DBARGS} --stop-after-init --no-http; then
            # Fija idioma + zona horaria de los usuarios y país de la empresa
            PY="users = env['res.users'].search([])"
            [ -n "${ODOO_LANGUAGE}" ] && PY="${PY}; users.write({'lang': '${ODOO_LANGUAGE}'})"
            [ -n "${ODOO_TZ}" ] && PY="${PY}; users.write({'tz': '${ODOO_TZ}'})"
            if [ -n "${ODOO_COUNTRY}" ]; then
                PY="${PY}; c = env['res.country'].search([('code','=','${ODOO_COUNTRY}')], limit=1)"
                PY="${PY}; env['res.company'].search([]).mapped('partner_id').write({'country_id': c.id}) if c else None"
            fi
            PY="${PY}; env.cr.commit()"
            echo "$PY" | odoo shell -d "${ODOO_DB}" ${DBARGS} --no-http 2>/dev/null || true
            echo "${STAMP}" > "$FLAG"
        else
            echo "[init] WARN: la inicialización/instalación falló"
        fi
    fi
fi

# Delega en el entrypoint oficial de la imagen odoo:18
exec /entrypoint.sh "$@"
