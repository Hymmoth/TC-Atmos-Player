#ifndef ATMOS_PROBE_H
#define ATMOS_PROBE_H

#include <stdint.h>

/* Risultato dell'analisi di un flusso audio del file. */
typedef struct tc_audio_stream_info {
    int index;          /* indice del flusso nel contenitore (ff-index di mpv) */
    int64_t id;         /* id del flusso nel contenitore (src-id di mpv, es. TrackNumber MKV) */
    int is_atmos;       /* 1 se contiene oggetti (TrueHD Atmos, DD+ JOC, DTS:X) */
    int channels;       /* canali del letto */
} tc_audio_stream_info;

/*
 * Apre il file con libavformat, analizza i flussi e riempie `out` con le
 * informazioni sulle tracce audio. Restituisce il numero di tracce audio
 * trovate (al massimo `max`), oppure -1 in caso di errore.
 * Va chiamata fuori dal thread principale: legge l'inizio del file.
 */
int tc_probe_audio_streams(const char *path, tc_audio_stream_info *out, int max);

#endif
