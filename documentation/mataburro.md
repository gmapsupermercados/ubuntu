# 🧩 Guia Técnico Unificado — Implantação e Reparo de Membro de Domínio (AD / Samba / Winbind)

Este documento consolida **todas as etapas de instalação, correção e integração** de uma máquina **Ubuntu Desktop** ao **Active Directory** (`GMAP.CD`), garantindo:

- Autenticação de usuários do AD no **login gráfico** (GDM / AnyDesk);
- Funcionamento de **compartilhamentos SMB** integrados ao domínio;
- Correção de falhas conhecidas em **Kerberos** e **PAM/Winbind**.

---

## 🧭 I. Histórico de Reparo — Servidor `DSKCDSUBQ02`

O erro de login na console (“Falha ao definir credenciais”) foi solucionado ao corrigir a configuração do **Kerberos**, fixando o IP do **KDC** (Controlador de Domínio).

| Área | Parâmetro | Valor Encontrado | Status | Observações |
| :--- | :--- | :--- | :--- | :--- |
| **Causa Raiz** | `kinit: Cannot contact any KDC` | Falha de comunicação com KDC | ✅ **Resolvido** | Ajustado IP fixo do DC |
| **Correção Aplicada** | `kdc` / `admin_server` | `10.172.2.2` | ✅ **Resolvido** | Comunicação direta com o DC |
| **Validação Final** | Login Console AD | OK | 🟢 **Sucesso total** | Autenticação via domínio restaurada |

---

## ⚙️ II. Guia de Implantação — Passo a Passo Cronológico

### 🔹 Fase 1 — Preparação do Sistema

| Etapa | Comando(s) | Descrição Técnica |
| :--- | :--- | :--- |
| **1. Atualização e Instalação de Pacotes** | ```bash sudo apt update && sudo apt install -y ntp samba winbind krb5-user libnss-winbind acl ``` | Instala pacotes essenciais. O NTP é **crítico** para o Kerberos. |
| **2. Definir Hostname** | ```bash sudo hostnamectl set-hostname NOME_DA_MAQUINA ``` | Define o nome estático da máquina que será registrada no AD. |
| **3. Sincronizar Relógio com o DC** | ```bash sudo ntpdate -s 10.172.2.2 ``` | Corrige o *clock skew* (diferença de tempo) com o DC. |
| **4. Ajustar `/etc/hosts`** | ```bash sudo nano /etc/hosts ``` <br> Adicionar a linha:<br>`192.168.22.XXX NOME_DA_MAQUINA.gmap.cd NOME_DA_MAQUINA` | Garante a resolução correta do FQDN local. |
| **5. Desabilitar Wayland (para Login GDM/AnyDesk)** | ```bash sudo sed -i 's/^#WaylandEnable=false/WaylandEnable=false/' /etc/gdm3/custom.conf ``` | Força o uso do Xorg, compatível com autenticação PAM. |

---

### 🔹 Fase 2 — Configuração do Kerberos e Samba

#### 🧱 Arquivo `/etc/krb5.conf`

Substitua **todo o conteúdo** pelo bloco abaixo:

```ini
[libdefaults]
    default_realm = GMAP.CD
    dns_lookup_realm = true
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[realms]
    GMAP.CD = {
        kdc = 10.172.2.2
        admin_server = 10.172.2.2
    }

[domain_realm]
    .gmap.cd = GMAP.CD
    gmap.cd = GMAP.CD
```

---

#### 🧱 Arquivo `/etc/samba/smb.conf`

Substitua o conteúdo da seção `[global]` pelo bloco abaixo:

```ini
[global]
    workgroup = GMAP
    realm = GMAP.CD
    security = ads
    kerberos method = secrets and keytab

    winbind use default domain = yes
    winbind offline logon = yes

    # ID MAPPING
    idmap config * : backend = tdb
    idmap config * : range = 3000-7999
    idmap config GMAP : backend = rid
    idmap config GMAP : range = 10000-999999

    # Templates de Usuário
    template shell = /bin/bash
    template homedir = /home/%D/%U
```

##### Exemplo de compartilhamento SMB

Adicione ao final do arquivo:

```ini
[Dados_Ti]
    comment = Compartilhamento de Dados do Time de TI
    path = /mnt/dados/ti_dados
    read only = no
    guest ok = no
    browseable = yes
    writable = yes

    # Restringe acesso a membros do grupo 'ti'
    valid users = @GMAP\ti 

    # Garante herança de permissões
    force group = ti
    create mask = 0660
    directory mask = 0770
```

---

### 🔹 Fase 3 — Integração ao Domínio e Autenticação

| Etapa | Comando(s) | Explicação Técnica |
| :--- | :--- | :--- |
| **1. Unir ao Domínio (JOIN)** | ```bash sudo net ads join -U rds_suporte.ti ``` | Junta a máquina ao AD, criando a conta de computador. |
| **2. Integrar Winbind ao NSS** | ```bash sudo sed -i 's/^passwd:.*$/passwd: files systemd winbind/' /etc/nsswitch.conf``` <br> ```bash sudo sed -i 's/^group:.*$/group: files systemd winbind/' /etc/nsswitch.conf``` | Permite que o sistema busque usuários e grupos do AD. |
| **3. Configurar PAM para Login Gráfico** | ```bash sudo pam-auth-update --enable mkhomedir --force ``` | Cria a pasta `/home/%D/%U` no primeiro login do usuário. |
| **4. Reiniciar Serviços Principais** | ```bash sudo systemctl restart winbind smbd nmbd gdm3 ``` | Recarrega os serviços e o Keytab recém-gerado. |

---

### 🔹 Fase 4 — Testes de Validação

| Etapa | Comando(s) | Verificação Esperada |
| :--- | :--- | :--- |
| **1. Testar Kerberos** | ```bash kinit rds_suporte.ti@GMAP.CD && klist ``` | Exibe ticket válido (`Default principal`). |
| **2. Testar Resolução de Usuários AD** | ```bash wbinfo -u``` <br> ```bash getent passwd rds_suporte.ti``` | Usuários do domínio devem aparecer listados. |
| **3. Testar Login Gráfico** | **Fazer login via GDM ou AnyDesk** com usuário AD. | Login deve criar `/home/GMAP/usuario` automaticamente. |

---

## 🧰 Dicas de Diagnóstico

| Comando | Finalidade |
| :--- | :--- |
| `realm list` | Mostra detalhes da integração ao domínio. |
| `wbinfo -g` | Lista grupos do AD disponíveis. |
| `systemctl status winbind` | Verifica o status do serviço Winbind. |
| `sudo tail -f /var/log/syslog` | Monitora logs em tempo real para depuração. |
| `kdestroy` | Remove tickets Kerberos para testes limpos. |

---

## ✅ Conclusão

Após seguir todas as etapas:

- A máquina deve estar **integrada ao domínio GMAP.CD**;  
- Usuários AD podem **fazer login gráfico normalmente**;  
- Compartilhamentos SMB aparecem com **controle de acesso do AD**;  
- Erros de `Cannot contact any KDC` ou `Falha ao definir credenciais` não devem mais ocorrer.

---

📌 **Responsável Técnico:** Equipe de Suporte TI – GMAP  
📅 **Versão do Documento:** 2.0 (Outubro/2025)  
💻 **Compatibilidade:** Ubuntu Desktop 22.04 LTS / 24.04 LTS
