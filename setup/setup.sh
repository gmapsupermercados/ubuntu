#!/bin/bash
# ============================================
# Domínio + DNS + Wallpaper + Suporte Remoto + Visuais (dark + dock bottom)
# Script robusto e automático
# ============================================

set -euo pipefail
IFS=$'\n\t'

# -------------------------------
# LOCKFILE
# -------------------------------
LOCKFILE="/var/lock/setup.lock"
exec 200>"$LOCKFILE"
flock -n 200 || { echo "❌ Outro processo deste script já está rodando."; exit 1; }
trap 'flock -u 200' EXIT

# -------------------------------
# LOGS
# -------------------------------
LOGFILE="/var/log/setup.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOGFILE"; }
error_exit() { log "❌ ERRO: $*"; exit 1; }

# -------------------------------
# VARIÁVEIS
# -------------------------------
DOMAIN="gmap.cd"
DOMAIN_USER="rds_suporte.ti"
DNS_PRIMARY="10.172.2.2"
DNS_SECONDARY="192.168.23.254"
SSSD_CONF="/etc/sssd/sssd.conf"
SUDOERS_FILE="/etc/sudoers.d/rds_suporte_ti"
CONFIG_FILE="/etc/set-wallpaper.conf"
SERVER="${SERVER:-//192.168.23.254/wallpapers}"
FILE="${FILE:-wallpaper_padrao.jpeg}"
LOCAL="/tmp/$FILE"
FALLBACK="${FALLBACK:-/usr/share/backgrounds/$FILE}"
SMB_AUTH="${SMB_AUTH:-/etc/smb-auth.conf}"
MAX_RETRIES=5
RETRY_DELAY=3

# Visual defaults
GTK_DARK_THEME="${GTK_DARK_THEME:-Yaru-dark}"
DOCK_EXTENSION_SCHEMA="org.gnome.shell.extensions.dash-to-dock"

# -------------------------------
# FUNÇÕES
# -------------------------------
check_root() {
    [ "$EUID" -eq 0 ] || error_exit "Este script precisa ser executado como root."
}

wait_for_network() {
    log "🌐 Verificando conectividade de rede..."
    for i in $(seq 1 $MAX_RETRIES); do
        if ping -c1 -W1 8.8.8.8 &>/dev/null; then
            log "✅ Rede disponível."
            return
        fi
        log "⚠️ Rede indisponível, tentativa $i/$MAX_RETRIES..."
        sleep $RETRY_DELAY
    done
    error_exit "Rede não disponível após $MAX_RETRIES tentativas."
}

install_packages() {
    log "📦 Instalando pacotes essenciais..."
    packages=(
        realmd sssd sssd-tools adcli samba-common krb5-user packagekit sudo
        wget curl iputils-ping iproute2 smbclient feh gnome-session dconf-cli
        gnome-remote-desktop dbus-x11 ufw ca-certificates apt-transport-https
        gnome-shell-extensions gnome-extensions-app gnome-tweaks
        gnome-shell-extension-dash-to-dock
    )
    apt_updated=0
    for pkg in "${packages[@]}"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            if [ "$apt_updated" -eq 0 ]; then
                apt-get update -y || true
                apt_updated=1
            fi
            log "Instalando $pkg..."
            apt-get install -y "$pkg" || log "⚠️ Falha ao instalar $pkg (continuando)"
        fi
    done
    log "✅ Pacotes essenciais (tentativa) finalizada."
}

configure_dns() {
    log "🔧 Configurando DNS..."
    iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5}' | head -n1 || true)
    if command -v resolvectl &>/dev/null && [ -n "$iface" ]; then
        resolvectl dns "$iface" "$DNS_PRIMARY" "$DNS_SECONDARY" || log "⚠️ resolvectl falhou"
        resolvectl flush-caches || true
    elif [ -f /etc/resolv.conf ]; then
        cp -n /etc/resolv.conf /etc/resolv.conf.bak || true
        cat > /etc/resolv.conf <<EOF
nameserver $DNS_PRIMARY
nameserver $DNS_SECONDARY
EOF
    else
        error_exit "Não foi possível configurar DNS automaticamente."
    fi
    log "✅ DNS configurado."
}

configure_ntp() {
    log "⏱ Habilitando NTP..."
    timedatectl set-ntp true || log "⚠️ timedatectl falhou"
}

validate_dns() {
    log "🔍 Validando conectividade com DNS..."
    ping -c 2 -W 2 "$DNS_PRIMARY" &>/dev/null || error_exit "DNS primário inacessível ($DNS_PRIMARY)"
    ping -c 2 -W 2 "$DNS_SECONDARY" &>/dev/null || log "⚠️ DNS secundário inacessível ($DNS_SECONDARY)"
    log "✅ Conectividade DNS OK"
}

discover_domain() {
    for i in $(seq 1 $MAX_RETRIES); do
        if realm discover "$DOMAIN" &>/dev/null; then
            return
        fi
        log "⚠️ Tentativa $i de descobrir domínio falhou, tentando novamente..."
        sleep $RETRY_DELAY
    done
    error_exit "Falha ao descobrir domínio $DOMAIN"
}

join_domain() {
    if realm list | grep -q "$DOMAIN"; then
        log "⚠️ Host já está no domínio $DOMAIN"
        return
    fi

    discover_domain

    for i in $(seq 1 $MAX_RETRIES); do
        log "🔧 Tentativa $i de ingressar no domínio $DOMAIN..."
        if realm join "$DOMAIN" -U "$DOMAIN_USER" --automatic-id-mapping; then
            log "✅ Host ingressou no domínio $DOMAIN"
            break
        else
            log "⚠️ Tentativa $i falhou"
            sleep $RETRY_DELAY
        fi
        [ "$i" -eq "$MAX_RETRIES" ] && error_exit "Falha ao ingressar no domínio $DOMAIN"
    done

    if ! grep -q "pam_mkhomedir.so" /etc/pam.d/common-session 2>/dev/null; then
        echo "session required pam_mkhomedir.so skel=/etc/skel/ umask=0022" >> /etc/pam.d/common-session
    fi

    if [ -f "$SSSD_CONF" ]; then
        sed -i 's/cache_credentials = False/cache_credentials = True/' "$SSSD_CONF" || true
        systemctl restart sssd || true
    fi
}

configure_sudo() {
    log "🔧 Configurando sudoers..."
    cat >"$SUDOERS_FILE" <<EOF
$DOMAIN_USER ALL=(ALL) NOPASSWD:ALL
EOF
    chmod 440 "$SUDOERS_FILE"
    chown root:root "$SUDOERS_FILE"
    log "✅ Sudoers configurado."
}

# Apply visual settings (theme + dock) for a session via provided DBUS/XAUTH envs
apply_visuals_session() {
    # expects DBUS_SESSION_BUS_ADDRESS and XDG_RUNTIME_DIR env (for Wayland) OR DISPLAY/XAUTHORITY (for X)
    local user="$1"
    local abs_local="$2"
    local local_uri="$3"

    # Set dark GTK theme
    sudo -u "$user" sh -c "
        set -e
        if command -v gsettings >/dev/null 2>&1; then
            gsettings set org.gnome.desktop.interface gtk-theme '$GTK_DARK_THEME' 2>/dev/null || true
            # Try modern color-scheme key when available
            gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true
        fi

        # If dash-to-dock is available, position it bottom and adjust behavior
        if gsettings writable $DOCK_EXTENSION_SCHEMA dock-position >/dev/null 2>&1; then
            gsettings set $DOCK_EXTENSION_SCHEMA dock-position 'BOTTOM' 2>/dev/null || true
            gsettings set $DOCK_EXTENSION_SCHEMA extend-height false 2>/dev/null || true
            gsettings set $DOCK_EXTENSION_SCHEMA intellihide false 2>/dev/null || true
            gsettings set $DOCK_EXTENSION_SCHEMA autohide false 2>/dev/null || true
        fi
    " 2>/dev/null || log "⚠️ Falha ao aplicar visual settings para $user (sessão)."
}

# Apply wallpaper and visuals for a single user (Wayland DBus, Xorg, or profile fallback)
apply_wallpaper() {
    local user_home="$1"
    local user="$2"
    local uid
    uid=$(id -u "$user" 2>/dev/null) || return
    local user_bus="/run/user/$uid/bus"
    local abs_local
    abs_local="$(readlink -f "$LOCAL" 2>/dev/null || echo "$LOCAL")"
    local local_uri="file://$abs_local"

    # ensure file readable
    if [ -f "$abs_local" ]; then
        chmod 644 "$abs_local" || true
    else
        log "⚠️ Arquivo local do wallpaper não existe: $abs_local"
        return
    fi

    # If user session bus exists (Wayland / modern GNOME): use gsettings via bus
    if [ -e "$user_bus" ]; then
        log "📌 Aplicando wallpaper e visuais via session bus para $user (UID=$uid)"
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$user_bus"
        export XDG_RUNTIME_DIR="/run/user/$uid"

        sudo -u "$user" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
            XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
            gsettings set org.gnome.desktop.background picture-uri "$local_uri" 2>/dev/null || \
            log "⚠️ gsettings picture-uri falhou para $user"

        sudo -u "$user" DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" \
            XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
            gsettings set org.gnome.desktop.background picture-options 'zoom' 2>/dev/null || true

        # apply theme + dock via session environment
        export DBUS_SESSION_BUS_ADDRESS
        export XDG_RUNTIME_DIR
        apply_visuals_session "$user" "$abs_local" "$local_uri"
        return
    fi

    # If Xauthority exists (Xorg sessions), try with DISPLAY and XAUTHORITY
    if [ -f "$user_home/.Xauthority" ]; then
        log "📌 Tentando aplicar via DISPLAY/XAUTHORITY para $user"
        export DISPLAY=:0
        export XAUTHORITY="$user_home/.Xauthority"

        sudo -u "$user" DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
            gsettings set org.gnome.desktop.background picture-uri "$local_uri" 2>/dev/null && true

        sudo -u "$user" DISPLAY="$DISPLAY" XAUTHORITY="$XAUTHORITY" \
            gsettings set org.gnome.desktop.background picture-options 'zoom' 2>/dev/null || true

        # apply visuals under X session
        apply_visuals_session "$user" "$abs_local" "$local_uri"
        return
    fi

    # If still not applied, create a profile.d script to apply at next login (wallpaper + visuals)
    log "ℹ️ Usuário $user sem sessão ativa — criando fallback para o próximo login"
    cat > "/etc/profile.d/apply_visuals_for_${user}.sh" <<EOF
#!/bin/sh
# Aplicar wallpaper e visuais automático para $user (gerado por setup.sh)
if [ "\$(id -u)" -eq $uid ]; then
    abs_local="$abs_local"
    local_uri="$local_uri"
    # wait for DBUS session if present
    if [ -n "\$DBUS_SESSION_BUS_ADDRESS" ] && command -v gsettings >/dev/null 2>&1; then
        gsettings set org.gnome.desktop.background picture-uri "\$local_uri" 2>/dev/null || true
        gsettings set org.gnome.desktop.background picture-options 'zoom' 2>/dev/null || true
        gsettings set org.gnome.desktop.interface gtk-theme '$GTK_DARK_THEME' 2>/dev/null || true
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark' 2>/dev/null || true
        if gsettings writable $DOCK_EXTENSION_SCHEMA dock-position >/dev/null 2>&1; then
            gsettings set $DOCK_EXTENSION_SCHEMA dock-position 'BOTTOM' 2>/dev/null || true
            gsettings set $DOCK_EXTENSION_SCHEMA extend-height false 2>/dev/null || true
            gsettings set $DOCK_EXTENSION_SCHEMA intellihide false 2>/dev/null || true
            gsettings set $DOCK_EXTENSION_SCHEMA autohide false 2>/dev/null || true
        fi
    elif command -v feh >/dev/null 2>&1; then
        feh --bg-scale "\$abs_local" 2>/dev/null || true
    fi
fi
EOF
    chmod 644 "/etc/profile.d/apply_visuals_for_${user}.sh"
    chown root:root "/etc/profile.d/apply_visuals_for_${user}.sh"
}

download_wallpaper() {
    local retries=$MAX_RETRIES
    rm -f "$LOCAL" 2>/dev/null || true
    while [ $retries -gt 0 ]; do
        if [ -f "$SMB_AUTH" ]; then
            if smbclient "$SERVER" -A "$SMB_AUTH" -c "get \"$FILE\" \"$LOCAL\"" &>/dev/null; then
                log "✅ Wallpaper baixado via SMB ($SERVER/$FILE)."
                chmod 644 "$LOCAL" || true
                return 0
            fi
        else
            # Try anonymous or guest (no auth file)
            if smbclient "$SERVER" -N -c "get \"$FILE\" \"$LOCAL\"" &>/dev/null; then
                log "✅ Wallpaper baixado via SMB (guest)."
                chmod 644 "$LOCAL" || true
                return 0
            fi
        fi
        retries=$((retries - 1))
        log "⚠️ Falha no download do wallpaper via SMB. Tentativas restantes: $retries"
        sleep $RETRY_DELAY
    done

    # fallback local
    if [ -f "$FALLBACK" ]; then
        cp -f "$FALLBACK" "$LOCAL"
        chmod 644 "$LOCAL" || true
        log "✅ Usando fallback local para wallpaper."
        return 0
    else
        log "⚠️ Fallback inexistente. Wallpaper não configurado."
        return 1
    fi
}

setup_wallpaper() {
    # load overrides if present
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

    # If SMB auth file doesn't exist, ask for password interactively (only if running in TTY)
    if [ ! -f "$SMB_AUTH" ]; then
        if [ -t 0 ]; then
            read -s -p "Senha para $DOMAIN_USER (para acessar SMB): " SMB_PASS
            echo
            if [ -n "$SMB_PASS" ]; then
                cat > "$SMB_AUTH" <<EOF
username = $DOMAIN_USER
password = $SMB_PASS
domain = $DOMAIN
EOF
                chmod 600 "$SMB_AUTH"
                chown root:root "$SMB_AUTH"
                log "✅ Arquivo de credenciais SMB criado em $SMB_AUTH"
            fi
        else
            log "ℹ️ Não há $SMB_AUTH e não é TTY — pulando criação interativa."
        fi
    fi

    download_wallpaper || log "⚠️ Falha ao obter wallpaper (continuando)."

    # apply for each local user home
    for user_home in /home/*; do
        [ -d "$user_home" ] || continue
        user=$(basename "$user_home")
        # skip system users (UID < 1000)
        uid=$(id -u "$user" 2>/dev/null || continue)
        if [ "$uid" -lt 1000 ]; then
            log "ℹ️ Pulando usuário $user (UID=$uid <1000)"
            continue
        fi
        apply_wallpaper "$user_home" "$user"
    done
}

configure_gnome_remote() {
    log "🔧 Configurando GNOME Remote Desktop..."
    # RDP password may be set earlier; if not, prompt (only in TTY)
    if [ -z "${RDP_PASSWORD-}" ] && [ -t 0 ]; then
        read -s -p "Senha RDP a ser usada para GNOME Remote Desktop: " RDP_PASSWORD
        echo
    fi

    if [ -n "${RDP_PASSWORD-}" ]; then
        sudo -u gdm dbus-run-session dconf write /org/gnome/desktop/remote-access/enabled true || true
        sudo -u gdm dbus-run-session dconf write /org/gnome/desktop/remote-access/require-encryption true || true
        sudo -u gdm dbus-run-session dconf write /org/gnome/desktop/remote-access/authentication-methods "['password']" || true
        sudo -u gdm dbus-run-session dconf write /org/gnome/desktop/remote-access/password "'$RDP_PASSWORD'" || true
    else
        log "⚠️ Sem RDP_PASSWORD — pulando algumas configurações de dconf."
    fi

    # Unit file — path may vary; keep conservative ExecStart
    tee /etc/systemd/system/gnome-remote-desktop-gdm.service > /dev/null <<EOF
[Unit]
Description=GNOME Remote Desktop for GDM
After=graphical.target

[Service]
Type=simple
User=gdm
ExecStart=/usr/lib/gnome-remote-desktop/gnome-remote-desktop || /usr/libexec/gnome-remote-desktop
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

    systemctl daemon-reload || true
    systemctl enable --now gnome-remote-desktop-gdm.service || log "⚠️ Não foi possível habilitar/rodar gnome-remote-desktop-gdm.service"
    ufw allow 3389/tcp || true
    ufw reload || true

    log "✅ GNOME Remote Desktop configurado (tentativa)."
}

# -------------------------------
# MAIN
# -------------------------------
main() {
    check_root
    wait_for_network
    install_packages
    configure_dns
    configure_ntp
    validate_dns
    join_domain
    configure_sudo
    setup_wallpaper
    configure_gnome_remote
    log "🎉 Script finalizado! Domínio, wallpaper e visuais configurados (quando possível)."
}

main
