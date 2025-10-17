#!/bin/bash

# ===============================================
# VARIÁVEIS DE AMBIENTE (AJUSTE AQUI)
# ===============================================
DOMINIO_KERBEROS="GMAP.CD"         # NOME DO DOMÍNIO EM MAIÚSCULAS
DOMINIO_DNS="gmap.cd"              # FQDN DO DOMÍNIO
DNS1="10.172.2.2"                  # IP DO DC PRIMÁRIO (ESSENCIAL PARA KERBEROS)
DNS2="192.168.23.254"              # IP DO DC SECUNDÁRIO
USER_ADMIN_AD="rds_suporte.ti"     # USUÁRIO COM PERMISSÕES DE JOIN

# Variáveis Dinâmicas (Obtidas no runtime)
IP_ATUAL=$(hostname -I | awk '{print $1}')
HOSTNAME_ATUAL=$(hostname)

# ===============================================
# 1. PRÉ-REQUISITOS E PREPARAÇÃO (Anti-Kerberos-Fail e Ambiente)
# ===============================================

echo "--- 1. Atualizando e instalando dependências (samba, sssd, realmd, adsys) ---"
# O pacote 'winbind' é adicionado para garantir que os binários do Samba tenham todas as dependências do AD.
sudo apt update
sudo apt install -y samba smbclient sssd krb5-user ntpdate adcli realmd adsys winbind

# --- CONFIGURAÇÃO DNS (CRÍTICO PARA KERBEROS: O CLIENTE DEVE APONTAR PARA O DC) ---
echo "--- Desativando systemd-resolved e configurando resolv.conf ---"
sudo systemctl disable --now systemd-resolved || true
sudo rm -f /etc/resolv.conf

echo "nameserver $DNS1
nameserver $DNS2
search $DOMINIO_DNS" | sudo tee /etc/resolv.conf

# Torna o arquivo imutável (previne sobrescrita por DHCP, etc.)
sudo chattr +i /etc/resolv.conf
echo "DNS configurado para: $DNS1 e $DNS2"

# --- CONFIGURAÇÃO DE TEMPO (NTP - ESSENCIAL PARA KERBEROS) ---
echo "--- Sincronizando o relógio com o DC ($DNS1) e garantindo estabilidade ---"
# Usa o DC como fonte de tempo (ntpdate é obsoleto, mas funciona para forçar o ajuste inicial)
sudo ntpdate $DNS1
sudo timedatectl set-ntp true
sudo timedatectl set-timezone America/Sao_Paulo 
sudo systemctl restart systemd-timesyncd.service
echo "Hora sincronizada. Verifique 'timedatectl' após o script."


# --- ARQUIVO HOSTS ---
echo "--- Configurando o /etc/hosts (Mapeamento local e FQDN) ---"
# Adicionar o FQDN e o hostname para evitar lookups de DNS problemáticos no inicio do Kerberos
echo "$IP_ATUAL $HOSTNAME_ATUAL.$DOMINIO_DNS $HOSTNAME_ATUAL" | sudo tee -a /etc/hosts


# --- DESATIVAÇÃO DO WAYLAND (Para mitigar possíveis falhas gráficas/aplicação GPO) ---
echo "--- Desativando o Wayland no GDM para garantir uso do Xorg ---"
sudo sed -i '/WaylandEnable=false/! s/#WaylandEnable=false/WaylandEnable=false/' /etc/gdm3/custom.conf || \
sudo sed -i '/WaylandEnable=true/ s/WaylandEnable=true/#WaylandEnable=false/' /etc/gdm3/custom.conf


# ===============================================
# 2. CONFIGURAÇÃO DE SERVIÇOS (SMBD e SSSD)
# ===============================================

# --- CONFIGURAÇÃO DO SAMBA (smb.conf) ---
# A GRANDE MUDANÇA: REMOVEMOS O MAPEMENTO DE ID DO SAMBA/WINBIND
# O Samba AGORA DEVE CONFIAR 100% NO SSSD para o mapeamento de IDs
echo "--- Configurando smb.conf para modo ADS/Cliente (Sem conflito de ID) ---"
sudo rm -f /etc/samba/smb.conf
echo "[global]
    # Configuracao ADS (Obrigatoria)
    workgroup = $(echo $DOMINIO_KERBEROS | cut -d'.' -f1)
    realm = $DOMINIO_KERBEROS
    security = ads
    kerberos method = secrets and keytab
    client signing = mandatory
    client use spnego = yes
    
    # Configuracao de Identidade SSSD/NSS
    winbind use default domain = yes
    
    # IMPORTANTE: Configura o SAMBA para usar o mapeamento de ID do sistema (SSSD)
    # E desabilita o mapeamento Winbind/RID (Elimina o Conflito)
    idmap config * : backend = tdb
    idmap config * : range = 10000-29999
    
    # Desabilita o enumerador Winbind que poderia conflitar com o SSSD
    winbind enum users = no
    winbind enum groups = no
    
    # Configuracoes de Home e Shell (para usuarios do AD)
    template shell = /bin/bash
    template homedir = /home/%U
    
    # Configuracoes de ACL (Importante para compartilhamento de arquivos)
    vfs objects = acl_xattr
    map acl inherit = yes
    store dos attributes = yes
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

# --- AJUSTE KRB5.CONF ---
# Embora o realm join faca isso, garantir que o dominio Kerberos esteja no krb5.conf
sudo rm -f /etc/krb5.conf
echo "[libdefaults]
    default_realm = $DOMINIO_KERBEROS
    dns_lookup_realm = true
    dns_lookup_kdc = true" | sudo tee /etc/krb5.conf


# ===============================================
# 3. JOIN NO DOMÍNIO E FINALIZAÇÃO
# ===============================================

echo "--- Reiniciando Servicos antes do Join para garantir que as configs sejam lidas ---"
sudo systemctl restart sssd smbd nmbd

echo "--- TENTANDO JOIN NO DOMÍNIO COM REALM JOIN (Cria SPN, Configura SSSD e Adsys) ---"
# O --client-software=sssd eh redundante, mas ajuda a clarear a intencao
# O --automatic-setup eh critico para configurar o Kerberos e o SSSD
sudo realm join $DOMINIO_DNS -U $USER_ADMIN_AD --client-software=sssd --automatic-setup
sudo realm permit --all

# --- ATIVAÇÃO DO ADSYS (INTEGRAÇÃO GPO) ---
echo "--- Habilitando e aplicando o adsys (GPO Integration) ---"
sudo systemctl enable --now adsys.service
# Forca uma atualizacao inicial do GPO
sudo adsysctl update --machine --wait

# --- HABILITAR CRIAÇÃO AUTOMÁTICA DE HOME DIRECTORY (Ajuste PAM) ---
echo "--- Habilitando criação automática de home directory (PAM) ---"
# Esta linha no common-session habilita a criacao de home para usuarios de dominio
sudo sed -i '/^session\s*required\s*pam_unix.so/a session optional pam_mkhomedir.so skel=/etc/skel/ umask=0022' /etc/pam.d/common-session

# --- VERIFICAÇÃO E REINÍCIO FINAL ---
echo "--- Verificação de Join ---"
# Net ads testjoin para checar a comunicacao Samba/AD
sudo net ads testjoin
# Realm list para checar a comunicacao SSSD/AD
sudo realm list

echo "--- REINICIANDO SSSD (FIM) ---"
sudo systemctl restart sssd

echo "Script concluído! O próximo passo é testar o login de um usuário de domínio. Recomenda-se fazer 'sudo reboot' para garantir que todas as configurações de GDM/Wayland e SSSD entrem em vigor."