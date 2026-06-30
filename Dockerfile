#####################################################################
# Odoo 18 + OCA (enterprise-like) — imagen reproducible y actualizable
#
# El conjunto de repos OCA se define en repos.yaml y se descarga en
# build con git-aggregator. Para actualizar: cambia repos.yaml y
# vuelve a hacer el deploy en Dokploy (rebuild).
#####################################################################
FROM odoo:18.0

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

# Descarga de repos OCA (rama 18.0) según el manifiesto
WORKDIR /opt/oca
COPY repos.yaml /opt/oca/repos.yaml
RUN gitaggregate -c /opt/oca/repos.yaml -j 4

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
