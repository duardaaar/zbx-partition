# Particionamento do Zabbix 7.0 LTS (PostgreSQL)

Script em Bash que converte as tabelas de histórico do Zabbix para **particionamento nativo do PostgreSQL** e mantém as partições automaticamente com um **systemd timer**, substituindo o housekeeper.

| Tabelas                  | Partição | Retenção padrão |
|--------------------------|----------|-----------------|
| `history`, `history_uint`| Diária   | 90 dias         |
| `trends`, `trends_uint`  | Diária   | 90 dias         |

---

## Sumário

- [Por que particionar](#por-que-particionar)
- [Como funciona](#como-funciona)
- [Requisitos](#requisitos)
- [Arquivos do repositório](#arquivos-do-repositório)
- [Instalação](#instalação)
- [Parâmetros (.env)](#parâmetros-env)
- [Comandos](#comandos)
- [O timer diário](#o-timer-diário)
- [Pontos importantes](#pontos-importantes)
- [Solução de problemas](#solução-de-problemas)
- [Segurança](#segurança)

---

## Por que particionar

Por padrão, o **housekeeper** do Zabbix apaga dados antigos com `DELETE` linha a linha. Em bancos grandes isso gera muita carga de disco, *bloat* nas tabelas e lentidão.

Com particionamento, cada dia de dados fica em uma tabela própria (partição). Apagar um dia inteiro vira um `DROP TABLE`, que é **instantâneo** e não deixa lixo no banco.

---

## Como funciona

1. **Conversão (uma única vez):** as tabelas viram tabelas particionadas por **range na coluna `clock`** (epoch em inteiro), com uma partição por dia.
2. **Partições futuras:** o script mantém sempre **7 dias à frente** já criados. Se o agendamento falhar por alguns dias, o Zabbix continua gravando normalmente.
3. **Retenção:** a cada execução, toda partição cujo dia terminou há mais de **90 dias** é apagada.
4. **Housekeeper desativado:** o housekeeper de history e trends é desligado, para não concorrer com o particionamento.
5. **Agendamento:** um **systemd timer** roda a manutenção todos os dias às 03:30.

Exemplo com retenção de 90 dias, executando em 30/09/2026:

```
 apagadas            mantidas (90 dias)                  futuras (7 dias)
┌────────────┬─────────────────────────────────────┬─────────────────────┐
│ ... 01/07  │ 02/07 ................... 30/09     │ 01/10 ...... 07/10  │
└────────────┴─────────────────────────────────────┴─────────────────────┘
```

Nomes das partições: `history_p2026_09_30`, `trends_uint_p2026_10_01`, etc.

---

## Requisitos

- Zabbix **7.0 LTS** com banco **PostgreSQL**
- Executar **no servidor de banco** (ou no servidor único, quando banco e aplicação estão juntos)
- `psql` (pacote `postgresql-client`) e `flock` (pacote `util-linux`), já presentes no servidor de banco
- Conexão com o usuário **dono das tabelas** (normalmente `zabbix`) — o script recusa outro usuário, porque o Zabbix perderia permissão nas tabelas novas
- Acesso `root`/`sudo` para instalar o timer

> 💡 Tire um **snapshot ou backup do banco** antes do `init`. A conversão altera a estrutura das tabelas.

---

## Arquivos do repositório

| Arquivo              | Descrição                                                   |
|----------------------|-------------------------------------------------------------|
| `zbx-partition.bash` | Script de particionamento                                   |
| `.env.example`       | Modelo de parâmetros                                        |
| `.gitignore`         | Impede que o `.env` (com a senha) seja enviado ao repositório |

---

## Instalação

**1. Clone o repositório no servidor de banco**

```bash
git clone https://github.com/duardaaar/zbx-partition.git
cd zbx-partition
```

**2. Crie o `.env`**

```bash
cp .env.example .env
nano .env            # defina pelo menos ZBX_DB_PASS
chmod 600 .env
```

> Se o script ficar na mesma pasta do `.env` usado na instalação do banco, você pode usar esse mesmo arquivo: basta acrescentar as linhas `ZBX_PART_*`.

**3. Veja o plano sem alterar nada**

```bash
sudo bash zbx-partition.bash init --dry-run
```

Confira quantas linhas e partições cada tabela terá e se alguma linha será descartada.

**4. Pare o Zabbix server** (no servidor da aplicação)

```bash
sudo systemctl stop zabbix-server
```

**5. Converta as tabelas** (no servidor de banco)

```bash
sudo bash zbx-partition.bash init
```

O script mostra o plano e pede que você digite `PARTICIONAR` para confirmar.

**6. Inicie o Zabbix server** (no servidor da aplicação)

```bash
sudo systemctl start zabbix-server
```

**7. Instale o timer diário** (no servidor de banco)

```bash
sudo bash zbx-partition.bash install-timer
```

**8. Confira**

```bash
sudo bash zbx-partition.bash status
```

No frontend, confira em *Monitoring → Latest data* se os valores continuam chegando e, em *Administration → Housekeeping*, se history e trends aparecem desativados.

---

## Parâmetros (.env)

```env
# --- Conexão com o banco (OBRIGATÓRIO) ---
ZBX_DB_HOST=localhost
ZBX_DB_PORT=5432
ZBX_DB_NAME=zabbix
ZBX_DB_USER=zabbix
ZBX_DB_PASS=sua_senha_aqui

# --- Opcional (valores padrão) ---
ZBX_PART_HISTORY_DAYS=90
ZBX_PART_TRENDS_DAYS=90
ZBX_PART_HISTORY_PREMAKE=7
ZBX_PART_TRENDS_PREMAKE=7
ZBX_PART_HISTORY_TABLES=history history_uint
ZBX_PART_TRENDS_TABLES=trends trends_uint
ZBX_PART_ONCALENDAR=*-*-* 03:30:00
```

| Variável                   | Descrição                                                   | Padrão               |
|----------------------------|-------------------------------------------------------------|----------------------|
| `ZBX_DB_HOST`              | Endereço do PostgreSQL                                      | `localhost`          |
| `ZBX_DB_PORT`              | Porta do PostgreSQL                                         | `5432`               |
| `ZBX_DB_NAME`              | Nome do banco                                               | `zabbix`             |
| `ZBX_DB_USER`              | Usuário (dono das tabelas)                                  | `zabbix`             |
| `ZBX_DB_PASS`              | Senha — **obrigatória para o timer**                        | *(perguntada)*       |
| `ZBX_PART_HISTORY_DAYS`    | Retenção de history, em dias                                | `90`                 |
| `ZBX_PART_TRENDS_DAYS`     | Retenção de trends, em dias                                 | `90`                 |
| `ZBX_PART_HISTORY_PREMAKE` | Dias de partições futuras de history                        | `7`                  |
| `ZBX_PART_TRENDS_PREMAKE`  | Dias de partições futuras de trends                         | `7`                  |
| `ZBX_PART_HISTORY_TABLES`  | Tabelas de history particionadas                            | `history history_uint` |
| `ZBX_PART_TRENDS_TABLES`   | Tabelas de trends particionadas                             | `trends trends_uint` |
| `ZBX_PART_ONCALENDAR`      | Horário do timer ([formato OnCalendar](https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html)) | `*-*-* 03:30:00` |

### API do Zabbix (opcional)

O housekeeper é desativado **direto no banco** por padrão. Se preferir usar a API oficial (fica registrado no log de auditoria do Zabbix), acrescente:

```env
ZBX_API_URL=http://IP-DA-APLICACAO/zabbix/api_jsonrpc.php
ZBX_API_TOKEN=seu_token
ZBX_API_INSECURE=no      # yes = aceita certificado HTTPS autoassinado
```

O token é criado no frontend em *User settings → API tokens*, com um usuário **Super admin**. Se a API falhar, o script aplica a alteração pelo banco e avisa.

### Regras do `.env`

- O script lê o `.env` que estiver **na mesma pasta** dele. Para usar outro arquivo: `--env /caminho/arquivo`.
- Valores com ou sem aspas: `ZBX_DB_PASS=abc`, `"abc"` ou `'abc'`.
- Linhas em branco e linhas que começam com `#` são ignoradas. **Não use comentário no fim da linha**: todo o texto após o `=` vira o valor.
- Prioridade: `variável na linha de comando > .env > valor padrão`.

---

## Comandos

```bash
sudo bash zbx-partition.bash <comando> [opções]
```

| Comando         | O que faz                                                                      |
|-----------------|--------------------------------------------------------------------------------|
| `init`          | Converte as tabelas para particionadas (uma única vez), cria as partições e desativa o housekeeper |
| `maintain`      | Cria as partições futuras e apaga as vencidas — é o que o timer executa        |
| `housekeeping`  | Desativa o housekeeper de history e trends                                     |
| `status`        | Mostra partições, tamanhos, housekeeper e timer                                |
| `install-timer` | Instala o systemd timer diário                                                 |
| `remove-timer`  | Remove o timer (as partições não são alteradas)                                |

| Opção           | Descrição                                                    |
|-----------------|--------------------------------------------------------------|
| `--dry-run`     | Mostra o SQL e as ações **sem executar nada**                |
| `--env ARQUIVO` | Usa outro arquivo de parâmetros                              |
| `--yes`         | Não pede confirmação no `init`                               |
| `--force`       | Roda o `init` mesmo com outras conexões ativas no banco      |

Sem comando, o script apenas mostra a ajuda.

### O que o `init` faz em cada tabela

Tudo em **uma transação por tabela** — se der erro, aquela tabela volta ao estado anterior:

1. Bloqueia a tabela e a renomeia para `<tabela>_old`
2. Cria a nova tabela particionada com a mesma estrutura e a mesma chave primária
3. Cria as partições diárias, do dado mais antigo (limitado à retenção) até 7 dias à frente
4. Copia os dados de `<tabela>_old` para a nova tabela
5. Apaga `<tabela>_old`

> ⚠️ Linhas **mais antigas que a retenção** não são copiadas. O `--dry-run` mostra quantas seriam descartadas.

Proteções:

- Recusa rodar com outras conexões no banco (Zabbix server ligado), salvo com `--force`
- Recusa rodar se o usuário da conexão não for o dono das tabelas
- Tabelas já particionadas são ignoradas — rodar o `init` de novo é seguro

### `maintain` é idempotente

Ele só cria as partições que faltam e só apaga as que venceram. Rodar várias vezes no mesmo dia não muda nada.

---

## O timer diário

O `install-timer`:

- copia o script para `/usr/local/sbin/zbx-partition.bash`
- copia o `.env` para `/etc/zbx-partition.env` (permissão `600`)
- cria `zbx-partition.service` e `zbx-partition.timer` em `/etc/systemd/system/`

Com `Persistent=true`, se o servidor estiver desligado no horário, a execução acontece assim que ele ligar.

> ⚠️ Se você alterar o `.env` depois, rode `install-timer` de novo para atualizar a cópia em `/etc/zbx-partition.env`.

**Comandos úteis**

```bash
systemctl list-timers zbx-partition.timer      # próxima execução
sudo systemctl start zbx-partition.service      # executar agora
journalctl -u zbx-partition.service -n 50       # resultado das execuções
tail -n 50 /var/log/zbx-partition.log           # log do script
```

---

## Pontos importantes

### Outras tabelas de history deixam de ser limpas

No Zabbix, o housekeeper de history é **uma única opção para todas as tabelas `history_*`**. Ao desativá-lo, as tabelas abaixo também deixam de ser limpas e crescem sem limite:

- `history_str` (texto curto)
- `history_text` (texto longo)
- `history_log` (logs)
- `history_bin` (binários)

O script mostra um aviso sobre isso. Na maioria dos ambientes elas são pequenas, mas acompanhe o tamanho:

```bash
sudo -u postgres psql zabbix -c "SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) FROM pg_class WHERE relname IN ('history_str','history_text','history_log','history_bin');"
```

Para particioná-las também, inclua-as na variável e rode o `init` de novo (com o Zabbix server parado):

```env
ZBX_PART_HISTORY_TABLES=history history_uint history_str history_text history_log history_bin
```

### A retenção dos itens deixa de valer

O "History storage period" e o "Trend storage period" configurados em cada item ou template **não são mais aplicados**. Quem manda é a retenção das partições (`ZBX_PART_HISTORY_DAYS` e `ZBX_PART_TRENDS_DAYS`).

### Horário das partições em UTC

Os limites das partições seguem **UTC**: no horário de Brasília, cada partição vai das 21h às 21h. Isso não afeta gráficos nem a retenção, apenas os nomes das partições.

### Não reative o housekeeper

Se o housekeeper de history/trends for reativado, ele volta a fazer `DELETE` nas tabelas particionadas, concorrendo com o script. O `maintain` avisa no log quando detecta isso. Para desativar de novo:

```bash
sudo bash zbx-partition.bash housekeeping
```

---

## Solução de problemas

### `Há N outra(s) conexão(ões) no banco`

O Zabbix server (ou o frontend) está conectado. Pare o `zabbix-server` no servidor da aplicação. Se o frontend continuar conectado, pare também o `php*-fpm` durante o `init`.

### `pertence a 'X', mas a conexão usa 'Y'`

`ZBX_DB_USER` precisa ser o dono das tabelas (normalmente `zabbix`).

### `Não foi possível conectar`

Confira usuário, senha e host no `.env`. Teste manualmente:

```bash
psql -h localhost -U zabbix -d zabbix -c "SELECT 1;"
```

### `Outra execução do zbx-partition está em andamento`

O timer está rodando ao mesmo tempo. Aguarde alguns segundos e tente de novo.

### O script só mostrou a ajuda

Faltou o comando: `init`, `maintain`, `status`...

### Zabbix com erro de gravação (`no partition of relation ... found for row`)

Não existe partição para o dia atual — o timer parou de rodar há mais de 7 dias. Crie as partições na hora e verifique o timer:

```bash
sudo bash zbx-partition.bash maintain
systemctl status zbx-partition.timer
journalctl -u zbx-partition.service -n 50
```

---

## Segurança

- **Nunca envie o `.env` para o repositório.** Ele está no `.gitignore`; envie apenas o `.env.example`.
- Mantenha o `.env` com permissão `600` (`chmod 600 .env`).
- A cópia usada pelo timer (`/etc/zbx-partition.env`) também é criada com permissão `600`.
- Faça backup do banco antes do `init`.
