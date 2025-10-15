# :Integração de Estações de Trabalho Ubuntu no Active Directory (AD)

## 🎯 Objetivo: Solução de Integração de Clientes Ubuntu

Este script Bash (`setup.sh`) foi desenvolvido para automatizar e robustecer a integração de **Estações de Trabalho Cliente Ubuntu** em ambientes de domínio Active Directory (AD).

O processo garante **três pilares** de integração essenciais para ambientes corporativos:

1.  **Single Sign-On (SSO) Preciso:** Autenticação de domínio no desktop via **UPN** (ex: `usuario@dominio.com`) e acesso transparente a compartilhamentos de rede SMB/Windows.
2.  **Gerenciamento de Políticas (GPO):** Total aplicação das Políticas de Grupo (GPOs) do AD na máquina Ubuntu, utilizando o serviço **`adsys`** da Canonical.
3.  **Estabilidade Crítica:** Blindagem contra falhas recorrentes de Kerberos (DNS e NTP) por meio de configurações do sistema operacional.

## ⚠️ Pré-requisitos e Avisos de Implementação

1.  **Sistema Base:** O script é otimizado para ser executado em uma instalação **limpa e atualizada** do Ubuntu Desktop (versão 20.04 LTS ou superior é recomendada).
2.  **Privilégios:** A execução deve ser feita por um usuário com permissões de `sudo`.
3.  **Higiene do AD:** Se a máquina cliente já ingressou no domínio e falhou anteriormente, **confirme que o objeto do computador foi removido do AD** para evitar a reutilização de Service Principal Name (SPN/Kerberos).

## ⚙️ Variáveis de Ambiente (Ajuste Obrigatório)

Edite esta seção no script `setup.sh` com as informações do seu domínio:

| Variável | Valor Exemplo | Descrição Técnica |
| :--- | :--- | :--- |
| `DOMINIO_KERBEROS` | `GMAP.CD` | O **Realm Kerberos** (Nome do Domínio em **MAIÚSCULAS**). |
| `DOMINIO_DNS` | `gmap.cd` | O **Sufixo DNS** do domínio (Nome do Domínio em **minúsculas**). |
| `DNS1` | `10.172.2.2` | **IP do Controlador de Domínio (DC) Primário.** Fonte de DNS e Sincronização de Tempo (NTP). |
| `DNS2` | `192.168.23.254` | **IP do DC Secundário.** |
| `USER_ADMIN_AD` | `rds_suporte.ti` | Usuário do AD com privilégio de **Domain Join** (ingresso de máquinas no domínio). |

## 🚀 Guia de Execução

1.  Salve o código com o nome `setup.sh`.
2.  Conceda permissão de execução:
    ```bash
    chmod +x setup.sh
    ```
3.  Execute o script com privilégios de root:
    ```bash
    sudo ./setup.sh
    ```
4.  O script solicitará a **senha do usuário administrador do AD** (`$USER_ADMIN_AD`) durante a fase de ingresso no domínio.
5.  **Ação Final:** Ao concluir, um **`sudo reboot`** é obrigatório para que os novos serviços (SSSD, Samba, Adsys) sejam carregados corretamente.

## 🧠 Explicação Técnica Detalhada (Assegurando Confiança)

O script utiliza uma arquitetura de integração modular com foco na prevenção de erros:

### Seção 1: PRÉ-REQUISITOS E BLINDAGEM DE SISTEMA

| Ação Principal | Detalhe Técnico | Objetivo de Segurança/Estabilidade |
| :--- | :--- | :--- |
| **Fixação de DNS** | Desabilita `systemd-resolved` e usa `chattr +i /etc/resolv.conf`. | Garante que **somente** os Controladores de Domínio sejam usados para resolução, eliminando ambiguidades de Kerberos. |
| **Sincronização NTP Robusta** | Usa `ntpdate` (sincronia imediata) seguido de `timedatectl` (serviço persistente). | É a dupla camada de proteção para garantir que o relógio da máquina não tenha desvio superior a 5 minutos, o que é um bloqueio fatal no AD. |

### Seção 2: CONFIGURAÇÃO DE SERVIÇOS E PROTOCOLOS

| Serviço | Configuração Chave | Resultado |
| :--- | :--- | :--- |
| **Samba (`smb.conf`)** | `security = ads`, `kerberos method = secrets and keytab` | Habilita o protocolo SMB a usar o tíquete Kerberos da máquina para acesso SSO. |
| **SSSD (`sssd.conf`)** | `use_fully_qualified_names = true`, `fallback_homedir = /home/%u@%d` | **Força o login por UPN** (`usuario@dominio`) e garante que os diretórios home sejam criados no formato específico de UPN. |

### Seção 3: JOIN, GPO e Verificação

| Comando | Propósito | Benefício de TI |
| :--- | :--- | :--- |
| **`realm join ...`** | Ingresso no domínio. | Cria o objeto de computador no AD (SPN) e configura automaticamente o SSSD/PAM para autenticação. |
| **`sudo systemctl enable --now adsys.service`** | Ativação do **`adsys`**. | **Integração GPO:** Permite que o cliente Ubuntu aplique políticas de usuário e máquina definidas no Console de Gerenciamento de Política de Grupo do AD. |
| **`sudo net ads testjoin`** | **Verificação Final de Confiança.** | Confirma a integridade da relação de confiança ADS/Kerberos para o Samba, essencial para o acesso a arquivos. |

## 🧪 Pós-Execução e Validação (Testes)

Após o **reboot**, valide a integração:

1.  **Teste de Login UPN/SSO:**
    * Faça **Logout**.
    * Na tela de login, selecione "Não listado?" e use o login **COMPLETO** (UPN), por exemplo: `mataburro.pacheco@gmap.cd`.
2.  **Teste de Acesso a Compartilhamentos SMB (SSO):**
    * Abra o Gerenciador de Arquivos (Nautilus).
    * Pressione `Ctrl+L` e acesse um servidor (Ex: `smb://192.168.23.4` ou `smb://DSKALCUBQ01`).
    * O acesso deve ocorrer **instantaneamente e sem solicitação de senha**.
3.  **Teste de Aplicação de GPO (`adsys`):**
    * Verifique se as políticas definidas no AD foram aplicadas.
    * Você pode forçar a atualização das políticas para fins de teste:
    ```bash
    sudo adsysctl update --machine --wait
    ```