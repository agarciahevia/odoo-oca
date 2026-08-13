#####################################################################
# Odoo + OCA (enterprise-like) — imagen reproducible y actualizable
#
# La VERSIÓN se elige con el build-arg ODOO_VERSION (18.0, 19.0, ...).
# repos.yaml se escribe con ramas 18.0 y se reescriben a ODOO_VERSION
# en el build (sed), así el mismo repos.yaml sirve para cualquier versión.
#####################################################################
ARG ODOO_VERSION=18.0
FROM odoo:${ODOO_VERSION}

# Re-declarar el ARG tras el FROM para poder usarlo abajo
ARG ODOO_VERSION=18.0
ENV ODOO_VERSION=${ODOO_VERSION}

# pip nuevo (bookworm, Odoo 18/19) exige --break-system-packages; via env se
# aplica sin pasar el flag. pip viejo (bullseye, Odoo 16) lo ignora y como no
# tiene PEP-668 instala igual. Así el mismo Dockerfile sirve para 16 y 18/19.
ENV PIP_BREAK_SYSTEM_PACKAGES=1

USER root

# Herramientas de build + git-aggregator
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        python3-pip \
        python3-dev \
        build-essential \
        libsasl2-dev \
        libldap2-dev \
        libssl-dev \
        fontconfig \
        fonts-liberation \
        default-jdk-headless \
    && pip3 install --no-cache-dir git-aggregator \
    && rm -rf /var/lib/apt/lists/*

# Descarga de repos OCA según el manifiesto (ramas reescritas a ODOO_VERSION)
WORKDIR /opt/oca
# repos por versión: usa repos-<ver>.yaml (p.ej. commits pineados en 16.0) si existe,
# si no el repos.yaml genérico (18/19, ramas reescritas a ODOO_VERSION).
COPY repos*.yaml /opt/oca/
RUN F="repos-${ODOO_VERSION}.yaml"; \
    [ -f "/opt/oca/$F" ] || F="repos.yaml"; \
    sed -i "s/18\.0/${ODOO_VERSION}/g" "/opt/oca/$F" && \
    gitaggregate -c "/opt/oca/$F" -j 4

# Dependencias Python extra que necesitan varios módulos OCA / l10n_es
COPY requirements.txt /opt/oca/requirements.txt
RUN pip3 install --no-cache-dir -r /opt/oca/requirements.txt

# Además, instala los requirements.txt que traen los propios repos OCA (cada uno
# lista las external_dependencies de sus módulos, p.ej. pycountry). Así no hay que ir
# dependencia a dependencia. Se EXCLUYEN cryptography/pyOpenSSL: subirlos rompe el
# pyOpenSSL del base image ("module 'lib' has no attribute 'GEN_EMAIL'" -> base no
# carga) y compilar cryptography nuevo en bullseye (Odoo 16) necesita Rust -> build
# roto. El par del base image ya es compatible; se deja tal cual.
RUN for r in $(find /opt/oca -mindepth 2 -maxdepth 2 -name requirements.txt); do \
        grep -ivE '^(cryptography|pyopenssl)' "$r" > /tmp/ocareq.txt 2>/dev/null || true; \
        echo "[deps] $r"; pip3 install --no-cache-dir -r /tmp/ocareq.txt || echo "[deps] WARN: falló $r"; \
    done

# Módulos vendorizados (terceros no-OCA) específicos por versión: vendor/<ver>/<modulo>.
# Se copia solo la carpeta de la versión que se compila a /opt/oca/vendor-extra,
# que el paso de addons_path de abajo recoge automáticamente.
COPY vendor/ /opt/vendor/
RUN if [ -d "/opt/vendor/${ODOO_VERSION}" ]; then \
        mkdir -p /opt/oca/vendor-extra && \
        cp -r /opt/vendor/${ODOO_VERSION}/. /opt/oca/vendor-extra/ ; \
    fi

# Config base de Odoo (sin addons_path; se genera abajo dinámicamente)
COPY odoo.conf /etc/odoo/odoo.conf

# Genera addons_path con TODOS los repos descargados + carpeta de addons propios.
# Así el addons_path se adapta solo a lo que haya en repos.yaml.
RUN ADDONS=$(find /opt/oca -mindepth 1 -maxdepth 1 -type d | sort | paste -sd, -) \
    && BASE="/usr/lib/python3/dist-packages/odoo/addons,/mnt/extra-addons,${ADDONS}" \
    && printf 'addons_path = %s\n' "$BASE" >> /etc/odoo/odoo.conf \
    && printf '%s' "$BASE" > /etc/odoo/.addons_base \
    && mkdir -p /mnt/extra-addons /mnt/custom-addons \
    && chown -R odoo:odoo /opt/oca /mnt/extra-addons /mnt/custom-addons /etc/odoo

# Entrypoint propio: inyecta la master password y delega en el oficial
COPY entrypoint.sh /opt/entrypoint.sh
RUN chmod +x /opt/entrypoint.sh

USER odoo
ENTRYPOINT ["/opt/entrypoint.sh"]
CMD ["odoo"]
