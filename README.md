# Diagnóstico de sistema operativo para IBM Disconnected Log Collector (DLC)

Script de diagnóstico en bash para instancias de **IBM Disconnected Log Collector (DLC)** sobre RHEL/CentOS que dejaron de enviar eventos a **IBM QRadar / QRadar on Cloud (QRoC)**. Ejecuta un conjunto ordenado de pruebas que deslindan si la causa está en el sistema operativo, la red, el propio DLC (servicio, certificados, TLS, CRLs, configuración) o en los log sources, y deja evidencia documentada de cada prueba.

> **AVISO**: este script **no cuenta con soporte oficial de IBM**. Es una herramienta de diagnóstico de campo elaborada por rodiaz@mx1.ibm.com. Úsela bajo responsabilidad del operador y valide los hallazgos antes de actuar.

## Características

- **Solo lectura**: no reinicia servicios ni modifica configuración, firewall o certificados. Única excepción: una escritura de prueba de 4 KB en `/store` (O_DIRECT/fsync) que se elimina al terminar — detecta el caso real de un disco virtual desconectado donde el permiso aparente se ve bien pero nada persiste.
- **Veredictos accionables**: cada prueba concluye OK / FALLA / ALERTA / INFO. Una prueba que no puede ejecutarse (comando faltante) se marca FALLA como "no ejecutada" — un diagnóstico incompleto también es un hallazgo.
- **Evidencia completa**: un archivo `.txt` por prueba con el comando ejecutado, la fecha y la salida cruda.
- **Informe en texto y HTML** con análisis cruzado final que indica a qué capa apunta la evidencia.
- **Paquete para IBM Support** conforme a la TechNote 7274013, listo para adjuntar a un caso.
- Todo se empaqueta en un único `.tgz` en `/tmp` y el directorio de trabajo se elimina.

## Requisitos

- Ejecutar como **root** en el host del DLC.
- RHEL/CentOS con `bash` 4+. Comandos requeridos (el bloque 0 los inventaría y reporta faltantes): `systemctl journalctl ss ip getent firewall-cmd tcpdump openssl curl findmnt rpm dnf tar gzip dd traceroute`, y opcionales `jq dig tcptraceroute mtr chronyc netstat`.

## Modos de ejecución

**1) Autónomo (sin opciones)** — el destino se toma del `config.json` del propio DLC y se ejecuta el diagnóstico completo. Las comparaciones contra valores esperados (pruebas 21 y 30b) se degradan a INFO y se emite un aviso al arranque. Útil cuando no se tienen a la mano los valores documentados del tenant.

```bash
sudo ./dlc_diagnostico_so.sh
```

**2) Con referencias** — agrega la comparación *esperado* (parámetros) vs *configurado* (`config.json`) vs *resuelto* (DNS del sistema), habilitando la detección de DNS alterado, destino mal configurado o puerto distinto del documentado.

```bash
sudo ./dlc_diagnostico_so.sh \
  -e logs-epXX-NNNNN.qradar.ibmcloud.com \
  -f logs-epYY-NNNNN.qradar.ibmcloud.com \
  -i <ip_esperada_ep1> -j <ip_esperada_ep2> -P 32500
```

| Opción | Descripción |
|---|---|
| `-e <fqdn>` | FQDN documentado del EP1 |
| `-f <fqdn>` | FQDN documentado del EP2 |
| `-i <ip>` | IP esperada del EP1 (comparación contra DNS y config.json) |
| `-j <ip>` | IP esperada del EP2 |
| `-d <destino>` | IP o FQDN destino manual (prioridad sobre config.json) |
| `-p <puerto>` | Puerto destino manual (prioridad sobre config.json) |
| `-P <puerto>` | Puerto esperado para la comparación (por defecto 32500; en QRoC no debe cambiarse) |
| `-h` | Ayuda |

## Pruebas incluidas

| Bloque | Pruebas |
|---|---|
| 0 — Prerequisitos | Comandos disponibles, instalación DLC presente |
| 1 — Sistema operativo | Uptime/reinicios, memoria, OOM killer, carga, disco e inodos, montaje y **escritura efectiva en /store**, errores XFS/E-S, hora/NTP |
| 2 — Servicio DLC | Estado systemd, historial de caídas, Java (IBM SDK), puertos en escucha |
| 3 — Red y firewall | Interfaces/rutas, DNS vs IPs esperadas, firewalld (514 y forward 514→1514), SELinux (denegaciones AVC), conexión TCP al EP, **handshake TLS (`openssl s_client -showcerts -verify 32`)**, IP pública IPv4 por dos canales, traza TCP al puerto (tcptraceroute/traceroute -T/mtr) |
| 4 — Frontera DLC | config.json, **coherencia esperado-configurado-resuelto**, tráfico entrante/saliente (tcpdump), contadores JMX en dos muestras, **certificados: vigencia, cadena (raíz/intermedio deducidos por hash de emisor), correspondencia con el PFX en uso, CAs aceptadas por el EP y cumplimiento del procedimiento de instalación (pasos 1–5)**, log de errores con antigüedad, **CRLs cacheadas y capacidad de refresco HTTP/80**, validación JSON de la configuración (con clasificación de archivos de fábrica en formato tolerante) |
| 5 — Post-parcheo | Historial dnf con versiones antes/después, kernel corriendo vs instalado, crypto-policies de RHEL 9, paquetes sensibles modificados (60 días) |
| 6 — Soporte | Paquete oficial para IBM Support (TechNote 7274013) |

## Resultado

```
/tmp/dlc-diagnostico-<fecha>.tgz
  ├── informe.txt        # informe completo con resumen, hallazgos y conclusión
  ├── informe.html       # informe preliminar navegable (tabla por veredicto)
  ├── evidencias/        # un .txt por prueba (comando + salida cruda)
  └── soporte_ibm/dlc.tar.gz   # paquete para caso de soporte IBM
```

> **Precaución**: el `.tgz` generado contiene datos del ambiente (hostnames, IPs internas, logs y configuración). El script es publicable; los informes que genera deben tratarse como información del cliente y no publicarse.

## Casos reales que motivaron pruebas específicas

- **Disco de `/store` desconectado de la VM**: el permiso de escritura se veía bien pero nada persistía → prueba de escritura efectiva con O_DIRECT/fsync (06b).
- **CRL cacheada vencida** (`Q1CRLExpiredException`): tras la rotación de intermedios del emisor del EP, una CRL en `conf/cached_crl/` quedó vencida e irrecuperable y abortaba la creación del contexto TLS aunque red, handshake y certificados de cliente estuvieran correctos → prueba 36.
- **`logSources.json` malformado por edición manual** (coma sobrante): `MalformedJsonException` en el arranque e impedía cargar los log sources → prueba 37 con `jq`.

## Licencia y contribuciones

Uso bajo su propia responsabilidad. Se aceptan mejoras vía pull request; toda contribución debe mantener el carácter de solo lectura del diagnóstico y no incluir datos de clientes.
