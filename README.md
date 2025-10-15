# DOCUMENTAÇÃO DE PROCEDIMENTO: Integração de Clientes Ubuntu no Active Directory (AD)

## 🎯 Sumário Executivo: Objetivo da Solução

Este documento detalha o script Bash (`setup.sh`), uma ferramenta desenvolvida para automatizar e padronizar o ingresso de **Estações de Trabalho Ubuntu** no ambiente de domínio Active Directory (AD).

O processo garante a **Conformidade Operacional** e a **Experiência do Usuário (UX)** por meio de três pilares centrais:

1.  **Acesso Unificado (Single Sign-On - SSO):** Permite que o colaborador utilize sua credencial de rede (UPN: `usuario@dominio.com`) para acessar o sistema operacional e os recursos de rede (SMB/Windows), eliminando a necessidade de múltiplas autenticações.
2.  **Governança de Políticas (GPO):** Garante que o ambiente Ubuntu receba e aplique as **Políticas de Grupo (GPOs)** estabelecidas na infraestrutura Windows (via serviço `adsys`), mantendo a segurança e o controle centralizado.
3.  **Robustez e Estabilidade:** Implementa mecanismos de "blindagem" no sistema operacional para prevenir falhas comuns de autenticação (Kerberos) causadas por inconsistências de rede (DNS e NTP).

## ⚠️ Condições de Execução e Pré-requisitos

1.  **Ambiente Inicial:** A execução é otimizada para ser realizada em uma instalação do Ubuntu Desktop que se encontre em estado **funcional e limpo**.
2.  **Nível de Acesso:** O executor do script deve possuir privilégios administrativos (`sudo`) no sistema Ubuntu.
3.  **Higiene do Domínio:** É mandatório confirmar junto à Administração de Redes que o objeto de computador correspondente ao hostname desta máquina esteja **removido do Active Directory**, caso tenha havido falhas anteriores de ingresso no domínio (evitando conflitos de Service Principal Name - SPN).

## ⚙️ Configuração de Ambiente (Ajuste Obrigatório)

A seção de variáveis (`VARIÁVEIS DE AMBIENTE`) do script `setup.sh` deve ser rigorosamente configurada com os parâmetros da rede corporativa:

| Variável | Exemplo | Função no Processo de Integração |
| :--- | :--- | :--- |
| `DOMINIO_KERBEROS` | `GMAP.CD` | Define o **Realm Kerberos** (identificador oficial do domínio, sempre em **MAIÚSCULAS**). |
| `DOMINIO_DNS` | `gmap.cd` | Especifica o **Sufixo DNS** do domínio (para resolução de nomes e serviços, em **minúsculas**). |
| `DNS1` | `10.172.2.2` | Endereço IP do **Controlador de Domínio (DC) Primário**, utilizado como referência de tempo e resolução. |
| `DNS2` | `192.168.23.254` | Endereço IP do **DC Secundário**, provendo redundância na resolução de nomes. |
| `USER_ADMIN_AD` | `rds_suporte.ti` | Conta de usuário do AD com permissões delegadas para realizar o **Domain Join** (ingresso de máquinas no domínio). |

## 🚀 Guia Formal de Procedimento (`setup.sh`)

1.  Salve o arquivo como `setup.sh`.
2.  Conceda a permissão de execução:
    ```bash
    chmod +x setup.sh
    ```
3.  Execute o script com privilégios de root:
    ```bash
    sudo ./setup.sh
    ```
4.  O sistema solicitará a **senha da conta administrativa do AD** (`$USER_ADMIN_AD`) para autenticar o processo de ingresso no domínio.
5.  **Finalização:** Após a conclusão bem-sucedida, o script exige um **reboot** do sistema para carregar integralmente os novos módulos de autenticação (SSSD) e políticas (adsys).

## 🧠 Detalhamento Técnico da Execução (Fluxo de Trabalho do Script)

O script `setup.sh` executa a integração em três fases sequenciais:

### FASE I: PRÉ-REQUISITOS E BLINDAGEM DE SISTEMA

| Ação Principal | Detalhe Técnico | Propósito Estratégico |
| :--- | :--- | :--- |
| **Fixação de DNS** | Desabilita `systemd-resolved` e usa `chattr +i /etc/resolv.conf`. | **Blindagem anti-falha de Kerberos:** Garante que o cliente Ubuntu use **apenas** os Controladores de Domínio para resolução de nomes. |
| **Sincronização NTP** | Utiliza `ntpdate` (sincronia imediata) e `timedatectl` (serviço persistente). | Defesa contra a rejeição de tickets de autenticação pelo AD, que exige desvio de tempo inferior a 5 minutos. |

### FASE II: CONFIGURAÇÃO DE SERVIÇOS E PROTOCOLOS

| Serviço | Configuração Chave | Resultado Funcional |
| :--- | :--- | :--- |
| **Samba (`smb.conf`)** | `security = ads`, `kerberos method = secrets and keytab` | Ativa o modo de segurança AD, permitindo o uso do SSO para o acesso a recursos SMB de rede. |
| **SSSD (`sssd.conf`)** | `use_fully_qualified_names = true` e `fallback_homedir = /home/%u@%d` | **Padrão UPN Formal:** Configura o sistema para **forçar o login completo** (`usuario@dominio`) e padroniza a criação de diretórios pessoais. |

### FASE III: JOIN, GPO e Verificação

| Comando | Propósito | Benefício para a Administração de TI |
| :--- | :--- | :--- |
| **`realm join ...`** | Realiza o ingresso formal da máquina no domínio. | Cria o objeto de computador no AD (SPN) e integra o SSSD/PAM ao sistema de autenticação. |
| **`sudo systemctl enable --now adsys.service`** | Ativação do **`adsys`**. | **Habilita a aplicação das GPOs** no cliente Linux, permitindo o gerenciamento centralizado do desktop. |
| **`sudo net ads testjoin`** | **Verificação Final de Confiança.** | Confirma a integridade da conexão Kerberos e valida que o Samba está apto para o SSO. |

---

## 🧪 Pós-Execução e Validação (Testes)

Após o **reboot**, valide a integração:

1.  **Teste de Autenticação UPN/SSO:** O login deve ser realizado com o formato **UPN COMPLETO** (Ex: `mataburro.pacheco@gmap.cd`).
2.  **Teste de Acesso a Compartilhamentos SMB (SSO):** O acesso a servidores (Ex: `smb://DSKALCUBQ01`) deve ocorrer de forma **imediata e transparente**, sem solicitação de credenciais.
3.  **Teste de Aplicação de GPO (`adsys`):** Verifique se as políticas definidas no AD foram aplicadas.

---

## 4. PROCEDIMENTO SUPLEMENTAR: Instalação de Ferramentas de Suporte (`apps.sh`)

Este script é opcional e deve ser executado **após o reboot** da máquina e a confirmação do Domain Join, para instalar as ferramentas de suporte remoto e configurar o acesso de TI.

### ⚙️ Variáveis de Segurança (Ajuste Obrigatório)

O script utiliza variáveis internas de segurança que devem ser revistas:

| Variável | Valor Padrão (Interno) | Função no Processo |
| :--- | :--- | :--- |
| `USER_SUPORTE` | `gmap` | Nome do usuário de suporte técnico local a ser criado. |
| `SENHA_INICIAL` | `159753` (Senha padrão) | Senha inicial temporária, armazenada como hash para segurança no script. |

### 🚀 Guia de Execução Suplementar

1.  Salve o código como `apps.sh`.
2.  Conceda a permissão de execução: `chmod +x apps.sh`
3.  Execute o script com privilégios de root: `sudo ./apps.sh`

### 🧠 Detalhamento da Execução do `apps.sh`

O script realiza as seguintes ações:

| Ação | Ferramenta | Propósito Estratégico |
| :--- | :--- | :--- |
| **Acesso Remoto** | AnyDesk | Instalação via repositório oficial para suporte em tempo real (on-demand). |
| **Cliente Universal** | Remmina | Instalação do cliente com suporte a plugins RDP e VNC (essencial para conexões múltiplas). |
| **Servidor de Tela** | Vino (Servidor VNC) | Habilita o servidor VNC nativo do GNOME, permitindo o compartilhamento de tela para suporte. |
| **Acesso via Terminal** | OpenSSH Server | Instala o servidor SSH para acesso seguro via terminal pelo usuário `gmap`. |
| **Criação de Usuário** | Usuário `gmap` | Cria o usuário local `gmap`, concede acesso `sudo` e define a senha inicial (`159753`). |

### 🚨 Aviso Crítico de Segurança

O usuário `gmap` é criado com uma senha padrão e pré-definida. É **mandatório** que esta senha seja alterada imediatamente após o primeiro uso, a fim de mitigar riscos de segurança.