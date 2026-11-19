# TrueNAS homelab toolkit — Documentazione

🇬🇧 [English](documentation.md) · 🇮🇹 **Italiano**

Questa è la guida completa: installazione, tutte le impostazioni di ogni script, come funzionano dentro, ripristino di un backup, problemi comuni, sicurezza e sviluppo. La versione breve è nel [README](../README.it.md).

- [Panoramica](#panoramica)
- [Installazione](#installazione)
- [lan-guard](#lan-guard)
- [heartbeat](#heartbeat)
- [storage-status](#storage-status)
- [system-backup](#system-backup)
- [Sicurezza](#sicurezza)
- [Sviluppo](#sviluppo)

# Panoramica

Quattro script indipendenti per un server TrueNAS SCALE / Community Edition di casa. Ognuno risolve un problema, ha il suo file di impostazioni e si può usare senza gli altri.

| Script | Problema che risolve | Quando gira |
|---|---|---|
| `lan-guard` | Docker apre le porte delle app a tutta la rete di casa, e le solite regole del firewall non lo fermano | all'avvio e ogni 5 minuti |
| `heartbeat` | Il monitoraggio sul NAS tace quando il NAS si spegne | ogni minuto |
| `storage-status` | Salute dei pool, scrub, errori dei dischi, spazio del cloud e snapshot sono sparsi nell'interfaccia, e le dashboard non dovrebbero avere credenziali da amministratore | ogni 30 minuti |
| `system-backup` | TrueNAS tiene le copie della sua configurazione sul NAS stesso, e lo snapshot di un database acceso non è un backup affidabile | ogni notte, verificato ogni settimana |

## Requisiti

- **TrueNAS 25.10** (la versione su cui sono provati). Su un'altra versione ogni script funziona lo stesso, e quando lo lanci a mano stampa un avviso.
- **Root**: gli script girano come root dai cron job e dagli script di avvio di TrueNAS.
- **Un pool di dati** per la cartella del toolkit: il pool di avvio viene sostituito a ogni aggiornamento di TrueNAS.
- Niente da installare: usano quello che TrueNAS ha già (bash 5, python 3.11, `midclt`, `iptables`, `docker`, `rclone`, `curl`, `flock`). Fuori da TrueNAS, `system-backup` funziona anche su qualsiasi Linux con Docker, senza le sue parti di TrueNAS.

## Cartelle

```
install.sh                    crea i cron job e lo script di avvio
toolkit.conf.example          impostazioni comuni a più script
lan-guard/                    lan-guard.sh, lan-guard.conf.example
heartbeat/                    heartbeat.sh, heartbeat.conf.example
storage-status/               storage-status.py, storage-status.conf.example
system-backup/                system-backup.sh, system-backup-verify.sh, common.sh, system-backup.conf.example
examples/system-backup.sh     lo script di backup originale, tenuto come riferimento
docs/                         questa guida, lo schema JSON di storage-status
tests/                        i test lanciati dalla CI
```

Ogni script legge le impostazioni da un file `.conf` accanto a sé, creato dal `.conf.example`. Sono semplici variabili della shell (`storage-status.conf` usa le stesse righe `CHIAVE="valore"`).

# Installazione

## Scaricare il toolkit

```bash
git clone https://github.com/EmaLau/truenas-homelab-toolkit.git /mnt/tank/toolkit
cd /mnt/tank/toolkit
```

Al posto di `/mnt/tank` metti uno dei tuoi pool. Per aggiornare: `git pull`, poi di nuovo `./install.sh`.

## Creare i file di impostazioni

Copia l'esempio di ogni script che vuoi usare e modificalo:

```bash
cp lan-guard/lan-guard.conf.example lan-guard/lan-guard.conf
cp heartbeat/heartbeat.conf.example heartbeat/heartbeat.conf && chmod 600 heartbeat/heartbeat.conf
cp storage-status/storage-status.conf.example storage-status/storage-status.conf     # facoltativo
cp system-backup/system-backup.conf.example system-backup/system-backup.conf && chmod 600 system-backup/system-backup.conf
```

I file che contengono indirizzi che valgono come password (heartbeat, system-backup, `toolkit.conf`) devono essere leggibili solo da root: gli script avvisano se non lo sono. Ogni sezione qui sotto elenca le impostazioni del suo script.

## install.sh

`install.sh` crea i job tramite il middleware di TrueNAS, come *System → Advanced → Cron Jobs* e *Init/Shutdown Scripts* nell'interfaccia web.

```bash
./install.sh --dry-run                    # mostra cosa creerebbe, senza cambiare niente
./install.sh                              # tutti gli script che hanno il loro file di impostazioni
./install.sh heartbeat storage-status     # solo questi
./install.sh --disabled                   # crea i job spenti, per controllarli prima nell'interfaccia
./install.sh --uninstall                  # toglie i job creati da install.sh
```

| Script | Job creato | Comando |
|---|---|---|
| lan-guard | script di avvio, post-init | `lan-guard.sh apply` |
| lan-guard | cron, ogni 5 minuti | `lan-guard.sh apply` |
| heartbeat | cron, ogni minuto | `heartbeat.sh` |
| storage-status | cron, ogni 30 minuti | `storage-status.py` |
| system-backup | cron, ogni giorno alle 03:00 | `system-backup.sh` |
| system-backup-verify | cron, la domenica alle 05:00 | `system-backup-verify.sh --restore` |

Gli orari si possono cambiare in `toolkit.conf` (`SCHEDULE_HEARTBEAT="*/2 * * * *"` e così via, vedi sotto). Scegli orari che non si sovrappongano ai job che aggiornano o riavviano le app.

Come si comporta:

- **Riconosce i suoi job dalla descrizione** (`truenas-homelab-toolkit: <script>`). Se lo rilanci e tutto è a posto non cambia niente; se qualcosa è diverso, per esempio il percorso dopo aver spostato la cartella, aggiorna i job. Non crea mai una seconda copia.
- **I job fatti a mano vengono segnalati, non toccati.** Se un altro job lancia già `lan-guard.sh` o `heartbeat.sh`, `install.sh` stampa un avviso: togli quel job, altrimenti lo script gira due volte.
- **Prima controlla le impostazioni**: uno script indicato senza il suo file di impostazioni, o un `lan-guard.conf` non valido, lo fermano prima di qualsiasi modifica.
- Avvisa se la versione di TrueNAS non è stata provata e se la cartella non sta sotto `/mnt`.
- I cron job girano come root, con l'uscita normale nascosta e gli errori visibili, così TrueNAS segnala i problemi.

Puoi anche creare i job a mano nell'interfaccia web, con i comandi della tabella (preceduti da `/bin/bash` o `/usr/bin/python3` e dal percorso completo).

## Impostazioni comuni: toolkit.conf

`toolkit.conf`, accanto a `install.sh` (un altro percorso: `TOOLKIT_CONF=/percorso`), contiene le impostazioni condivise da più script:

| Impostazione | Usata da |
|---|---|
| `NOTIFY_URL`, `NOTIFY_FORMAT`, `NOTIFY_TOKEN`, `NOTIFY_CHAT_ID` | heartbeat, system-backup |
| `KUMA_URL` | heartbeat |
| `SCHEDULE_LAN_GUARD`, `SCHEDULE_HEARTBEAT`, `SCHEDULE_STORAGE_STATUS`, `SCHEDULE_SYSTEM_BACKUP`, `SCHEDULE_SYSTEM_BACKUP_VERIFY` | install.sh: l'orario di ogni job (5 campi del cron) |

Un valore lasciato **vuoto** nel file dello script prende quello di `toolkit.conf`; un valore scritto lì vince. Le impostazioni delle notifiche vanno insieme: se uno script ha il suo `NOTIFY_URL`, usa anche il suo formato, il suo token e la sua chat.

# lan-guard

## Perché

Un'app di TrueNAS viene pubblicata su una porta del NAS, e Docker rende quella porta raggiungibile da tutti i dispositivi della rete di casa. I pannelli di amministrazione (Uptime Kuma, Scrutiny, Dozzle…) spesso non hanno login, o ne hanno uno debole: il telefono di un ospite, una smart TV o un dispositivo compromesso possono aprirli. Se usi questi strumenti solo dalla VPN, la rete di casa non ha bisogno di vederli.

## Come funziona

La soluzione ovvia, una regola nella catena `INPUT`, non funziona: Docker riscrive la destinazione del pacchetto (DNAT) **prima** che il filtro lo veda. Un pacchetto per `NAS:30002` diventa un pacchetto per `container:3001`, e da lì passa da `FORWARD`, non da `INPUT`, e la porta originale non c'è più.

lan-guard usa due cose:

- **La catena `DOCKER-USER`**, che Docker lascia apposta agli utenti: viene controllata prima delle regole di Docker e Docker non la svuota mai.
- **Conntrack**, che ricorda la destinazione originale di ogni connessione: `--ctorigdstport 30002` riconosce la connessione anche dopo la modifica.

Per ogni porta crea, in una catena `LAN-GUARD` chiamata da `DOCKER-USER`:

```
-A LAN-GUARD -i eth0 -m conntrack --ctstate NEW --ctproto tcp --ctorigdstport 30002 -j DROP
```

e la stessa regola in una catena `LAN-GUARD-IN` chiamata da `INPUT`, per le connessioni che arrivano direttamente al NAS (per esempio a `docker-proxy` su IPv6). Vengono scartate solo le connessioni **nuove** che arrivano **dall'interfaccia della rete di casa**: le risposte, il traffico della VPN (un'altra interfaccia), localhost, SSH e l'interfaccia web non vengono toccati, quindi non puoi chiuderti fuori.

Le regole vengono ricostruite in una catena temporanea e poi scambiate, così non c'è mai un momento senza. TrueNAS e Docker riscrivono il firewall quando ripartono le app o il sistema: per questo lo script gira all'avvio e ogni 5 minuti.

## Impostazioni (lan-guard.conf)

| Impostazione | Predefinito | Significato |
|---|---|---|
| `LAN_IF` | `eth0` | L'interfaccia collegata alla rete di casa (`ip -br link`) |
| `PORTS` | nessuno, obbligatoria | Porte TCP da bloccare dalla rete di casa, es. `(30001 30002)` |
| `ALLOW` | vuoto | Indirizzi della rete di casa ammessi comunque su una porta: `("30002=192.168.1.20" "30001=192.168.1.0/28" "30002=fd00::20")` |
| `LOG_DROPS` | `no` | `yes`: scrive le connessioni bloccate nel log del kernel |
| `LOG_LIMIT` | `5/min` | Al massimo tante righe di log per porta e catena |

- Le porte devono essere numeri da 1 a 65535.
- `ALLOW` accetta indirizzi IPv4 o IPv6, con un prefisso facoltativo; la porta deve essere in `PORTS`. I nomi host vengono rifiutati, perché il firewall li tradurrebbe una volta sola. Le connessioni ammesse escono dalle catene di lan-guard con `RETURN` e proseguono con le normali regole di Docker e di INPUT.
- Le righe di log iniziano con `lan-guard-drop:`: si leggono con `dmesg | grep lan-guard-drop` o `journalctl -k -g lan-guard-drop`.

Ogni valore viene controllato prima di toccare il firewall: uno sbagliato ferma lo script con un messaggio.

## Comandi

| Comando | Cosa fa |
|---|---|
| `lan-guard.sh dry-run` | Stampa, nella sintassi di `iptables-save`, esattamente le regole che `apply` creerebbe, per IPv4 e IPv6. Non servono né root né iptables |
| `lan-guard.sh` o `lan-guard.sh apply` | Crea o ricostruisce le regole (si può ripetere senza effetti doppi) |
| `lan-guard.sh status` | Mostra le regole con i loro contatori |
| `lan-guard.sh off` | Toglie tutte le regole e le catene (per tornare indietro) |

## Controllare che funzioni

1. `lan-guard.sh dry-run`: le porte e l'interfaccia sono quelle che ti aspetti.
2. `lan-guard.sh`, poi apri una porta bloccata **da un dispositivo sul Wi-Fi di casa, con la VPN spenta**: non deve aprirsi.
3. `lan-guard.sh status`: i contatori di quella porta sono sopra lo 0.
4. Con la VPN accesa lo stesso indirizzo si apre: il traffico della VPN non viene filtrato, apposta.

## Avvisi e limiti

- **Solo TCP**: le porte UDP restano raggiungibili dalla rete di casa.
- **IPv6**: filtrato quando `ip6tables` funziona; altrimenti viene saltato con un avviso.
- **L'interfaccia è riconosciuta per nome.** Se `LAN_IF` non esiste (un errore di battitura, una scheda di rete nuova, un bridge creato dopo) le regole non bloccano niente e le porte tornano aperte. `apply` e `status` avvisano se l'interfaccia manca; contatori sempre a 0 sono un altro indizio.
- **Docker deve usare iptables.** Le regole per i container stanno in `DOCKER-USER`, che Docker usa con il suo firewall predefinito basato su iptables (su TrueNAS `iptables` scrive regole nftables, e va bene così). Con Docker spento o passato al suo firewall nftables, niente arriva più a `DOCKER-USER`: `apply` e `status` avvisano se `FORWARD` non ci passa.

## Problemi comuni

- **La porta si apre ancora.** Sei sulla VPN? `LAN_IF` è l'interfaccia da cui arriva il traffico della rete di casa (`ip -br addr`)? `status` stampa un avviso sull'interfaccia o su `DOCKER-USER`?
- **"ip6tables not available, IPv6 is not filtered".** IPv6 è spento nel kernel o manca `ip6tables`: IPv4 viene filtrato lo stesso.
- **Voglio annullare tutto.** `lan-guard.sh off`, e togli i job (`./install.sh --uninstall lan-guard`).

# heartbeat

## Perché

Uno strumento di monitoraggio che gira sul NAS non può dirti che il NAS è spento: quando si blocca, perde la corrente o resta senza internet, tace insieme a lui, e il silenzio sembra "tutto a posto". heartbeat rovescia il controllo: ogni minuto il NAS dimostra di essere vivo, e un servizio **esterno** dà l'allarme quando la prova smette di arrivare.

## Le parti

Ogni parte è facoltativa e viene saltata se le sue impostazioni sono vuote; senza nessuna parte configurata lo script si ferma con un errore.

1. **NAS vivo → servizio di heartbeat.** Una richiesta a `HEALTHCHECKS_URL` ogni minuto: [Healthchecks.io](https://healthchecks.io) (piano gratuito, o installato su un'altra macchina), o qualsiasi servizio che accetti una visita a un indirizzo come segnale (per esempio un URL push di Uptime Kuma su un'altra macchina). Imposta il periodo del controllo a 1 minuto e una tolleranza di qualche minuto.
2. **Stato di Tailscale → Uptime Kuma.** Invia `up` se il container di Tailscale risulta `Running`, `down` altrimenti, a un monitor *push* di Kuma.
3. **I tuoi controlli → Uptime Kuma.** Qualsiasi comando: codice di uscita 0 vuol dire su, qualsiasi altro (o il tempo scaduto) vuol dire giù.
4. **Notifiche → ntfy o un webhook**, quando la parte 2 o 3 cambia stato.

## Impostazioni (heartbeat.conf)

| Impostazione | Predefinito | Significato |
|---|---|---|
| `HEALTHCHECKS_URL` | vuoto | Indirizzo di ping del servizio di heartbeat |
| `KUMA_URL` | vuoto | Indirizzo base di Uptime Kuma, es. `http://127.0.0.1:3001` |
| `KUMA_TOKEN` | vuoto | Token del monitor push per lo stato di Tailscale (l'ultima parte di `/api/push/<token>`) |
| `TAILSCALE_CONTAINER` | `ix-tailscale-tailscale-1` | Nome del container di Tailscale (`docker ps`) |
| `CHECKS` | vuoto | Controlli, uno per voce: `"NOME|TOKEN_KUMA|COMANDO"` |
| `CHECK_TIMEOUT` | `20` | Secondi a disposizione di ogni controllo |
| `NOTIFY_URL` | vuoto | Indirizzo del topic ntfy o del webhook |
| `NOTIFY_FORMAT` | `ntfy` | `ntfy`, `json` o `telegram` |
| `NOTIFY_TOKEN` | vuoto | Inviato come `Authorization: Bearer <token>` (ntfy, json) |
| `NOTIFY_CHAT_ID` | vuoto | Solo Telegram: la chat che riceve i messaggi |

`KUMA_URL` e le impostazioni delle notifiche possono venire da `toolkit.conf`.

## Configurare Uptime Kuma

In Kuma aggiungi un monitor di tipo **Push** per ogni cosa da controllare (Tailscale, ogni controllo). Kuma mostra un indirizzo come `http://kuma:3001/api/push/AbC123?status=up&msg=OK&ping=`: l'indirizzo base va in `KUMA_URL` (una volta sola), il token (`AbC123`) in `KUMA_TOKEN` o nel controllo. Imposta l'intervallo a 60 secondi, come il cron job.

## Controlli

```bash
CHECKS=(
  "pools|<token-kuma>|zpool status -x | grep -q 'all pools are healthy'"
  "nextcloud||curl -fsS -m 5 -o /dev/null http://127.0.0.1:30027/status.php"
)
```

- `NOME`: lettere, cifre, punto, trattino, trattino basso. Identifica il controllo nelle notifiche e nella cartella dello stato.
- `TOKEN_KUMA`: il monitor push del controllo; lascialo vuoto per usare il controllo solo per le notifiche.
- `COMANDO`: gira con bash, come root, con `CHECK_TIMEOUT` secondi a disposizione. La prima riga che stampa diventa il messaggio (`exit 3: <prima riga>` quando fallisce, `timed out after 20s` se il tempo scade); Kuma riceve anche quanto ci ha messo.

## Notifiche

Solo sui cambiamenti: quando un controllo va giù e quando torna su, mai ogni minuto. L'ultimo stato di ogni controllo sta in `state/` accanto allo script; al primissimo giro avvisano solo i controlli giù.

- `NOTIFY_FORMAT=ntfy` invia il messaggio come testo all'indirizzo del topic (`https://ntfy.sh/<topic>` o il tuo server ntfy), con un titolo (`<host>: <controllo> is DOWN` o `is back up`), un'etichetta e una priorità (alta quando è giù).
- `NOTIFY_FORMAT=json` invia a qualsiasi webhook:

```json
{"host": "nas", "check": "nextcloud", "status": "down", "msg": "exit 7: ...", "time": 1795102290}
```

- `NOTIFY_FORMAT=telegram` manda titolo e messaggio tramite un bot di Telegram: `NOTIFY_URL="https://api.telegram.org/bot<token>/sendMessage"` (il token del bot, da @BotFather) e la chat in `NOTIFY_CHAT_ID`. L'indirizzo contiene il token: tieni il file con `chmod 600`.

Le notifiche riguardano solo i controlli: un NAS spento non può avvisare di niente, ed è per questo che c'è la parte 1.

## Comportamento

- **Un giro alla volta**: se il giro precedente è ancora in corso (controlli lenti), il successivo viene saltato con un messaggio.
- Un file **`PAUSE`** nella cartella sospende tutto, per esempio durante la manutenzione.
- Le richieste che falliscono (rete giù, Kuma che riparte) stampano un avviso e non fermano le altre parti.

## Problemi comuni

- **Kuma segna il monitor giù anche se il NAS funziona.** L'intervallo del push in Kuma è più corto di quello del cron, oppure `KUMA_URL` non è raggiungibile dal NAS (provalo a mano con `curl`).
- **Nessuna notifica.** Le notifiche partono solo sui cambiamenti; controlla `state/<nome>` e prova l'indirizzo con `curl -d test <NOTIFY_URL>`.
- **"is readable by other users".** `chmod 600 heartbeat.conf`.

# storage-status

## Perché

I numeri che dicono se un NAS sta andando verso un problema sono in pagine diverse dell'interfaccia di TrueNAS, e lo spazio del cloud non c'è proprio. Le dashboard come Homepage sanno mostrare un file JSON, ma non dovrebbero avere una chiave da amministratore di TrueNAS o le tue credenziali del cloud. storage-status raccoglie tutto come root, ogni mezz'ora, in un file che qualsiasi dashboard o bot può leggere senza credenziali.

## Cosa raccoglie

Tramite il middleware di TrueNAS (`midclt`), `zfs` e `rclone`:

- stato, dimensione, spazio libero e salute di ogni pool, con il livello dello spazio (`OK`, `LOW`, `CRITICAL`);
- l'ultimo scrub o resilver di ogni pool: stato, errori, avanzamento mentre gira, età;
- ogni disco di ogni pool, con il ruolo (data, cache, log, spare, special, dedup), lo stato e gli errori di lettura, scrittura e checksum;
- spazio usato e libero delle credenziali cloud che lo indicano: **OneDrive e Google Drive** (gli altri provider vengono saltati);
- l'ultima esecuzione di ogni task di cloud sync: stato, inizio, fine, errore;
- lo spazio occupato dagli snapshot in ogni pool;
- per ogni dataset con un task di snapshot periodici: numero di snapshot, il più recente e la sua età, spazio occupato. Gli snapshot vengono riconosciuti dal *naming schema* del task, quindi quelli manuali non contano; più task sullo stesso dataset vengono uniti.

## Impostazioni (storage-status.conf)

Tutte facoltative. Il file può stare altrove con `STORAGE_STATUS_CONF=/percorso`; le variabili d'ambiente con gli stessi nomi hanno la precedenza.

| Impostazione | Predefinito | Significato |
|---|---|---|
| `STORAGE_STATUS_OUT` | `/var/tmp/storage_status.json` | Dove scrivere il file JSON |
| `PROMETHEUS_OUT` | vuoto (spento) | Scrive anche le metriche Prometheus in questo file |
| `WARN_PCT` | `20` | Spazio libero (percentuale) sotto cui pool e cloud sono `LOW` |
| `CRIT_PCT` | `10` | Spazio libero sotto cui sono `CRITICAL` |

Le soglie devono rispettare `0 ≤ CRIT_PCT < WARN_PCT ≤ 100`.

## Il file JSON

Scritto in un colpo solo (una dashboard non legge mai un file a metà), leggibile da tutti. I valori sono numeri grezzi: byte, timestamp Unix, ore; la formattazione la fa la dashboard. Il formato completo è in [storage-status.schema.json](storage-status.schema.json), e un esempio completo, con un pool degradato durante un resilver e un pool offline, in [storage-status.example.json](../tests/storage-status.example.json).

| Chiave | Contenuto |
|---|---|
| `schema_version` | 1. Sale solo con cambiamenti incompatibili; i campi nuovi possono comparire senza cambiarla |
| `generated_at`, `generated_epoch` | Quando sono stati raccolti i dati (ISO 8601 con il fuso orario, e tempo Unix) |
| `thresholds` | `warn_pct` e `crit_pct` in uso |
| `errors` | Le sezioni fallite, con il messaggio; vuoto se è andato tutto bene |
| `pools` | Per nome del pool: `status`, `size`, `free`, `used`, `free_pct`, `space_status`, `healthy`, `scan`, `disks` |
| `cloud` | Per nome della credenziale: `provider`, `status` (`OK`, `LOW`, `CRITICAL`, `ERROR`), `total`, `used`, `free`, `free_pct` |
| `cloud_sync` | Per descrizione del task: `credential`, `direction`, `enabled`, `state`, `started`, `finished`, `age_hours`, `error` |
| `snapshot_space` | Per pool: byte occupati dagli snapshot |
| `snapshots` | Per dataset: `tasks`, `recursive`, `count`, `bytes`, `last`, `last_epoch`, `age_hours` |

Da sapere: ZFS tiene solo l'ultimo scan, quindi `scan` è l'ultimo scrub **o** resilver. TrueNAS tiene solo l'ultimo job di un task di cloud sync, quindi mentre un sync gira `state` è `RUNNING` e l'esito del precedente non si vede.

## Errori

Ogni sezione (`pools`, `cloud`, `cloud_sync`, `snapshots`) viene raccolta per conto suo. Se una fallisce (una chiamata al middleware va in timeout, `zfs` dà errore), il file viene scritto lo stesso con le altre sezioni complete, quella fallita compare in `errors`, e lo script esce con codice 1, così il cron job lo segnala.

## Metriche Prometheus

Con `PROMETHEUS_OUT` impostato, gli stessi dati vengono scritti anche come gauge per il collector *textfile* di node_exporter: fai puntare `PROMETHEUS_OUT` a un file nella cartella indicata a `--collector.textfile.directory`.

| Metrica | Etichette |
|---|---|
| `storage_status_generated_timestamp_seconds` | |
| `storage_status_section_ok` (1 se la sezione è stata raccolta) | `section` |
| `storage_status_pool_size_bytes`, `_pool_free_bytes` | `pool` |
| `storage_status_pool_healthy`, `_pool_online` (1 o 0) | `pool` |
| `storage_status_pool_scan_errors`, `_pool_scan_end_timestamp_seconds`, `_pool_scan_running` | `pool` |
| `storage_status_disk_online` | `pool`, `disk` |
| `storage_status_disk_errors` | `pool`, `disk`, `type` (read, write, checksum) |
| `storage_status_cloud_up`, `_cloud_total_bytes`, `_cloud_used_bytes`, `_cloud_free_bytes` | `credential`, `provider` |
| `storage_status_cloudsync_success`, `_cloudsync_running`, `_cloudsync_finished_timestamp_seconds` | `task`, `id` |
| `storage_status_snapshot_space_bytes` | `pool` |
| `storage_status_snapshots`, `_snapshots_bytes`, `_snapshot_last_timestamp_seconds` | `dataset` |

Esempi di allarmi: `storage_status_pool_healthy == 0`, `time() - storage_status_snapshot_last_timestamp_seconds > 2 * 86400`, `storage_status_cloudsync_success == 0`.

## I token del cloud

Per leggere lo spazio del cloud, le credenziali di TrueNAS vengono passate a `rclone about` in un file di configurazione temporaneo (permessi 600, cancellato subito dopo). rclone rinnova i token OAuth quando scadono, e OneDrive fa ruotare i suoi refresh token: un token rinnovato e buttato via, prima o poi, romperebbe i task di cloud sync. Per questo, come fa TrueNAS dopo un cloud sync, lo script salva il token rinnovato nella credenziale (`cloudsync.credentials.update`), e solo se sembra valido.

## Problemi comuni

- **Una sezione è in `errors`.** Lancia lo script a mano: il messaggio viene stampato anche sullo schermo.
- **Manca una credenziale cloud.** Solo OneDrive e Google Drive indicano il loro spazio.
- **La dashboard mostra dati vecchi.** Controlla `generated_at` e che il cron job giri; il file viene sostituito solo alla fine di un giro.

# system-backup

## Perché

Le copie che TrueNAS tiene della sua configurazione restano sul NAS, quindi si perdono insieme a lui, e lo snapshot ZFS della cartella di un database acceso non è garantito che si ripristini. Un backup notturno utile deve copiare i database nel modo giusto, salvare la configurazione con il suo secret seed e dimostrare che ogni pezzo si può rileggere.

## Cosa contiene un backup

Ogni esecuzione crea `BACKUP_DIR/AAAA-MM-GG_HH-MM-SS`, con solo le parti che configuri:

```
truenas/      truenas-config-<versione>-<data>.tar   config.save con il secret seed
app-configs/  app-query.json, <app>.json              impostazioni delle app di TrueNAS
databases/    pg-<container>-<db>.dump                pg_dump -Fc
              pg-<container>-globals.sql              ruoli
              mysql-<container>-<db>.sql.gz           mariadb-dump / mysqldump
archives/     <nome>.tar.gz                           uno per voce di ARCHIVES
metadata/     manifest.json, SHA256SUMS
```

Ogni parte viene controllata appena fatta:

- la configurazione deve contenere il database (`freenas-v1.db`) e il secret seed (`pwenc_secret`): senza il seed, una configurazione ripristinata perde tutte le password salvate;
- un dump PostgreSQL deve essere un archivio di `pg_dump` e superare `pg_restore --list`;
- un dump MariaDB/MySQL deve finire con la riga di fine dump;
- un archivio deve contenere tutti i file obbligatori.

Il lavoro avviene in una cartella `.incomplete-*` rinominata solo alla fine, così un backup fatto a metà non sembra mai completo. I file sono leggibili solo da root.

## Impostazioni (system-backup.conf)

| Impostazione | Predefinito | Significato |
|---|---|---|
| `BACKUP_DIR` | nessuno, obbligatoria | Cartella che contiene i backup (esistente, percorso assoluto) |
| `MIN_FREE_GB` | `5` | Non parte se c'è meno spazio libero |
| `KEEP_DAILY` | `30` | Tiene tutti i backup degli ultimi N giorni |
| `KEEP_MONTHLY` | `12` | Poi il primo backup di ciascuno degli ultimi N mesi |
| `TRUENAS_CONFIG` | `yes` | Salva la configurazione di TrueNAS |
| `APP_CONFIGS` | vuoto | Nomi delle app di cui salvare `app.config`, o `("*")` per tutte |
| `PG_DUMPS` | vuoto | Database PostgreSQL: `("CONTAINER UTENTE DATABASE" ...)` |
| `MYSQL_DUMPS` | vuoto | Database MariaDB/MySQL, stesso formato |
| `ARCHIVES` | vuoto | Archivi di cartelle (vedi sotto) |
| `APP_START_TIMEOUT` | `300` | Secondi di attesa perché un'app fermata torni accesa |
| `APP_IDLE_CHECKS` | vuoto | Attesa prima di fermare un'app occupata: `("APP|COMANDO|ATTESA_MASSIMA_SECONDI" ...)` (vedi sotto) |
| `HEALTHCHECKS_URL` | vuoto | Riceve un ping all'avvio, alla riuscita e all'errore |
| `NOTIFY_URL`, `NOTIFY_FORMAT`, `NOTIFY_TOKEN`, `NOTIFY_CHAT_ID` | vuoto, `ntfy`, vuoto, vuoto | Notifiche, come in heartbeat (ntfy, json o telegram) |
| `NOTIFY_ON` | `failure` | `failure` o `always` (gli avvisi vengono notificati sempre) |
| `PG_IMAGE`, `MYSQL_IMAGE` | `postgres:18-alpine`, `mariadb:11` | Immagini usate da `--restore` |

I nomi dei container si trovano con `docker ps` (le app di TrueNAS sono `ix-<app>-<servizio>-1`).

## Database

- **PostgreSQL**: `pg_dump -Fc` gira dentro il container, in una sola transazione, quindi il dump è coerente anche mentre l'app lavora. Vengono salvati anche i ruoli (`pg_dumpall --globals-only`).
- **MariaDB/MySQL**: `mariadb-dump` (o `mysqldump`) con `--single-transaction --routines --triggers --events`. La password viene letta **dentro il container** dalle sue variabili d'ambiente (`MARIADB_ROOT_PASSWORD`/`MYSQL_ROOT_PASSWORD` per root, `MARIADB_PASSWORD`/`MYSQL_PASSWORD` per gli altri), quindi non compare mai sulla riga di comando del NAS né nel log.

Lo stesso database non può comparire due volte.

## Archivi

Una voce per archivio: `"NOME|APP_DA_FERMARE|PERCORSI|ESCLUSIONI|OBBLIGATORI"`, con le liste separate da virgole.

```bash
ARCHIVES=(
  "monitoring|uptime-kuma|/mnt/Apps/UptimeKuma||/mnt/Apps/UptimeKuma/data/kuma.db"
  "live||/mnt/Apps/Nextcloud/html/config,?/mnt/Apps/Extra|*/cache|/mnt/Apps/Nextcloud/html/config/config.php"
)
```

| Campo | Significato |
|---|---|
| `NOME` | Nome del file dell'archivio (lettere, cifre, `.`, `_`, `-`) |
| `APP_DA_FERMARE` | App di TrueNAS fermate mentre si fa **questo** archivio, poi riaccese, solo se erano accese. Vuoto: l'archivio si fa con le app accese |
| `PERCORSI` | Percorsi assoluti. Un `?` davanti rende un percorso facoltativo (saltato con un avviso se manca); un percorso che manca senza `?` fa fallire il backup |
| `ESCLUSIONI` | Pattern di tar, confrontati con i percorsi senza la `/` iniziale (es. `*/cache`) |
| `OBBLIGATORI` | Percorsi che devono finire nell'archivio, altrimenti il backup fallisce |

**App occupate.** Alcune app non andrebbero fermate a metà lavoro (una copia, una conversione). `APP_IDLE_CHECKS` dà a un'app del genere un comando che esce con 0 quando si può fermare, per esempio uno script che chiede all'API dell'app se sta copiando:

```bash
APP_IDLE_CHECKS=("auto-disk-copy|/mnt/tank/scripts/autodiskcopy-idle.sh|2700")
```

Prima di fermare l'app, il comando viene provato ogni minuto per al massimo `ATTESA_MASSIMA_SECONDI`. Se l'app è ancora occupata **non viene fermata**: il suo archivio si fa con l'app accesa, con un avviso nel log e nella notifica.

Ferma le app i cui dati devono essere coerenti sul disco (per esempio un database SQLite) e archivia il resto con le app accese; in un archivio fatto ad app accese, i file che cambiano durante la lettura sono un avviso, non un errore. Le app fermate vengono riaccese **anche se il backup fallisce**, e il backup fallisce se una di loro non è di nuovo accesa dopo `APP_START_TIMEOUT` secondi. I percorsi vengono salvati senza la `/` iniziale, così un archivio si estrae nella cartella che scegli. I percorsi non possono contenere virgole.

## Conservazione

Dopo ogni backup riuscito: si tengono tutti i backup degli ultimi `KEEP_DAILY` giorni; dei più vecchi, il primo backup di ciascuno degli ultimi `KEEP_MONTHLY` mesi; una cartella che contiene un file `.keep` non viene mai cancellata (`touch BACKUP_DIR/<data>/.keep`). Il backup appena fatto non viene mai cancellato.

## Avvisi e stato

- `HEALTHCHECKS_URL` riceve `/start` all'inizio, l'indirizzo semplice alla riuscita e `/fail` all'errore. Con un periodo di un giorno in Healthchecks, scatta l'allarme anche per un backup che non è partito.
- `NOTIFY_URL` riceve un messaggio quando il backup fallisce; quando riesce, solo se ci sono avvisi, o sempre con `NOTIFY_ON="always"`.
- `BACKUP_DIR/status/last_run.json` descrive l'ultima esecuzione (`status`, `timestamp`, `version` di TrueNAS, dimensione, durata, avvisi o codice di errore), `last_success.json` l'ultima riuscita, `last_verify.json` l'ultima verifica. `BACKUP_DIR/latest` punta al backup più recente, e il log sta in `BACKUP_DIR/logs/`.
- Gira un solo backup alla volta.

## Verificare un backup

```bash
system-backup-verify.sh                       # l'ultimo backup
system-backup-verify.sh --restore             # ripristina anche i database
system-backup-verify.sh /mnt/tank/SystemBackups/2026-11-19_03-00-00
```

Controlla i checksum e il manifest, estrae la configurazione di TrueNAS, fa il controllo di integrità di SQLite sul suo database e verifica il secret seed, legge tutte le impostazioni delle app, legge ogni archivio fino in fondo (un blocco rovinato in qualsiasi punto viene trovato) e controlla il formato di ogni dump.

Con `--restore`, ogni database viene ripristinato in un **container usa e getta senza rete** (`PG_IMAGE`, `MYSQL_IMAGE`) e se ne contano le tabelle. Le immagini devono essere almeno della versione dei tuoi database: `pg_restore` legge i dump delle versioni precedenti, non di quelle successive. Non viene cambiato niente fuori da una cartella temporanea dentro `BACKUP_DIR`, e i container vengono cancellati alla fine. Un errore fa uscire con codice 1 e viene notificato.

## Ripristinare

Il backup è fatto di file normali; il ripristino si fa a mano, un pezzo alla volta.

- **Configurazione di TrueNAS**: su un TrueNAS nuovo della stessa versione o più recente, *System → General Settings → Manage Configuration → Upload File*, e scegli `truenas/truenas-config-*.tar`. L'archivio contiene il secret seed, quindi le password salvate continuano a funzionare.
- **PostgreSQL**: ferma l'app che usa il database (non il container del database), poi:

  ```bash
  docker exec -i ix-nextcloud-postgres-1 pg_restore -U nextcloud -d nextcloud --clean --if-exists < databases/pg-ix-nextcloud-postgres-1-nextcloud.dump
  ```

- **MariaDB/MySQL**: `zcat databases/mysql-<container>-<db>.sql.gz | docker exec -i <container> sh -c 'mariadb -u root -p"$MARIADB_ROOT_PASSWORD" <db>'`.
- **Archivi**: ferma le app, poi `tar -xzf archives/<nome>.tar.gz -C /` rimette i file dov'erano (oppure `-C /una/cartella` per guardarli prima).
- **Impostazioni delle app** (`app-configs/`): riferimento per ricreare un'app con le stesse impostazioni.

Lancia `system-backup-verify.sh --restore` regolarmente (`install.sh` lo programma ogni settimana): è la prova che questi passi funzioneranno.

## Senza TrueNAS

Con `TRUENAS_CONFIG="no"`, senza `APP_CONFIGS` e senza app da fermare, `system-backup.sh` non ha bisogno né di `midclt` né di TrueNAS: salva database in container Docker e cartelle su qualsiasi Linux.

## L'esempio originale

`examples/system-backup.sh` è lo script da cui sono nati questi due, tenuto come riferimento. È legato a un homelab preciso e contiene logica specifica di alcune app (aspettare che un'app sia inattiva prima di fermarla, le notifiche Telegram): usa `system-backup/` al suo posto.

## Problemi comuni

- **"midclt not found".** Le parti di TrueNAS sono attive e lo script non gira su TrueNAS.
- **Un'app non è accesa dopo il backup.** Il log dice quale; `APP_START_TIMEOUT` potrebbe essere troppo corto per un'app lenta.
- **"another backup is running".** Un backup precedente è ancora in corso (o si è bloccato tenendo il lucchetto: viene liberato quando il suo processo finisce).
- **`--restore` fallisce su PostgreSQL.** `PG_IMAGE` è più vecchia del database che ha fatto il dump.

# Sicurezza

- **Gli script girano come root.** Leggili prima di installarli; ognuno è breve e fa solo quello che descrive la sua sezione.
- **I file di impostazioni contengono segreti** (indirizzi di Healthchecks e Kuma, token delle notifiche): tienili con `chmod 600`; gli script avvisano se altri utenti possono leggerli. Non metterli nel repository: `.gitignore` esclude i `*.conf`.
- **I backup contengono segreti**: il secret seed di TrueNAS, le impostazioni delle app, i dump dei database. Le cartelle dei backup vengono create leggibili solo da root; tieni `BACKUP_DIR` privata, e cifrala se esce dal NAS.
- **lan-guard non può chiuderti fuori**: filtra solo le connessioni nuove dall'interfaccia della rete di casa verso le porte che elenchi, mai SSH, l'interfaccia web o la VPN.
- **Rete**: gli script contattano solo gli indirizzi che configuri (Healthchecks, Kuma, ntfy o webhook, i provider cloud tramite rclone). `system-backup-verify.sh --restore` scarica le immagini dei database e fa girare i container di ripristino senza rete.
- **Le password dei database** non passano mai sulla riga di comando del NAS: i dump MariaDB/MySQL le leggono dentro il container.

Problemi di sicurezza: vedi [SECURITY.md](../SECURITY.md).

# Sviluppo

## Struttura

Ogni script è autonomo: bash per lan-guard, heartbeat e system-backup (`common.sh` contiene quello che `system-backup.sh` e `system-backup-verify.sh` hanno in comune), Python per storage-status (solo libreria standard). Puntano a quello che c'è su TrueNAS 25.10: bash 5 e Python 3.11.

## Test

| Test | Cosa controlla | Come gira |
|---|---|---|
| `tests/lan-guard-test.sh` | Regole su un firewall vero: apply, ripetizione, dry-run, eccezioni, log, avvisi, rimozione, senza ip6tables | in un container usa e getta con `NET_ADMIN` (si rifiuta di girare altrove) |
| `tests/heartbeat-test.sh` | Push, controlli, timeout, notifiche sui cambiamenti, impostazioni, lucchetto, `toolkit.conf` | finti `curl` e `docker`, non viene inviato niente |
| `tests/storage-status-test.py` | JSON, file Prometheus, soglie, token del cloud, sezioni che falliscono, impostazioni | finti `midclt`, `zfs` e `rclone` che rispondono da `tests/storage-status.fixtures.json` |
| `tests/system-backup-test.sh` | Configurazione, impostazioni delle app, fermare e riaccendere app, errori, conservazione, lucchetto, verifica | finti `midclt` e `curl` |
| `tests/system-backup-restore-test.sh` | Backup vero e `--restore` di PostgreSQL 16 e MariaDB 11 | serve Docker |
| `tests/install-test.sh` | Creazione, aggiornamento dopo aver spostato la cartella, job fatti a mano, rimozione | finto middleware |

```bash
docker run --rm --cap-add NET_ADMIN -v "$PWD":/src:ro alpine:3.20 \
  sh -c 'apk add -q iptables ip6tables bash && bash /src/tests/lan-guard-test.sh'
bash tests/heartbeat-test.sh
python3 tests/storage-status-test.py
bash tests/system-backup-test.sh
bash tests/system-backup-restore-test.sh
bash tests/install-test.sh
```

I test in bash hanno bisogno degli strumenti GNU (su macOS lanciali in un container `python:3.13-alpine` con `bash coreutils tar findutils util-linux`, come indicano i commenti in testa a ogni test).

## Integrazione continua

A ogni push e pull request, GitHub Actions lancia: controllo della sintassi, shellcheck, ruff (lint e formato), compilazione con Python 3.11, controllo del JSON di esempio con lo schema, tutti i test qui sopra e la generazione di questa documentazione in pagine HTML.

## Documentazione

Questa guida esiste in inglese (`docs/documentation.md`) e in italiano (`docs/documentazione.md`), come il README. `docs/web/build.sh <cartella>` le trasforma in pagine HTML autonome con pandoc (`docs-en.html`, `docs-it.html`). Quando cambia qualcosa, aggiorna tutte e due le lingue e il [changelog](../CHANGELOG.md).

Contributi: vedi [CONTRIBUTING.md](../CONTRIBUTING.md).
