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
# 1. PRÉ-REQUISITOS E PREPARAÇÃO (Anti-Kerberos-Fail)
# ===============================================

echo "--- 1. Atualizando e instalando dependências (realmd, sssd, samba, adcli) ---"
sudo apt update
sudo apt install -y samba smbclient sssd krb5-user ntpdate adcli realmd

# --- CONFIGURAÇÃO DNS (CRÍTICO PARA KERBEROS) ---
echo "--- Desativando systemd-resolved e configurando resolv.conf ---"
sudo systemctl disable --now systemd-resolved || true
sudo rm -f /etc/resolv.conf

# Cria /etc/resolv.conf com os IPs dos Controladores de Domínio
echo "nameserver $DNS1
nameserver $DNS2
search $DOMINIO_DNS" | sudo tee /etc/resolv.conf

# Torna o arquivo imutável
sudo chattr +i /etc/resolv.conf

# --- CONFIGURAÇÃO DE TEMPO (NTP - ESSENCIAL PARA KERBEROS) ---
echo "--- Sincronizando o relógio com o DC ($DNS1) ---"
sudo ntpdate $DNS1
sudo systemctl restart systemd-timesyncd.service

# --- ARQUIVO HOSTS ---
echo "--- Configurando o /etc/hosts (Mapeamento local e FQDN) ---"
echo "127.0.0.1       localhost
$IP_ATUAL $HOSTNAME_ATUAL.$DOMINIO_DNS $HOSTNAME_ATUAL" | sudo tee /etc/hosts


# ===============================================
# 2. CONFIGURAÇÃO DE SERVIÇOS (SMBD)
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


# ===============================================
# 3. JOIN NO DOMÍNIO E FINALIZAÇÃO
# ===============================================

echo "--- TENTANDO JOIN NO DOMÍNIO COM REALM JOIN (Cria SPN e Configura SSSD) ---"
# O REALM JOIN (ou ADCLI) faz o join e configura SSSD/PAM.
# Ele é o método preferido do Ubuntu/systemd.
sudo realm join $DOMINIO_DNS -U $USER_ADMIN_AD --client-software=sssd --automatic-setup
sudo realm permit --all # Permite que todos os usuários do AD façam login

# --- REFINAMENTO SSSD (Login com nome curto e home dir) ---
echo "--- Refinando configuração SSSD para uso amigável ---"
# O realm join já configurou o SSSD, fazemos o ajuste fino para login 'curto'
sudo sed -i 's/use_fully_qualified_names = True/use_fully_qualified_names = false/' /etc/sssd/sssd.conf
sudo sed -i 's/fallback_homedir = \/home\/%u@%d/fallback_homedir = \/home\/%u/' /etc/sssd/sssd.conf

# --- HABILITAR CRIAÇÃO AUTOMÁTICA DE HOME DIRECTORY ---
echo "--- Habilitando criação automática de home directory (PAM) ---"
# Garante que o diretório seja criado no primeiro login (session optional é mais seguro)
sudo sed -i '/^session\s*required\s*pam_unix.so/a session optional pam_mkhomedir.so skel=/etc/skel/ umask=0022' /etc/pam.d/common-session

# --- VERIFICAÇÃO E REINÍCIO FINAL ---
echo "--- Verificação de Join ---"
sudo net ads testjoin # Testa o join do Samba/ADS (confiança da máquina)
sudo realm list      # Lista o status do realm (confiança do sistema)

echo "--- Reiniciando serviços (FIM) ---"
sudo systemctl restart sssd smbd nmbd cups

echo "Script concluído! Faça um 'sudo reboot' agora."