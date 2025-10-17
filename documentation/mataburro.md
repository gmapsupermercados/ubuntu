# 📝 Documentação Técnica: Reparo e Implantação de Membro de Domínio (AD/Samba/Winbind)

## 📅 Status de Reparo do Servidor DSKCDSUBQ02

Este documento registra o processo de correção do servidor **DSKCDSUBQ02** após a mudança acidental do hostname e serve como guia para futuras implantações. Após configurar conforme o documento abaixo, será possível o TS (servidor do consinco) acessar a pasta/impressora compartilhada via SAMBA (SMB).


| Área | Parâmetro | Valor Encontrado | Status | Observações |
| :--- | :--- | :--- | :--- | :--- |
| **Identidade** | Hostname Estático | `DSKCDSUBQ02` | ✅ Corrigido |
| **Endereço IP** | IP Principal (`enp2s0`) | `192.168.22.101/22` | OK |
| **Arquivo Hosts** | Mapeamento IP/FQDN/Host | `192.168.22.101 DSKCDSUBQ02.gmap.cd DSKCDSUBQ02`| ✅ **Crucial para Kerberos** |
| **DNS** | Servidor DNS | `10.172.2.2` | OK (DC Primário) |
| **Integração AD** | `security` / `realm` | `ads` / `GMAP.CD` | OK |
| **Funcionalidade** | `wbinfo -u` e `getent passwd` | FUNCIONANDO | **SUCESSO** (Resolução de Usuários/Grupos) |
| **ID Mapeamento**| Backend/Range | `rid` / `10000-999999` | OK (Baseado em RID do AD) |
| **Serviços** | `winbind` e `smbd` | `active (running)` | OK |

---

## II. Guia de Implantação: Nova Máquina Membro de Domínio (Template)

Este guia define o processo para configurar uma nova máquina Linux (Ubuntu 24.04 LTS) com sucesso na integração ao AD (Domínio: `GMAP.CD`).

### Fase 1: Preparação do Hostname e Rede

1.  **Definir Hostname Exclusivo (Ex: NOVA_MAQUINA):**
    ```bash
    sudo hostnamectl set-hostname NOVA_MAQUINA
    ```

2.  **Configurar IP Estático e DNS:**
    * Definir um IP estático (Ex: `192.168.22.XXX`) e garantir que o DNS principal seja o DC (`10.172.2.2`).
    * **Teste de Conectividade:** `ping 10.172.2.2` e `nslookup ad.gmap.cd`.

3.  **Ajustar o Arquivo Hosts (`/etc/hosts`):**
    * Mapear o IP da nova máquina para o FQDN e nome curto, seguindo o padrão corrigido.
    ```bash
    sudo nano /etc/hosts
    
    # Exemplo: Substituir XXX pelo IP estático da nova máquina
    127.0.0.1      localhost
    127.0.1.1      NOVA_MAQUINA.gmap.cd NOVA_MAQUINA
    192.168.22.XXX NOVA_MAQUINA.gmap.cd NOVA_MAQUINA
    ```

### Fase 2: Instalação e Configuração Base

1.  **Instalar Pacotes Essenciais:**
    ```bash
    sudo apt update
    sudo apt install -y samba winbind krb5-user libnss-winbind acl
    ```

2.  **Configurar o Kerberos (`/etc/krb5.conf`):**
    * Garantir o mapeamento correto do KDC.
    ```bash
    sudo nano /etc/krb5.conf
    # Deve conter a seguinte estrutura (Verifique se as entradas batem com o seu ambiente):
    [libdefaults]
        default_realm = GMAP.CD
    [realms]
        GMAP.CD = {
            kdc = ad.gmap.cd
            admin_server = ad.gmap.cd
        }
    [domain_realm]
        .gmap.cd = GMAP.CD
        gmap.cd = GMAP.CD
    ```

3.  **Configurar o Samba (`/etc/samba/smb.conf`):**
    * **Ação:** Copiar a estrutura `[global]` funcional do `DSKCDSUBQ02`.
    ```bash
    sudo nano /etc/samba/smb.conf
    
    [global]
        workgroup = GMAP
        realm = GMAP.CD
        security = ads
        kerberos method = secrets and keytab
        winbind use default domain = yes
        winbind offline logon = yes

        # ID MAPPING (CRÍTICO)
        idmap config * : backend = tdb
        idmap config * : range = 3000-7999
        idmap config GMAP : backend = rid
        idmap config GMAP : range = 10000-999999
        
        # Templates de Usuário (Necessário para logins de domínio)
        template shell = /bin/bash
        template homedir = /home/%D/%U
        
        # [...] outras configurações (log, printing, etc.)
    ```

### Fase 3: Adesão ao Domínio (JOIN)

1.  **Testar a Sintaxe do Samba:**
    ```bash
    testparm
    ```

2.  **Unir ao Domínio (JOIN):**
    * Usar a conta de administrador de domínio (ex: `rds_suporte.ti`).
    ```bash
    sudo net ads join -U rds_suporte.ti
    ```

3.  **Integrar o Winbind no NSS (Name Service Switch):**
    * Forçar o sistema operacional a usar o Winbind para autenticação.
    ```bash
    sudo sed -i 's/^passwd:.*$/passwd: files systemd winbind/' /etc/nsswitch.conf
    sudo sed -i 's/^group:.*$/group: files systemd winbind/' /etc/nsswitch.conf
    ```

4.  **Reiniciar Serviços:**
    ```bash
    sudo systemctl restart winbind smbd nmbd
    ```

### Fase 4: Testes de Validação Final

1.  **Verificar Resolução de Usuários/Grupos:**
    ```bash
    wbinfo -u
    wbinfo -g
    getent passwd um_usuario_do_dominio
    ```

2.  **Testar Confiança (Opcional, pode falhar mas o serviço funcionar):**
    ```bash
    wbinfo -t
    # O sucesso real é o wbinfo -u funcionar.
    ```

---

## III. Template de Compartilhamento de Pasta

*Exemplo de seção a ser adicionada ao `/etc/samba/smb.conf` para compartilhamento de dados com grupos do AD.*

```ini
[Dados Compartilhados]
    comment = Compartilhamento de Dados para o Time de TI
    path = /mnt/dados/ti_dados
    read only = no
    guest ok = no
    browseable = yes
    writable = yes
    
    # Restringe acesso apenas a membros do grupo 'ti'
    valid users = @GMAP\ti
    
    # Garante que novos arquivos herdem as permissões de grupo
    force group = ti
    create mask = 0660
    directory mask = 0770