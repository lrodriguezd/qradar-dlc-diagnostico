# Registro de cambios

Versiones de `dlc_diagnostico_so.sh`. La versión se consulta con `-V` y queda impresa en el `informe.txt` y en el `informe.html` de cada ejecución.

> **Por qué importa la versión**: los veredictos cambian de significado entre versiones. Al comparar un informe nuevo contra una línea base anterior, verifique primero que ambos provengan de la misma versión; si no, revise aquí qué se corrigió antes de concluir que el servidor cambió.

## 1.1 — 2026-09-01

### Correcciones que alteran veredictos

Todos los defectos se reprodujeron ejecutando el script antes de corregirlos.

- **`cap()` — el password del keystore podía quedar en claro.** El enmascarado usaba `${var//$pat/...}`, donde el patrón se interpreta como *glob*: un `tls.keystorepassword` con `?`, `[` o `\` no se sustituía y quedaba legible en `evidencias/34_certs.txt`, es decir dentro del `.tgz` que se adjunta al caso de IBM. Ahora la sustitución es literal (`awk` con `index()`) y se aplica también a la **salida** capturada, no solo al comando mostrado. Se omiten passwords de menos de 4 caracteres para no mutilar la evidencia con coincidencias fortuitas.
- **`42_crypto` — se perdían las subpolíticas criptográficas.** `DEFAULT:SHA1` y `DEFAULT:NO-SHA1` se reducían a `DEFAULT`. Consecuencia: en un servidor donde la mitigación SHA-1 ya estaba aplicada, el informe la recomendaba de nuevo y el análisis cruzado sostenía una hipótesis de causa raíz SHA-1 falsa. El veredicto ahora conserva la cadena completa y distingue los tres casos.
- **`37_json` — veredicto vacuo.** Reportaba OK ("todos los archivos JSON son válidos") cuando `conf/` no existía o estaba vacío. Sin archivos que revisar no hay nada que declarar válido: se aplica la regla del propio script y la prueba se marca no ejecutada.
- **`35_dlc_error` — antigüedad absurda.** Informaba "hace 20697 dia(s)" cuando `dlc.error` no existe, porque un `stat` fallido dejaba la marca de tiempo en 0 y se calculaba la edad de la época Unix.
- **`12_java` — podía describir el runtime equivocado.** El patrón `A && B || C` hacía que un `java` del DLC existente pero fallido cayera al `java` del `PATH` **concatenando ambas salidas**, de modo que el veredicto podía describir un runtime distinto del que corre el DLC.

### Pruebas nuevas

- **`14_limites`** (bloque 2) — descriptores de archivo del proceso DLC contra el límite `nofile`, con el desglose por tipo (sockets, pipes, archivos) y el límite declarado en la unidad systemd, que es el que aplica. Al agotarlos el DLC deja de aceptar conexiones y de abrir archivos **sin detenerse**: produce el cuadro de "no llegan eventos" con el servicio aparentemente sano. Umbrales configurables: 90 % FALLA, 75 % ALERTA.
- **`28_proxy`** (bloque 3) — distingue la ruta de salida de `curl` (la que miden las pruebas 26 y 36) de la de la JVM del DLC, que ignora `http_proxy`/`https_proxy` y solo usa proxy con `-Dhttp.proxyHost`/`-Dhttps.proxyHost`. Cuando ambas difieren, un resultado correcto en 26 y 36 **no** descarta un bloqueo perimetral sobre el tráfico del DLC, y el análisis cruzado lo advierte. Solo se reportan nombres de variable, nunca sus valores, para no exponer credenciales del proxy.
- **`38_buffer`** (bloque 4) — backlog del buffer de eventos en `/store/ec`, medido en dos muestras. El buffer ya se recolectaba para el paquete de soporte pero nunca se evaluaba, y es la señal más directa del deslinde entre recepción y entrega. La primera muestra se toma al entrar al bloque 4 para que la ventana de observación sea el tiempo real de las pruebas 31–37, sin costo adicional; si esas pruebas se omitieron por falta de comandos, se espera hasta completar una ventana mínima de 30 s.

### Otros cambios

- Sello de versión en el informe y el HTML; nueva opción `-V`.
- `du` y `find` pasan a comandos requeridos (los usan las pruebas 05 y 38); `numfmt` a opcional, con degradación a bytes crudos si falta.
- Dos hallazgos de `shellcheck` corregidos: redirección colocada en medio de `find` (SC2227) y recorrido de la salida de `find` en el paquete de soporte, que se rompía con nombres de archivo con espacios (SC2044).
- Se limpian los restos de la opción `-b`, retirada en 1.0 al volverse el respaldo parte de toda ejecución: el comentario del bloque 7 y la sangría huérfana del condicional que ya no existe.
- Variables del buffer renombradas a `EVBUF_*` para no confundirse con `BUF`, que en el bloque 6 es el directorio del paquete de soporte.

## 1.0 — 2026-08-07 … 2026-08-11

Versión inicial y su evolución previa al registro de cambios. No llevaba número de versión impreso: un informe sin la línea `Script : dlc_diagnostico_so.sh vX.Y` corresponde a esta serie.

- Diagnóstico de SO para IBM DLC: bloques 0 a 6, informe en texto y HTML, evidencia por prueba y paquete para IBM Support conforme a la TechNote 7274013.
- Licencia MIT.
- Corrección de los veredictos 27 y 32 con base en un caso real de bloqueo perimetral.
- Bloque 7: respaldo de configuración verificado, primero como opción `-b` y después como parte de toda ejecución, integrado al paquete final en `respaldo_config/`.
- Autodetección por contenido del certificado firmado y de la cadena completa dentro de `keystore/<UUID>/`.
