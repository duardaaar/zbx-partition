#!/usr/bin/env bash
# =============================================================================
#  Particionamento das tabelas de histórico do Zabbix 7.0 LTS (PostgreSQL)
#
#  history, history_uint, trends, trends_uint -> partição DIÁRIA
#  Retenção padrão: 90 dias (configurável separadamente para history e trends).
#  Range na coluna "clock" (epoch inteiro). Limites das partições em UTC.
#
#  Comandos:
#     init            converte as tabelas para particionadas (uma única vez),
#                     cria as partições e desativa o housekeeper
#     maintain        cria partições futuras e apaga as vencidas (usado pelo timer)
#     housekeeping    desativa o housekeeper de history/trends e ativa o
#                     override de período com a retenção das partições
#     status          mostra partições, tamanhos, housekeeper e timer
#     install-timer   instala o systemd timer que roda "maintain" todo dia
#     remove-timer    remove o systemd timer
#
#  Opções:
#     --dry-run       mostra o SQL/ações sem executar nada
#     --env ARQUIVO   arquivo de parâmetros (padrão: .env ao lado do script)
#     --yes           não pede confirmação no init
#     --force         roda o init mesmo com outras conexões ativas no banco
#                     ou com pouco espaço livre em disco
#
#  Exemplos:
#     sudo bash zbx-partition.bash init --dry-run
#     sudo bash zbx-partition.bash init
#     sudo bash zbx-partition.bash install-timer
#     sudo bash zbx-partition.bash status
#
#  Prioridade: variável de ambiente na linha de comando > .env > padrão.
# =============================================================================
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Argumentos
# -----------------------------------------------------------------------------
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
ENV_FILE="${SCRIPT_DIR}/.env"
CMD=""; DRY_RUN=0; ASSUME_YES=0; FORCE=0

# Mostra o cabeçalho como ajuda, com o nome real do arquivo nos exemplos
usage() { sed -n "3,/^# ====/p" "$SCRIPT_PATH" | sed "s|zbx-partition\.bash|$(basename "$SCRIPT_PATH")|g"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        init|maintain|housekeeping|status|install-timer|remove-timer)
            [[ -z "$CMD" ]] || { echo "Informe apenas um comando."; exit 1; }
            CMD="$1"; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --yes|-y)  ASSUME_YES=1; shift ;;
        --force)   FORCE=1; shift ;;
        --env)     ENV_FILE="${2:?Informe o caminho do arquivo após --env}"; shift 2 ;;
        --env=*)   ENV_FILE="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Parâmetro desconhecido: $1 (use --help)"; exit 1 ;;
    esac
done
[[ -n "$CMD" ]] || { usage; exit 1; }

# -----------------------------------------------------------------------------
# Arquivo .env (mesmas regras dos scripts de instalação)
# -----------------------------------------------------------------------------
load_env() {
    local file="$1" line key val n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n+1))
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line#export }"
        if [[ ! "$line" =~ ^(ZBX_[A-Z0-9_]+)=(.*)$ ]]; then
            echo "[AVISO] .env linha ${n} ignorada (formato esperado ZBX_CHAVE=valor)." >&2
            continue
        fi
        key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
        if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then
            val="${BASH_REMATCH[1]}"
        fi
        [[ -n "${!key+x}" ]] && continue
        printf -v "$key" '%s' "$val"
    done < "$file"
}
if [[ -f "$ENV_FILE" ]]; then
    load_env "$ENV_FILE"
fi

# -----------------------------------------------------------------------------
# Parâmetros
# -----------------------------------------------------------------------------
ZBX_DB_HOST="${ZBX_DB_HOST:-localhost}"
ZBX_DB_PORT="${ZBX_DB_PORT:-5432}"
ZBX_DB_NAME="${ZBX_DB_NAME:-zabbix}"
ZBX_DB_USER="${ZBX_DB_USER:-zabbix}"
ZBX_DB_PASS="${ZBX_DB_PASS:-}"

ZBX_API_URL="${ZBX_API_URL:-}"              # ex.: http://10.0.0.20/zabbix/api_jsonrpc.php
ZBX_API_TOKEN="${ZBX_API_TOKEN:-}"
ZBX_API_INSECURE="${ZBX_API_INSECURE:-no}"  # yes = aceita certificado HTTPS autoassinado

ZBX_PART_HISTORY_TABLES="${ZBX_PART_HISTORY_TABLES:-history history_uint}"
ZBX_PART_TRENDS_TABLES="${ZBX_PART_TRENDS_TABLES:-trends trends_uint}"
ZBX_PART_HISTORY_DAYS="${ZBX_PART_HISTORY_DAYS:-90}"      # retenção (dias)
ZBX_PART_TRENDS_DAYS="${ZBX_PART_TRENDS_DAYS:-90}"        # retenção (dias)
ZBX_PART_HISTORY_PREMAKE="${ZBX_PART_HISTORY_PREMAKE:-7}" # partições futuras (dias)
ZBX_PART_TRENDS_PREMAKE="${ZBX_PART_TRENDS_PREMAKE:-7}"   # partições futuras (dias)
ZBX_PART_ONCALENDAR="${ZBX_PART_ONCALENDAR:-*-*-* 03:30:00}"

INSTALL_BIN=/usr/local/sbin/zbx-partition.bash
INSTALL_ENV=/etc/zbx-partition.env
UNIT_DIR=/etc/systemd/system

# -----------------------------------------------------------------------------
# Log
# -----------------------------------------------------------------------------
LOG_FILE=/var/log/zbx-partition.log
if [[ $DRY_RUN -eq 1 ]] || ! { touch "$LOG_FILE" 2>/dev/null && [[ -w "$LOG_FILE" ]]; }; then
    LOG_FILE=/dev/null
fi
log()   { local lvl="$1"; shift; printf '%s [%s] %s\n' "$(date '+%F %T')" "$lvl" "$*" | tee -a "$LOG_FILE" >&2; }
info()  { log INFO "$@"; }
warn()  { log AVISO "$@"; }
fatal() { log ERRO "$@"; exit 1; }
trap 'fatal "Falha na linha $LINENO: $BASH_COMMAND"' ERR

# -----------------------------------------------------------------------------
# Validação dos parâmetros
# -----------------------------------------------------------------------------
for v in ZBX_PART_HISTORY_DAYS ZBX_PART_TRENDS_DAYS ZBX_PART_HISTORY_PREMAKE ZBX_PART_TRENDS_PREMAKE; do
    [[ "${!v}" =~ ^[0-9]+$ && "${!v}" -gt 0 ]] || fatal "$v deve ser um número inteiro maior que zero (atual: '${!v}')."
done
for t in $ZBX_PART_HISTORY_TABLES $ZBX_PART_TRENDS_TABLES; do
    [[ "$t" =~ ^[a-z_][a-z0-9_]*$ ]] || fatal "Nome de tabela inválido: '$t'."
done

# -----------------------------------------------------------------------------
# PostgreSQL
# -----------------------------------------------------------------------------
export PGHOST="$ZBX_DB_HOST" PGPORT="$ZBX_DB_PORT" PGDATABASE="$ZBX_DB_NAME" PGUSER="$ZBX_DB_USER"
export PGAPPNAME="zbx-partition" PGCONNECT_TIMEOUT=10
if [[ -n "$ZBX_DB_PASS" ]]; then export PGPASSWORD="$ZBX_DB_PASS"; fi

q() { psql -X -qtA -v ON_ERROR_STOP=1 -c "$1"; }   # consulta (somente leitura)

exec_sql() {  # executa um bloco de SQL; no --dry-run apenas mostra
    local sql="$1" out
    if [[ $DRY_RUN -eq 1 ]]; then
        printf '%s\n' "$sql"
        return 0
    fi
    printf '%s\n' "$sql" >>"$LOG_FILE"
    if ! out=$(printf '%s\n' "$sql" | psql -X -q -v ON_ERROR_STOP=1 2>&1); then
        printf '%s\n' "$out" | tee -a "$LOG_FILE" >&2
        fatal "Erro ao executar o SQL acima. A transação desta etapa foi desfeita; nada foi alterado nela."
    fi
}

relkind() { q "SELECT relkind FROM pg_class WHERE oid = to_regclass('$1')"; }  # p=particionada r=comum

partitions() {  # "nome|limite_superior" de cada partição
    q "SELECT c.relname || '|' || rtrim(split_part(pg_get_expr(c.relpartbound, c.oid), ' TO (', 2), ')')
         FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
        WHERE i.inhparent = '$1'::regclass ORDER BY c.relname"
}

# -----------------------------------------------------------------------------
# Datas (sempre UTC)
# -----------------------------------------------------------------------------
# Todas as partições são diárias. O 1º argumento das funções abaixo é o
# grupo da tabela ("history" ou "trends"), que define retenção e antecedência.
NOW=$(date -u +%s)
epoch()        { date -u -d "$1" +%s; }                    # AAAA-MM-DD -> epoch 00:00 UTC
day_of()       { date -u -d "@$1" +%F; }                   # epoch -> AAAA-MM-DD
next_day()     { date -u -d "$1 +1 day" +%F; }
part_name()    { echo "${1}_p$(date -u -d "$2" +%Y_%m_%d)"; }
retention()    { if [[ $1 == history ]]; then echo "$ZBX_PART_HISTORY_DAYS"; else echo "$ZBX_PART_TRENDS_DAYS"; fi; }
premake()      { if [[ $1 == history ]]; then echo "$ZBX_PART_HISTORY_PREMAKE"; else echo "$ZBX_PART_TRENDS_PREMAKE"; fi; }
cutoff()       { echo $(( NOW - $(retention "$1") * 86400 )); }
premake_until() { epoch "$(date -u -d "today +$(( $(premake "$1") + 1 )) day" +%F)"; }  # fim (exclusivo) da última partição futura

gen_creates() {  # SQL das partições diárias que cobrem [from, to) e ainda não existem
    local t="$1" from="$2" to="$3" existing="$4" d nd s name
    d=$(day_of "$from")
    while :; do
        s=$(epoch "$d")
        [[ $s -lt $to ]] || break
        nd=$(next_day "$d")
        name=$(part_name "$t" "$d")
        if ! grep -qx "$name" <<<"$existing"; then
            echo "CREATE TABLE IF NOT EXISTS ${name} PARTITION OF ${t} FOR VALUES FROM (${s}) TO ($(epoch "$nd"));"
        fi
        d="$nd"
    done
}

each_table() {  # chama "$1 grupo tabela" para todas as tabelas configuradas
    local fn="$1" t
    for t in $ZBX_PART_HISTORY_TABLES; do "$fn" history "$t"; done
    for t in $ZBX_PART_TRENDS_TABLES;  do "$fn" trends  "$t"; done
}

fmt_date() { date -u -d "@$1" '+%F %H:%M UTC'; }

# -----------------------------------------------------------------------------
# maintain: cria partições futuras e apaga as vencidas
# -----------------------------------------------------------------------------
maintain_table() {
    local group="$1" t="$2" existing names creates drops="" dropped="" name upper co n_new n_drop
    case "$(relkind "$t")" in
        p) ;;
        r) warn "$t ainda não é particionada; rode primeiro: $0 init"; return 0 ;;
        *) warn "$t não encontrada; ignorada."; return 0 ;;
    esac

    existing=$(partitions "$t")
    names=$(cut -d'|' -f1 <<<"$existing")
    creates=$(gen_creates "$t" "$NOW" "$(premake_until "$group")" "$names")

    # Apaga partições cujo período terminou antes do limite da retenção
    co=$(cutoff "$group")
    while IFS='|' read -r name upper; do
        [[ -n "$name" && "$upper" =~ ^[0-9]+$ ]] || continue
        if [[ $upper -le $co ]]; then
            drops+="DROP TABLE IF EXISTS ${name};"$'\n'
            dropped+=" ${name}"
        fi
    done <<<"$existing"

    n_new=$(grep -c . <<<"$creates" || true)
    n_drop=$(grep -c . <<<"$drops" || true)
    if [[ $n_new -eq 0 && $n_drop -eq 0 ]]; then
        info "$t: nada a fazer (retenção $(retention "$group") dias; mantém dados desde $(fmt_date "$co"))."
        return 0
    fi
    # Uma transação por tabela: se um comando falhar, nenhuma partição é
    # criada nem apagada nesta tabela.
    local sql="-- ${t}: ${n_new} partição(ões) nova(s), ${n_drop} vencida(s)"$'\n'"BEGIN;"
    if [[ -n "$creates" ]]; then sql+=$'\n'"$creates"; fi
    if [[ -n "$drops" ]];   then sql+=$'\n'"${drops%$'\n'}"; fi
    sql+=$'\n'"COMMIT;"
    exec_sql "$sql"
    if [[ $DRY_RUN -eq 1 ]]; then
        info "$t: ${n_new} partição(ões) seriam criadas, ${n_drop} seriam apagadas.${dropped:+ Vencidas:$dropped}"
    else
        info "$t: ${n_new} partição(ões) criada(s), ${n_drop} apagada(s).${dropped:+ Apagadas:$dropped}"
    fi
}

cmd_maintain() {
    each_table maintain_table
    check_housekeeper
}

# -----------------------------------------------------------------------------
# housekeeping: desativa o housekeeper de history e trends e ativa o
# "Override item history/trend period" com a mesma retenção das partições.
#
# Sem o override, cada item mantém o próprio período de history (padrão 31d)
# e os gráficos escolhem entre history e trends com base nele, não no que
# realmente existe no banco. Com o override, todos os itens usam a retenção
# das partições.
# -----------------------------------------------------------------------------
# Estado atual: modo_history|modo_trends|override_history|periodo_history|override_trends|periodo_trends
hk_state()    { q "SELECT hk_history_mode || '|' || hk_trends_mode || '|' || hk_history_global || '|' || hk_history || '|' || hk_trends_global || '|' || hk_trends FROM config"; }
hk_expected() { echo "0|0|1|${ZBX_PART_HISTORY_DAYS}d|1|${ZBX_PART_TRENDS_DAYS}d"; }

check_housekeeper() {
    local st mode_h mode_t glob_h per_h glob_t per_t
    st=$(hk_state)
    [[ "$st" == "$(hk_expected)" ]] && return 0
    IFS='|' read -r mode_h mode_t glob_h per_h glob_t per_t <<<"$st"
    if [[ "$mode_h" != 0 || "$mode_t" != 0 ]]; then
        warn "O housekeeper de history/trends está ATIVO (history=${mode_h}, trends=${mode_t}). Ele concorre com o particionamento: rode '$0 housekeeping'."
    fi
    if [[ "$glob_h" != 1 || "$per_h" != "${ZBX_PART_HISTORY_DAYS}d" || "$glob_t" != 1 || "$per_t" != "${ZBX_PART_TRENDS_DAYS}d" ]]; then
        warn "O override de período no Zabbix (history=${per_h} ativo=${glob_h}, trends=${per_t} ativo=${glob_t}) não bate com a retenção das partições (${ZBX_PART_HISTORY_DAYS}d/${ZBX_PART_TRENDS_DAYS}d). Os gráficos podem escolher a fonte errada: rode '$0 housekeeping'."
    fi
}

warn_unpartitioned_history() {
    # O housekeeper de "history" é um só para TODAS as tabelas history_*.
    local t
    for t in history history_uint history_str history_text history_log history_bin; do
        [[ " $ZBX_PART_HISTORY_TABLES " == *" $t "* ]] && continue
        if [[ "$(relkind "$t")" == r ]]; then
            warn "Com o housekeeper desativado, a tabela $t (não particionada) deixa de ser limpa e cresce sem limite. Para incluí-la, adicione em ZBX_PART_HISTORY_TABLES."
        fi
    done
}

cmd_housekeeping() {
    local body resp hk_h="${ZBX_PART_HISTORY_DAYS}d" hk_t="${ZBX_PART_TRENDS_DAYS}d"
    body='{"jsonrpc":"2.0","method":"housekeeping.update","params":{"hk_history_mode":0,"hk_trends_mode":0,"hk_history_global":1,"hk_history":"'"$hk_h"'","hk_trends_global":1,"hk_trends":"'"$hk_t"'"},"id":1}'
    local api_ok=0

    if [[ -n "$ZBX_API_URL" && -n "$ZBX_API_TOKEN" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            printf -- '-- API: POST %s\n-- %s\n' "$ZBX_API_URL" "$body"
            return 0
        fi
        local curl_opts=(-sS --max-time 30 -H 'Content-Type: application/json-rpc'
                         -H "Authorization: Bearer ${ZBX_API_TOKEN}" -d "$body")
        if [[ "$ZBX_API_INSECURE" == yes ]]; then curl_opts+=(-k); fi
        if resp=$(curl "${curl_opts[@]}" "$ZBX_API_URL" 2>&1) && grep -q '"result"' <<<"$resp"; then
            info "Housekeeper atualizado via API."
            api_ok=1
        else
            warn "A API não confirmou a alteração: ${resp}"
            warn "Aplicando pelo banco de dados como alternativa."
        fi
    else
        warn "ZBX_API_URL/ZBX_API_TOKEN não configurados; atualizando o housekeeper direto no banco (tabela config)."
    fi

    if [[ $api_ok -eq 0 ]]; then
        exec_sql "UPDATE config SET hk_history_mode = 0, hk_trends_mode = 0,
       hk_history_global = 1, hk_history = '${hk_h}',
       hk_trends_global = 1, hk_trends = '${hk_t}';"
    fi
    if [[ $DRY_RUN -eq 0 ]]; then
        if [[ "$(hk_state)" == "$(hk_expected)" ]]; then
            info "Confirmado: housekeeper de history e trends desativado; override de período ativo (history ${hk_h}, trends ${hk_t})."
        else
            warn "A configuração do housekeeper não ficou como esperado ($(hk_state)). Verifique em Administration → Housekeeping."
        fi
    fi
    warn_unpartitioned_history
}

# -----------------------------------------------------------------------------
# init: converte as tabelas para particionadas
# -----------------------------------------------------------------------------
declare -A INIT_SQL=()
INIT_ORDER=()
MAX_TABLE_BYTES=0   # maior tabela a converter (pico de espaço em disco no init)
MAX_TABLE_NAME=""

pretty_bytes() { q "SELECT pg_size_pretty(${1}::bigint)"; }

# Na conversão, a tabela antiga e a nova coexistem até o COMMIT. Como cada
# tabela é convertida e confirmada separadamente, o pico de uso é o tamanho
# da MAIOR tabela (mais folga para o WAL gerado pela cópia).
check_disk_space() {
    [[ $MAX_TABLE_BYTES -gt 0 ]] || return 0
    local need=$(( MAX_TABLE_BYTES * 12 / 10 )) dir="" avail=""
    info "Espaço livre necessário no disco do banco: ~$(pretty_bytes "$need") (maior tabela: ${MAX_TABLE_NAME} com $(pretty_bytes "$MAX_TABLE_BYTES"), +20% para o WAL)."

    # Só dá para medir o disco quando o PostgreSQL está nesta máquina
    if [[ "$ZBX_DB_HOST" == localhost || "$ZBX_DB_HOST" == 127.0.0.1 || "$ZBX_DB_HOST" == ::1 || "$ZBX_DB_HOST" == /* ]]; then
        dir=$(psql -X -qtA -c "SHOW data_directory" 2>/dev/null || true)
        if [[ -z "$dir" && $EUID -eq 0 ]] && command -v sudo >/dev/null; then
            dir=$(sudo -u postgres psql -X -qtA -c "SHOW data_directory" 2>/dev/null || true)
        fi
        if [[ -n "$dir" && -d "$dir" ]]; then
            avail=$(df -PB1 "$dir" | awk 'NR==2 {print $4}')
        fi
    fi

    if [[ ! "$avail" =~ ^[0-9]+$ ]]; then
        warn "Não foi possível medir o espaço livre (banco remoto ou sem permissão). Confirme manualmente antes de continuar."
        return 0
    fi
    info "Espaço livre em ${dir}: $(pretty_bytes "$avail")."
    if [[ $avail -lt $need ]]; then
        if [[ $FORCE -eq 1 || $DRY_RUN -eq 1 ]]; then
            warn "Espaço livre insuficiente para a conversão com segurança."
        else
            fatal "Espaço livre insuficiente: há $(pretty_bytes "$avail"), são necessários ~$(pretty_bytes "$need"). Libere espaço ou use --force por sua conta e risco."
        fi
    fi
}

check_connections() {
    local n list
    n=$(q "SELECT count(*) FROM pg_stat_activity
            WHERE datname = current_database() AND pid <> pg_backend_pid() AND backend_type = 'client backend'")
    [[ $n -eq 0 ]] && return 0
    list=$(q "SELECT '  - ' || usename || '@' || COALESCE(host(client_addr), 'local') || ' (' || COALESCE(NULLIF(application_name, ''), '?') || ')'
                FROM pg_stat_activity
               WHERE datname = current_database() AND pid <> pg_backend_pid() AND backend_type = 'client backend'")
    if [[ $FORCE -eq 1 || $DRY_RUN -eq 1 ]]; then
        warn "Há ${n} outra(s) conexão(ões) no banco:"$'\n'"$list"
    else
        fatal "Há ${n} outra(s) conexão(ões) no banco:"$'\n'"${list}"$'\n'"Pare o Zabbix server antes do init (systemctl stop zabbix-server, no servidor da aplicação) ou use --force."
    fi
}

plan_table() {
    local group="$1" t="$2" owner pkname pkcols idxdefs co minc maxc total from to first_s creates n_parts
    local old_rows=0 future_rows=0

    case "$(relkind "$t")" in
        p) info "$t já é particionada; conversão ignorada."; return 0 ;;
        r) ;;
        *) warn "$t não encontrada; ignorada."; return 0 ;;
    esac
    [[ -z "$(relkind "${t}_old")" ]] || fatal "Já existe a tabela ${t}_old no banco; renomeie ou remova antes do init."

    owner=$(q "SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = '${t}'::regclass")
    [[ "$owner" == "$ZBX_DB_USER" ]] || fatal "$t pertence a '$owner', mas a conexão usa '$ZBX_DB_USER'. Use o dono da tabela em ZBX_DB_USER."
    if [[ -n "$(q "SELECT relacl FROM pg_class WHERE oid = '${t}'::regclass")" ]]; then
        warn "$t tem permissões (GRANT) para outros usuários; elas NÃO são copiadas para a nova tabela."
    fi

    pkname=$(q "SELECT conname FROM pg_constraint WHERE conrelid = '${t}'::regclass AND contype = 'p'")
    pkcols=$(q "SELECT string_agg(a.attname, ',' ORDER BY k.ord)
                  FROM pg_constraint c
                  CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
                  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
                 WHERE c.conrelid = '${t}'::regclass AND c.contype = 'p'")
    if [[ -n "$pkcols" && ",${pkcols}," != *",clock,"* ]]; then
        fatal "A chave primária de $t ($pkcols) não contém 'clock'; não é possível particionar."
    fi
    # Demais índices (esquemas antigos sem PK usam, por ex., history_1)
    idxdefs=$(q "SELECT pg_get_indexdef(indexrelid) || ';' FROM pg_index WHERE indrelid = '${t}'::regclass AND NOT indisprimary")

    info "$t: analisando dados existentes..."
    local size_b
    size_b=$(q "SELECT pg_total_relation_size('${t}')")
    if [[ $size_b -gt $MAX_TABLE_BYTES ]]; then MAX_TABLE_BYTES=$size_b; MAX_TABLE_NAME=$t; fi
    co=$(cutoff "$group")
    IFS='|' read -r minc maxc total <<<"$(q "SELECT COALESCE(min(clock),0) || '|' || COALESCE(max(clock),0) || '|' || count(*) FROM ${t}")"

    # Período coberto: do limite da retenção (ou do dado mais antigo) até as partições futuras
    if [[ $total -gt 0 ]]; then
        from=$(( minc > co ? minc : co ))
    else
        from=$NOW
    fi
    to=$(premake_until "$group")
    if [[ $total -gt 0 && $maxc -ge $to ]]; then
        if [[ $maxc -gt $(( NOW + 366 * 86400 )) ]]; then
            warn "$t tem dados com clock muito no futuro ($(fmt_date "$maxc")); essas linhas não serão copiadas."
        else
            to=$(( maxc + 1 ))
        fi
    fi
    first_s=$(epoch "$(day_of "$from")")

    if [[ $total -gt 0 ]]; then
        IFS='|' read -r old_rows future_rows <<<"$(q "SELECT count(*) FILTER (WHERE clock < ${first_s}) || '|' || count(*) FILTER (WHERE clock >= ${to}) FROM ${t}")"
    fi

    creates=$(gen_creates "$t" "$from" "$to" "")
    n_parts=$(grep -c . <<<"$creates" || true)

    local sql="-- ===== ${t}: conversão para tabela particionada =====
BEGIN;
LOCK TABLE ${t} IN ACCESS EXCLUSIVE MODE;
ALTER TABLE ${t} RENAME TO ${t}_old;"
    if [[ -n "$pkname" ]]; then
        sql+="
ALTER TABLE ${t}_old RENAME CONSTRAINT ${pkname} TO ${t}_old_pkey;"
    fi
    sql+="
CREATE TABLE ${t} (LIKE ${t}_old INCLUDING DEFAULTS) PARTITION BY RANGE (clock);"
    if [[ -n "$pkname" ]]; then
        sql+="
ALTER TABLE ${t} ADD CONSTRAINT ${pkname} PRIMARY KEY (${pkcols});"
    fi
    sql+="
${creates}
INSERT INTO ${t} SELECT * FROM ${t}_old WHERE clock >= ${first_s} AND clock < ${to};
DROP TABLE ${t}_old;"
    if [[ -n "$idxdefs" ]]; then
        sql+="
${idxdefs}"
    fi
    sql+="
COMMIT;"

    INIT_SQL[$t]="$sql"
    INIT_ORDER+=("$t")
    info "$t: ${total} linha(s), $(pretty_bytes "$size_b"); ${n_parts} partição(ões) de $(fmt_date "$first_s") até $(fmt_date "$to")."
    if [[ $old_rows -gt 0 ]]; then
        warn "$t: ${old_rows} linha(s) mais antiga(s) que a retenção ($(retention "$group") dias) serão descartadas."
    fi
    if [[ $future_rows -gt 0 ]]; then
        warn "$t: ${future_rows} linha(s) com clock no futuro serão descartadas."
    fi
}

cmd_init() {
    check_connections
    each_table plan_table

    if [[ ${#INIT_ORDER[@]} -eq 0 ]]; then
        info "Nenhuma tabela para converter."
    else
        check_disk_space
        if [[ $DRY_RUN -eq 0 && $ASSUME_YES -eq 0 ]]; then
            [[ -t 0 ]] || fatal "Confirmação necessária: rode em um terminal ou use --yes."
            echo
            echo "As tabelas acima serão convertidas: ${INIT_ORDER[*]}"
            echo "Cada tabela é convertida em uma transação (em caso de erro, nada muda nela)."
            read -rp "Digite PARTICIONAR para continuar: " ans
            [[ "$ans" == "PARTICIONAR" ]] || { echo "Cancelado."; exit 0; }
        fi
        local t t0 t_start
        t_start=$(date +%s)
        for t in "${INIT_ORDER[@]}"; do
            t0=$(date +%s)
            [[ $DRY_RUN -eq 1 ]] || info "$t: convertendo..."
            exec_sql "${INIT_SQL[$t]}"
            [[ $DRY_RUN -eq 1 ]] || info "$t: convertida em $(( $(date +%s) - t0 ))s."
        done
        [[ $DRY_RUN -eq 1 ]] || info "Conversão de ${#INIT_ORDER[@]} tabela(s) concluída em $(( $(date +%s) - t_start ))s."
    fi

    cmd_housekeeping
    if [[ $DRY_RUN -eq 0 ]]; then
        cmd_maintain
        info "Particionamento concluído. Pode iniciar o Zabbix server (systemctl start zabbix-server)."
        info "Próximo passo: $0 install-timer"
    fi
}

# -----------------------------------------------------------------------------
# status
# -----------------------------------------------------------------------------
status_table() {
    local group="$1" t="$2" rk
    rk=$(relkind "$t")
    case "$rk" in
        p) q "SELECT '${t}' || '|' || count(*) || '|' || COALESCE(min(c.relname),'-') || '|' || COALESCE(max(c.relname),'-') || '|' ||
                     pg_size_pretty(COALESCE(sum(pg_total_relation_size(c.oid)),0))
                FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
               WHERE i.inhparent = '${t}'::regclass" ;;
        r) echo "${t}|NÃO particionada|-|-|$(q "SELECT pg_size_pretty(pg_total_relation_size('${t}'))")" ;;
        *) echo "${t}|não encontrada|-|-|-" ;;
    esac
}

cmd_status() {
    echo
    local fmt=(cat)
    if command -v column >/dev/null; then fmt=(column -t -s'|'); fi
    { echo "TABELA|PARTIÇÕES|MAIS ANTIGA|MAIS NOVA|TAMANHO"; each_table status_table; } | "${fmt[@]}"
    echo
    local mode_h mode_t glob_h per_h glob_t per_t
    IFS='|' read -r mode_h mode_t glob_h per_h glob_t per_t <<<"$(hk_state)"
    echo "Housekeeper (0 = desativado): history=${mode_h} trends=${mode_t}"
    echo "Override de período (1 = ativo): history=${glob_h} (${per_h}) trends=${glob_t} (${per_t})"
    echo "Retenção: history ${ZBX_PART_HISTORY_DAYS} dias | trends ${ZBX_PART_TRENDS_DAYS} dias"
    echo "Partições (diárias) criadas com antecedência: history ${ZBX_PART_HISTORY_PREMAKE} dias | trends ${ZBX_PART_TRENDS_PREMAKE} dias"
    echo
    if command -v systemctl >/dev/null && [[ -f "${UNIT_DIR}/zbx-partition.timer" ]]; then
        systemctl list-timers zbx-partition.timer --no-pager || true
    else
        echo "Timer não instalado (use: $0 install-timer)."
    fi
}

# -----------------------------------------------------------------------------
# systemd timer
# -----------------------------------------------------------------------------
cmd_install_timer() {
    [[ $EUID -eq 0 || $DRY_RUN -eq 1 ]] || fatal "install-timer precisa de root (sudo)."
    [[ -f "$ENV_FILE" ]] || fatal "Arquivo $ENV_FILE não encontrado; o timer precisa dele para conectar no banco."
    [[ -n "$ZBX_DB_PASS" ]] || fatal "ZBX_DB_PASS está vazio em $ENV_FILE; o timer roda sem terminal e não consegue pedir a senha."

    local svc tmr
    svc="[Unit]
Description=Zabbix - manutenção das partições de history/trends
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_BIN} maintain --env ${INSTALL_ENV}
Nice=10
IOSchedulingClass=idle"
    tmr="[Unit]
Description=Executa a manutenção das partições do Zabbix diariamente

[Timer]
OnCalendar=${ZBX_PART_ONCALENDAR}
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "# copiaria ${SCRIPT_PATH} -> ${INSTALL_BIN} (750) e ${ENV_FILE} -> ${INSTALL_ENV} (600)"
        echo "# ${UNIT_DIR}/zbx-partition.service"; echo "$svc"; echo
        echo "# ${UNIT_DIR}/zbx-partition.timer";   echo "$tmr"
        return 0
    fi

    if [[ "$SCRIPT_PATH" != "$INSTALL_BIN" ]]; then install -m 750 "$SCRIPT_PATH" "$INSTALL_BIN"; fi
    if [[ "$(readlink -f "$ENV_FILE")" != "$INSTALL_ENV" ]]; then install -m 600 "$ENV_FILE" "$INSTALL_ENV"; fi
    printf '%s\n' "$svc" > "${UNIT_DIR}/zbx-partition.service"
    printf '%s\n' "$tmr" > "${UNIT_DIR}/zbx-partition.timer"
    systemctl daemon-reload
    systemctl enable --now zbx-partition.timer >/dev/null 2>&1
    info "Timer instalado (${ZBX_PART_ONCALENDAR}). Script: ${INSTALL_BIN} | parâmetros: ${INSTALL_ENV}"
    systemctl list-timers zbx-partition.timer --no-pager || true
}

cmd_remove_timer() {
    [[ $EUID -eq 0 || $DRY_RUN -eq 1 ]] || fatal "remove-timer precisa de root (sudo)."
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "# desativaria zbx-partition.timer e removeria as units, ${INSTALL_BIN} e ${INSTALL_ENV}"
        return 0
    fi
    systemctl disable --now zbx-partition.timer >/dev/null 2>&1 || true
    rm -f "${UNIT_DIR}/zbx-partition.timer" "${UNIT_DIR}/zbx-partition.service" "$INSTALL_BIN" "$INSTALL_ENV"
    systemctl daemon-reload
    info "Timer removido. As partições existentes não foram alteradas."
}

# -----------------------------------------------------------------------------
# Principal
# -----------------------------------------------------------------------------
case "$CMD" in
    install-timer) cmd_install_timer; exit 0 ;;
    remove-timer)  cmd_remove_timer;  exit 0 ;;
esac

command -v psql  >/dev/null || fatal "psql não encontrado (instale: apt install postgresql-client)."
command -v flock >/dev/null || fatal "flock não encontrado (instale: apt install util-linux)."
if [[ "$CMD" == housekeeping || "$CMD" == init ]] && [[ -n "$ZBX_API_URL" ]]; then
    command -v curl >/dev/null || fatal "curl não encontrado (instale: apt install curl)."
fi

if [[ -z "${PGPASSWORD:-}" && -t 0 ]]; then
    read -rsp "Senha do usuário '${ZBX_DB_USER}' no PostgreSQL: " PGPASSWORD; echo
    export PGPASSWORD
fi
if ! err=$(psql -X -qtA -c 'SELECT 1' 2>&1); then
    fatal "Não foi possível conectar em ${ZBX_DB_USER}@${ZBX_DB_HOST}:${ZBX_DB_PORT}/${ZBX_DB_NAME}: ${err}"
fi

# Uma execução por vez (timer x execução manual)
LOCK_FILE=/run/lock/zbx-partition.lock
[[ -w /run/lock ]] || LOCK_FILE=/tmp/zbx-partition.lock
exec 9>"$LOCK_FILE"
flock -n 9 || fatal "Outra execução do zbx-partition está em andamento."

[[ $DRY_RUN -eq 1 ]] && info "Modo --dry-run: nada será alterado; o SQL é exibido abaixo."
info "Comando: ${CMD} | banco: ${ZBX_DB_USER}@${ZBX_DB_HOST}:${ZBX_DB_PORT}/${ZBX_DB_NAME}"

case "$CMD" in
    init)         cmd_init ;;
    maintain)     cmd_maintain ;;
    housekeeping) cmd_housekeeping ;;
    status)       cmd_status ;;
esac
