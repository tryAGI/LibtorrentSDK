#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*adv_libtorrent_event_callback_t)(const char *json, void *context);

int adv_libtorrent_session_create(
    adv_libtorrent_event_callback_t callback,
    void *context,
    void **session
);

void adv_libtorrent_session_destroy(void *session);
int adv_libtorrent_job_start(void *session, const char *json);
int adv_libtorrent_job_apply_selection(void *session, const char *json);
int adv_libtorrent_job_pause(void *session, const char *json);
int adv_libtorrent_job_resume(void *session, const char *json);
int adv_libtorrent_job_cancel(void *session, const char *json);
const char *adv_libtorrent_last_error(void *session);

#ifdef __cplusplus
}
#endif
