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

# --- Addons a medida desde uno o VARIOS repos Git --------------------
# CUSTOM_ADDONS = specs separados por espacio; cada uno: url|branch|token
#   (branch y token opcionales). Cada repo se clona en su carpeta y se
#   añade al addons_path. Compatible con el antiguo CUSTOM_ADDONS_REPO.
SPECS="${CUSTOM_ADDONS}"
if [ -n "${CUSTOM_ADDONS_REPO}" ]; then
    SPECS="${SPECS} ${CUSTOM_ADDONS_REPO}|${CUSTOM_ADDONS_BRANCH:-main}|${CUSTOM_ADDONS_TOKEN}"
fi
EXTRA_DIRS=""
if [ -n "${SPECS}" ]; then
    mkdir -p /mnt/custom-addons
    for spec in ${SPECS}; do
        IFS='|' read -r repo_url repo_branch repo_token <<< "${spec}"
        [ -z "${repo_url}" ] && continue
        repo_branch="${repo_branch:-main}"
        name="$(basename "${repo_url}" .git)"
        dest="/mnt/custom-addons/${name}"
        aurl="${repo_url}"
        [ -n "${repo_token}" ] && aurl="$(echo "${repo_url}" | sed -E "s#https://#https://${repo_token}@#")"
        if [ -d "${dest}/.git" ]; then
            echo "[addons] actualizando ${name}#${repo_branch}"
            git -C "${dest}" remote set-url origin "${aurl}"
            git -C "${dest}" fetch --depth 1 origin "${repo_branch}" \
                && git -C "${dest}" reset --hard "origin/${repo_branch}" \
                || echo "[addons] WARN: no se pudo actualizar ${name}"
        else
            echo "[addons] clonando ${name}#${repo_branch}"
            git clone --depth 1 -b "${repo_branch}" "${aurl}" "${dest}" \
                || echo "[addons] WARN: no se pudo clonar ${name} (¿token/rama?)"
        fi
        [ -d "${dest}" ] && EXTRA_DIRS="${EXTRA_DIRS},${dest}"
    done
    # Reconstruye addons_path = base + carpetas de los repos a medida
    if [ -n "${EXTRA_DIRS}" ] && [ -f /etc/odoo/.addons_base ]; then
        BASE="$(cat /etc/odoo/.addons_base)"
        sed -i "s|^addons_path = .*|addons_path = ${BASE}${EXTRA_DIRS}|" "$CONF"
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
