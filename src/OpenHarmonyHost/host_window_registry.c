// Per-window XComponent surface registry (MULTIWINDOW-L M1). See host_window_registry.h for the
// contract; this file is pure C (no NAPI/OpenHarmony headers) so it is unit-testable off-device.
#include "host_window_registry.h"

#include <pthread.h>
#include <string.h>

typedef struct {
    int used;
    ohos_host_window_record record;
} ohos_host_window_slot;

static ohos_host_window_slot g_windows[OHOS_HOST_WINDOW_COUNT_MAX];
static pthread_mutex_t g_windows_lock = PTHREAD_MUTEX_INITIALIZER;

static int WindowIdValid(const char* id) {
    return id != NULL && id[0] != '\0' && strlen(id) <= OHOS_HOST_WINDOW_ID_MAX;
}

static void CopyId(char* destination, const char* source) {
    size_t length = strlen(source);
    if (length > OHOS_HOST_WINDOW_ID_MAX) {
        length = OHOS_HOST_WINDOW_ID_MAX;
    }
    memcpy(destination, source, length);
    destination[length] = '\0';
}

// --- table helpers; every caller holds g_windows_lock -------------------------------

static ohos_host_window_record* FindById(const char* id) {
    for (int i = 0; i < OHOS_HOST_WINDOW_COUNT_MAX; i++) {
        if (g_windows[i].used && strcmp(g_windows[i].record.id, id) == 0) {
            return &g_windows[i].record;
        }
    }
    return NULL;
}

static ohos_host_window_record* FindByComponent(void* component) {
    for (int i = 0; i < OHOS_HOST_WINDOW_COUNT_MAX; i++) {
        if (g_windows[i].used && g_windows[i].record.component == component) {
            return &g_windows[i].record;
        }
    }
    return NULL;
}

static int FindIndexById(const char* id) {
    for (int i = 0; i < OHOS_HOST_WINDOW_COUNT_MAX; i++) {
        if (g_windows[i].used && strcmp(g_windows[i].record.id, id) == 0) {
            return i;
        }
    }
    return -1;
}

// Removes one slot and keeps registration order contiguous, so iteration (at/count) and
// unregister_owner never observe a hole.
static void DropSlot(int index) {
    for (int i = index; i + 1 < OHOS_HOST_WINDOW_COUNT_MAX; i++) {
        g_windows[i] = g_windows[i + 1];
    }
    memset(&g_windows[OHOS_HOST_WINDOW_COUNT_MAX - 1], 0, sizeof(g_windows[0]));
}

int ohos_host_window_register(const char* id, void* component, void* owner, int primary) {
    if (!WindowIdValid(id) || component == NULL) {
        return OHOS_HOST_WINDOW_INVALID;
    }
    pthread_mutex_lock(&g_windows_lock);
    ohos_host_window_record* existing = FindById(id);
    if (existing != NULL) {
        int idempotent = existing->component == component;
        pthread_mutex_unlock(&g_windows_lock);
        return idempotent ? OHOS_HOST_WINDOW_OK : OHOS_HOST_WINDOW_DUPLICATE;
    }
    if (FindByComponent(component) != NULL) {
        pthread_mutex_unlock(&g_windows_lock);
        return OHOS_HOST_WINDOW_DUPLICATE;
    }
    int slot = -1;
    for (int i = 0; i < OHOS_HOST_WINDOW_COUNT_MAX; i++) {
        if (!g_windows[i].used) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        pthread_mutex_unlock(&g_windows_lock);
        return OHOS_HOST_WINDOW_FULL;
    }
    ohos_host_window_record* record = &g_windows[slot].record;
    memset(record, 0, sizeof(*record));
    CopyId(record->id, id);
    record->component = component;
    record->owner = owner;
    record->state = -1;
    record->primary = primary ? 1 : 0;
    g_windows[slot].used = 1;
    pthread_mutex_unlock(&g_windows_lock);
    return OHOS_HOST_WINDOW_OK;
}

int ohos_host_window_surface(const char* id, void* surface, int width, int height, int state) {
    if (!WindowIdValid(id)) {
        return OHOS_HOST_WINDOW_INVALID;
    }
    pthread_mutex_lock(&g_windows_lock);
    ohos_host_window_record* record = FindById(id);
    if (record == NULL) {
        pthread_mutex_unlock(&g_windows_lock);
        return OHOS_HOST_WINDOW_NOT_FOUND;
    }
    record->surface = surface;
    record->width = width;
    record->height = height;
    record->state = state;
    record->surface_events++;
    pthread_mutex_unlock(&g_windows_lock);
    return OHOS_HOST_WINDOW_OK;
}

int ohos_host_window_note_touch(const char* id) {
    if (!WindowIdValid(id)) {
        return OHOS_HOST_WINDOW_INVALID;
    }
    pthread_mutex_lock(&g_windows_lock);
    ohos_host_window_record* record = FindById(id);
    if (record == NULL) {
        pthread_mutex_unlock(&g_windows_lock);
        return OHOS_HOST_WINDOW_NOT_FOUND;
    }
    record->touch_events++;
    pthread_mutex_unlock(&g_windows_lock);
    return OHOS_HOST_WINDOW_OK;
}

int ohos_host_window_note_frame(const char* id) {
    if (!WindowIdValid(id)) {
        return OHOS_HOST_WINDOW_INVALID;
    }
    pthread_mutex_lock(&g_windows_lock);
    ohos_host_window_record* record = FindById(id);
    if (record == NULL) {
        pthread_mutex_unlock(&g_windows_lock);
        return OHOS_HOST_WINDOW_NOT_FOUND;
    }
    record->frame_events++;
    pthread_mutex_unlock(&g_windows_lock);
    return OHOS_HOST_WINDOW_OK;
}

int ohos_host_window_unregister(const char* id) {
    if (!WindowIdValid(id)) {
        return OHOS_HOST_WINDOW_INVALID;
    }
    pthread_mutex_lock(&g_windows_lock);
    int index = FindIndexById(id);
    if (index < 0) {
        pthread_mutex_unlock(&g_windows_lock);
        return OHOS_HOST_WINDOW_NOT_FOUND;
    }
    DropSlot(index);
    pthread_mutex_unlock(&g_windows_lock);
    return OHOS_HOST_WINDOW_OK;
}

int ohos_host_window_unregister_owner(void* owner) {
    if (owner == NULL) {
        return 0;
    }
    int removed = 0;
    pthread_mutex_lock(&g_windows_lock);
    for (int i = 0; i < OHOS_HOST_WINDOW_COUNT_MAX;) {
        if (g_windows[i].used && g_windows[i].record.owner == owner) {
            DropSlot(i);
            removed++;
        } else {
            i++;
        }
    }
    pthread_mutex_unlock(&g_windows_lock);
    return removed;
}

int ohos_host_window_lookup(const char* id, ohos_host_window_record* out) {
    if (!WindowIdValid(id) || out == NULL) {
        return OHOS_HOST_WINDOW_INVALID;
    }
    pthread_mutex_lock(&g_windows_lock);
    ohos_host_window_record* record = FindById(id);
    if (record != NULL) {
        *out = *record;
    }
    pthread_mutex_unlock(&g_windows_lock);
    return record != NULL ? OHOS_HOST_WINDOW_OK : OHOS_HOST_WINDOW_NOT_FOUND;
}

int ohos_host_window_lookup_component(void* component, ohos_host_window_record* out) {
    if (component == NULL || out == NULL) {
        return OHOS_HOST_WINDOW_INVALID;
    }
    pthread_mutex_lock(&g_windows_lock);
    ohos_host_window_record* record = FindByComponent(component);
    if (record != NULL) {
        *out = *record;
    }
    pthread_mutex_unlock(&g_windows_lock);
    return record != NULL ? OHOS_HOST_WINDOW_OK : OHOS_HOST_WINDOW_NOT_FOUND;
}

int ohos_host_window_at(int index, ohos_host_window_record* out) {
    if (index < 0 || index >= OHOS_HOST_WINDOW_COUNT_MAX || out == NULL) {
        return -1;
    }
    pthread_mutex_lock(&g_windows_lock);
    int seen = 0;
    int found = 0;
    for (int i = 0; i < OHOS_HOST_WINDOW_COUNT_MAX; i++) {
        if (!g_windows[i].used) {
            continue;
        }
        if (seen == index) {
            *out = g_windows[i].record;
            found = 1;
            break;
        }
        seen++;
    }
    pthread_mutex_unlock(&g_windows_lock);
    return found ? 0 : -1;
}

int ohos_host_window_count(void) {
    int count = 0;
    pthread_mutex_lock(&g_windows_lock);
    for (int i = 0; i < OHOS_HOST_WINDOW_COUNT_MAX; i++) {
        if (g_windows[i].used) {
            count++;
        }
    }
    pthread_mutex_unlock(&g_windows_lock);
    return count;
}

void ohos_host_window_reset(void) {
    pthread_mutex_lock(&g_windows_lock);
    memset(g_windows, 0, sizeof(g_windows));
    pthread_mutex_unlock(&g_windows_lock);
}
