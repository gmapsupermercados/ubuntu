#!/bin/bash
# Script de Implantação Rápida: AD Join, Samba/Winbind e Configuração de Login Gráfico
# Autor: Gemini

# --- VARIÁVEIS DE CONFIGURAÇÃO OBRIGATÓRIAS ---------------------------------
# O técnico DEVE ajustar estas variáveis antes de executar.

# 1. Dados do Domínio
DOMINIO_REALM="GMAP.CD"         # Nome do Realm Kerberos (SEMPRE MAIÚSCULO)
DOMINIO_NETBIOS="GMAP"          # Nome NetBIOS do domínio (usado no workgroup)
DC_IP="10.172.2.2"              # IP do Controlador de Domínio (KDC/Admin Server)
DNS_SEARCH="gmap.cd"            # Domínio DNS (usado no FQDN e krb5.conf)

# 2. Dados da Máquina
# O hostname deve ser definido manualmente (sudo hostnamectl set-hostname NOME) antes de executar.
# Este script buscará o hostname atual e o IP da interface principal.
USUARIO_JOIN="rds_suporte.ti"   # Usuário com permissão de adicionar máquina ao domínio

# 3. Caminhos de Compartilhamento (Ajuste conforme a necessidade)
COMPARTILHAMENTO_PATH="/mnt/dados/ti_dados"
COMPARTILHAMENTO_NOME="Dados Compartilhados"
GRUPO_PERMITIDO="ti"            # Grupo do AD que terá acesso ao compartilhamento

# -----------------------------------------------------------------------------
echo "--- INICIANDO IMPLANTAÇÃO RÁPIDA DE MEMBRO DE DOMÍNIO ---"

# --- Validação e Coleta de Dados Dinâmicos ---
NOVO_HOSTNAME=$(hostname -s)
IP_ESTATICO=$(hostname -I | awk '{print $1}') # Pega o IP da primeira interface ativa

if [ -z "$IP_ESTATICO" ] || [ -z "$NOVO_HOSTNAME" ]; then
    echo "ERRO: Não foi possível determinar o IP ou Hostname da máquina."
    echo "Garanta que o hostname está definido e a rede está ativa."
    exit 1
fi

echo "Host detectado: $NOVO_HOSTNAME | IP: $IP_ESTATICO"
echo "DC: $DC_IP | Domínio: $DOMINIO_REALM"

# 1. FASE DE PREPARAÇÃO DE SISTEMA
echo -e "\n[1/5] Preparando Sistema (Instalação e Hosts)..."
sudo apt update
sudo apt install -y ntp samba winbind krb5-user libnss-winbind acl net-tools telnet dnsutils

# Sincronização de tempo (CRÍTICO)
echo "Sincronizando horário com o DC ($DC_IP)..."
sudo ntpdate -s $DC_IP

# Ajusta o arquivo Hosts (garantindo FQDN/IP estático)
echo "Ajustando /etc/hosts..."
# Remove mapeamentos antigos do 127.0.1.1
sudo sed -i '/127.0.1.1/d' /etc/hosts
# Adiciona o mapeamento do IP estático
echo -e "$IP_ESTATICO\t$NOVO_HOSTNAME.$DNS_SEARCH $NOVO_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null

# Desabilita Wayland (necessário para AnyDesk/VNC no login)
echo "Forçando Xorg no GDM3..."
sudo sed -i 's/^#WaylandEnable=false/WaylandEnable=false/' /etc/gdm3/custom.conf

# 2. FASE DE CONFIGURAÇÃO DE ARQUIVOS (KERBEROS E SAMBA)

# a) Configura /etc/krb5.conf (Fixando o IP do KDC)
echo -e "\n[2/5] Configurando /etc/krb5.conf..."
sudo tee /etc/krb5.conf > /dev/null <<EOF
[libdefaults]
    default_realm = $DOMINIO_REALM
    dns_lookup_realm = true
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[realms]
    $DOMINIO_REALM = {
        kdc = $DC_IP
        admin_server = $DC_IP
    }

[domain_realm]
    .$DNS_SEARCH = $DOMINIO_REALM
    $DNS_SEARCH = $DOMINIO_REALM
EOF

# b) Configura /etc/samba/smb.conf (Seção [global])
echo -e "\n[3/5] Configurando /etc/samba/smb.conf (Seção Global)..."
# Faz backup do arquivo original
sudo mv /etc/samba/smb.conf /etc/samba/smb.conf.bak.$(date +%F)

sudo tee /etc/samba/smb.conf > /dev/null <<EOF
[global]
    workgroup = $DOMINIO_NETBIOS
    realm = $DOMINIO_REALM
    security = ads
    kerberos method = secrets and keytab
    winbind use default domain = yes
    winbind offline logon = yes
    
    # Mapeamento de ID (RID Backend, CRÍTICO)
    idmap config * : backend = tdb
    idmap config * : range = 3000-7999
    idmap config $DOMINIO_NETBIOS : backend = rid
    idmap config $DOMINIO_NETBIOS : range = 10000-999999
    
    # Templates de Usuário e Logs
    template shell = /bin/bash
    template homedir = /home/%D/%U
    log file = /var/log/samba/log.%m
    max log size = 1000

# --- Compartilhamentos serão adicionados abaixo (Ver Seção III)
EOF

# 3. FASE DE ADESÃO AO DOMÍNIO
echo -e "\n[4/5] Adesão ao Domínio e Configuração PAM..."

echo "Testando sintaxe do Samba..."
testparm
if [ $? -ne 0 ]; then
    echo "ERRO CRÍTICO: Falha na sintaxe do smb.conf. Abortando JOIN."
    exit 1
fi

echo "Unindo ao domínio AD (net ads join -U $USUARIO_JOIN)..."
# O comando net ads join solicitará a senha do usuário
sudo net ads join -U $USUARIO_JOIN

# Verifica o sucesso do JOIN
if [ $? -ne 0 ]; then
    echo "ERRO CRÍTICO: Falha no JOIN do AD. Verifique o horário, DNS e credenciais."
    exit 1
fi

# Integra Winbind no NSS (permite comandos como getent passwd)
echo "Integrando Winbind no NSS..."
sudo sed -i 's/^passwd:.*$/passwd: files systemd winbind/' /etc/nsswitch.conf
sudo sed -i 's/^group:.*$/group: files systemd winbind/' /etc/nsswitch.conf

# Configura PAM para Login Gráfico (mkhomedir)
echo "Configurando PAM para criação de Home e autenticação Winbind..."
sudo pam-auth-update --enable mkhomedir --force

# 4. FASE DE COMPARTILHAMENTO E REINÍCIO

echo -e "\n[5/5] Configurando Compartilhamento SMB e Reiniciando Serviços..."

# Cria o diretório de compartilhamento se não existir
sudo mkdir -p "$COMPARTILHAMENTO_PATH"

# Adiciona o compartilhamento (III. Template) ao smb.conf
sudo tee -a /etc/samba/smb.conf > /dev/null <<EOF

# --- INÍCIO DO COMPARTILHAMENTO (Ajuste para Impressoras/Pastas) ---
[${COMPARTILHAMENTO_NOME}]
    comment = Compartilhamento para o grupo ${GRUPO_PERMITIDO}
    path = ${COMPARTILHAMENTO_PATH}
    read only = no
    guest ok = no
    browseable = yes
    writable = yes
    
    # Restringe acesso apenas a membros do grupo AD
    valid users = @${DOMINIO_NETBIOS}\${GRUPO_PERMITIDO}
    
    # Garante que novos arquivos herdem as permissões de grupo
    force group = ${GRUPO_PERMITIDO}
    create mask = 0660
    directory mask = 0770
# --- FIM DO COMPARTILHAMENTO ---
EOF

# Reinicia todos os serviços
sudo systemctl restart winbind smbd nmbd

# 5. TESTES DE VALIDAÇÃO FINAL

echo -e "\n--- TESTES RÁPIDOS DE VALIDAÇÃO ---"
echo "Testando canal seguro (wbinfo -t)..."
sudo wbinfo -t
echo "Testando autenticação Kerberos (kinit)..."
# Tente obter um ticket para o usuário join
kinit $USUARIO_JOIN@$DOMINIO_REALM
klist

echo -e "\n--- SUCESSO! ---"
echo "Máquina $NOVO_HOSTNAME unida ao $DOMINIO_REALM e compartilhamento configurado."
echo "Para ativar o login gráfico, reinicie o Gerenciador de Exibição (GDM/LightDM):"
echo "sudo systemctl restart gdm3"
# FIM DO SCRIPT