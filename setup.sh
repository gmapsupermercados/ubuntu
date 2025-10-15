#!/bin/bash

# ===============================================
# VARIÁVEIS DE AMBIENTE (AJUSTE AQUI)
# ===============================================
DOMINIO_KERBEROS="GMAP.CD"
DOMINIO_DNS="gmap.cd"
DNS1="10.172.2.2"
DNS2="192.168.23.254"
USER_ADMIN_AD="rds_suporte.ti"

# Variáveis Dinâmicas (Obtidas no runtime)
IP_ATUAL=$(hostname -I | awk '{print $1}')
HOSTNAME_ATUAL=$(hostname)

# ===============================================
# 1. PRÉ-REQUISITOS E PREPARAÇÃO (Anti-Kerberos-Fail e Ambiente)
# ===============================================

echo "--- 1. Atualizando e instalando dependências (samba, sssd, realmd, adsys) ---"
sudo apt update
sudo apt install -y samba smbclient sssd krb5-user ntpdate adcli realmd adsys

# --- CONFIGURAÇÃO DNS (CRÍTICO PARA KERBEROS) ---
echo "--- Desativando systemd-resolved e configurando resolv.conf ---"
sudo systemctl disable --now systemd-resolved || true
sudo rm -f /etc/resolv.conf

# Cria /etc/resolv.conf com os IPs dos Controladores de Domínio
echo "nameserver $DNS1
nameserver $DNS2
search $DOMINIO_DNS" | sudo tee /etc/resolv.conf

# Torna o arquivo imutável (previne sobrescrita)
sudo chattr +i /etc/resolv.conf

# --- CONFIGURAÇÃO DE TEMPO (NTP - ESSENCIAL PARA KERBEROS) ---
echo "--- Sincronizando o relógio com o DC ($DNS1) e garantindo estabilidade ---"
sudo ntpdate $DNS1
sudo timedatectl set-ntp true
sudo timedatectl set-timezone America/Sao_Paulo # Ajuste o timezone se necessário
sudo systemctl restart systemd-timesyncd.service

# --- ARQUIVO HOSTS ---
echo "--- Configurando o /etc/hosts (Mapeamento local e FQDN) ---"
echo "127.0.0.1       localhost
$IP_ATUAL $HOSTNAME_ATUAL.$DOMINIO_DNS $HOSTNAME_ATUAL" | sudo tee /etc/hosts

# --- DESATIVAÇÃO DO WAYLAND (Prioriza o Xorg/X11) ---
echo "--- Desativando o Wayland no GDM para garantir uso do Xorg ---"
# O GNOME Display Manager (GDM) será forçado a usar o Xorg por padrão após o reboot.
# Isso não afeta a sessão atual.
sudo sed -i 's/#WaylandEnable=false/WaylandEnable=false/' /etc/gdm3/custom.conf || \
sudo sed -i 's/WaylandEnable=true/#WaylandEnable=false/' /etc/gdm3/custom.conf
# Reinicia o GDM (opcional, mas mais seguro para garantir a leitura da config no próximo boot)
sudo systemctl restart gdm3.service


# ===============================================
# 2. CONFIGURAÇÃO DE SERVIÇOS (SMBD e SSSD)
# ===============================================

# --- CONFIGURAÇÃO DO SAMBA (smb.conf) ---
echo "--- Configurando smb.conf para modo ADS/Cliente ---"
sudo rm -f /etc/samba/smb.conf
echo "[global]
    workgroup = $(echo $DOMINIO_KERBEROS | cut -d'.' -f1)
    realm = $DOMINIO_KERBEROS
    security = ads
    kerberos method = secrets and keytab
    winbind use default domain = yes
    idmap config * : backend = tdb
    idmap config * : range = 10000-29999
    idmap config $DOMINIO_KERBEROS : backend = rid
    idmap config $DOMINIO_KERBEROS : range = 30000-4000000
    template shell = /bin/bash
    vfs objects = acl_xattr
    map acl inherit = yes
    store dos attributes = yes
    client signing = mandatory
    client use spnego = yes
" | sudo tee /etc/samba/smb.conf

# --- CONFIGURAÇÃO MANUAL DO SSSD (Para garantir Kerberos e Login UPN) ---
echo "--- Configurando SSSD para FORÇAR LOGIN COMPLETO (usuario@dominio) ---"
sudo rm -f /etc/sssd/sssd.conf
echo "[sssd]
services = nss, pam, ad
config_file_version = 2
domains = $DOMINIO_DNS

[domain/$DOMINIO_DNS]
ad_server = $DNS1
id_provider = ad
auth_provider = ad
access_provider = ad
chpass_provider = ad
krb5_realm = $DOMINIO_KERBEROS
ldap_id_mapping = true
use_fully_qualified_names = true 
fallback_homedir = /home/%u@%d
default_shell = /bin/bash" | sudo tee /etc/sssd/sssd.conf

sudo chmod 600 /etc/sssd/sssd.conf


# ===============================================
# 3. JOIN NO DOMÍNIO E FINALIZAÇÃO
# ===============================================

echo "--- TENTANDO JOIN NO DOMÍNIO COM REALM JOIN (Cria SPN, Configura SSSD e Adsys) ---"
sudo realm join $DOMINIO_DNS -U $USER_ADMIN_AD --client-software=sssd --automatic-setup
sudo realm permit --all

# --- ATIVAÇÃO DO ADSYS (INTEGRAÇÃO GPO) ---
echo "--- Habilitando e aplicando o adsys (GPO Integration) ---"
sudo systemctl enable --now adsys.service
sudo adsysctl update --machine --wait

# --- HABILITAR CRIAÇÃO AUTOMÁTICA DE HOME DIRECTORY (Ajuste PAM) ---
echo "--- Habilitando criação automática de home directory (PAM) ---"
sudo sed -i '/^session\s*required\s*pam_unix.so/a session optional pam_mkhomedir.so skel=/etc/skel/ umask=0022' /etc/pam.d/common-session

# --- VERIFICAÇÃO E REINÍCIO FINAL ---
echo "--- Verificação de Join ---"
sudo net ads testjoin
sudo realm list

echo "--- Reiniciando serviços na ordem correta (FIM) ---"
sudo systemctl restart sssd
sudo systemctl restart smbd nmbd cups

echo "Script concluído! Faça um 'sudo reboot' agora."