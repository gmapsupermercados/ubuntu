# README: Integração de Estações de Trabalho Ubuntu no Active Directory (AD)

## 🎯 Objetivo

Este script Bash (`setup.sh`) automatiza a integração completa de **Estações de Trabalho Cliente Ubuntu** em um domínio Active Directory (AD).

O processo é projetado para garantir:
1.  **Single Sign-On (SSO):** Login de domínio no desktop e acesso a compartilhamentos de rede SMB/Windows.
2.  **Gerenciamento de Políticas (GPO):** Aplicação das Políticas de Grupo (GPOs) do AD na máquina Ubuntu (via `adsys`).
3.  **Máxima Estabilidade:** Prevenção de falhas de Kerberos através de configurações rígidas de DNS e NTP.

## ⚠️ Pré-requisitos e Avisos

1.  **Instalação Limpa:** Este script deve ser executado em uma instalação **limpa** do Ubuntu Desktop.
2.  **Permissão de `sudo`:** O usuário que executar o script deve ter permissões de `sudo`.
3.  **Objeto do Computador:** Se o hostname da máquina já existiu no AD e causou problemas, **garanta que o objeto do computador esteja removido do AD** para evitar conflitos de Service Principal Name (SPN/Kerberos).

## ⚙️ Variáveis de Ambiente (Ajuste Antes de Executar)

Edite a seção **`VARIÁVEIS DE AMBIENTE`** do script antes de usá-lo:

| Variável | Valor Exemplo | Descrição |
| :--- | :--- | :--- |
| `DOMINIO_KERBEROS` | `GMAP.CD` | O **Realm Kerberos** (Nome do Domínio em **MAIÚSCULAS**). |
| `DOMINIO_DNS` | `gmap.cd` | O **Sufixo DNS** do domínio (Nome do Domínio em **minúsculas**). |
| `DNS1` | `10.172.2.2` | **IP do Controlador de Domínio (DC) Primário.** Usado para DNS e NTP. |
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
4.  O script pedirá a **senha do usuário administrador do AD** (`rds_suporte.ti`) durante o processo de *join*.
5.  **IMPORTANTE:** Ao final da execução, o script solicitará que você **reinicie o sistema**.

## 🧠 Explicação Técnica do Script (Robô de Kerberos e GPO)

O script utiliza uma sequência de comandos otimizada para garantir a estabilidade do Kerberos e a aplicação das Políticas de Grupo.

### Seção 1: PRÉ-REQUISITOS E PREPARAÇÃO

| Comando Principal | Propósito | Por Que É Crucial |
| :--- | :--- | :--- |
| `systemctl disable systemd-resolved` & `chattr +i /etc/resolv.conf` | **Fixação de DNS.** | Elimina a principal causa de falha de Kerberos ao forçar o uso exclusivo dos DCs como resolvedores. |
| **`ntpdate $DNS1` & `timedatectl set-ntp true`** | **Estabilidade de Tempo.** | Garante a sincronização imediata (ntpdate) e a estabilidade contínua do serviço de tempo (`timedatectl`), essencial para que o AD não rejeite os tickets Kerberos. |

### Seção 2: CONFIGURAÇÃO DE SERVIÇOS (SAMBA e SSSD)

| Comando Principal | Propósito | Benefício |
| :--- | :--- | :--- |
| **Configuração `smb.conf`** | Define `security = ads` e `kerberos method = secrets and keytab`. | Garante que o protocolo SMB use o cache de chaves Kerberos da máquina para acesso SSO a compartilhamentos Windows. |
| **Configuração `sssd.conf`** | Define explicitamente o provedor de autenticação (`id_provider = ad`) e o servidor AD. | Garante que o login de usuário do AD funcione corretamente e com mapeamento de IDs de usuário (POSIX) estável. |

### Seção 3: JOIN NO DOMÍNIO E FINALIZAÇÃO

| Comando Principal | Propósito | Benefício de TI |
| :--- | :--- | :--- |
| **`realm join ...`** | Realiza o ingresso da máquina no domínio. | Cria a identidade do computador no AD (SPN/Kerberos) e integra o SSSD/PAM (login). |
| **`sudo systemctl enable --now adsys.service`** | Habilita e inicia o serviço **`adsys`**. | **Integração GPO:** Permite que a estação de trabalho Ubuntu receba e aplique as Políticas de Grupo do AD. |
| `pam_mkhomedir.so` | Habilita a criação automática do diretório `/home/usuario` no primeiro login do AD. | Melhora a Experiência do Usuário (UX). |
| **`sudo net ads testjoin`** | **Verificação Final de Confiança.** | Confirma que a confiança do Kerberos/ADS para o protocolo SMB está perfeitamente estabelecida. |

## 🧪 Pós-Execução e Testes

Após o **reboot**, valide a integração:

1.  **Teste de Login SSO:**
    * Faça **Logout**.
    * Na tela de login, selecione "Não listado?" e use apenas o **nome de usuário do AD** (Ex: `matheusps.it`). Se logar, o SSSD está OK.
2.  **Teste de Acesso a Compartilhamentos SMB (SSO):**
    * Abra o Gerenciador de Arquivos (Nautilus).
    * Pressione `Ctrl+L` e digite o caminho de um compartilhamento Windows (Ex: `smb://servidor-ad/dados`).
    * O acesso deve ocorrer **instantaneamente, sem pedir senha**, confirmando que o Kerberos para o Samba está 100% funcional.
3.  **Teste de Aplicação de GPO (adsys):**
    * Verifique se as políticas de máquina ou usuário definidas no AD (ex: fundo de tela, proxy) foram aplicadas ao ambiente Ubuntu. Você pode checar o status com:
    ```bash
    sudo adsysctl update --machine --wait
    ```