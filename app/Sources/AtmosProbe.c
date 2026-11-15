#include "AtmosProbe.h"

#include <string.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/dict.h>

/* Vero se il titolo contiene "atmos" (senza distinguere maiuscole). */
static int title_says_atmos(AVDictionary *meta)
{
    AVDictionaryEntry *t = av_dict_get(meta, "title", NULL, 0);
    if (!t || !t->value)
        return 0;
    return strcasestr(t->value, "atmos") != NULL;
}

int tc_probe_audio_streams(const char *path, tc_audio_stream_info *out, int max)
{
    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, path, NULL, NULL) < 0)
        return -1;

    /* Basta leggere qualche secondo: i flag Atmos stanno nei primi frame. */
    fmt->probesize = 20 * 1024 * 1024;
    fmt->max_analyze_duration = 5 * AV_TIME_BASE;

    if (avformat_find_stream_info(fmt, NULL) < 0) {
        avformat_close_input(&fmt);
        return -1;
    }

    int n = 0;
    for (unsigned i = 0; i < fmt->nb_streams && n < max; i++) {
        AVStream *st = fmt->streams[i];
        AVCodecParameters *par = st->codecpar;
        if (par->codec_type != AVMEDIA_TYPE_AUDIO)
            continue;

        int atmos = 0;
        switch (par->codec_id) {
        case AV_CODEC_ID_TRUEHD:
            atmos = par->profile == AV_PROFILE_TRUEHD_ATMOS;
            break;
        case AV_CODEC_ID_EAC3:
            atmos = par->profile == AV_PROFILE_EAC3_DDP_ATMOS;
            break;
        case AV_CODEC_ID_DTS:
            atmos = par->profile == AV_PROFILE_DTS_HD_MA_X ||
                    par->profile == AV_PROFILE_DTS_HD_MA_X_IMAX;
            break;
        default:
            break;
        }
        if (!atmos && (par->codec_id == AV_CODEC_ID_TRUEHD ||
                       par->codec_id == AV_CODEC_ID_EAC3))
            atmos = title_says_atmos(st->metadata);

        out[n].index = (int)i;
        out[n].id = st->id;
        out[n].is_atmos = atmos;
        out[n].channels = par->ch_layout.nb_channels;
        n++;
    }

    avformat_close_input(&fmt);
    return n;
}
