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

USER root

# Herramientas de build + git-aggregator
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        git \
        python3-pip \
        build-essential \
        libsasl2-dev \
        libldap2-dev \
        libssl-dev \
        fontconfig \
        fonts-liberation \
        default-jdk-headless \
    && pip3 install --break-system-packages --no-cache-dir git-aggregator \
    && rm -rf /var/lib/apt/lists/*

# Descarga de repos OCA según el manifiesto (ramas reescritas a ODOO_VERSION)
WORKDIR /opt/oca
COPY repos.yaml /opt/oca/repos.yaml
RUN sed -i "s/18\.0/${ODOO_VERSION}/g" /opt/oca/repos.yaml \
    && gitaggregate -c /opt/oca/repos.yaml -j 4

# Dependencias Python extra que necesitan varios módulos OCA / l10n_es
COPY requirements.txt /opt/oca/requirements.txt
RUN pip3 install --break-system-packages --no-cache-dir -r /opt/oca/requirements.txt

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
