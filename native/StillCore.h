#ifndef STILL_CORE_H
#define STILL_CORE_H
#include <stdint.h>
#include <stdbool.h>
typedef struct Core Core;
typedef struct {
    uint32_t fps, max_height, countdown, auto_stop_seconds;
    uint32_t system_audio, microphone, cursor, clicks, hide_app, hevc;
} StillSettings;
typedef struct { uint32_t phase, remaining; uint64_t elapsed; uint32_t should_stop; } StillStatus;
Core *still_create(const char *root);
void still_destroy(Core *core);
void still_string_free(char *value);
StillSettings still_settings(const Core *core);
bool still_save_settings(Core *core, StillSettings settings);
bool still_begin(Core *core);
StillStatus still_status(Core *core);
bool still_started(Core *core);
bool still_stop(Core *core);
bool still_finish(Core *core);
void still_reset(Core *core);
char *still_error(const Core *core);
char *still_path(Core *core, bool screenshot);
char *still_library(Core *core);
bool still_set_destination(Core *core, const char *path);
char *still_destination(const Core *core);
#endif
