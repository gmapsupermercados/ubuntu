# README: Integração de Estações de Trabalho Ubuntu no Active Directory (AD)

## 🎯 Objetivo

Este script Bash (`setup.sh`) automatiza o processo de ingresso de **Estações de Trabalho Cliente Ubuntu** em um domínio Active Directory (AD) da Microsoft. Ele é projetado para garantir o **Single Sign-On (SSO)** para login no desktop e acesso a compartilhamentos de rede SMB/Windows, prevenindo falhas comuns de Kerberos causadas por dessincronia de DNS e NTP.

## ⚠️ Pré-requisitos e Avisos

1.  **Instalação Limpa:** Este script deve ser executado em uma instalação **limpa** do Ubuntu Desktop.
2.  **Permissão de `sudo`:** O usuário que executar o script deve ter permissões de `sudo` (ser membro do grupo `sudo`).
3.  **Objeto do Computador:** Se o hostname da máquina já existiu no AD e apresentou problemas, garanta que o objeto do computador esteja **removido** do AD para evitar conflitos de SPN (Kerberos).

## ⚙️ Variáveis de Ambiente (Ajuste Antes de Executar)

Edite a seção **`VARIÁVEIS DE AMBIENTE`** do script antes de usá-lo:

| Variável | Valor Exemplo | Descrição |
| :--- | :--- | :--- |
| `DOMINIO_KERBEROS` | `GMAP.CD` | O **Realm Kerberos** (Nome do Domínio em **MAIÚSCULAS**). |
| `DOMINIO_DNS` | `gmap.cd` | O **Sufixo DNS** do domínio (Nome do Domínio em **minúsculas**). |
| `DNS1` | `10.172.2.2` | **IP do Controlador de Domínio (DC) Primário.** Usado para DNS e Sincronização de Tempo (NTP). |
| `DNS2` | `192.168.23.254` | **IP do DC Secundário.** |
| `USER_ADMIN_AD` | `rds_suporte.ti` | Usuário do AD com permissão para ingressar máquinas no domínio. |

## 🚀 Como Executar o Script

1.  Baixe ou salve o código como `setup.sh`.
2.  Torne o script executável:
    ```bash
    chmod +x setup.sh
    ```
3.  Execute o script:
    ```bash
    sudo ./setup.sh
    ```
4.  O script pedirá a **senha do seu usuário de administração do AD** (`rds_suporte.ti`) durante o processo de *join* (ingresso no domínio).
5.  **IMPORTANTE:** Ao final da execução, o script solicitará que você **reinicie o sistema**.

## 🧠 Explicação Técnica do Script (Anti-Falha de Kerberos)

O script foi estruturado para resolver as causas mais comuns de falha de Kerberos: DNS instável e tempo dessincronizado.

### Seção 1: PRÉ-REQUISITOS E PREPARAÇÃO

| Comando Principal | Propósito | Por Que Evita Falhas de Kerberos |
| :--- | :--- | :--- |
| `systemctl disable --now systemd-resolved` | Desativa o resolvedor de DNS padrão do Ubuntu. | O Kerberos requer consistência. O `systemd-resolved` pode levar a consultas DNS inconsistentes, quebrando a confiança. |
| **`chattr +i /etc/resolv.conf`** | Torna o arquivo `resolv.conf` imutável. | Garante que o sistema **nunca** sobrescreva os IPs dos DCs, mantendo o DNS fixo. |
| **`ntpdate $DNS1`** | Força a sincronização do relógio com o DC primário. | O Kerberos falha se o relógio do cliente e do servidor estiverem com mais de 5 minutos de diferença. **CRÍTICO!** |
| `echo ... | sudo tee /etc/hosts` | Mapeia o IP da máquina para seu próprio FQDN. | Garante que a máquina resolva seu próprio nome localmente, requisito de estabilidade. |

### Seção 2: CONFIGURAÇÃO DE SERVIÇOS (SMBD)

| Comando Principal | Propósito | Por Que Garante o SSO no SMB |
| :--- | :--- | :--- |
| `security = ads` | Define o modo de segurança do Samba como Active Directory Services. | Permite que o Samba use o Kerberos. |
| `kerberos method = secrets and keytab` | Instrui o Samba a usar o cache de chaves Kerberos (`keytab`) da máquina. | Essencial para que o acesso a compartilhamentos do AD funcione via SSO, sem pedir senha. |

### Seção 3: JOIN NO DOMÍNIO E FINALIZAÇÃO

| Comando Principal | Propósito | Benefício |
| :--- | :--- | :--- |
| **`realm join ...`** | Realiza o ingresso da máquina no domínio. | Cria a identidade do computador no AD (SPN/Kerberos) E configura o SSSD/PAM automaticamente para o login. |
| `pam_mkhomedir.so` | Habilita a criação automática do diretório `/home/usuario` no primeiro login do AD. | Melhora a Experiência do Usuário (UX). |
| **`sudo net ads testjoin`** | **Verificação Final do Samba.** | Confirma que a confiança do Kerberos/ADS para o protocolo SMB foi estabelecida com sucesso. |

## 🧪 Pós-Execução e Testes

Após o **reboot**, valide a integração:

1.  **Teste de Login SSO:**
    * Faça **Logout**.
    * Na tela de login, selecione "Não listado?" e use apenas o **nome de usuário do AD** (Ex: `matheusps.it`).
2.  **Teste de Acesso a Compartilhamentos SMB (SSO):**
    * Abra o Gerenciador de Arquivos (Nautilus).
    * Pressione `Ctrl+L` e digite o caminho de um compartilhamento Windows (Ex: `smb://servidor-ad/dados`).
    * O acesso deve ocorrer **instantaneamente, sem pedir senha**, confirmando que o Kerberos para o Samba está 100% funcional.