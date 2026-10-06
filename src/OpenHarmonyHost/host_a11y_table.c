// Per-instance accessibility shadow-node table. See host_a11y_table.h for the contract.
//
// The legacy exports (no instance argument) address the primary partition with exactly the
// table, string interning and id-map semantics openharmony_host.c always had (zero change for
// the main provider). The *_for exports address one named partition each: the NAPI layer
// registers a provider per instance with OH_ArkUI_AccessibilityProviderRegisterCallbackWithInstance
// and its callbacks read back through these entries, so a child window's frame can never
// overwrite the primary node table and vice versa.
#include "host_a11y_table.h"

// The public exports are declared inside openharmony_host.h's extern "C" block; including it
// before the definitions is what gives them C linkage when clang++ compiles this .c as C++
// (a definition after a C-linkage declaration inherits it). Without it the device build
// exports _Z... mangled names and the managed EntryPoints fail at runtime.
#include "openharmony_host.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// Argument order is the publish contract shared with the managed DllImport and the NAPI
// consumer; see the declarations in openharmony_host.h before touching this struct or the
// signatures below. Absent values: hint may be NULL, a range is only valid when
// range_min <= range_max (NaN compares false), checked is -1 when unknown/not applicable.
typedef struct OhosAccessibilityNode {
    int id;
    int parent_id;
    char* role;
    char* text;
    char* description;
    char* hint;
    float x, y, width, height;
    int flags;
    int actions;
    double range_min, range_max, range_current;
    int checked;
} OhosAccessibilityNode;

// One provider instance's table. The primary partition is the static g_a11y_primary; named
// partitions hang off g_a11y_named in creation order (the order is irrelevant: lookups are by
// exact instance string).
typedef struct OhosA11yPartition {
    char* instance;   // owned; NULL for the legacy primary partition
    OhosAccessibilityNode* nodes;
    int capacity;
    int fill;
    int count;
    // id -> index map over the published table, filled as each slot is written, so the
    // provider's id lookups are O(1) instead of a linear scan. Open addressing with linear
    // probing; node ids are positive and 0 marks an empty slot. Kept for the life of the
    // partition and only grown. If a grow ever fails the map is marked incomplete and lookups
    // fall back to the scan, so a query never misses a published node.
    int* id_keys;
    int* id_values;
    int id_capacity;
    int id_used;
    int id_complete;
    struct OhosA11yPartition* next;
} OhosA11yPartition;

static OhosA11yPartition g_a11y_primary = {0};
static OhosA11yPartition* g_a11y_named = NULL;
static int g_a11y_named_count = 0;

// Serializes the shadow node tables between the managed publisher (begin/node/commit on the
// app thread) and the NAPI accessibility providers (count/get on the ArkUI thread).
static pthread_mutex_t g_a11y_mutex = PTHREAD_MUTEX_INITIALIZER;

// The getter must never hand the interned node strings to the provider: begin frees the whole
// table while the provider is still forwarding the fields to the ArkUI setters (A11yFillElement
// in host_napi.cpp). Each get copies the strings under g_a11y_mutex into per-thread storage
// that stays valid until the next get on that thread, so a concurrent publish can free the
// table without invalidating the caller's fill. The storage hangs off a pthread key instead of
// __thread on purpose: the host library is dlopen'ed, and the OpenHarmony toolchain lowers
// __thread to emulated TLS (libc++_shared's __emutls_get_address), while the key needs no
// TLS relocations; its destructor frees the copies when the thread exits.
#define OHOS_A11Y_COPY_SLOTS 4

typedef struct OhosA11yCopySet {
    char* strings[OHOS_A11Y_COPY_SLOTS];
    size_t sizes[OHOS_A11Y_COPY_SLOTS];
} OhosA11yCopySet;

static pthread_key_t g_a11y_copy_key;
static pthread_once_t g_a11y_copy_once = PTHREAD_ONCE_INIT;
static int g_a11y_copy_key_ready = 0;

static void OhosA11yCopySetDestroy(void* value) {
    OhosA11yCopySet* set = (OhosA11yCopySet*)value;
    if (set == NULL) {
        return;
    }
    for (int i = 0; i < OHOS_A11Y_COPY_SLOTS; i++) {
        free(set->strings[i]);
    }
    free(set);
}

static void OhosA11yCopyKeyInit(void) {
    g_a11y_copy_key_ready = pthread_key_create(&g_a11y_copy_key, OhosA11yCopySetDestroy) == 0;
}

// Caller holds g_a11y_mutex. Returns NULL when the thread cannot have copies (all string
// outputs then report the field as absent, which is the safe failure mode).
static OhosA11yCopySet* OhosA11yCopySetForThread(void) {
    pthread_once(&g_a11y_copy_once, OhosA11yCopyKeyInit);
    if (!g_a11y_copy_key_ready) {
        return NULL;
    }
    OhosA11yCopySet* set = (OhosA11yCopySet*)pthread_getspecific(g_a11y_copy_key);
    if (set == NULL) {
        set = (OhosA11yCopySet*)calloc(1, sizeof(OhosA11yCopySet));
        if (set == NULL || pthread_setspecific(g_a11y_copy_key, set) != 0) {
            free(set);
            return NULL;
        }
    }
    return set;
}

static const char* OhosA11yCopyString(OhosA11yCopySet* set, int slot, const char* value) {
    if (set == NULL || value == NULL) {
        return NULL;
    }
    size_t length = strlen(value) + 1;
    if (set->sizes[slot] < length) {
        char* grown = (char*)realloc(set->strings[slot], length);
        if (grown == NULL) {
            return NULL;   // report the field as absent rather than a dangling pointer
        }
        set->strings[slot] = grown;
        set->sizes[slot] = length;
    }
    memcpy(set->strings[slot], value, length);
    return set->strings[slot];
}

static char* OhosA11yString(const char* value) {
    if (value == NULL) {
        return NULL;
    }
    size_t length = strlen(value) + 1;
    char* copy = (char*)malloc(length);
    if (copy != NULL) {
        memcpy(copy, value, length);
    }
    return copy;
}

int ohos_host_accessibility_instance_valid(const char* instance) {
    if (instance == NULL || instance[0] == '\0') {
        return 0;
    }
    size_t length = strlen(instance);
    if (length >= OHOS_A11Y_INSTANCE_MAX) {
        return 0;
    }
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char)instance[i];
        if (c < 0x21 || c > 0x7E) {
            return 0;
        }
    }
    return 1;
}

// Caller holds g_a11y_mutex. Resolves one named partition; create=0 never allocates (a read
// for an unknown instance then fails cleanly instead of growing the table).
static OhosA11yPartition* OhosA11yPartitionForLocked(const char* instance, int create) {
    if (instance == NULL || instance[0] == '\0' || !ohos_host_accessibility_instance_valid(instance)) {
        return NULL;
    }
    for (OhosA11yPartition* part = g_a11y_named; part != NULL; part = part->next) {
        if (strcmp(part->instance, instance) == 0) {
            return part;
        }
    }
    if (!create || g_a11y_named_count >= OHOS_A11Y_MAX_NAMED_PARTITIONS) {
        return NULL;
    }
    OhosA11yPartition* part = (OhosA11yPartition*)calloc(1, sizeof(OhosA11yPartition));
    if (part == NULL) {
        return NULL;
    }
    part->instance = OhosA11yString(instance);
    if (part->instance == NULL) {
        free(part);
        return NULL;
    }
    part->next = g_a11y_named;
    g_a11y_named = part;
    g_a11y_named_count++;
    return part;
}

// Caller holds g_a11y_mutex (begin is the only caller). The node array itself is kept: the
// strings of the previous publish are released here, the slots are overwritten by the next
// publish and the array is only reallocated when the new count needs more room.
static void OhosA11yFreeNodeStrings(OhosA11yPartition* part) {
    if (part->nodes != NULL) {
        for (int i = 0; i < part->fill; i++) {
            free(part->nodes[i].role);
            free(part->nodes[i].text);
            free(part->nodes[i].description);
            free(part->nodes[i].hint);
            part->nodes[i].role = NULL;
            part->nodes[i].text = NULL;
            part->nodes[i].description = NULL;
            part->nodes[i].hint = NULL;
        }
    }
    part->fill = 0;
    part->count = 0;
}

static size_t OhosA11yIdSlot(int id, int capacity) {
    return ((size_t)(unsigned int)id * 2654435761u) & (size_t)(capacity - 1);
}

// Caller holds g_a11y_mutex.
static void OhosA11yIndexClear(OhosA11yPartition* part) {
    if (part->id_keys != NULL) {
        memset(part->id_keys, 0, (size_t)part->id_capacity * sizeof(int));
    }
    part->id_used = 0;
    part->id_complete = 1;
}

// Caller holds g_a11y_mutex. Doubles the table once the load factor would pass 1/2.
static int OhosA11yIndexGrow(OhosA11yPartition* part) {
    int new_capacity = part->id_capacity == 0 ? 64 : part->id_capacity * 2;
    int* keys = (int*)calloc((size_t)new_capacity, sizeof(int));
    int* values = (int*)malloc((size_t)new_capacity * sizeof(int));
    if (keys == NULL || values == NULL) {
        free(keys);
        free(values);
        return -1;
    }
    for (int i = 0; i < part->id_capacity; i++) {
        int id = part->id_keys[i];
        if (id == 0) {
            continue;
        }
        size_t slot = OhosA11yIdSlot(id, new_capacity);
        while (keys[slot] != 0) {
            slot = (slot + 1) & (size_t)(new_capacity - 1);
        }
        keys[slot] = id;
        values[slot] = part->id_values[i];
    }
    free(part->id_keys);
    free(part->id_values);
    part->id_keys = keys;
    part->id_values = values;
    part->id_capacity = new_capacity;
    return 0;
}

// Caller holds g_a11y_mutex. The first node published under an id wins, matching the linear
// scan this map replaces.
static void OhosA11yIndexInsert(OhosA11yPartition* part, int id, int index) {
    if (id <= 0) {
        return;   // ids are positive; the empty-slot marker is 0
    }
    if ((part->id_used + 1) * 2 > part->id_capacity && OhosA11yIndexGrow(part) != 0) {
        part->id_complete = 0;
        return;
    }
    size_t slot = OhosA11yIdSlot(id, part->id_capacity);
    while (part->id_keys[slot] != 0) {
        if (part->id_keys[slot] == id) {
            return;
        }
        slot = (slot + 1) & (size_t)(part->id_capacity - 1);
    }
    part->id_keys[slot] = id;
    part->id_values[slot] = index;
    part->id_used++;
}

// Caller holds g_a11y_mutex. Shared begin: clears the partition's table and makes room for
// `count` nodes.
static int OhosA11yBeginLocked(OhosA11yPartition* part, int count) {
    // The provider cannot observe the cleared table: count drops to 0 here and is only raised
    // again by commit, and the getter refuses an index outside [0, count).
    OhosA11yFreeNodeStrings(part);
    OhosA11yIndexClear(part);
    if (count <= 0) {
        return 0;
    }
    if (part->capacity < count) {
        OhosAccessibilityNode* grown =
            (OhosAccessibilityNode*)realloc(part->nodes, (size_t)count * sizeof(OhosAccessibilityNode));
        if (grown == NULL) {
            return -1;
        }
        part->nodes = grown;
        part->capacity = count;
    }
    return 0;
}

// 16 arguments, in this exact order: id, parent_id, role, text, description, hint,
// x, y, width, height, flags, actions, range_min, range_max, range_current, checked.
// The order is mirrored by the managed DllImport (maui-ohos OpenHarmonyAccessibility.cs)
// and asserted off-device by the interaction harness; see openharmony_host.h.
static int OhosA11yNodeLocked(OhosA11yPartition* part, int id, int parent_id, const char* role,
                              const char* text, const char* description, const char* hint,
                              float x, float y, float width, float height,
                              int flags, int actions,
                              double range_min, double range_max, double range_current,
                              int checked) {
    if (part->nodes == NULL || part->fill >= part->capacity) {
        return -1;
    }
    int index = part->fill;
    OhosAccessibilityNode* node = &part->nodes[index];
    node->id = id;
    node->parent_id = parent_id;
    node->role = OhosA11yString(role);
    node->text = OhosA11yString(text);
    node->description = OhosA11yString(description);
    node->hint = OhosA11yString(hint);
    node->x = x;
    node->y = y;
    node->width = width;
    node->height = height;
    node->flags = flags;
    node->actions = actions;
    node->range_min = range_min;
    node->range_max = range_max;
    node->range_current = range_current;
    node->checked = checked;
    part->fill = index + 1;
    OhosA11yIndexInsert(part, id, index);
    return 0;
}

// Index of the published node with this id, or -1 when no committed node carries it. O(1)
// through the id map the publisher maintains; when the map could not be grown, this falls
// back to the linear scan the map replaces. Caller holds g_a11y_mutex.
static int OhosA11yIndexLocked(OhosA11yPartition* part, int id) {
    int index = -1;
    if (id > 0 && part->count > 0) {
        if (!part->id_complete) {
            for (int i = 0; i < part->count; i++) {
                if (part->nodes[i].id == id) {
                    index = i;
                    break;
                }
            }
        } else if (part->id_capacity > 0) {
            size_t slot = OhosA11yIdSlot(id, part->id_capacity);
            while (part->id_keys[slot] != 0) {
                if (part->id_keys[slot] == id) {
                    int candidate = part->id_values[slot];
                    if (candidate >= 0 && candidate < part->count) {
                        index = candidate;
                    }
                    break;
                }
                slot = (slot + 1) & (size_t)(part->id_capacity - 1);
            }
        }
    }
    return index;
}

// Mirrors OhosA11yNodeLocked: 17 arguments, same order plus the output pointers (index first,
// then the 16 published fields). See openharmony_host.h. The string outputs point at per-thread
// copies taken under the table lock (OhosA11yCopySetForThread), not at the interned node
// fields, so begin can free the table while the provider fills its element. Caller holds
// g_a11y_mutex.
static int OhosA11yGetLocked(OhosA11yPartition* part, int index, int* id, int* parent_id,
                             const char** role, const char** text, const char** description,
                             const char** hint, float* x, float* y, float* width, float* height,
                             int* flags, int* actions, double* range_min, double* range_max,
                             double* range_current, int* checked) {
    if (part->nodes == NULL || index < 0 || index >= part->count) {
        return -1;
    }
    OhosAccessibilityNode* node = &part->nodes[index];
    OhosA11yCopySet* copies = OhosA11yCopySetForThread();
    if (id != NULL) *id = node->id;
    if (parent_id != NULL) *parent_id = node->parent_id;
    if (role != NULL) *role = OhosA11yCopyString(copies, 0, node->role);
    if (text != NULL) *text = OhosA11yCopyString(copies, 1, node->text);
    if (description != NULL) *description = OhosA11yCopyString(copies, 2, node->description);
    if (hint != NULL) *hint = OhosA11yCopyString(copies, 3, node->hint);
    if (x != NULL) *x = node->x;
    if (y != NULL) *y = node->y;
    if (width != NULL) *width = node->width;
    if (height != NULL) *height = node->height;
    if (flags != NULL) *flags = node->flags;
    if (actions != NULL) *actions = node->actions;
    if (range_min != NULL) *range_min = node->range_min;
    if (range_max != NULL) *range_max = node->range_max;
    if (range_current != NULL) *range_current = node->range_current;
    if (checked != NULL) *checked = node->checked;
    return 0;
}

// --- legacy exports: the primary partition (unchanged main-provider path) ------------------

int ohos_host_accessibility_begin(int count) {
    pthread_mutex_lock(&g_a11y_mutex);
    int rc = OhosA11yBeginLocked(&g_a11y_primary, count);
    pthread_mutex_unlock(&g_a11y_mutex);
    return rc;
}

int ohos_host_accessibility_node(int id, int parent_id, const char* role, const char* text,
                                 const char* description, const char* hint,
                                 float x, float y, float width, float height,
                                 int flags, int actions,
                                 double range_min, double range_max, double range_current,
                                 int checked) {
    pthread_mutex_lock(&g_a11y_mutex);
    int rc = OhosA11yNodeLocked(&g_a11y_primary, id, parent_id, role, text, description, hint,
                                x, y, width, height, flags, actions, range_min, range_max,
                                range_current, checked);
    pthread_mutex_unlock(&g_a11y_mutex);
    return rc;
}

int ohos_host_accessibility_commit(void) {
    pthread_mutex_lock(&g_a11y_mutex);
    g_a11y_primary.count = g_a11y_primary.fill;
    int count = g_a11y_primary.count;
    pthread_mutex_unlock(&g_a11y_mutex);
    return count;
}

int ohos_host_accessibility_count(void) {
    pthread_mutex_lock(&g_a11y_mutex);
    int count = g_a11y_primary.count;
    pthread_mutex_unlock(&g_a11y_mutex);
    return count;
}

// Published node count for the shell's accessibility self-check (host.accessibilityNodeCount).
// Same value as ohos_host_accessibility_count; the distinct name keeps the publish-contract
// reflection described above from mistaking this symbol for the 16-argument publish function.
int ohos_host_accessibility_node_count(void) {
    return ohos_host_accessibility_count();
}

int ohos_host_accessibility_index_of(int id) {
    pthread_mutex_lock(&g_a11y_mutex);
    int index = OhosA11yIndexLocked(&g_a11y_primary, id);
    pthread_mutex_unlock(&g_a11y_mutex);
    return index;
}

int ohos_host_accessibility_get(int index, int* id, int* parent_id, const char** role,
                                const char** text, const char** description, const char** hint,
                                float* x, float* y, float* width, float* height,
                                int* flags, int* actions,
                                double* range_min, double* range_max, double* range_current,
                                int* checked) {
    pthread_mutex_lock(&g_a11y_mutex);
    int rc = OhosA11yGetLocked(&g_a11y_primary, index, id, parent_id, role, text, description,
                               hint, x, y, width, height, flags, actions, range_min, range_max,
                               range_current, checked);
    pthread_mutex_unlock(&g_a11y_mutex);
    return rc;
}

// --- per-instance exports: one named partition each (MULTIWINDOW-L2 a) ---------------------

int ohos_host_accessibility_begin_for(const char* instance, int count) {
    pthread_mutex_lock(&g_a11y_mutex);
    OhosA11yPartition* part = OhosA11yPartitionForLocked(instance, 1);
    int rc = part == NULL ? -1 : OhosA11yBeginLocked(part, count);
    pthread_mutex_unlock(&g_a11y_mutex);
    return rc;
}

int ohos_host_accessibility_node_for(const char* instance, int id, int parent_id, const char* role,
                                     const char* text, const char* description, const char* hint,
                                     float x, float y, float width, float height,
                                     int flags, int actions,
                                     double range_min, double range_max, double range_current,
                                     int checked) {
    pthread_mutex_lock(&g_a11y_mutex);
    // create=0: only begin_for allocates a partition. A stray node write for a typo'd instance
    // must not burn one of the OHOS_A11Y_MAX_NAMED_PARTITIONS slots (the capped partition table
    // is the resource guard; the documented sequence is begin/node/commit).
    OhosA11yPartition* part = OhosA11yPartitionForLocked(instance, 0);
    int rc = part == NULL ? -1 : OhosA11yNodeLocked(part, id, parent_id, role, text, description,
                                                    hint, x, y, width, height, flags, actions,
                                                    range_min, range_max, range_current, checked);
    pthread_mutex_unlock(&g_a11y_mutex);
    return rc;
}

int ohos_host_accessibility_commit_for(const char* instance) {
    pthread_mutex_lock(&g_a11y_mutex);
    OhosA11yPartition* part = OhosA11yPartitionForLocked(instance, 0);
    int count = -1;
    if (part != NULL) {
        part->count = part->fill;
        count = part->count;
    }
    pthread_mutex_unlock(&g_a11y_mutex);
    return count;
}

int ohos_host_accessibility_count_for(const char* instance) {
    pthread_mutex_lock(&g_a11y_mutex);
    OhosA11yPartition* part = OhosA11yPartitionForLocked(instance, 0);
    int count = part == NULL ? 0 : part->count;
    pthread_mutex_unlock(&g_a11y_mutex);
    return count;
}

int ohos_host_accessibility_node_count_for(const char* instance) {
    return ohos_host_accessibility_count_for(instance);
}

int ohos_host_accessibility_index_of_for(const char* instance, int id) {
    pthread_mutex_lock(&g_a11y_mutex);
    OhosA11yPartition* part = OhosA11yPartitionForLocked(instance, 0);
    int index = part == NULL ? -1 : OhosA11yIndexLocked(part, id);
    pthread_mutex_unlock(&g_a11y_mutex);
    return index;
}

int ohos_host_accessibility_get_for(const char* instance, int index, int* id, int* parent_id,
                                    const char** role, const char** text, const char** description,
                                    const char** hint, float* x, float* y, float* width,
                                    float* height, int* flags, int* actions,
                                    double* range_min, double* range_max, double* range_current,
                                    int* checked) {
    pthread_mutex_lock(&g_a11y_mutex);
    OhosA11yPartition* part = OhosA11yPartitionForLocked(instance, 0);
    int rc = part == NULL ? -1 : OhosA11yGetLocked(part, index, id, parent_id, role, text,
                                                   description, hint, x, y, width, height, flags,
                                                   actions, range_min, range_max, range_current,
                                                   checked);
    pthread_mutex_unlock(&g_a11y_mutex);
    return rc;
}

void ohos_host_accessibility_table_reset(void) {
    pthread_mutex_lock(&g_a11y_mutex);
    OhosA11yFreeNodeStrings(&g_a11y_primary);
    OhosA11yIndexClear(&g_a11y_primary);
    OhosA11yPartition* part = g_a11y_named;
    while (part != NULL) {
        OhosA11yPartition* next = part->next;
        OhosA11yFreeNodeStrings(part);
        free(part->id_keys);
        free(part->id_values);
        free(part->nodes);
        free(part->instance);
        free(part);
        part = next;
    }
    g_a11y_named = NULL;
    g_a11y_named_count = 0;
    pthread_mutex_unlock(&g_a11y_mutex);
}
