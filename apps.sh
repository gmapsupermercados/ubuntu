#!/bin/bash

# ===============================================
# VARIÁVEIS DE SEGURANÇA E USUÁRIO (AJUSTE AQUI)
# ===============================================
USER_SUPORTE="gmap"
# Senha temporária: 159753
# Gerando hash seguro (SHA-512) para a senha inicial.
SENHA_INICIAL_HASHED=$(echo "159753" | openssl passwd -6 -stdin) 

# ===============================================
# 1. ATUALIZAÇÃO E PRÉ-REQUISITOS
# ===============================================

echo "--- 1. Iniciando atualização e instalação de pré-requisitos ---"
sudo apt update
sudo apt upgrade -y
# Dependências básicas para download e gerenciamento de repositórios
sudo apt install -y curl wget software-properties-common apt-transport-https

# ===============================================
# 2. INSTALAÇÃO DE FERRAMENTAS DE ACESSO REMOTO E SSH
# ===============================================

# --- 2.1. AnyDesk (Suporte em Tempo Real) ---
echo "--- 2.1. Instalando AnyDesk ---"
# Adiciona a chave GPG do repositório
wget -qO - https://keys.anydesk.com/repos/DEB-GPG-KEY | sudo gpg --dearmor -o /usr/share/keyrings/anydesk.gpg
# Adiciona o repositório oficial
echo "deb [signed-by=/usr/share/keyrings/anydesk.gpg] http://deb.anydesk.com/ all main" | sudo tee /etc/apt/sources.list.d/anydesk.list > /dev/null
sudo apt update
sudo apt install -y anydesk

# --- 2.2. Remmina (Cliente Universal RDP/VNC/SSH) ---
echo "--- 2.2. Instalando Remmina (Cliente VNC/RDP/SSH) ---"
# Instala o cliente e os plugins essenciais
sudo apt install -y remmina remmina-plugin-rdp remmina-plugin-vnc

# --- 2.3. VNC Server (Servidor de Compartilhamento de Tela Nativo) ---
echo "--- 2.3. Habilitando Servidor VNC Nativo (Acesso de Tela) ---"
# O 'vino' é o servidor VNC que o GNOME/Ubuntu geralmente usa para compartilhamento.
sudo apt install -y vino

# --- 2.4. OpenSSH Server (Acesso via Terminal) ---
echo "--- 2.4. Instalando e Configurando OpenSSH Server ---"
sudo apt install -y openssh-server

# ===============================================
# 3. CRIAÇÃO E CONFIGURAÇÃO DE USUÁRIO DE SUPORTE
# ===============================================

echo "--- 3.1. Criando usuário de suporte '$USER_SUPORTE' ---"
# Cria o usuário se ele não existir
if ! id "$USER_SUPORTE" &>/dev/null; then
    sudo useradd -m -s /bin/bash "$USER_SUPORTE"
fi
# Define a senha inicial segura (usando o hash)
sudo usermod --password "$SENHA_INICIAL_HASHED" "$USER_SUPORTE"
# Concede acesso sudo
sudo usermod -aG sudo "$USER_SUPORTE" 

echo ""
echo "################################################################"
echo "### AVISO CRÍTICO DE SEGURANÇA: Senha de '$USER_SUPORTE'     ###"
echo "### O usuário '$USER_SUPORTE' foi criado com a senha '159753'. ###"
echo "### POR FAVOR, altere esta senha imediatamente!               ###"
echo "################################################################"
echo ""

# ===============================================
# 4. FINALIZAÇÃO E REINÍCIO DE SERVIÇOS
# ===============================================

echo "--- 4. Finalizando: Reiniciando serviços de rede e SSH ---"
sudo systemctl restart ssh
sudo systemctl daemon-reload
echo "Instalação de aplicativos e configuração de usuário concluída."