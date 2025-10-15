# DOCUMENTAÇÃO DE PROCEDIMENTO: Integração de Clientes Ubuntu no Active Directory (AD)

## 🎯 Sumário Executivo: Objetivo da Solução

Este documento detalha o script Bash (`setup.sh`), uma ferramenta desenvolvida para automatizar e padronizar o ingresso de **Estações de Trabalho Ubuntu** no ambiente de domínio Active Directory (AD).

A solução visa assegurar a **Conformidade Operacional** e a **Experiência do Usuário (UX)** por meio de três pilares centrais:

1.  **Acesso Unificado (Single Sign-On - SSO):** Permite que o colaborador utilize sua credencial de rede (UPN: `usuario@dominio.com`) para acessar o sistema operacional e os recursos de rede (SMB/Windows), eliminando a necessidade de múltiplas autenticações.
2.  **Governança de Políticas (GPO):** Garante que o ambiente Ubuntu receba e aplique as **Políticas de Grupo (GPOs)** estabelecidas na infraestrutura Windows (via serviço `adsys`), mantendo a segurança e o controle centralizado.
3.  **Robustez e Estabilidade:** Implementa mecanismos de "blindagem" no sistema operacional para prevenir falhas comuns de autenticação (Kerberos) causadas por inconsistências de rede (DNS e NTP).

## ⚠️ Condições de Execução e Pré-requisitos

Para garantir o sucesso do procedimento, observe as seguintes condições:

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
| `USER_ADMIN_AD` | `rds_suporte.ti` | Conta de usuário do AD com permissões delegadas para realizar o **Domain Join**. |

## 🚀 Guia Formal de Procedimento

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

## 🧠 Detalhamento Técnico (Ações de Robustez)

O sucesso da integração reside na precisão das configurações de sistema:

### Seção 1: Estabilização de Rede e Tempo

| Ação Principal | Detalhe Técnico | Propósito Estratégico |
| :--- | :--- | :--- |
| **Fixação de DNS** | Desabilita o serviço `systemd-resolved` e utiliza o comando `chattr +i /etc/resolv.conf`. | Garante que o cliente Ubuntu **apenas consulte os DCs**, eliminando a causa mais comum de falha no protocolo Kerberos. |
| **Sincronização NTP** | Utiliza `ntpdate` (sincronia imediata) e `timedatectl` (serviço persistente). | É uma defesa contra a rejeição de tickets de autenticação pelo AD, que exige que o desvio de tempo seja inferior a 5 minutos. |

### Seção 2: Configuração de Serviços Essenciais

| Serviço | Configuração Chave | Resultado Funcional |
| :--- | :--- | :--- |
| **Samba (`smb.conf`)** | `security = ads`, `kerberos method = secrets and keytab` | Ativa o modo de segurança AD, permitindo o uso do SSO para o acesso a recursos SMB de rede. |
| **SSSD (`sssd.conf`)** | `use_fully_qualified_names = true` e `fallback_homedir = /home/%u@%d` | **Determina o UPN como formato de login obrigatório** (`usuario@dominio`) e padroniza a criação de diretórios pessoais. |

### Seção 3: Ingresso, Governança e Validação

| Comando | Propósito | Benefício para a Administração de TI |
| :--- | :--- | :--- |
| **`realm join ...`** | Realiza o ingresso formal da máquina no domínio. | Cria a identidade de segurança do computador (SPN) no AD e integra o SSSD/PAM ao sistema. |
| **`sudo systemctl enable --now adsys.service`** | Ativa o serviço **`adsys`**. | **Habilita a aplicação das GPOs** do AD no cliente Linux, permitindo o gerenciamento centralizado do desktop. |
| **`sudo net ads testjoin`** | **Verificação Final de Confiança ADS.** | Confirma a integridade da conexão Kerberos e valida que o Samba está apto para o SSO. |

## 🧪 Validação Pós-Implementação

Após o **reboot** obrigatório, a integração deve ser validada pelos seguintes testes:

1.  **Teste de Autenticação UPN (SSO):**
    * No *prompt* de login, o usuário deve selecionar "Não listado?" e autenticar utilizando o formato **UPN COMPLETO** (Ex: `usuario.sobrenome@gmap.cd`).
2.  **Teste de Acesso a Recursos SMB:**
    * No navegador de arquivos (Nautilus), acesse um servidor de arquivos utilizando o endereço (Ex: `smb://SRVFILE01`).
    * O acesso deve ser concedido de forma **imediata e transparente**, sem que o sistema solicite a credencial de rede.
3.  **Teste de Aplicação de GPO (`adsys`):**
    * Verifique se uma política de grupo de máquina (ex: bloqueio de área de trabalho) definida no AD foi aplicada ao ambiente. O status pode ser inspecionado via terminal:
    ```bash
    sudo adsysctl update --machine --wait
    ```