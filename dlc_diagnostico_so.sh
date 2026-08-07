#!/usr/bin/env bash
#=============================================================================
# dlc_diagnostico_so.sh
#
# Diagnóstico de sistema operativo para IBM Disconnected Log Collector (DLC)
# que dejó de enviar eventos a QRadar on Cloud (QRoC).
#
# Objetivo: determinar si la causa está en el SO (RHEL 9), en la red local,
# en el propio DLC (servicio/certificados/TLS) o en los log sources,
# y dejar EVIDENCIA documentada de cada prueba.
#
# - Se ejecuta como root EN el servidor DLC.
# - SOLO LECTURA: no reinicia servicios, no modifica configuración ni firewall.
#   (Las capturas tcpdump están acotadas en tiempo y no vuelcan payloads.)
#   Única excepción: una escritura de prueba de 4 KB en /store (O_DIRECT/fsync)
#   que se elimina al terminar — detecta el caso real de un disco desconectado
#   de la VM donde el permiso de escritura se ve bien pero el disco ya no está.
# - Trabaja en /tmp y AL FINAL deja unicamente /tmp/dlc-diagnostico-<fecha>.tgz
#   con todo dentro (informe.txt, informe.html, evidencias/ -un .txt por
#   prueba- y el paquete para IBM Support). El directorio de trabajo se
#   elimina al terminar para no ocupar espacio.
#
# Uso:   sudo ./dlc_diagnostico_so.sh [-e fqdn_ep1] [-f fqdn_ep2] [-i ip_ep1]
#          [-j ip_ep2] [-d destino] [-p puerto] [-P puerto_esperado] [-h]
#
# MODOS DE EJECUCION:
#   1) Autonomo (sin opciones): el script lee el destino real del config.json
#      del DLC y ejecuta el diagnostico completo. Las comparaciones contra
#      valores esperados (pruebas 21 y 30b) se degradan a INFO y se emite un
#      aviso al arranque. Util cuando no se tienen a la mano los valores
#      documentados del tenant.
#   2) Con referencias (-e/-f/-i/-j/-P): ademas del diagnostico completo, se
#      compara lo esperado (parametros) contra lo configurado (config.json) y
#      lo resuelto (DNS del sistema), habilitando la deteccion de DNS
#      alterado, destino mal configurado o puerto distinto del documentado.
#
# Referencias: IBM DLC Guide (b_dlc_inst.pdf), IBM TechNotes 6604017 y 7274013.
#
# AVISO / DISCLAIMER:
#   Este script NO cuenta con soporte oficial de IBM. Es una herramienta de
#   diagnostico de campo elaborada por lrodriguezd@outlook.com. Usarla bajo
#   responsabilidad del operador y validar los hallazgos antes de actuar.
#=============================================================================

set -u
export LANG=C LC_ALL=C

#--------------------------- PARÁMETROS EDITABLES ----------------------------
DLC_HOME="/opt/ibm/si/services/dlc"
CONFIG_JSON="$DLC_HOME/conf/config.json"
JMX_SH="$DLC_HOME/current/script/jmx.sh"
JMX_PORT=7787
KEYSTORE_DIR="$DLC_HOME/keystore"
DLC_ERROR_LOG="/var/log/dlc/dlc.error"

# Endpoints del tenant QRoC. VACIOS por defecto: proporcionarlos aqui o por
# linea de comandos (-e/-f/-i/-j). Formato de ejemplo:
#   FQDN: logs-epXX-NNNNN.qradar.ibmcloud.com    IP: la documentada por IBM
# El script SOLO compara y reporta; nunca modifica /etc/hosts.
EP1_FQDN=""
EP2_FQDN=""
EP1_IP_DOC=""
EP2_IP_DOC=""

# Destino para las pruebas de conectividad/TLS: por defecto se toma del
# config.json del DLC. Definir aqui (o con -d/-p) les da PRIORIDAD.
EP_MANUAL=""       # IP o FQDN del EP a probar
PUERTO_MANUAL=""   # puerto a probar

# Puerto esperado/documentado para la comparacion configurado-vs-esperado.
# En QRadar on Cloud debe permanecer en 32500 (no debe cambiarse).
PUERTO_ESPERADO="32500"

# Nombres de los artefactos del certificado firmado dentro de keystore/<UUID>/
# (ajustar si la convencion del despliegue difiere).
CERT_FIRMADO_NOMBRE="firmado.pem"
CERT_FULLCHAIN_NOMBRE="dlc-fullchain.pem"

# Puertos de recepción de syslog en el DLC
PUERTOS_ENTRADA="514 or port 1514 or port 6514"

TCPDUMP_SEGUNDOS=20      # duración máxima de cada captura
JMX_INTERVALO=30         # segundos entre las dos muestras de contadores JMX
DISCO_UMBRAL=90          # % de uso de disco que se considera FALLA
#-----------------------------------------------------------------------------

#--------------------- PARAMETROS DE LINEA DE COMANDOS -----------------------
uso() {
    cat <<'USO'
Uso: sudo ./dlc_diagnostico_so.sh [opciones]   (ejecutar como root en el DLC)
  -e <fqdn>    FQDN documentado del EP1 (ej. logs-epXX-NNNNN.qradar.ibmcloud.com)
  -f <fqdn>    FQDN documentado del EP2
  -i <ip>      IP esperada del EP1 (comparacion contra DNS y config.json)
  -j <ip>      IP esperada del EP2
  -d <destino> IP o FQDN destino manual (prioridad sobre config.json)
  -p <puerto>  Puerto destino manual (prioridad sobre config.json)
  -P <puerto>  Puerto esperado para la comparacion (por defecto 32500)
  -h           Muestra esta ayuda

Modos de ejecucion:
  Autonomo (sin opciones): el destino se toma del config.json del DLC y se
    ejecuta el diagnostico completo; las comparaciones contra valores
    esperados (pruebas 21 y 30b) se degradan a INFO y se avisa al arranque.
  Con referencias (-e/-f/-i/-j/-P): agrega la comparacion esperado vs
    configurado vs resuelto por DNS (deteccion de DNS alterado, destino mal
    configurado o puerto distinto del documentado).
USO
}
while getopts "e:f:i:j:d:p:P:h" _op; do
    case "$_op" in
        e) EP1_FQDN="$OPTARG" ;;
        f) EP2_FQDN="$OPTARG" ;;
        i) EP1_IP_DOC="$OPTARG" ;;
        j) EP2_IP_DOC="$OPTARG" ;;
        d) EP_MANUAL="$OPTARG" ;;
        p) PUERTO_MANUAL="$OPTARG" ;;
        P) PUERTO_ESPERADO="$OPTARG" ;;
        h) uso; exit 0 ;;
        *) uso; exit 1 ;;
    esac
done

TS="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTDIR:-/tmp/dlc-diagnostico-$TS}"
EVID="$OUTDIR/evidencias"
INFORME="$OUTDIR/informe.txt"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: este script debe ejecutarse como root." >&2
    exit 1
fi
mkdir -p "$EVID"

#------------------------------- UTILERÍAS ----------------------------------
# Resultados acumulados: id | veredicto | descripción | detalle
declare -a R_ID R_VER R_DESC R_DET
declare -A V   # veredicto por id, para la conclusión final

add_result() {  # add_result <id> <veredicto> <descripcion> <detalle>
    R_ID+=("$1"); R_VER+=("$2"); R_DESC+=("$3"); R_DET+=("$4")
    V["$1"]="$2"
    printf '  [%s] %s - %s\n' "$2" "$1" "$3"
}

nota() {  # texto que va al informe (no a consola)
    echo -e "$@" >> "$INFORME"
}

seccion() {
    echo "" ; echo "===== $1 ====="
    nota "" ; nota "============================================================"
    nota "== $1"
    nota "============================================================"
}

cap() {  # cap <id> <descripcion> <comando...>  -> guarda evidencia + informe
    local id="$1" desc="$2"; shift 2
    local f="$EVID/$id.txt"
    local cmd_mostrado="$*"
    # Nunca imprimir el password del keystore en la evidencia
    [[ -n "${KS_PASS:-}" ]] && cmd_mostrado="${cmd_mostrado//$KS_PASS/***OCULTO***}"
    {
        echo "# $desc"
        echo "# Comando: $cmd_mostrado"
        echo "# Fecha: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "#----------------------------------------"
    } > "$f"
    timeout 90 bash -c "$*" >> "$f" 2>&1
    local rc=$?
    echo "#---- (codigo de salida: $rc; 0 = el comando termino bien, otro valor = fallo o no existe)" >> "$f"
    nota ""
    cat "$f" >> "$INFORME"
    return $rc
}

tiene() { command -v "$1" >/dev/null 2>&1; }

salida() {  # salida <id> : imprime unicamente la salida real de la evidencia,
            # excluyendo el encabezado (que contiene el texto del comando y
            # podria coincidir con los patrones buscados por los veredictos)
    awk '/^#----------------------------------------$/{f=1;next} f' "$EVID/$1.txt" 2>/dev/null
}

no_ejecutada() {  # no_ejecutada <id> <descripcion> <motivo>
    # Regla definida: una prueba que no pudo ejecutarse se registra como FALLA,
    # dado que deja el diagnostico incompleto y ello constituye un hallazgo.
    add_result "$1" FALLA "$2" "PRUEBA NO EJECUTADA: $3. Corregir el prerequisito y volver a ejecutar el diagnostico."
}

#------------------------------- ENCABEZADO ---------------------------------
# UUID de la instancia DLC: nombre del subdirectorio del keystore; es el CN
# del certificado de cliente y el identificador de la instancia en QRadar.
DLC_UUID=$(find "$KEYSTORE_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null -exec basename {} \; | tr '\n' ' ')
DLC_UUID="${DLC_UUID%% }"
{
    echo "############################################################"
    echo "# INFORME DE DIAGNOSTICO - IBM DLC / SISTEMA OPERATIVO"
    echo "# Host      : $(hostname -f 2>/dev/null || hostname)"
    echo "# Fecha     : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "# Kernel    : $(uname -r)"
    echo "# SO        : $(cat /etc/redhat-release 2>/dev/null || echo 'desconocido')"
    echo "# Version DLC (symlink current):"
    ls -ld "$DLC_HOME/current" 2>/dev/null | sed 's/^/#   /'
    echo "# UUID DLC  : ${DLC_UUID:-no identificado}"
    echo "# Script    : dlc_diagnostico_so.sh (solo lectura)"
    echo "# AVISO     : Este script NO cuenta con soporte oficial de IBM."
    echo "#             Herramienta de diagnostico de campo elaborada por"
    echo "#             lrodriguezd@outlook.com."
    echo "############################################################"
} > "$INFORME"
echo "Informe: $INFORME"

# Aviso de ejecucion sin referencias esperadas: el diagnostico opera con el
# destino del config.json del DLC; solo se omiten las comparaciones.
if [[ -z "$EP1_FQDN$EP2_FQDN$EP1_IP_DOC$EP2_IP_DOC" ]]; then
    AVISO_REF="Aviso: ejecucion SIN referencias esperadas (-e/-f/-i/-j). El destino se toma del config.json del DLC; las comparaciones de DNS (prueba 21) y de coherencia del destino (prueba 30b) se limitaran a informar los valores encontrados. Ejecute con -h para ver las opciones."
    echo "$AVISO_REF"
    nota ""
    nota "# $AVISO_REF"
fi

# Lectura de configuración del DLC (destino, tipo, password de keystore)
DEST_IP=""; DEST_PORT=""; DEST_TYPE=""; KS_PASS=""
if [[ -r "$CONFIG_JSON" ]]; then
    if command -v jq >/dev/null 2>&1; then
        DEST_IP=$(jq -r '.Destination["destination.ip"]   // empty' "$CONFIG_JSON" 2>/dev/null)
        DEST_PORT=$(jq -r '.Destination["destination.port"] // empty' "$CONFIG_JSON" 2>/dev/null)
        DEST_TYPE=$(jq -r '.Destination["destination.type"] // empty' "$CONFIG_JSON" 2>/dev/null)
        KS_PASS=$(jq -r '.TLS["tls.keystorepassword"]      // empty' "$CONFIG_JSON" 2>/dev/null)
    else
        DEST_IP=$(grep -o '"destination.ip"[^,}]*'   "$CONFIG_JSON" | sed 's/.*:[ "]*//;s/"//g')
        DEST_PORT=$(grep -o '"destination.port"[^,}]*' "$CONFIG_JSON" | sed 's/.*:[ "]*//;s/"//g')
        DEST_TYPE=$(grep -o '"destination.type"[^,}]*' "$CONFIG_JSON" | sed 's/.*:[ "]*//;s/"//g')
        KS_PASS=$(grep -o '"tls.keystorepassword"[^,}]*' "$CONFIG_JSON" | sed 's/.*:[ "]*//;s/"//g')
    fi
fi
DEST_PORT="${DEST_PORT:-32500}"
# Prioridad a los valores manuales definidos en los parametros editables
[[ -n "$EP_MANUAL" ]]     && DEST_IP="$EP_MANUAL"
[[ -n "$PUERTO_MANUAL" ]] && DEST_PORT="$PUERTO_MANUAL"

#=============================================================================
seccion "BLOQUE 0 - Verificacion de prerequisitos"
#=============================================================================
# Comandos requeridos por las pruebas. Si falta alguno: FALLA aqui, y la
# prueba dependiente tambien se marca FALLA como "no ejecutada".
REQ_CMDS="systemctl journalctl ss ip getent firewall-cmd tcpdump openssl curl findmnt rpm dnf tar gzip awk sed grep df free timeout dd traceroute"
OPC_CMDS="jq ausearch chronyc netstat alternatives dig tcptraceroute"
cap 00_prereq "Inventario de comandos requeridos y opcionales" \
    "echo '--- requeridos:';
     for c in $REQ_CMDS; do printf '%-14s: ' \"\$c\"; command -v \"\$c\" 2>/dev/null || echo 'NO INSTALADO'; done;
     echo; echo '--- opcionales (funcionalidad reducida si faltan):';
     for c in $OPC_CMDS; do printf '%-14s: ' \"\$c\"; command -v \"\$c\" 2>/dev/null || echo 'no instalado'; done"
FALTAN=""
for c in $REQ_CMDS; do tiene "$c" || FALTAN="$FALTAN $c"; done
if [[ -z "$FALTAN" ]]; then
    add_result 00_prereq OK "Comandos requeridos disponibles" "Todos los comandos requeridos estan instalados."
else
    add_result 00_prereq FALLA "Comandos requeridos disponibles" "FALTAN:$FALTAN. Instalarlos con dnf install. Las pruebas dependientes se marcan FALLA como no ejecutadas."
fi

# Prerequisitos de la propia instalacion DLC
if [[ -d "$DLC_HOME" ]]; then
    add_result 00_dlc OK "Instalacion DLC presente" "$DLC_HOME existe; current -> $(readlink "$DLC_HOME/current" 2>/dev/null || echo '?')."
else
    add_result 00_dlc FALLA "Instalacion DLC presente" "$DLC_HOME NO existe: o este no es el servidor DLC o la instalacion se perdio."
fi
[[ -r "$CONFIG_JSON" ]] || no_ejecutada 00_configjson "Acceso a config.json" "no se puede leer $CONFIG_JSON"
[[ -x "$JMX_SH" ]]      || no_ejecutada 00_jmxsh "Acceso a jmx.sh" "no existe o no es ejecutable $JMX_SH"
[[ -e "$DLC_ERROR_LOG" ]] || no_ejecutada 00_dlclog "Acceso a dlc.error" "no existe $DLC_ERROR_LOG (o el DLC nunca ha registrado errores en esta ruta)"

#=============================================================================
seccion "BLOQUE 1 - Salud general del sistema operativo"
#=============================================================================

# 01 - Uptime y reinicios --------------------------------------------------
cap 01_uptime "Uptime, arranques recientes y reinicios" \
    "uptime; echo; uptime -s; echo; last -x reboot shutdown 2>/dev/null | head -10; echo; journalctl --list-boots --no-pager 2>/dev/null | tail -5"
add_result 01_uptime INFO "Uptime y reinicios recientes" \
    "Arranque actual: $(uptime -s 2>/dev/null). Correlacionar con la fecha del parcheo."

# 02 - Memoria -------------------------------------------------------------
cap 02_memoria "Memoria RAM y swap" "free -h; echo; vmstat 1 3 2>/dev/null"
MEM_DISP=$(free -m | awk '/^Mem:/ {print $7}')
if [[ -n "${MEM_DISP:-}" && "$MEM_DISP" -lt 256 ]]; then
    add_result 02_memoria FALLA "Memoria disponible" "Solo ${MEM_DISP} MB disponibles (<256 MB): presion critica de memoria, riesgo alto de OOM."
elif [[ -n "${MEM_DISP:-}" && "$MEM_DISP" -lt 1024 ]]; then
    add_result 02_memoria ALERTA "Memoria disponible" "${MEM_DISP} MB disponibles: nivel bajo. Un DLC funcional de referencia opera con aproximadamente 310 MB; no obstante, una memoria disponible reducida incrementa el riesgo de terminacion del proceso java del DLC por el OOM killer (correlacionar con 03_oom)."
else
    add_result 02_memoria OK "Memoria disponible" "${MEM_DISP:-?} MB disponibles."
fi

# 03 - OOM killer ----------------------------------------------------------
cap 03_oom "Eventos OOM killer en los ultimos 30 dias (kernel)" \
    "journalctl -k --since '-30 days' --no-pager 2>/dev/null | grep -iE 'out of memory|oom-killer|killed process' | tail -20"
# Se excluyen las lineas de encabezado (#) para no contar el propio comando
OOM_HITS=$(salida 03_oom | grep -icE 'out of memory|oom-killer|killed process')
[[ -z "$OOM_HITS" ]] && OOM_HITS=0
if [[ "$OOM_HITS" -gt 0 ]]; then
    add_result 03_oom FALLA "OOM killer" "Se detectaron eventos OOM ($OOM_HITS lineas). Si el proceso terminado fue el java del DLC, constituye causa a nivel de sistema operativo. Ver evidencias/03_oom.txt."
else
    add_result 03_oom OK "OOM killer" "Sin eventos OOM en 30 dias."
fi

# 04 - Carga de CPU --------------------------------------------------------
cap 04_carga "Carga del sistema y procesos top" "nproc; echo; uptime; echo; top -bn1 | head -20"
add_result 04_carga INFO "Carga de CPU" "Comparar load average contra $(nproc) nucleos (ver evidencia)."

# 05 - Espacio en disco e inodos ------------------------------------------
cap 05_disco "Espacio en disco e inodos (/ y /store)" \
    "df -hP; echo; df -iP; echo; du -sh /store 2>/dev/null"
DISCO_LLENO=$(df -P / /store 2>/dev/null | awk -v u="$DISCO_UMBRAL" 'NR>1 {gsub("%","",$5); if ($5+0>=u) print $6"="$5"%"}' | tr '\n' ' ')
if [[ -n "$DISCO_LLENO" ]]; then
    add_result 05_disco FALLA "Espacio en disco" "Particion(es) sobre ${DISCO_UMBRAL}%: $DISCO_LLENO. /store lleno detiene el buffer del DLC; / lleno afecta todo el SO."
else
    add_result 05_disco OK "Espacio en disco" "/ y /store por debajo de ${DISCO_UMBRAL}%."
fi

# 06 - /store montada ------------------------------------------------------
cap 06_store "Montaje de /store (LVM/XFS), disco presente y fstab" \
    "findmnt /store; echo; lsblk; echo; grep -v '^#' /etc/fstab; echo; mount | grep -w /store"
if findmnt -n /store >/dev/null 2>&1; then
    STORE_OPTS=$(findmnt -n -o OPTIONS /store 2>/dev/null)
    if echo "$STORE_OPTS" | grep -qw ro; then
        add_result 06_store FALLA "/store montada" "/store esta montada en SOLO LECTURA (ro): tipico de XFS que se protege tras errores de E/S o disco desconectado de la VM. El DLC no puede bufferizar."
    else
        add_result 06_store OK "/store montada" "$(findmnt -n -o SOURCE,FSTYPE /store) (opciones: $STORE_OPTS)"
    fi
elif [[ -d /store ]]; then
    add_result 06_store ALERTA "/store montada" "/store existe como directorio sobre la raiz, no como particion dedicada (configuracion observada en algunos despliegues; operativa). Riesgo: el crecimiento de /store puede agotar el sistema de archivos raiz y comprometer el sistema operativo; la guia de despliegue del producto recomienda una particion dedicada. La prueba de escritura efectiva continua en 06b."
else
    add_result 06_store FALLA "/store montada" "/store NO existe ni como particion ni como directorio: el DLC no tiene donde bufferizar. Si era un disco dedicado, verificar en lsblk si el disco virtual sigue presentado a la VM."
fi

# 06b - Escritura efectiva en /store ---------------------------------------
# Antecedente documentado: el disco de /store fue desconectado de la maquina
# virtual; el proceso continuaba en ejecucion desde memoria y la verificacion
# de permiso '[ -w /store ]' resultaba exitosa, pero ninguna escritura se
# persistia en disco. Por ello se realiza una escritura efectiva con
# O_DIRECT/fsync (evita la cache de memoria); el archivo se elimina al final.
TESTF="/store/.dlc_diag_write_$$"
if [[ ! -d /store ]]; then
    no_ejecutada 06b_store_rw "Escritura efectiva en /store" "/store no existe (ver 06_store)"
else
cap 06b_store_rw "Prueba de escritura efectiva en /store (O_DIRECT + fsync, 4 KB)" \
    "echo 'Permiso aparente (-w /store):' \$( [ -w /store ] && echo 'escribible' || echo 'NO escribible' );
     echo '--- intento 1: dd con oflag=direct,dsync';
     dd if=/dev/zero of=$TESTF bs=4k count=1 oflag=direct,dsync 2>&1;
     echo '--- intento 2 (fallback): dd con conv=fsync';
     dd if=/dev/zero of=$TESTF.b bs=4k count=1 conv=fsync 2>&1;
     ls -l $TESTF $TESTF.b 2>&1;
     rm -f $TESTF $TESTF.b"
if salida 06b_store_rw | grep -qE '4096 bytes.*copied|records out' && ! salida 06b_store_rw | grep -qiE 'error|no space|read-only|input/output'; then
    add_result 06b_store_rw OK "Escritura efectiva en /store" "La escritura sincronizada a disco se completo correctamente (el disco de /store esta presente y acepta operaciones de E/S)."
else
    add_result 06b_store_rw FALLA "Escritura efectiva en /store" "La escritura efectiva fallo aun cuando el permiso aparente resulte correcto: verificar si el disco virtual de /store continua conectado a la maquina virtual (antecedente documentado) o si XFS conmuto a solo lectura. Ver evidencias/06b_store_rw.txt y 07_xfs."
fi
rm -f "$TESTF" "$TESTF.b" 2>/dev/null
fi

# 07 - Errores de disco/XFS en kernel -------------------------------------
cap 07_xfs "Errores de XFS / E-S en el kernel" \
    "dmesg 2>/dev/null | grep -iE '(xfs).*(error|corrupt|shut)|i/o error|blk_update_request' | tail -20"
# Se excluyen las lineas de encabezado (#) para no contar el propio comando
XFS_HITS=$(salida 07_xfs | grep -icE 'error|corrupt|shut')
[[ -z "$XFS_HITS" ]] && XFS_HITS=0
if [[ "$XFS_HITS" -gt 0 ]]; then
    add_result 07_xfs FALLA "Errores de disco/XFS" "Se detectaron mensajes de error de E/S o XFS ($XFS_HITS lineas). Revisar evidencias/07_xfs.txt."
else
    add_result 07_xfs OK "Errores de disco/XFS" "Sin errores de E/S recientes en kernel."
fi

# 08 - Hora del sistema y NTP ----------------------------------------------
cap 08_hora "Sincronizacion de hora (critica para TLS)" \
    "timedatectl; echo; chronyc tracking 2>/dev/null; echo; systemctl is-active chronyd 2>/dev/null"
if grep -q 'System clock synchronized: yes' "$EVID/08_hora.txt"; then
    add_result 08_hora OK "Hora sincronizada (NTP)" "Reloj sincronizado."
else
    add_result 08_hora FALLA "Hora sincronizada (NTP)" "El reloj no esta sincronizado. Un desfase de hora invalida el handshake TLS con QRoC aun cuando el resto de los componentes opere correctamente. Causa a nivel de sistema operativo."
fi

#=============================================================================
seccion "BLOQUE 2 - Servicio DLC como proceso del SO"
#=============================================================================

# 10 - Estado del servicio -------------------------------------------------
cap 10_servicio "Estado del servicio dlc (systemd)" \
    "systemctl status dlc --no-pager -l; echo; systemctl is-enabled dlc"
DLC_PID=$(systemctl show -p MainPID --value dlc 2>/dev/null || echo 0)
if systemctl is-active --quiet dlc 2>/dev/null; then
    add_result 10_servicio OK "Servicio dlc activo" "PID principal: $DLC_PID."
else
    add_result 10_servicio FALLA "Servicio dlc activo" "El servicio dlc no esta en ejecucion. Revisar 11_reinicios y 03_oom antes de reiniciarlo, a fin de preservar la evidencia."
fi

# 11 - Historial del servicio ---------------------------------------------
cap 11_reinicios "Historial del servicio dlc (14 dias)" \
    "journalctl -u dlc --since '-14 days' --no-pager 2>/dev/null | grep -iE 'started|stopped|failed|killed|main process exited|oom' | tail -30"
FALLOS_24H=$(journalctl -u dlc --since '-24 hours' --no-pager 2>/dev/null | grep -ciE 'failed|killed|oom')
[[ -z "$FALLOS_24H" ]] && FALLOS_24H=0
if [[ "$FALLOS_24H" -gt 0 ]] && ! systemctl is-active --quiet dlc 2>/dev/null; then
    add_result 11_reinicios FALLA "Historial del servicio" "Caidas del servicio en las ultimas 24 horas y el servicio se encuentra detenido. Correlacionar fechas con el parcheo (bloque 5)."
elif [[ "$FALLOS_24H" -gt 0 ]]; then
    add_result 11_reinicios ALERTA "Historial del servicio" "Caidas o reinicios en las ultimas 24 horas, aunque el servicio opera actualmente. Si corresponden a intervenciones de correccion documentadas, no constituyen hallazgo; en caso contrario, correlacionar con 03_oom y el bloque 5."
elif salida 11_reinicios | grep -qiE 'failed|killed|oom'; then
    add_result 11_reinicios ALERTA "Historial del servicio" "Existen caidas en los ultimos 14 dias pero ninguna en las ultimas 24 horas y el servicio opera. Historial esperado tras un incidente ya atendido; verificar fechas en la evidencia."
else
    add_result 11_reinicios OK "Historial del servicio" "Sin caidas registradas en 14 dias."
fi

# 12 - Java del DLC --------------------------------------------------------
JAVA_CMD=""
if [[ "$DLC_PID" -gt 0 && -r "/proc/$DLC_PID/cmdline" ]]; then
    JAVA_CMD=$(tr '\0' '\n' < "/proc/$DLC_PID/cmdline" | head -1)
fi
cap 12_java "Java en uso por el DLC (el parche pudo reemplazarlo)" \
    "echo 'Binario java del proceso dlc: ${JAVA_CMD:-servicio detenido}';
     [ -n '${JAVA_CMD:-}' ] && '${JAVA_CMD}' -version 2>&1;
     echo; echo '--- java en PATH:'; command -v java && java -version 2>&1;
     echo; echo '--- alternatives:'; alternatives --display java 2>/dev/null | head -15;
     echo; echo '--- RPMs java instalados:'; rpm -qa | grep -iE 'ibm-java|java-|openjdk' | sort"
JAVA_INFO=$( { [[ -n "$JAVA_CMD" ]] && "$JAVA_CMD" -version 2>&1 || java -version 2>&1; } | head -3 | tr '\n' ' ' )
if echo "$JAVA_INFO" | grep -qiE 'ibm|j9'; then
    add_result 12_java OK "Java de IBM presente" "$JAVA_INFO"
elif echo "$JAVA_INFO" | grep -q '1.8'; then
    add_result 12_java ALERTA "Java 8 presente pero no parece IBM J9" "DLC 1.8.6 requiere IBM SDK Java 8. La actualizacion pudo sustituir el runtime por OpenJDK. Detalle: $JAVA_INFO"
else
    add_result 12_java FALLA "Java requerido por DLC" "No se confirma IBM Java 8. Posible reemplazo/actualizacion por el parche. Detalle: $JAVA_INFO"
fi

# 13 - Puertos en escucha --------------------------------------------------
cap 13_escucha "Puertos en escucha del DLC (1514 syslog interno, $JMX_PORT JMX)" \
    "ss -tulnp | grep -E ':(1514|6514|$JMX_PORT)\\b' || echo 'NINGUNO de los puertos esperados esta en escucha'"
if salida 13_escucha | grep -q ':1514'; then
    add_result 13_escucha OK "Puerto 1514 en escucha" "$(salida 13_escucha | grep ':1514' | head -1 | tr -s ' ')"
else
    add_result 13_escucha FALLA "Puerto 1514 en escucha" "El DLC no esta escuchando en 1514: el servicio no inicio sus listeners."
fi

#=============================================================================
seccion "BLOQUE 3 - Red y firewall del SO"
#=============================================================================

# 20 - Interfaz y rutas ----------------------------------------------------
cap 20_red "Interfaces de red y tabla de ruteo" \
    "ip -br addr; echo; ip -br link; echo; ip route"
if ip route 2>/dev/null | grep -q '^default'; then
    add_result 20_red OK "Interfaz y ruta por defecto" "$(ip route | grep '^default' | head -1)"
else
    add_result 20_red FALLA "Interfaz y ruta por defecto" "No hay ruta por defecto: sin salida a QRoC. Causa de SO/red."
fi

# 21 - DNS -----------------------------------------------------------------
EP1_RES=$(getent hosts "$EP1_FQDN" 2>/dev/null | awk '{print $1; exit}')
EP2_RES=$(getent hosts "$EP2_FQDN" 2>/dev/null | awk '{print $1; exit}')
if [[ -z "$EP1_FQDN" && -z "$EP2_FQDN" ]]; then
    cap 21_dns "Resolucion DNS (sin FQDNs esperados proporcionados)" \
        "cat /etc/resolv.conf; echo; grep -v '^#' /etc/hosts"
    add_result 21_dns INFO "Resolucion DNS de los EP" "No se proporcionaron FQDNs esperados (-e/-f); la comparacion DNS se omite y las pruebas de conectividad emplean el destino de config.json (${DEST_IP:-no definido})."
else
    cap 21_dns "Resolucion DNS de los EP y comparacion contra IPs esperadas" \
        "cat /etc/resolv.conf; echo; grep -v '^#' /etc/hosts; echo;
         getent hosts $EP1_FQDN; getent hosts $EP2_FQDN;
         echo; echo 'IP esperada EP1: ${EP1_IP_DOC:-no proporcionada}'; echo 'IP esperada EP2: ${EP2_IP_DOC:-no proporcionada}'"
    if [[ -z "$EP1_RES" && -z "$EP2_RES" ]]; then
        add_result 21_dns FALLA "Resolucion DNS de EP1/EP2" "El SO no resuelve los FQDN proporcionados. Revisar /etc/resolv.conf (un parche/NetworkManager pudo reescribirlo)."
    elif [[ ( -n "$EP1_RES" && -n "$EP1_IP_DOC" && "$EP1_RES" != "$EP1_IP_DOC" ) || ( -n "$EP2_RES" && -n "$EP2_IP_DOC" && "$EP2_RES" != "$EP2_IP_DOC" ) ]]; then
        add_result 21_dns ALERTA "Resolucion DNS de EP1/EP2" "La resolucion no coincide con las IPs esperadas (EP1: ${EP1_RES:-sin respuesta} vs ${EP1_IP_DOC:-n/d}; EP2: ${EP2_RES:-sin respuesta} vs ${EP2_IP_DOC:-n/d}). Puede corresponder a DNS alterado, proxy intermedio o cambio de IPs por parte de IBM: confirmar antes de aplicar cambios. No corregir mediante entradas en /etc/hosts sin validacion."
    else
        add_result 21_dns OK "Resolucion DNS de EP1/EP2" "EP1=${EP1_RES:-no-resuelto} EP2=${EP2_RES:-no-resuelto}; coincide con las referencias proporcionadas."
    fi
fi

# 22 - firewalld -----------------------------------------------------------
if tiene firewall-cmd; then
    cap 22_firewall "Reglas de firewalld (514, forward 514->1514)" \
        "firewall-cmd --state; echo; firewall-cmd --list-all; echo; firewall-cmd --list-all --permanent"
    if salida 22_firewall | grep -q 'running'; then
        if salida 22_firewall | grep -q '514' && salida 22_firewall | grep -q 'forward-ports' && salida 22_firewall | grep -qE 'toport=1514'; then
            add_result 22_firewall OK "firewalld con reglas del DLC" "Puertos 514 y forward 514->1514 presentes."
        else
            add_result 22_firewall FALLA "firewalld con reglas del DLC" "firewalld corre pero FALTAN los puertos 514 o el forward 514->1514. Un reload/parche pudo borrar reglas no permanentes. Comparar runtime vs permanent en la evidencia."
        fi
    else
        add_result 22_firewall ALERTA "firewalld" "firewalld no esta en ejecucion. Si la detencion no fue intencional, pudo derivarse del parcheo; verificar si existe otro firewall (nftables) activo."
    fi
else
    no_ejecutada 22_firewall "Reglas de firewalld" "falta el comando firewall-cmd (verificar si firewalld fue desinstalado durante el parcheo)"
fi

# 23 - SELinux -------------------------------------------------------------
# SELinux es el modulo de seguridad del kernel de RHEL: puede BLOQUEAR en
# silencio operaciones de un proceso (leer certificados, escribir en /store,
# abrir conexiones) aunque los permisos de archivo se vean bien. Cuando
# bloquea algo deja un rastro "avc: denied" en la auditoria; eso es lo que
# esta prueba busca contra el proceso java/dlc.
cap 23_selinux "SELinux: verificacion de bloqueos del modulo de seguridad del kernel hacia el DLC" \
    "getenforce; echo; sestatus 2>/dev/null | head -6; echo;
     echo '--- denegaciones AVC recientes (vacio = nada bloqueado):';
     ausearch -m avc -ts recent 2>/dev/null | tail -40 || echo 'sin denegaciones registradas (o ausearch no disponible)'"
if salida 23_selinux | grep -E 'avc: *denied' | grep -qiE 'java|dlc'; then
    add_result 23_selinux FALLA "SELinux bloqueando al DLC" "Hay denegaciones AVC contra java/dlc: SELinux esta impidiendo operaciones al DLC en silencio. Una actualizacion de politica SELinux en el parche es causa de SO. Ver evidencias/23_selinux.txt."
else
    add_result 23_selinux OK "SELinux no bloquea al DLC" "Modo: $(getenforce 2>/dev/null). No hay rastros 'avc: denied' contra java/dlc: SELinux no esta interfiriendo."
fi

# 24 - Conectividad TCP al EP ----------------------------------------------
DESTINOS=""
[[ -n "$DEST_IP" ]] && DESTINOS="$DEST_IP"
for f in "$EP1_FQDN" "$EP2_FQDN"; do
    ip_res=$(getent hosts "$f" 2>/dev/null | awk '{print $1; exit}')
    [[ -n "$ip_res" && "$ip_res" != "$DEST_IP" ]] && DESTINOS="$DESTINOS $ip_res"
done
CONN_OK=""; CONN_DET=""
for d in $DESTINOS; do
    if timeout 10 bash -c "echo > /dev/tcp/$d/$DEST_PORT" 2>/dev/null; then
        CONN_OK="si"; CONN_DET="$CONN_DET $d:$DEST_PORT=CONECTA"
    else
        CONN_DET="$CONN_DET $d:$DEST_PORT=NO-CONECTA"
    fi
done
cap 24_conexion "Prueba de conexion TCP saliente a QRoC ($DEST_PORT)" \
    "echo 'Destino en config.json: ${DEST_IP:-no leido} : $DEST_PORT (tipo: ${DEST_TYPE:-?})'; echo 'Resultados:$CONN_DET'"
if [[ -n "$CONN_OK" ]]; then
    add_result 24_conexion OK "Conexion TCP al EP ($DEST_PORT)" "$CONN_DET"
elif [[ -z "$DESTINOS" ]]; then
    no_ejecutada 24_conexion "Conexion TCP al EP" "no se pudo determinar el destino (config.json ilegible y DNS fallo)"
else
    add_result 24_conexion FALLA "Conexion TCP al EP ($DEST_PORT)" "Ningun endpoint acepta conexion:$CONN_DET. Indica un problema de salida (ruta, firewall perimetral o allowlist de QRoC)."
fi

# 25 - Handshake TLS al EP -------------------------------------------------
# Se emplea la forma de validacion de campo del autor:
#   openssl s_client -showcerts -verify 32 -connect <EP>:<puerto>
# (-verify 32: verificacion de la cadena del servidor con profundidad maxima
#  32; reporta cada nivel 'depth=N ... verify return' y el codigo final).
TLS_DEST="${DEST_IP:-$(getent hosts "$EP1_FQDN" 2>/dev/null | awk '{print $1; exit}')}"
# Para el handshake se prefiere el FQDN del EP cuando el destino corresponde
# a las IPs esperadas proporcionadas (habilita SNI).
TLS_HOST="$TLS_DEST"
[[ "$TLS_DEST" == "$EP1_IP_DOC" ]] && TLS_HOST="$EP1_FQDN"
[[ "$TLS_DEST" == "$EP2_IP_DOC" ]] && TLS_HOST="$EP2_FQDN"
if [[ -n "$TLS_DEST" ]] && tiene openssl; then
    cap 25_tls "Handshake TLS contra $TLS_HOST:$DEST_PORT (showcerts, verify 32)" \
        "echo | timeout 25 openssl s_client -showcerts -verify 32 -connect $TLS_HOST:$DEST_PORT 2>&1 | grep -E 'CONNECTED|^depth|verify return|verify error|Verify return code|Verification|Protocol|Cipher|error|unable' | head -20;
         echo '--- cadena de certificados presentada por el servidor:';
         echo | timeout 20 openssl s_client -connect $TLS_HOST:$DEST_PORT -showcerts 2>/dev/null | grep -E '^ *[si]:' | head -10"
    if salida 25_tls | grep -q 'CONNECTED'; then
        add_result 25_tls OK "Handshake TLS al EP" "$(salida 25_tls | grep -E 'Verify return code|Protocol|Cipher' | tr '\n' '; ')"
    else
        add_result 25_tls FALLA "Handshake TLS al EP" "No se completo el handshake TLS. Cruzar con 42_crypto (crypto-policies) y 34_certs."
    fi
elif ! tiene openssl; then
    no_ejecutada 25_tls "Handshake TLS al EP" "falta el comando openssl"
else
    no_ejecutada 25_tls "Handshake TLS al EP" "no se pudo resolver el destino QRoC (ver 21_dns y 30_config)"
fi

# 26 - IP publica de salida ------------------------------------------------
if tiene curl; then
    # El allowlist de QRoC se registra con la IPv4; en enlaces dual-stack
    # (IPv4+IPv6) ifconfig.me responde la IPv6 si no se fuerza -4.
    cap 26_ip_publica "IP publica de salida IPv4 (dos canales) e IPv6 informativa" \
        "echo '--- IPv4 via HTTPS (curl -4 ifconfig.me):';
         curl -4 -s --max-time 15 https://ifconfig.me || echo 'sin respuesta IPv4 por HTTPS';
         echo; echo '--- IPv4 via DNS (OpenDNS; funciona aunque HTTPS salga bloqueado):';
         { command -v dig >/dev/null 2>&1 && timeout 15 dig -4 +short A myip.opendns.com @resolver1.opendns.com; } || echo 'dig no disponible o sin respuesta';
         echo; echo '--- IPv6 via HTTPS (solo informativa; el allowlist de QRoC usa la IPv4):';
         curl -6 -s --max-time 10 https://ifconfig.me || echo 'sin IPv6 (normal en muchos enlaces)'"
    IP_PUB=$(salida 26_ip_publica | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
    if [[ -n "$IP_PUB" ]]; then
        add_result 26_ip_publica INFO "IP publica de salida (IPv4)" "IPv4 publica actual: $IP_PUB. VERIFICAR MANUALMENTE que siga en el allowlist de QRoC; si el cliente cambio de IP publica, QRoC descarta la conexion aunque todo lo local este sano. La IPv6 (si aparece en la evidencia) es solo informativa."
    else
        add_result 26_ip_publica FALLA "IP publica de salida (IPv4)" "No se obtuvo la IPv4 publica por ningun canal (HTTPS ni DNS). Si solo respondio IPv6, el enlace podria estar saliendo sin IPv4 utilizable hacia QRoC; cruzar con 24_conexion y 27_traceroute."
    fi
else
    no_ejecutada 26_ip_publica "IP publica de salida" "falta el comando curl"
fi

# 27 - Ruta TCP hacia el EP (identificar el salto donde se interrumpe) ------
# El ICMP suele estar filtrado hacia QRoC; por eso se traza con SYN TCP al
# puerto real. Cascada de herramientas: tcptraceroute -> traceroute -T -> mtr.
if [[ -n "$TLS_DEST" ]]; then
    TR_TOOL=""
    if tiene tcptraceroute; then
        TR_TOOL="tcptraceroute"
        cap 27_traceroute "Ruta TCP al EP $TLS_DEST:$DEST_PORT (tcptraceroute)" \
            "timeout 75 tcptraceroute -n $TLS_DEST $DEST_PORT 2>&1 | head -25"
    elif tiene traceroute; then
        TR_TOOL="traceroute -T"
        cap 27_traceroute "Ruta TCP al EP $TLS_DEST:$DEST_PORT (traceroute -T, SYN TCP)" \
            "timeout 75 traceroute -T -n -p $DEST_PORT -m 15 -w 2 $TLS_DEST 2>&1 | head -25"
    elif tiene mtr; then
        TR_TOOL="mtr --tcp"
        cap 27_traceroute "Ruta TCP al EP $TLS_DEST:$DEST_PORT (mtr --tcp)" \
            "timeout 75 mtr --tcp -P $DEST_PORT -n -r -c 5 $TLS_DEST 2>&1 | head -25"
    fi
    if [[ -z "$TR_TOOL" ]]; then
        no_ejecutada 27_traceroute "Ruta TCP al EP" "no hay tcptraceroute, traceroute ni mtr instalados"
    elif salida 27_traceroute | grep -qE "open|$TLS_DEST"; then
        add_result 27_traceroute OK "Ruta TCP al EP ($TR_TOOL)" "La traza alcanza el destino $TLS_DEST:$DEST_PORT (ver saltos en la evidencia)."
    elif [[ "${V[24_conexion]:-}" == OK ]]; then
        add_result 27_traceroute INFO "Ruta TCP al EP ($TR_TOOL)" "La traza no muestra el salto final (comportamiento comun cuando el perimetro filtra las respuestas del trazado), pero la conectividad extremo a extremo esta confirmada por 24_conexion y 25_tls; no constituye hallazgo."
    else
        add_result 27_traceroute ALERTA "Ruta TCP al EP ($TR_TOOL)" "La traza no alcanza el destino: identificar en la evidencia el ultimo salto que responde; en ese punto (firewall perimetral o proveedor) se interrumpe la ruta hacia el puerto $DEST_PORT."
    fi
else
    no_ejecutada 27_traceroute "Ruta TCP al EP" "no se pudo determinar el destino QRoC"
fi

#=============================================================================
seccion "BLOQUE 4 - Frontera SO <-> aplicacion DLC (deslinde)"
#=============================================================================

# 30 - Configuracion del DLC ----------------------------------------------
cap 30_config "Configuracion del DLC (config.json, sin passwords)" \
    "sed 's/\\(keystorepassword\"[ ]*:[ ]*\\)\"[^\"]*\"/\\1\"***OCULTO***\"/' '$CONFIG_JSON' 2>/dev/null || echo 'No se pudo leer $CONFIG_JSON'"
if [[ -n "$DEST_IP" ]]; then
    add_result 30_config OK "config.json legible" "destino=$DEST_IP:$DEST_PORT tipo=${DEST_TYPE:-?}"
else
    add_result 30_config FALLA "config.json legible" "No se pudo leer destino de $CONFIG_JSON."
fi


# 30b - Coherencia del destino: esperado (parametros) vs configurado vs DNS -
if [[ -z "$DEST_IP" ]]; then
    no_ejecutada 30b_destino "Coherencia del destino" "no se pudo leer el destino de config.json"
else
    HAY_REF="no"; COINCIDE="no"
    for _ref in "$EP1_IP_DOC" "$EP2_IP_DOC" "${EP1_RES:-}" "${EP2_RES:-}" "$EP1_FQDN" "$EP2_FQDN"; do
        [[ -n "$_ref" ]] || continue
        HAY_REF="si"
        [[ "$DEST_IP" == "$_ref" ]] && COINCIDE="si"
    done
    PUERTO_OBS=""
    [[ -n "$PUERTO_ESPERADO" && "$DEST_PORT" != "$PUERTO_ESPERADO" ]] && \
        PUERTO_OBS=" El puerto configurado ($DEST_PORT) difiere del esperado ($PUERTO_ESPERADO); en QRadar on Cloud el puerto debe permanecer en 32500."
    if [[ "$HAY_REF" == "si" && "$COINCIDE" == "no" ]]; then
        add_result 30b_destino ALERTA "Coherencia del destino" "El destino configurado en config.json ($DEST_IP:$DEST_PORT) no corresponde a ninguna referencia esperada (parametros -e/-f/-i/-j ni su resolucion DNS): validar contra la documentacion del tenant.$PUERTO_OBS"
    elif [[ -n "$PUERTO_OBS" ]]; then
        add_result 30b_destino ALERTA "Coherencia del destino" "Destino configurado: $DEST_IP:$DEST_PORT.$PUERTO_OBS"
    elif [[ "$HAY_REF" == "si" ]]; then
        add_result 30b_destino OK "Coherencia del destino" "El destino configurado ($DEST_IP:$DEST_PORT) coincide con las referencias esperadas y con el puerto esperado (${PUERTO_ESPERADO:-n/d})."
    else
        add_result 30b_destino INFO "Coherencia del destino" "Sin referencias esperadas proporcionadas (-e/-f/-i/-j); destino configurado: $DEST_IP:$DEST_PORT (puerto esperado: ${PUERTO_ESPERADO:-no definido})."
    fi
fi

# 31 - Trafico ENTRANTE (verificar si llegan eventos de los log sources) ----
if tiene tcpdump; then
    cap 31_entrante "Captura ${TCPDUMP_SEGUNDOS}s de trafico entrante syslog (514/1514/6514)" \
        "timeout $TCPDUMP_SEGUNDOS tcpdump -nn -i any -c 40 'port $PUERTOS_ENTRADA' 2>&1 | head -50"
    PKT_IN=$(salida 31_entrante | grep -cE '^[0-9]{2}:[0-9]{2}')
    if [[ "$PKT_IN" -gt 0 ]]; then
        add_result 31_entrante OK "Llegan eventos al servidor" "$PKT_IN paquetes syslog vistos en ${TCPDUMP_SEGUNDOS}s."
    else
        add_result 31_entrante FALLA "Llegan eventos al servidor" "0 paquetes en ${TCPDUMP_SEGUNDOS}s: los log sources no estan entregando eventos a este servidor (problema en los log sources o en el firewall de entrada). Nota: con pocos o ningun log source configurado (volumen muy bajo) este resultado puede ser esperado; incrementar TCPDUMP_SEGUNDOS y repetir la prueba."
    fi
else
    no_ejecutada 31_entrante "Llegan eventos al servidor" "falta el comando tcpdump"
fi

# 32 - Trafico SALIENTE (verificar si el DLC envia hacia QRoC) --------------
if command -v tcpdump >/dev/null 2>&1 && [[ -n "$TLS_DEST" ]]; then
    cap 32_saliente "Captura ${TCPDUMP_SEGUNDOS}s de trafico saliente hacia $TLS_DEST:$DEST_PORT" \
        "timeout $TCPDUMP_SEGUNDOS tcpdump -nn -i any -c 40 'dst host $TLS_DEST and port $DEST_PORT' 2>&1 | head -50"
    PKT_OUT=$(salida 32_saliente | grep -cE '^[0-9]{2}:[0-9]{2}')
    if [[ "$PKT_OUT" -gt 0 ]]; then
        add_result 32_saliente OK "El DLC envia trafico a QRoC" "$PKT_OUT paquetes hacia $TLS_DEST:$DEST_PORT en ${TCPDUMP_SEGUNDOS}s."
    else
        add_result 32_saliente FALLA "El DLC envia trafico a QRoC" "0 paquetes salientes en ${TCPDUMP_SEGUNDOS}s: el DLC no esta transmitiendo. Nota: con volumen muy bajo y sin eventos entrantes (31), es posible que el DLC no tenga datos por transmitir durante la ventana de captura; interpretar en conjunto con 33_jmx."
    fi
elif ! tiene tcpdump; then
    no_ejecutada 32_saliente "El DLC envia trafico a QRoC" "falta el comando tcpdump"
else
    no_ejecutada 32_saliente "El DLC envia trafico a QRoC" "no se pudo determinar el destino QRoC"
fi

# 33 - Contadores JMX (dos muestras, para ver si CRECEN) -------------------
if [[ -x "$JMX_SH" ]] && systemctl is-active --quiet dlc 2>/dev/null; then
    MBEAN_SRC="com.q1labs.sem:application=dlc.dlc,type=sources,name=Syslog Source"
    MBEAN_DST="com.q1labs.sem:application=dlc.dlc,type=destinations,id=SECStoreForwardDestination"
    S1=$("$JMX_SH" -p $JMX_PORT "$MBEAN_SRC" Posted     2>/dev/null | awk -F': *' '/Posted/     {print $2; exit}')
    D1=$("$JMX_SH" -p $JMX_PORT "$MBEAN_DST" EventsSeen 2>/dev/null | awk -F': *' '/EventsSeen/ {print $2; exit}')
    sleep "$JMX_INTERVALO"
    S2=$("$JMX_SH" -p $JMX_PORT "$MBEAN_SRC" Posted     2>/dev/null | awk -F': *' '/Posted/     {print $2; exit}')
    D2=$("$JMX_SH" -p $JMX_PORT "$MBEAN_DST" EventsSeen 2>/dev/null | awk -F': *' '/EventsSeen/ {print $2; exit}')
    cap 33_jmx "Contadores JMX del DLC (2 muestras con ${JMX_INTERVALO}s de intervalo)" \
        "echo 'Fuente Syslog (Posted, entrada al pipeline):  muestra1=${S1:-?}  muestra2=${S2:-?}';
         echo 'Destino StoreForward (EventsSeen, salida):    muestra1=${D1:-?}  muestra2=${D2:-?}'"
    DNOTA=""
    [[ -z "${D1:-}" && -z "${D2:-}" ]] && DNOTA=" Nota: el atributo EventsSeen del destino no esta disponible en esta version del DLC; la transmision efectiva se valida con 32_saliente."
    if [[ -n "${S1:-}" && -n "${S2:-}" ]]; then
        DET="entrada: ${S1}->${S2}; salida: ${D1:-no disponible}->${D2:-no disponible}.$DNOTA"
        if [[ "$S2" -gt "$S1" ]]; then
            add_result 33_jmx OK "El DLC esta procesando eventos" "Los contadores crecen ($DET)."
        elif [[ "${V[31_entrante]:-}" == OK && "${V[32_saliente]:-}" == OK ]]; then
            add_result 33_jmx INFO "El DLC esta procesando eventos" "Los contadores no variaron en la ventana de ${JMX_INTERVALO}s ($DET); no obstante, el trafico entrante (31) y saliente (32) esta confirmado: consistente con un volumen de eventos muy bajo, no con una falla de procesamiento. Para confirmar, ampliar JMX_INTERVALO y repetir la prueba."
        else
            add_result 33_jmx FALLA "El DLC esta procesando eventos" "Los contadores no crecen ($DET) y el trafico no corrobora procesamiento: el DLC no recibe o no procesa. Correlacionar con 31, 32 y 35."
        fi
    else
        add_result 33_jmx FALLA "Contadores JMX" "jmx.sh se ejecuto pero no devolvio valores (posible JMX $JMX_PORT deshabilitado o servicio degradado). Ver evidencias/33_jmx.txt."
    fi
else
    no_ejecutada 33_jmx "Contadores JMX" "servicio dlc detenido o $JMX_SH no disponible"
fi

# 34 - Certificados --------------------------------------------------------
CERT_CMDS="ls -l '$KEYSTORE_DIR' '$KEYSTORE_DIR'/*/ 2>/dev/null; echo;
echo '--- Certificados en keystore (x509):';
for c in \$(find '$KEYSTORE_DIR' -type f \\( -name '*.cer' -o -name '*.crt' -o -name '*.pem' \\) 2>/dev/null); do
  echo \"== \$c\"; openssl x509 -in \"\$c\" -noout -subject -enddate 2>/dev/null;
  openssl x509 -in \"\$c\" -noout -text 2>/dev/null | grep -m1 'Signature Algorithm';
done; echo;
echo '--- PFX del cliente:';
for p in \$(find '$KEYSTORE_DIR' -type f -name '*.pfx' 2>/dev/null); do
  echo \"== \$p\";
  openssl pkcs12 -in \"\$p\" -nokeys -passin 'pass:$KS_PASS' 2>/dev/null | openssl x509 -noout -subject -enddate 2>/dev/null || echo '   (no se pudo abrir con el password de config.json - validar manualmente)';
done; echo;
echo '--- Anclas CA del SO (/etc/pki/ca-trust/source/anchors):';
for a in /etc/pki/ca-trust/source/anchors/*; do
  [ -f \"\$a\" ] || continue; echo \"== \$a\"; openssl x509 -in \"\$a\" -noout -subject -enddate 2>/dev/null;
done; echo;
echo '--- Validacion de CADENA de confianza (certificados que usa el producto):';
BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem;
for d in '$KEYSTORE_DIR'/*/; do
  F=\"\${d}$CERT_FIRMADO_NOMBRE\"; FC=\"\${d}$CERT_FULLCHAIN_NOMBRE\";
  [ -f \"\$F\" ] || continue;
  echo \"== UUID: \$(basename \"\$d\")\";
  UNT='';
  [ -f \"\$FC\" ] && UNT=\"-untrusted \$FC\";
  [ -f '$KEYSTORE_DIR/intermediate.pem' ] && UNT=\"\$UNT -untrusted $KEYSTORE_DIR/intermediate.pem\";
  printf 'verify cert firmado     : '; openssl verify -CAfile \"\$BUNDLE\" \$UNT \"\$F\" 2>&1 | tail -1;
  if [ -f \"\$FC\" ]; then printf 'verify cadena completa  : '; openssl verify -CAfile \"\$BUNDLE\" \$UNT \"\$FC\" 2>&1 | tail -1; fi;
done; echo;
echo '--- CORRESPONDENCIA certificado firmado <-> PFX en uso <-> llave privada:';
FP1='';
for d in '$KEYSTORE_DIR'/*/; do
  F=\"\${d}$CERT_FIRMADO_NOMBRE\"; [ -f \"\$F\" ] || continue;
  FP1=\$(openssl x509 -in \"\$F\" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2);
  echo \"huella cert firmado (\$(basename \"\$d\")): \$FP1\";
done;
FP2='';
if [ -f '$KEYSTORE_DIR/dlc-client.pfx' ]; then
  FP2=\$(openssl pkcs12 -in '$KEYSTORE_DIR/dlc-client.pfx' -nokeys -passin 'pass:$KS_PASS' 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2);
  echo \"huella dlc-client.pfx (en uso)  : \${FP2:-no extraible con el password de config.json}\";
fi;
if [ -n \"\$FP1\" ] && [ -n \"\$FP2\" ]; then
  if [ \"\$FP1\" = \"\$FP2\" ]; then
    echo 'correspondencia cert-firmado <-> dlc-client.pfx: COINCIDEN';
  else
    echo 'correspondencia cert-firmado <-> dlc-client.pfx: NO COINCIDEN (el PFX en uso NO se genero del certificado firmado por la CA emisora)';
  fi;
fi;
if [ -f '$KEYSTORE_DIR/privatekey.pem' ] && [ -f '$KEYSTORE_DIR/publiccert.pem' ]; then
  M1=\$(openssl x509 -in '$KEYSTORE_DIR/publiccert.pem' -noout -modulus 2>/dev/null </dev/null | md5sum | awk '{print \$1}');
  M2=\$(openssl rsa -in '$KEYSTORE_DIR/privatekey.pem' -noout -modulus -passin 'pass:$KS_PASS' 2>/dev/null </dev/null | md5sum | awk '{print \$1}');
  [ -z \"\$M2\" ] && M2=\$(openssl rsa -in '$KEYSTORE_DIR/privatekey.pem' -noout -modulus -passin pass: 2>/dev/null </dev/null | md5sum | awk '{print \$1}');
  if [ -z \"\$M2\" ] || [ \"\$M2\" = \"\$(echo -n '' | md5sum | awk '{print \$1}')\" ]; then
    echo 'correspondencia publiccert <-> privatekey: NO COMPARABLE - privatekey.pem esta cifrada con passphrase no disponible (no constituye un error; la validacion determinante es la correspondencia cert-firmado <-> dlc-client.pfx de la seccion anterior)';
  elif [ -n \"\$M1\" ] && [ \"\$M1\" = \"\$M2\" ]; then
    echo 'correspondencia publiccert <-> privatekey: COINCIDEN';
  else
    echo 'correspondencia publiccert <-> privatekey: NO COINCIDEN';
  fi;
fi; echo;
echo '--- DEDUCCION de la cadena: emisor del certificado del DLC vs CAs instaladas:';
echo '(no hace falta conocer el raiz/intermedio de antemano: se identifican por hash de emisor)';
for d in '$KEYSTORE_DIR'/*/; do
  F=\"\${d}$CERT_FIRMADO_NOMBRE\"; [ -f \"\$F\" ] || continue;
  echo \"cliente    : \$(openssl x509 -in \"\$F\" -noout -subject 2>/dev/null)\";
  echo \"emisor     : \$(openssl x509 -in \"\$F\" -noout -issuer 2>/dev/null)\";
  IH=\$(openssl x509 -in \"\$F\" -noout -issuer_hash 2>/dev/null);
  ENC='';
  for ca in /etc/pki/ca-trust/source/anchors/* '$KEYSTORE_DIR/intermediate.pem'; do
    [ -f \"\$ca\" ] || continue;
    SH=\$(openssl x509 -in \"\$ca\" -noout -subject_hash 2>/dev/null);
    [ -n \"\$SH\" ] && [ \"\$SH\" = \"\$IH\" ] && ENC=\"\$ca\";
  done;
  if [ -n \"\$ENC\" ]; then
    echo \"INTERMEDIO DEDUCIDO (instalado): \$ENC\";
    IH2=\$(openssl x509 -in \"\$ENC\" -noout -issuer_hash 2>/dev/null);
    SH2=\$(openssl x509 -in \"\$ENC\" -noout -subject_hash 2>/dev/null);
    if [ \"\$IH2\" = \"\$SH2\" ]; then
      echo 'el emisor deducido es autofirmado: es el RAIZ';
    else
      RAIZ='';
      for ca2 in /etc/pki/ca-trust/source/anchors/*; do
        [ -f \"\$ca2\" ] || continue;
        [ \"\$(openssl x509 -in \"\$ca2\" -noout -subject_hash 2>/dev/null)\" = \"\$IH2\" ] && RAIZ=\"\$ca2\";
      done;
      if [ -n \"\$RAIZ\" ]; then echo \"RAIZ DEDUCIDA (instalada): \$RAIZ\"; else echo 'RAIZ NO ENCONTRADA entre las anclas instaladas: falta instalar el certificado raiz de la CA emisora (update-ca-trust)'; fi;
    fi;
  else
    echo 'EMISOR NO ENCONTRADO entre las CAs instaladas: falta el intermedio/raiz de la CA emisora en /etc/pki/ca-trust/source/anchors o en el keystore';
  fi;
done; echo;
echo '--- CAs de cliente ACEPTADAS por el EP (expuestas en el handshake TLS mutuo):';
if [ -n '$TLS_DEST' ]; then
  LISTA=\$(echo | timeout 20 openssl s_client -connect '$TLS_DEST:$DEST_PORT' 2>/dev/null | sed -n '/Acceptable client certificate CA names/,/^---/p' | head -25);
  if [ -n \"\$LISTA\" ]; then echo \"\$LISTA\"; else echo 'el EP no expone lista de CAs aceptadas o no se pudo consultar'; fi;
  FPEM=\$(find '$KEYSTORE_DIR' -maxdepth 2 -name '$CERT_FIRMADO_NOMBRE' 2>/dev/null | head -1);
  if [ -n \"\$FPEM\" ] && [ -n \"\$LISTA\" ]; then
    CNV=\$(openssl x509 -in \"\$FPEM\" -noout -issuer 2>/dev/null | sed -n 's/.*CN *= *\([^,]*\).*/\1/p');
    if [ -n \"\$CNV\" ] && printf '%s' \"\$LISTA\" | grep -qF \"\$CNV\"; then
      echo \"comparacion contra el EP: COINCIDE - el EP acepta la CA emisora del certificado del DLC (\$CNV)\";
    else
      echo \"comparacion contra el EP: NO SE ENCONTRO la CA emisora (\${CNV:-desconocida}) en la lista del EP - validar con IBM\";
    fi;
  fi;
else
  echo 'destino EP no disponible (ver 21_dns / 30_config)';
fi; echo;
echo '--- CUMPLIMIENTO DEL PROCEDIMIENTO DE INSTALACION DE CERTIFICADOS';
echo '    (guia IBM: certificate-based authentication on Disconnected Log Collector)';
echo 'paso 1: certificado raiz en /etc/pki/ca-trust/source/anchors y update-ca-trust ejecutado';
BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem;
HAY_ANCLA='';
for a in /etc/pki/ca-trust/source/anchors/*; do
  [ -f \"\$a\" ] || continue; HAY_ANCLA=si;
  R=\$(openssl verify -CAfile \"\$BUNDLE\" \"\$a\" 2>&1 | tail -1);
  case \"\$R\" in
    *': OK') echo \"  PROCEDIMIENTO OK: \$a incorporado al truststore extraido (update-ca-trust ejecutado)\";;
    *) echo \"  PROCEDIMIENTO DESVIACION: \$a no figura en el truststore extraido; ejecutar update-ca-trust\";;
  esac;
done;
[ -z \"\$HAY_ANCLA\" ] && echo '  PROCEDIMIENTO DESVIACION: no existen anclas en /etc/pki/ca-trust/source/anchors (paso 2 del procedimiento no ejecutado)';
echo 'paso 2: CSR generado con generateCertificate.sh -csr (keystore/<UUID>/dlc-client.csr)';
for d in '$KEYSTORE_DIR'/*/; do
  U=\$(basename \"\$d\"); CSR=\"\${d}dlc-client.csr\"; F=\"\${d}$CERT_FIRMADO_NOMBRE\";
  if [ -f \"\$CSR\" ]; then
    CNC=\$(openssl req -in \"\$CSR\" -noout -subject 2>/dev/null | sed -n 's@.*CN *= *\([^,]*\).*@\1@p');
    echo \"  PROCEDIMIENTO OK: CSR presente (UUID \$U; CN=\${CNC:-no legible})\";
    [ \"\$CNC\" = \"\$U\" ] || echo \"  PROCEDIMIENTO DESVIACION: el CN del CSR (\${CNC:-vacio}) no coincide con el UUID (\$U) requerido para el CN whitelist en QRadar\";
  else
    echo \"  PROCEDIMIENTO DESVIACION: no existe dlc-client.csr en \$d\";
  fi;
  echo 'paso 3: certificado firmado por la CA corresponde al CSR y conserva el CN=UUID';
  if [ -f \"\$CSR\" ] && [ -f \"\$F\" ]; then
    MC=\$(openssl req -in \"\$CSR\" -noout -modulus 2>/dev/null | md5sum | awk '{print \$1}');
    MF=\$(openssl x509 -in \"\$F\" -noout -modulus 2>/dev/null | md5sum | awk '{print \$1}');
    if [ -n \"\$MC\" ] && [ \"\$MC\" = \"\$MF\" ]; then
      echo '  PROCEDIMIENTO OK: la llave publica del certificado firmado coincide con la del CSR generado en este DLC';
    else
      echo '  PROCEDIMIENTO DESVIACION: el certificado firmado no corresponde al CSR generado en este DLC';
    fi;
    CNF=\$(openssl x509 -in \"\$F\" -noout -subject 2>/dev/null | sed -n 's@.*CN *= *\([^,]*\).*@\1@p');
    if [ \"\$CNF\" = \"\$U\" ]; then
      echo \"  PROCEDIMIENTO OK: CN del certificado firmado = UUID (\$U)\";
    else
      echo \"  PROCEDIMIENTO DESVIACION: CN del certificado firmado (\${CNF:-vacio}) distinto del UUID (\$U)\";
    fi;
  elif [ ! -f \"\$F\" ]; then
    echo \"  PROCEDIMIENTO DESVIACION: no existe el certificado firmado ($CERT_FIRMADO_NOMBRE) en \$d\";
  fi;
done;
echo 'paso 4: PFX generado con generateCertificate.sh -p12 (keystore/dlc-client.pfx)';
if [ -f '$KEYSTORE_DIR/dlc-client.pfx' ]; then
  echo '  PROCEDIMIENTO OK: dlc-client.pfx presente';
  echo '  nota: tls.keystorepassword se almacena cifrado por el servicio DLC; si la huella del PFX no resulto extraible en la seccion de correspondencia, la comparacion debe realizarse de forma manual con el password original de la conversion -p12';
else
  echo '  PROCEDIMIENTO DESVIACION: no existe dlc-client.pfx; ejecutar generateCertificate.sh -p12 con el certificado firmado';
fi;
echo 'paso 5: config.json con destination.type=TLS y keystore configurado';
if [ '${DEST_TYPE}' = 'TLS' ]; then
  echo '  PROCEDIMIENTO OK: destination.type=TLS';
else
  echo \"  PROCEDIMIENTO DESVIACION: destination.type='${DEST_TYPE}' (el procedimiento requiere TLS)\";
fi;
if grep -q 'tls.keystorefilepath' '$CONFIG_JSON' 2>/dev/null; then
  echo '  PROCEDIMIENTO OK: tls.keystorefilepath definido en config.json';
else
  echo '  PROCEDIMIENTO DESVIACION: tls.keystorefilepath no definido en config.json';
fi"
cap 34_certs "Certificados: keystore del DLC y anclas CA (vigencia y algoritmo)" "$CERT_CMDS"
if ! tiene openssl; then
    no_ejecutada 34_certs "Vigencia de certificados" "falta el comando openssl"
else
HOY_EPOCH=$(date +%s); CERT_VENCIDO=""; CERT_SHA1=""
while IFS= read -r linea; do
    fecha="${linea#notAfter=}"
    exp_epoch=$(date -d "$fecha" +%s 2>/dev/null || echo "")
    [[ -n "$exp_epoch" && "$exp_epoch" -lt "$HOY_EPOCH" ]] && CERT_VENCIDO="si"
done < <(salida 34_certs | grep '^notAfter=')
salida 34_certs | grep -qi 'sha1' && CERT_SHA1="si"
CERT_CHAIN_ERR=""
salida 34_certs | grep -qiE 'unable to get local issuer|verification failed|certificate has expired|self-signed certificate in' && CERT_CHAIN_ERR="si"
CERT_NOCORR=""
salida 34_certs | grep -q 'NO COINCIDEN' && CERT_NOCORR="si"
CERT_SIN_CA=""
salida 34_certs | grep -qE 'EMISOR NO ENCONTRADO|RAIZ NO ENCONTRADA' && CERT_SIN_CA="si"
CERT_EP_NC=""
salida 34_certs | grep -q 'NO SE ENCONTRO la CA emisora' && CERT_EP_NC="si"
CERT_PROC=""
salida 34_certs | grep -q 'PROCEDIMIENTO DESVIACION' && CERT_PROC="si"
if [[ -n "$CERT_VENCIDO" ]]; then
    add_result 34_certs FALLA "Vigencia y cadena de certificados" "Existen certificados vencidos (ver notAfter en evidencias/34_certs.txt). Causa frecuente de interrupcion repentina del envio en TLS."
elif [[ -n "$CERT_CHAIN_ERR" ]]; then
    add_result 34_certs FALLA "Vigencia y cadena de certificados" "La CADENA de confianza NO valida: openssl verify fallo para el certificado firmado/cadena completa contra las anclas CA instaladas (raiz/intermedio corporativos). Verificar las anclas en /etc/pki/ca-trust/source/anchors y ejecutar update-ca-trust conforme a la guia oficial de IBM. Ver evidencias/34_certs.txt."
elif [[ -n "$CERT_NOCORR" ]]; then
    add_result 34_certs FALLA "Vigencia y cadena de certificados" "Los certificados NO se corresponden entre si (certificado firmado vs dlc-client.pfx en uso, o llave privada vs certificado): el DLC estaria presentando un certificado distinto al firmado por la CA emisora. Ver evidencias/34_certs.txt."
elif [[ -n "$CERT_SIN_CA" ]]; then
    add_result 34_certs FALLA "Vigencia y cadena de certificados" "No se encontro el intermedio o el raiz de la CA emisora entre las anclas instaladas (la deduccion por hash de emisor no hallo coincidencia): instalar los certificados raiz/intermedio en /etc/pki/ca-trust/source/anchors y ejecutar update-ca-trust conforme a la guia oficial de IBM."
elif [[ -n "$CERT_PROC" ]]; then
    add_result 34_certs FALLA "Vigencia, cadena y procedimiento de certificados" "Se detectaron desviaciones del procedimiento de instalacion de certificados: revisar las lineas 'PROCEDIMIENTO DESVIACION' en evidencias/34_certs.txt (guia IBM de autenticacion basada en certificados)."
elif [[ -n "$CERT_EP_NC" ]]; then
    add_result 34_certs ALERTA "Vigencia y cadena de certificados" "La cadena local es valida, pero la CA emisora del certificado del DLC NO aparece en la lista de CAs aceptadas que expone el EP en el handshake: validar con IBM que el EP tenga registrada la CA emisora del cliente. Ver evidencias/34_certs.txt."
elif [[ -n "$CERT_SHA1" ]]; then
    add_result 34_certs ALERTA "Certificados con firma SHA-1" "Se detecto SHA-1. Las crypto-policies DEFAULT de RHEL 9 rechazan SHA-1 en TLS: cruzar con 42_crypto. Un parche pudo endurecer la politica."
else
    add_result 34_certs OK "Vigencia, cadena y procedimiento de certificados" "Sin vencidos, cadena valida (raiz/intermedio deducidos de las CAs instaladas), correspondencia verificada, CA aceptada por el EP y cumplimiento del procedimiento de instalacion (pasos 1-5) confirmado en la evidencia."
fi
fi

# 35 - Log de errores del DLC ----------------------------------------------
cap 35_dlc_error "Log de errores del DLC ($DLC_ERROR_LOG)" \
    "ls -l --time-style=long-iso '$DLC_ERROR_LOG' 2>/dev/null; echo; tail -n 60 '$DLC_ERROR_LOG' 2>/dev/null || echo 'No existe o no legible'"
LOG_MOD=$(stat -c %Y "$DLC_ERROR_LOG" 2>/dev/null || echo 0)
LOG_DIAS=$(( ($(date +%s) - LOG_MOD) / 86400 ))
if salida 35_dlc_error | grep -qiE 'ERROR_COULD_NOT_CONNECT|Network is unreachable|Connection refused|handshake|certificate|Crl expired|CRLExpired'; then
    PATRONES=$(salida 35_dlc_error | grep -oiE 'ERROR_COULD_NOT_CONNECT|Network is unreachable|Connection refused|handshake_failure|Q1CRLExpiredException|Crl expired|certificate[a-z_ ]*' | sort -u | head -4 | tr '\n' '; ')
    if [[ "$LOG_MOD" -gt 0 && "$LOG_DIAS" -le 7 ]]; then
        add_result 35_dlc_error FALLA "Errores en dlc.error" "Hay errores de conexion/TLS y el log se escribio hace $LOG_DIAS dia(s) (RECIENTE): $PATRONES"
    else
        add_result 35_dlc_error INFO "Errores en dlc.error" "Hay patrones de error pero el log NO se escribe desde hace $LOG_DIAS dia(s): son errores ANTIGUOS, no necesariamente de la falla actual. Comparar fechas dentro de la evidencia."
    fi
else
    add_result 35_dlc_error INFO "Errores en dlc.error" "Sin patrones de error de conexion en las ultimas 60 lineas (ultima escritura del log: hace $LOG_DIAS dia(s))."
fi

# 36 - CRLs cacheadas por el DLC (revocacion de la cadena del EP) -----------
# El DLC valida la revocacion de la cadena TLS del EP mediante CRLs que
# cachea en conf/cached_crl/ y refresca por HTTP (puerto 80) desde los
# puntos de distribucion del emisor (por ejemplo c.lencr.org para Let's
# Encrypt). Una CRL cacheada vencida que no puede refrescarse produce
# Q1CRLExpiredException en TLSSocketConnector.connect y detiene el envio,
# aun cuando red, handshake y certificados de cliente se observen correctos.
CRL_DIR="$DLC_HOME/conf/cached_crl"
if [[ -d "$CRL_DIR" ]] && tiene openssl; then
    cap 36_crl "CRLs cacheadas por el DLC: vigencia y capacidad de refresco (HTTP/80)" \
        "ls -l '$CRL_DIR' 2>/dev/null; echo;
         echo '--- vigencia de cada CRL cacheada (nextUpdate):';
         AHORA=\$(date +%s);
         for f in '$CRL_DIR'/*; do
           [ -f \"\$f\" ] || continue;
           NU=\$(openssl crl -in \"\$f\" -noout -nextupdate 2>/dev/null || openssl crl -inform DER -in \"\$f\" -noout -nextupdate 2>/dev/null);
           NU=\${NU#nextUpdate=};
           if [ -z \"\$NU\" ]; then echo \"\$f : no legible como CRL\"; continue; fi;
           NUE=\$(date -d \"\$NU\" +%s 2>/dev/null || echo 0);
           if [ \"\$NUE\" -gt 0 ] && [ \"\$NUE\" -lt \"\$AHORA\" ]; then EST='VENCIDA'; else EST='vigente'; fi;
           echo \"\$f : nextUpdate=\$NU -> \$EST\";
         done; echo;
         echo '--- prueba de refresco: salida HTTP/80 hacia los hosts de las CRLs cacheadas:';
         HOSTS=\$(ls '$CRL_DIR' 2>/dev/null | tr '\\\\' '/' | cut -d/ -f2 | sort -u);
         if [ -z \"\$HOSTS\" ]; then echo 'sin hosts que probar'; fi;
         for h in \$HOSTS; do
           [ -n \"\$h\" ] || continue;
           C=\$(curl -s -o /dev/null -m 10 -w '%{http_code}' \"http://\$h/\" 2>/dev/null);
           echo \"http://\$h/ -> codigo HTTP \${C:-sin respuesta} (000 o vacio = sin salida HTTP/80 hacia ese host)\";
         done"
    if salida 36_crl | grep -q 'VENCIDA'; then
        add_result 36_crl FALLA "CRLs cacheadas del DLC" "Existen CRLs cacheadas VENCIDAS en $CRL_DIR. El DLC valida la revocacion de la cadena del EP con estas CRLs; una CRL vencida que no puede refrescarse aborta la creacion del contexto TLS (Q1CRLExpiredException, correlacionar con 35_dlc_error) y detiene el envio. Verificar en la evidencia la salida HTTP/80 hacia los puntos de distribucion; la depuracion del cache y el reinicio del servicio deben ejecutarse de forma controlada y documentada."
    elif salida 36_crl | grep -q 'nextUpdate'; then
        add_result 36_crl OK "CRLs cacheadas del DLC" "Todas las CRLs cacheadas se encuentran vigentes."
    else
        add_result 36_crl INFO "CRLs cacheadas del DLC" "El directorio $CRL_DIR no contiene CRLs legibles (posible primera conexion pendiente o cache depurado)."
    fi
elif [[ ! -d "$CRL_DIR" ]]; then
    add_result 36_crl INFO "CRLs cacheadas del DLC" "No existe $CRL_DIR: el DLC no ha cacheado CRLs (no constituye un error por si mismo)."
else
    no_ejecutada 36_crl "CRLs cacheadas del DLC" "falta el comando openssl"
fi

# 37 - Validacion de sintaxis JSON de la configuracion del DLC --------------
# Antecedente documentado: un logSources.json malformado (edicion manual)
# produce MalformedJsonException al construir el config store durante el
# arranque, impidiendo la carga de los log sources ahi definidos. jq senala el
# archivo y la linea exacta del defecto.
if tiene jq || tiene python3; then
    # Nota: los archivos de fabrica del DLC (metaconf.json, metricConfig*.json,
    # metricMetaData*.json, payloadMapping.json) emplean un formato tolerante
    # (comillas simples, valores sin comillas como EventRate, booleanos True/
    # False) que el parser gson del producto acepta pero que no es JSON
    # estricto. El administrador no los edita segun procedimiento, por lo que
    # se excluyen de la validacion estricta y se reportan como JSON LENIENT.
    # El resto de los archivos (config.json, logSources.json, etc.) si se
    # valida estrictamente; solo esos pueden producir JSON INVALIDO.
    cap 37_json "Validacion de sintaxis JSON de los archivos de configuracion del DLC" \
        "for f in '$DLC_HOME'/conf/*.json; do
           [ -f \"\$f\" ] || continue;
           case \"\$(basename \"\$f\")\" in
             metaconf.json|metricConfig*.json|metricMetaData*.json|payloadMapping.json)
               echo \"JSON LENIENT  : \$f (archivo de fabrica en formato tolerante del producto; excluido de la validacion estricta, no constituye defecto)\";
               continue;;
           esac;
           if command -v jq >/dev/null 2>&1; then
             ERR=\$(jq empty \"\$f\" 2>&1);
             LEN=\$(sed \"s/'/\\\"/g\" \"\$f\" | jq empty 2>&1);
           else
             ERR=\$(python3 -m json.tool \"\$f\" 2>&1 >/dev/null);
             LEN=\$(sed \"s/'/\\\"/g\" \"\$f\" | python3 -m json.tool 2>&1 >/dev/null);
           fi;
           if [ -z \"\$ERR\" ]; then
             echo \"JSON VALIDO   : \$f\";
           elif [ -z \"\$LEN\" ]; then
             echo \"JSON LENIENT  : \$f (comillas simples aceptadas por el parser tolerante del producto - no constituye defecto)\";
           else
             echo \"JSON INVALIDO : \$f -> \$ERR\";
           fi;
         done"
    if salida 37_json | grep -q 'JSON INVALIDO'; then
        ARCHIVOS_INV=$(salida 37_json | grep 'JSON INVALIDO' | sed 's/JSON INVALIDO : //; s/ ->.*//' | tr '\n' ' ')
        add_result 37_json FALLA "Sintaxis JSON de la configuracion" "Archivo(s) con JSON invalido: $ARCHIVOS_INV. El servicio no puede cargar la configuracion ahi definida (correlacionar con MalformedJsonException en 35_dlc_error). La evidencia indica la linea exacta del defecto; corregir de forma controlada: respaldar el archivo, ajustar la sintaxis y reiniciar el servicio en ventana."
    else
        add_result 37_json OK "Sintaxis JSON de la configuracion" "Todos los archivos JSON de $DLC_HOME/conf son validos (los de formato lenient de fabrica quedan identificados en la evidencia y no constituyen defecto)."
    fi
else
    no_ejecutada 37_json "Sintaxis JSON de la configuracion" "faltan jq y python3"
fi

#=============================================================================
seccion "BLOQUE 5 - Cambios por el parcheo de Red Hat"
#=============================================================================

# 40 - Historial de dnf ----------------------------------------------------
cap 40_dnf "Transacciones dnf recientes, con ANTES y DESPUES de cada paquete" \
    "dnf -q history list 2>/dev/null | head -15; echo;
     echo '--- Detalle de las ultimas 3 transacciones (Upgraded = version ANTERIOR, Upgrade = version NUEVA):';
     for t in last last-1 last-2; do
       echo \"===== transaccion \$t =====\";
       dnf -q history info \$t 2>/dev/null | grep -E 'Begin time|Command Line|^ *(Upgrade|Upgraded|Install|Removed|Obsoleted)' | head -60;
     done; echo;
     echo '--- Ultimos 40 RPM instalados/actualizados (con fecha):';
     rpm -qa --last 2>/dev/null | head -40"
add_result 40_dnf INFO "Historial de parcheo (antes/despues)" "La evidencia muestra por transaccion la version ANTERIOR (lineas 'Upgraded') y la NUEVA (lineas 'Upgrade') de cada paquete: comparar y correlacionar la fecha de la transaccion con el dia en que dejo de enviar eventos."

# 41 - Kernel --------------------------------------------------------------
cap 41_kernel "Kernel en ejecucion vs instalado" \
    "uname -r; echo; rpm -q --last kernel 2>/dev/null | head -3"
KRUN=$(uname -r); KNEW=$(rpm -q --last kernel 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^kernel-//')
if [[ -n "$KNEW" && "$KRUN" != "$KNEW" ]]; then
    add_result 41_kernel ALERTA "Kernel" "En ejecucion $KRUN; el mas reciente instalado es $KNEW: existe un reinicio pendiente posterior al parcheo (o se inicio un kernel anterior)."
else
    add_result 41_kernel OK "Kernel" "En ejecucion el kernel mas reciente instalado ($KRUN)."
fi

# 42 - Crypto-policies -----------------------------------------------------
cap 42_crypto "Politica criptografica del sistema (RHEL 9)" \
    "update-crypto-policies --show 2>/dev/null; echo; ls -l /etc/crypto-policies/config 2>/dev/null"
CPOL=$(head -5 "$EVID/42_crypto.txt" | grep -m1 -oE 'LEGACY|DEFAULT|FUTURE|FIPS[A-Z:]*' || true)
case "${CPOL:-}" in
    LEGACY)  add_result 42_crypto OK "Crypto-policies" "Politica LEGACY (mas permisiva)." ;;
    DEFAULT) add_result 42_crypto INFO "Crypto-policies" "Politica DEFAULT: en RHEL 9 rechaza SHA-1 y TLS<1.2. Si 34_certs detecto SHA-1, correlacionar ambos hallazgos; la mitigacion documentada es 'update-crypto-policies --set DEFAULT:SHA1' (este script no la aplica)." ;;
    FUTURE|FIPS*) add_result 42_crypto ALERTA "Crypto-policies" "Politica ${CPOL}: altamente restrictiva; puede rechazar el TLS del DLC. Verificar si fue modificada por el parcheo o por un proceso de hardening." ;;
    *) no_ejecutada 42_crypto "Crypto-policies" "update-crypto-policies no disponible o sin salida" ;;
esac

# 43 - Paquetes DLC/Java tocados por el parche -----------------------------
cap 43_paquetes "Verificacion de paquetes sensibles modificados por el parcheo reciente (60 dias)" \
    "UMBRAL=\$(date -d '-60 days' +%s);
     rpm -qa --qf '%{INSTALLTIME}|%{INSTALLTIME:date}|%{NAME}-%{VERSION}-%{RELEASE}\n' 2>/dev/null |
       awk -F'|' -v u=\"\$UMBRAL\" '\$1 >= u {print \$2\" | \"\$3}' |
       grep -iE 'dlc|java|openssl|crypto-policies|firewalld|selinux-policy|chrony|NetworkManager|kernel' | head -30;
     echo '(vacio = ningun paquete sensible instalado/actualizado en los ultimos 60 dias)'"
if salida 43_paquetes | grep -qiE 'dlc|java|openssl|crypto-policies|firewalld|selinux-policy|chrony|NetworkManager|kernel'; then
    add_result 43_paquetes ALERTA "Paquetes sensibles actualizados (60 dias)" "El parcheo reciente toco paquetes de los que depende el DLC (fechas en la evidencia); correlacionar con 40_dnf (antes/despues) y con el dia de la falla."
else
    add_result 43_paquetes OK "Paquetes sensibles actualizados (60 dias)" "Sin cambios en java/openssl/firewalld/selinux/kernel en los ultimos 60 dias."
fi

#=============================================================================
seccion "BLOQUE 6 - Paquete de diagnostico para IBM Support (TechNote 7274013)"
#=============================================================================
# Replica la recoleccion oficial de IBM para adjuntar a un caso de soporte:
# logs del DLC, configuracion, keystore, MBeans completos, red y filesystem.
SOPORTE="$OUTDIR/soporte_ibm"
BUF="$SOPORTE/buffer"
mkdir -p "$BUF"
if tiene tar && tiene gzip; then
    {
        echo "# Paquete de soporte IBM segun TechNote 7274013"
        echo "# Fecha: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        tar -cf "$SOPORTE/dlc.tar" /var/log/dlc 2>&1
        tar -rf "$SOPORTE/dlc.tar" "$DLC_HOME"/conf/* 2>&1
        ls -lsRa "$KEYSTORE_DIR/" > "$BUF/keystore_contents.txt" 2>&1
        for file in $(find "$KEYSTORE_DIR" -name "*.crt" 2>/dev/null); do
            ls -l "$file" >> "$BUF/keystore_contents.txt"
            cat "$file"  >> "$BUF/keystore_contents.txt"
        done
        if [[ -x "$JMX_SH" ]] && systemctl is-active --quiet dlc 2>/dev/null; then
            timeout 60 "$JMX_SH" -p $JMX_PORT > "$BUF/mbeans.txt" 2>&1
        else
            echo "servicio dlc inactivo o jmx.sh no disponible" > "$BUF/mbeans.txt"
        fi
        ip address  > "$BUF/ifconfig.txt" 2>&1
        ip route    > "$BUF/iproute.txt" 2>&1
        df -h       > "$BUF/df_sh.txt" 2>&1
        ls -lR /store >> "$BUF/df_sh.txt" 2>&1
        firewall-cmd --list-all > "$BUF/firewalld.txt" 2>&1
        mount       > "$BUF/mount.txt" 2>&1
        { netstat -toupan 2>/dev/null || ss -toupan; } > "$BUF/netstat_output.txt" 2>&1
        hostnamectl > "$BUF/hostname.txt" 2>&1
        timeout 15 curl -s ifconfig.me > "$BUF/public_IP.txt" 2>&1
        tar -rf "$SOPORTE/dlc.tar" "$BUF"/*.txt 2>&1
        if [[ -d /store/ec ]]; then
            tar -rf "$SOPORTE/dlc.tar" /store/ec/* 2>&1
        fi
        gzip -f "$SOPORTE/dlc.tar" 2>&1
    } > "$EVID/50_soporte_ibm.txt" 2>&1
    nota ""
    cat "$EVID/50_soporte_ibm.txt" >> "$INFORME"
    if [[ -s "$SOPORTE/dlc.tar.gz" ]]; then
        add_result 50_soporte_ibm OK "Paquete para IBM Support" "$SOPORTE/dlc.tar.gz ($(du -h "$SOPORTE/dlc.tar.gz" 2>/dev/null | awk '{print $1}')). Listo para adjuntar al caso de soporte si se escala."
    else
        add_result 50_soporte_ibm FALLA "Paquete para IBM Support" "No se pudo crear dlc.tar.gz; ver evidencias/50_soporte_ibm.txt."
    fi
else
    no_ejecutada 50_soporte_ibm "Paquete para IBM Support" "faltan tar/gzip"
fi

#=============================================================================
seccion "RESUMEN DE RESULTADOS"
#=============================================================================
{
    echo ""
    printf '%-16s %-16s %s\n' "PRUEBA" "VEREDICTO" "DESCRIPCION"
    printf '%-16s %-16s %s\n' "------" "---------" "-----------"
    for i in "${!R_ID[@]}"; do
        printf '%-16s %-16s %s\n' "${R_ID[$i]}" "${R_VER[$i]}" "${R_DESC[$i]}"
    done
    echo ""
    echo "Detalle de hallazgos (FALLA / ALERTA / NO_CONCLUYENTE):"
    for i in "${!R_ID[@]}"; do
        case "${R_VER[$i]}" in
            FALLA|ALERTA|NO_CONCLUYENTE)
                echo ""
                echo "* [${R_VER[$i]}] ${R_ID[$i]} - ${R_DESC[$i]}"
                echo "  ${R_DET[$i]}"
                ;;
        esac
    done
} | tee -a "$INFORME"

#=============================================================================
seccion "CONCLUSION (analisis cruzado)"
#=============================================================================
concluir() {
    local c=""
    # 0) Diagnostico incompleto por prerequisitos
    [[ "${V[00_prereq]:-}" == FALLA ]] && c+=$'- DIAGNOSTICO INCOMPLETO: faltan comandos requeridos (ver 00_prereq); existen pruebas marcadas FALLA por no haberse podido ejecutar. Instalar los paquetes faltantes y ejecutar nuevamente el script antes de considerar concluyente el deslinde.\n'
    # 1) Causas directas de SO
    [[ "${V[03_oom]:-}"  == FALLA ]] && c+=$'- CAUSA DE SO PROBABLE: el OOM killer del kernel termino procesos; si el proceso afectado fue el java del DLC, constituye la causa de la falla. Evidencia: 03_oom.\n'
    [[ "${V[06_store]:-}" == FALLA ]] && c+=$'- CAUSA DE SO PROBABLE: /store no esta montada o se encuentra en solo lectura (frecuente tras un reinicio posterior al parcheo). Evidencia: 06_store.\n'
    [[ "${V[06b_store_rw]:-}" == FALLA ]] && c+=$'- CAUSA DE SO PROBABLE: la escritura efectiva en /store falla aun con permiso aparente correcto: escenario documentado de disco virtual desconectado de la maquina virtual (el proceso permanece en memoria sin persistir datos). Evidencia: 06b_store_rw, 07_xfs.\n'
    [[ "${V[05_disco]:-}" == FALLA ]] && c+=$'- CAUSA DE SO PROBABLE: particion llena. Evidencia: 05_disco.\n'
    [[ "${V[08_hora]:-}"  == FALLA ]] && c+=$'- CAUSA DE SO PROBABLE: reloj sin sincronizar; rompe TLS con QRoC. Evidencia: 08_hora.\n'
    [[ "${V[23_selinux]:-}" == FALLA ]] && c+=$'- CAUSA DE SO PROBABLE: SELinux esta denegando operaciones al DLC (posible cambio de politica introducido por el parcheo). Evidencia: 23_selinux.\n'
    [[ "${V[12_java]:-}" == FALLA || "${V[12_java]:-}" == ALERTA ]] && c+=$'- POSIBLE EFECTO DEL PARCHEO: el Java requerido por DLC (IBM SDK 8) no se confirma; la actualizacion pudo reemplazarlo o modificar alternatives. Evidencia: 12_java, 43_paquetes.\n'
    # 2) Servicio
    [[ "${V[10_servicio]:-}" == FALLA ]] && c+=$'- El servicio dlc se encuentra detenido. Antes de reiniciarlo, conservar las evidencias (03, 11, 35): un reinicio sin diagnostico elimina la evidencia de la causa.\n'
    # 3) Red de salida
    if [[ "${V[24_conexion]:-}" == FALLA || "${V[20_red]:-}" == FALLA || "${V[21_dns]:-}" == FALLA ]]; then
        c+=$'- SALIDA HACIA QROC ROTA: el SO no logra conectar al EP:32500 (ruta/DNS/firewall perimetral). La traza de 27_traceroute muestra el ultimo salto que responde (donde se corta). Verificar tambien el allowlist de QRoC con la IP publica de 26_ip_publica.\n'
    fi
    [[ "${V[21_dns]:-}" == ALERTA ]] && c+=$'- DNS NO COINCIDE con las IPs esperadas (21_dns): confirmar con IBM un posible cambio de IPs de los EP antes de aplicar modificaciones; no agregar entradas a /etc/hosts sin validacion.\n'
    # 4) TLS / certificados / crypto
    if [[ "${V[24_conexion]:-}" == OK && ( "${V[25_tls]:-}" == FALLA || "${V[34_certs]:-}" == FALLA ) ]]; then
        c+=$'- LA CONEXION TCP SE ESTABLECE PERO EL TLS FALLA: indica certificados vencidos o cadena invalida (34_certs), o crypto-policies endurecidas por el parcheo (42_crypto); se descarta la red como causa.\n'
    fi
    [[ "${V[36_crl]:-}" == FALLA ]] && c+=$'- HIPOTESIS PRINCIPAL: CRL cacheada vencida (36_crl, correlacionar con Q1CRLExpiredException en 35_dlc_error). El DLC no puede crear el contexto TLS hacia QRoC aunque red, handshake externo y certificados de cliente se observen correctos. Acciones controladas sugeridas: habilitar salida HTTP/80 hacia los puntos de distribucion de CRL del emisor del EP y depurar el cache de conf/cached_crl con reinicio del servicio en ventana autorizada.\n'
    [[ "${V[37_json]:-}" == FALLA ]] && c+=$'- CONFIGURACION JSON INVALIDA (37_json): el config store no puede cargar los archivos afectados (MalformedJsonException en el arranque, ver 35_dlc_error); los log sources definidos en ellos no operan. Corregir la sintaxis en la linea indicada por la evidencia, con respaldo previo y reinicio del servicio en ventana.\n'
    [[ "${V[34_certs]:-}" == ALERTA && "${V[42_crypto]:-}" != OK ]] && c+=$'- CORRELACION SHA-1: existen certificados con firma SHA-1 y la politica criptografica de RHEL 9 no es LEGACY; la politica DEFAULT rechaza SHA-1 en TLS. Hipotesis principal de causa raiz tras un parcheo.\n'
    # 5) Deslinde entrada/salida
    if [[ "${V[31_entrante]:-}" == FALLA && "${V[22_firewall]:-}" == OK ]]; then
        c+=$'- NO LLEGAN EVENTOS AL SERVIDOR y el firewall local esta bien: el problema esta EN LOS LOG SOURCES o en la red del cliente, no en este SO.\n'
    fi
    if [[ "${V[31_entrante]:-}" == FALLA && "${V[22_firewall]:-}" == FALLA ]]; then
        c+=$'- NO LLEGAN EVENTOS y el firewall local perdio reglas: restaurar las reglas 514/forward 514->1514 (efecto probable del parcheo o de un reload).\n'
    fi
    if [[ "${V[33_jmx]:-}" == OK && "${V[32_saliente]:-}" == FALLA ]]; then
        c+=$'- EL DLC PROCESA PERO NO TRANSMITE: los contadores crecen sin paquetes salientes; el problema corresponde al DLC/TLS local (certificados, configuracion), no al SO base.\n'
    fi
    if [[ "${V[31_entrante]:-}" == OK && "${V[32_saliente]:-}" == OK && "${V[33_jmx]:-}" == OK ]]; then
        c+=$'- Entrada, procesamiento y salida se observan correctos desde este servidor. Si QRoC continua sin recibir eventos, el deslinde apunta al lado QRoC (allowlist, log source/listener 32500): abrir un caso con IBM Support adjuntando este informe.\n'
    fi
    [[ -z "$c" ]] && c=$'- No se identifico una causa unica evidente. Revisar el detalle de hallazgos y las evidencias; considerar abrir un caso con IBM Support adjuntando el paquete completo del diagnostico.\n'
    echo "$c"
    echo "Nota: este script no aplico cambio alguno. Toda correccion (reglas de firewall,"
    echo "crypto-policies, montaje de /store, renovacion de certificados) debe realizarse"
    echo "de forma controlada y documentada, validando previamente con el cliente."
}
CONCLUSION_TXT="$(concluir)"
echo "$CONCLUSION_TXT" | tee -a "$INFORME"

nota ""
nota "Fin del informe: $(date '+%Y-%m-%d %H:%M:%S %Z')"

#=============================================================================
# INFORME PRELIMINAR EN HTML
#=============================================================================
HTML="$OUTDIR/informe.html"
htmlesc() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

N_OK=0; N_FALLA=0; N_ALERTA=0; N_INFO=0
for v in "${R_VER[@]}"; do
    case "$v" in
        OK) ((N_OK++)) ;; FALLA) ((N_FALLA++)) ;;
        ALERTA) ((N_ALERTA++)) ;; *) ((N_INFO++)) ;;
    esac
done

{
cat <<HTMLHEAD
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<title>Diagnostico DLC/SO - $(hostname) - $TS</title>
<style>
 body { font-family: Arial, Helvetica, sans-serif; margin: 24px; color: #222; }
 h1 { font-size: 1.4em; border-bottom: 3px solid #0f62fe; padding-bottom: 8px; }
 h2 { font-size: 1.1em; margin-top: 28px; }
 .meta { color: #555; font-size: 0.9em; }
 .tarjetas { display: flex; gap: 12px; margin: 16px 0; }
 .tarjeta { padding: 10px 18px; border-radius: 6px; color: #fff; font-weight: bold; }
 .c-ok { background: #24a148; } .c-falla { background: #da1e28; }
 .c-alerta { background: #f1c21b; color: #222; } .c-info { background: #697077; }
 table { border-collapse: collapse; width: 100%; font-size: 0.9em; }
 th, td { border: 1px solid #ccc; padding: 6px 10px; text-align: left; vertical-align: top; }
 th { background: #f4f4f4; }
 .v-OK { background: #defbe6; } .v-FALLA { background: #ffd7d9; }
 .v-ALERTA { background: #fff8e1; } .v-INFO { background: #f2f4f8; }
 .veredicto { font-weight: bold; white-space: nowrap; }
 pre { background: #f4f4f4; border: 1px solid #ddd; padding: 12px; white-space: pre-wrap; font-size: 0.85em; }
 .pie { margin-top: 24px; color: #777; font-size: 0.8em; }
 a { color: #0f62fe; }
</style>
</head>
<body>
<h1>Informe preliminar de diagnostico &mdash; IBM DLC / Sistema Operativo</h1>
<p class="meta">
 Host: <b>$(hostname -f 2>/dev/null || hostname)</b> &nbsp;|&nbsp;
 Fecha: <b>$(date '+%Y-%m-%d %H:%M:%S %Z')</b> &nbsp;|&nbsp;
 SO: $(htmlesc "$(cat /etc/redhat-release 2>/dev/null || echo 'desconocido')") &nbsp;|&nbsp;
 Kernel: $(uname -r)<br>
 DLC current: $(htmlesc "$(readlink "$DLC_HOME/current" 2>/dev/null || echo '?')") &nbsp;|&nbsp;
 UUID DLC: <b>$(htmlesc "${DLC_UUID:-no identificado}")</b> &nbsp;|&nbsp;
 Destino QRoC: $(htmlesc "${DEST_IP:-?}:${DEST_PORT} (${DEST_TYPE:-?})")
</p>
<div class="tarjetas">
 <div class="tarjeta c-ok">OK: $N_OK</div>
 <div class="tarjeta c-falla">FALLA: $N_FALLA</div>
 <div class="tarjeta c-alerta">ALERTA: $N_ALERTA</div>
 <div class="tarjeta c-info">INFO: $N_INFO</div>
</div>
<h2>Resultados por prueba</h2>
<table>
<tr><th>Prueba</th><th>Veredicto</th><th>Descripcion</th><th>Detalle</th><th>Evidencia</th></tr>
HTMLHEAD
for i in "${!R_ID[@]}"; do
    id="${R_ID[$i]}"; ver="${R_VER[$i]}"
    cls="v-INFO"; case "$ver" in OK) cls="v-OK";; FALLA) cls="v-FALLA";; ALERTA) cls="v-ALERTA";; esac
    evlink="&mdash;"
    [[ -f "$EVID/$id.txt" ]] && evlink="<a href=\"evidencias/$id.txt\">$id.txt</a>"
    echo "<tr class=\"$cls\"><td>$(htmlesc "$id")</td><td class=\"veredicto\">$(htmlesc "$ver")</td><td>$(htmlesc "${R_DESC[$i]}")</td><td>$(htmlesc "${R_DET[$i]}")</td><td>$evlink</td></tr>"
done
cat <<HTMLFOOT
</table>
<h2>Conclusion (analisis cruzado)</h2>
<pre>$(htmlesc "$CONCLUSION_TXT")</pre>
<h2>Contenido del paquete</h2>
<ul>
 <li><b>informe.txt</b> &mdash; informe completo en texto plano.</li>
 <li><b>informe.html</b> &mdash; este informe preliminar.</li>
 <li><b>evidencias/</b> &mdash; un archivo .txt por prueba, con el comando ejecutado y su salida cruda.</li>
 <li><b>soporte_ibm/dlc.tar.gz</b> &mdash; paquete oficial para IBM Support (TechNote 7274013), listo para adjuntar a un caso.</li>
</ul>
<p class="pie">Generado por dlc_diagnostico_so.sh (solo lectura, sin cambios al sistema). Los enlaces de evidencia funcionan al abrir el HTML desde el paquete descomprimido.<br>
AVISO: este script no cuenta con soporte oficial de IBM. Herramienta de diagnostico de campo elaborada por lrodriguezd@outlook.com.</p>
</body>
</html>
HTMLFOOT
} > "$HTML"

#=============================================================================
# EMPAQUETADO FINAL (.tgz con todo el diagnostico)
#=============================================================================
PAQUETE="/tmp/dlc-diagnostico-$TS.tgz"
LIMPIEZA=""
if tar -czf "$PAQUETE" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")" 2>/dev/null && [[ -s "$PAQUETE" ]]; then
    RES_PAQ="$PAQUETE ($(du -h "$PAQUETE" 2>/dev/null | awk '{print $1}'))"
    # Peticion del cliente: conservar solo el tgz para ahorrar espacio.
    # Solo se borra si OUTDIR es el directorio de trabajo esperado en /tmp.
    case "$OUTDIR" in
        /tmp/dlc-diagnostico-*)
            rm -rf "$OUTDIR"
            LIMPIEZA="directorio de trabajo eliminado; solo queda el .tgz" ;;
        *)
            LIMPIEZA="OUTDIR personalizado ($OUTDIR): no se elimina automaticamente" ;;
    esac
else
    RES_PAQ="ERROR: no se pudo crear $PAQUETE"
    LIMPIEZA="se conserva $OUTDIR para no perder los resultados"
fi

echo ""
echo "============================================================"
echo " Diagnostico terminado."
echo " PAQUETE FINAL : $RES_PAQ"
echo " Limpieza      : $LIMPIEZA"
echo " Para revisar  : tar -xzf $PAQUETE"
echo "   Contiene: informe.txt, informe.html, evidencias/ (un .txt"
echo "   por prueba) y soporte_ibm/dlc.tar.gz (TechNote 7274013)."
echo "============================================================"
