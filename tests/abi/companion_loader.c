/* Independent pinned C ABI fixture; loads the actual production-built DLL.
 * Not a renderer or real Pulse host. Replies arrive only after API return. */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "pulse/settings_pages.h"
#include "pulse/resources.h"
#include "pulse/tasks.h"
#include "pulse/dispatch.h"
#include "pulse/dialogs.h"
#include "pulse/context.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "ABI fixture line %d: %s\n", __LINE__, #x); return PULSE_ERROR_ARGUMENT; } } while (0)

static const char *commands[] = {
    "companion.library", "companion.running", "companion.market", "companion.global",
    "companion.settings.refresh", "companion.download.less", "companion.download.more",
    "companion.library.reload", "companion.library.poll", "companion.library.previous", "companion.library.next", "companion.library.favorites", "companion.running.start", "companion.running.stop", "companion.running.stop-one", "companion.library.start", "companion.library.favorite-toggle", "companion.library.tag-add", "companion.library.tag-remove", "companion.library.import", "companion.library.import-cancel", "companion.library.browse", "companion.library.recovery-scan"
};
#define COMMAND_COUNT (sizeof(commands) / sizeof(commands[0]))
/* Optional 1.0.61 picker ABI: independent C layout matching the supplied
 * SDK pickers.h (SHA-256 103b59a0289caf0096f00e35dc53b6ff6e8759e3c83438b2a463ca855a5fbf46).
 * The old public header baseline has no picker declarations. */
typedef struct {
    uint32_t size, flags;
    PulseStringView title, ok_label, initial_path;
} FolderRequest;
typedef struct {
    uint32_t size, outcome;
    uint64_t request_id;
    uint32_t filter_index, path_count;
    const PulseStringView *paths;
    PulseStringView selected_id, error;
} FolderResult;
typedef void (PULSE_CALL *FolderCallback)(void *, const FolderResult *);
typedef struct {
    uint32_t size, version;
    void *context;
    void *open_files, *save_file;
    PulseStatus (PULSE_CALL *pick_folders)(void *, const FolderRequest *, FolderCallback, void *, uint64_t *);
    void *quick_pick;
    PulseStatus (PULSE_CALL *cancel)(void *, uint64_t);
} FolderTable;
_Static_assert(sizeof(FolderTable) == 56 && sizeof(FolderRequest) == 56 && sizeof(FolderResult) == 64, "picker ABI");
typedef void (PULSE_CALL *DialogCommandFn)(void *, uint64_t, PulseStringView);
typedef struct {
    uint32_t size, version;
    void *context;
    PulseStatus (PULSE_CALL *show)(void *, const PulseDialogRequest *, PulseDialogStateChanged, PulseDialogClosed, void *, uint64_t *);
    PulseStatus (PULSE_CALL *set_states)(void *, uint64_t, const PulseUiState *, uint32_t);
    PulseStatus (PULSE_CALL *close)(void *, uint64_t);
    PulseStatus (PULSE_CALL *subscribe_command)(void *, uint64_t, PulseStringView, DialogCommandFn, void *, uint64_t *);
    PulseStatus (PULSE_CALL *unsubscribe_command)(void *, uint64_t);
    PulseStatus (PULSE_CALL *update_model)(void *, uint64_t, const PulseUiModelTree *);
    PulseStatus (PULSE_CALL *get_state)(void *, uint64_t, PulseStringView, char *, uint32_t, uint32_t *);
} DialogsV2Compat;
_Static_assert(sizeof(DialogsV2Compat) == 72, "dialogs V2 ABI");

typedef struct {
    uint64_t page, next, pending, version;
    unsigned created, removed, canceled, updates, subscribed, fail_subscribe;
    int fallback, fail_remove, enabled_more, enabled_less, global, saved_present;
    int auto_dispatch, bundled, dialogs_v2, start_enabled, stop_enabled, first_frame, two_ready, only_second;
    unsigned running_rows;
    HANDLE worker;
    volatile LONG cancel_flag;
    CRITICAL_SECTION dispatch_lock;
    PulseDispatchCallback queued;
    void *queued_user;
    uint64_t dispatch_id;
    char saved, requested;
    uint32_t operation;
    PulseUiClickFn click[COMMAND_COUNT];
    void *users[COMMAND_COUNT];
    uint64_t task, aux_task;
    PulseTaskWorkFn aux_work;
    void *aux_user;
    unsigned aux_released;
    unsigned task_released, task_canceled;
    PulseTaskState task_state;
    PulseTaskWorkFn task_work;
    void *task_user;
    uint64_t dialog, picker;
    FolderCallback picker_callback;
    void *picker_user;
    DialogCommandFn dialog_command;
    void *dialog_command_user;
    uint64_t dialog_command_subscription;
    unsigned dialog_states_updated;
    PulseDialogClosed dialog_closed;
    void *dialog_user;
    PulseResourcesCompletionFn completion;
    void *reply_user;
} Fixture;

static PulseStringView view(const char *s) { return (PulseStringView){s, (uint32_t)strlen(s)}; }
static int same(PulseStringView s, const char *text) {
    size_t n = strlen(text);
    return s.data && s.length == n && memcmp(s.data, text, n) == 0;
}

static PulseStatus inspect(Fixture *f, const PulseUiModelTree *t) {
    REQUIRE(t && t->size == sizeof(*t) && t->root && t->command_count == COMMAND_COUNT && t->commands);
    for (unsigned i = 0; i < COMMAND_COUNT; ++i) REQUIRE(same(t->commands[i], commands[i]));
    const PulseUiModelNode *root = t->root;
    REQUIRE(root->size == sizeof(*root) && root->type == PULSE_UI_MODEL_STACK);
    REQUIRE(root->children.present && root->children.data && (root->children.count >= 3 && root->children.count <= 28));
    const PulseUiModelNode *nav = root->children.data;
    REQUIRE(nav->children.present && nav->children.count == 4 && nav->children.data);
    for (unsigned i = 0; i < 4; ++i) {
        const PulseUiModelNode *n = nav->children.data + i;
        REQUIRE(n->size == sizeof(*n) && n->type == PULSE_UI_MODEL_BUTTON && n->command.present && same(n->command.value, commands[i]));
    }
    f->global = same(root->children.data[1].id, "global");
    f->enabled_less = f->enabled_more = 0;
    if (f->global) {
        REQUIRE(root->children.count == 5);
        const PulseUiModelNode *toolbar = root->children.data + 4;
        REQUIRE(toolbar->children.present && toolbar->children.count == 3 && toolbar->children.data);
        const PulseUiModelNode *less = toolbar->children.data + 1, *more = less + 1;
        REQUIRE(less->enabled.present && more->enabled.present);
        REQUIRE(same(less->command.value, commands[5]) && same(more->command.value, commands[6]));
        f->enabled_less = (int)less->enabled.value;
        f->enabled_more = (int)more->enabled.value;
    }
    if (same(root->children.data[1].id, "running")) {
        REQUIRE(root->children.count >= 4 && root->children.count <= 14);
        const PulseUiModelNode *toolbar = root->children.data + 3;
        REQUIRE(toolbar->children.present && toolbar->children.count == 2);
        f->start_enabled = (int)toolbar->children.data[0].enabled.value;
        f->stop_enabled = (int)toolbar->children.data[1].enabled.value;
        f->first_frame = 0;
        f->two_ready = 0;
        f->running_rows = root->children.count >= 6 ? root->children.count - 6 : 0;
        f->only_second = 0;
        if (f->running_rows == 1) {
            const PulseStringView row = root->children.data[6].text.value;
            f->only_second = row.data && row.length >= 5 && memcmp(row.data, "ID 2 ", 5) == 0;
        }
        if (root->children.count >= 5) {
            const PulseStringView text = root->children.data[4].text.value;
            const char *prefix = "首帧已确认";
            const char *two = "首帧已确认 · 运行 2/2";
            f->first_frame = text.data && text.length >= strlen(prefix) &&
                memcmp(text.data, prefix, strlen(prefix)) == 0;
            f->two_ready = text.data && text.length >= strlen(two) &&
                memcmp(text.data, two, strlen(two)) == 0;
        }
    }
    if (same(root->children.data[1].id, "library")) {
        REQUIRE(root->children.count >= 5);
        const PulseUiModelNode *toolbar = root->children.data + 4;
        REQUIRE(toolbar->children.present && toolbar->children.data &&
                (toolbar->children.count == 3 || toolbar->children.count == 4));
        REQUIRE(toolbar->children.data[0].type == PULSE_UI_MODEL_TEXT_INPUT);
        REQUIRE(toolbar->children.data[0].placeholder.present);
        REQUIRE(same(toolbar->children.data[1].command.value, commands[7]));
        REQUIRE(same(toolbar->children.data[2].command.value, commands[11]));
        if (toolbar->children.count == 4)
            REQUIRE(same(toolbar->children.data[3].command.value, commands[8]));
        unsigned recovery_buttons = 0;
        for (unsigned i = 0; i < root->children.count; ++i) {
            const PulseUiModelNode *node = root->children.data + i;
            if (!same(node->id, "library.recovery-scan")) continue;
            REQUIRE(node->type == PULSE_UI_MODEL_BUTTON && node->command.present && same(node->command.value, commands[22]));
            ++recovery_buttons;
        }
        REQUIRE(recovery_buttons == (f->bundled ? 1u : 0u));
    }
    return PULSE_OK;
}
static PulseStatus PULSE_CALL create(void *ctx, PulseStringView title, const PulseUiModelTree *tree, uint64_t *page) {
    Fixture *f = ctx;
    REQUIRE(!f->page && page && same(title, "Pulse Companion"));
    PulseStatus s = inspect(f, tree);
    if (s != PULSE_OK) return s;
    f->page = ++f->next;
    *page = f->page;
    ++f->created;
    return PULSE_OK;
}
static PulseStatus PULSE_CALL update(void *ctx, uint64_t page, const PulseUiModelTree *tree) {
    Fixture *f = ctx;
    REQUIRE(page && page == f->page);
    ++f->updates;
    return inspect(f, tree);
}
static PulseStatus PULSE_CALL subscribe(void *ctx, uint64_t page, PulseStringView command, PulseUiClickFn click, void *user, uint64_t *id) {
    Fixture *f = ctx;
    REQUIRE(page && page == f->page && click && user && id);
    for (unsigned i = 0; i < COMMAND_COUNT; ++i) {
        if (!same(command, commands[i])) continue;
        REQUIRE(!f->click[i]);
        if (f->fail_subscribe && i == 2) return PULSE_ERROR_STATE;
        f->click[i] = click; f->users[i] = user;
        ++f->subscribed; *id = ++f->next;
        return PULSE_OK;
    }
    return PULSE_ERROR_ARGUMENT;
}
static PulseStatus PULSE_CALL remove_page(void *ctx, uint64_t page) {
    Fixture *f = ctx;
    REQUIRE(page && page == f->page);
    if (f->fail_remove) return PULSE_ERROR_PERMISSION;
    memset(f->click, 0, sizeof(f->click));
    memset(f->users, 0, sizeof(f->users));
    f->subscribed = 0; f->page = 0;
    ++f->removed;
    return PULSE_OK;
}
static PulseStatus PULSE_CALL get_state(void *ctx, uint64_t page, PulseStringView key, char *buffer, uint32_t capacity, uint32_t *needed) {
    Fixture *f = ctx;
    REQUIRE(page == f->page && needed && buffer && capacity >= 5);
    if (same(key, "running.stop-id")) {
        memcpy(buffer, "1", 2); *needed = 1; return PULSE_OK;
    }
    REQUIRE(same(key, "library.query"));
    memcpy(buffer, "test", 5);
    *needed = 4;
    return PULSE_OK;
}
static PulseStatus model(Fixture *f, void *out, uint32_t size) {
    REQUIRE(out && size >= sizeof(PulseUiModelV1));
    PulseUiModelV1 t = {.size=sizeof(t), .version=1, .context=f, .create=create,
        .update=update, .subscribe_command=subscribe, .get_state=get_state, .close=remove_page};
    memcpy(out, &t, sizeof(t));
    return PULSE_OK;
}
static PulseStatus PULSE_CALL query_page(void *ctx, uint64_t page, PulseStringView name, uint32_t version, void *out, uint32_t size) {
    Fixture *f = ctx;
    REQUIRE(page && page == f->page && version == 1 && same(name, PULSE_UI_MODEL_INTERFACE));
    return model(f, out, size);
}
static PulseStatus request(Fixture *f, uint32_t operation, PulseResourcesCompletionFn callback, void *user, uint64_t *id) {
    REQUIRE(!f->pending && callback && user && id);
    f->pending = ++f->next;
    f->operation = operation;
    f->completion = callback; f->reply_user = user;
    *id = f->pending;
    return PULSE_OK;
}
static PulseStatus PULSE_CALL get(void *ctx, PulseResourcesCompletionFn callback, void *user, uint64_t *id) {
    return request(ctx, PULSE_RESOURCES_SETTINGS_GET, callback, user, id);
}
static PulseStatus PULSE_CALL set(void *ctx, PulseStringView key, PulseStringView value, uint32_t del, uint64_t version, PulseResourcesCompletionFn callback, void *user, uint64_t *id) {
    Fixture *f = ctx;
    REQUIRE(same(key, "market.downloadConcurrency") && !del && version == f->version);
    REQUIRE(value.data && value.length == 1 && value.data[0] >= '1' && value.data[0] <= '8');
    f->requested = value.data[0];
    return request(f, PULSE_RESOURCES_SETTINGS_SET, callback, user, id);
}
static PulseStatus PULSE_CALL cancel(void *ctx, uint64_t id) {
    Fixture *f = ctx;
    REQUIRE(id && id == f->pending);
    f->pending = 0; f->completion = NULL; f->reply_user = NULL;
    ++f->canceled;
    return PULSE_OK;
}
static uint32_t PULSE_CALL worker_cancelled(void *ctx) {
    Fixture *f = ctx;
    return InterlockedCompareExchange(&f->cancel_flag, 0, 0) != 0;
}
static DWORD WINAPI work_thread(void *ctx) {
    Fixture *f = ctx;
    PulseTaskContext task = {.id=f->task, .context=f, .cancelled=worker_cancelled};
    return f->task_work(f->task_user, &task);
}
static void observe_worker(Fixture *f) {
    if (!f->worker || WaitForSingleObject(f->worker, 0) != WAIT_OBJECT_0) return;
    DWORD code = 0;
    if (!GetExitCodeThread(f->worker, &code)) code = PULSE_TASK_FAILED;
    f->task_state = code;
}
static PulseStatus PULSE_CALL create_task(void *ctx, const PulseTaskDescriptor *desc, PulseTaskId *id) {
    Fixture *f = ctx;
    REQUIRE(desc && desc->size == sizeof(*desc) && desc->work && desc->user && id);
    if (f->bundled && f->worker && same(desc->type, "companion.library")) {
        REQUIRE(!f->aux_task);
        f->aux_task = ++f->next; f->aux_work = desc->work; f->aux_user = desc->user;
        *id = f->aux_task;
        return PULSE_OK;
    }
    REQUIRE(!f->task);
    int runtime = same(desc->type, "companion.runtime") || same(desc->type, "companion.session");
    REQUIRE(same(desc->type, "companion.library") || (f->bundled && runtime));
    f->task = ++f->next; f->task_state = PULSE_TASK_RUNNING;
    f->task_work = desc->work; f->task_user = desc->user;
    if (runtime) {
        InterlockedExchange(&f->cancel_flag, 0);
        f->worker = CreateThread(NULL, 0, work_thread, f, 0, NULL);
        if (!f->worker) { f->task = 0; return PULSE_ERROR_STATE; }
    }
    *id = f->task;
    return PULSE_OK;
}
static uint32_t PULSE_CALL cancelled(void *ctx) {
    (void)ctx;
    return 1;
}
static PulseStatus PULSE_CALL cancel_task(void *ctx, PulseTaskId id) {
    Fixture *f = ctx;
    if (id && id == f->aux_task) return PULSE_OK;
    REQUIRE(id && id == f->task && f->task_work);
    observe_worker(f);
    if (f->task_state != PULSE_TASK_RUNNING) return PULSE_ERROR_STATE;
    if (f->worker) {
        InterlockedExchange(&f->cancel_flag, 1);
        ++f->task_canceled;
        return PULSE_OK;
    }
    PulseTaskContext task = {.id=id, .context=f, .cancelled=cancelled};
    f->task_state = f->task_work(f->task_user, &task);
    REQUIRE(f->task_state == PULSE_TASK_CANCELLED);
    ++f->task_canceled;
    return PULSE_OK;
}
static PulseStatus PULSE_CALL get_task(void *ctx, PulseTaskId id, PulseTaskSnapshotFn callback, void *user) {
    Fixture *f = ctx;
    if (id && id == f->aux_task) {
        REQUIRE(callback && f->aux_work);
        PulseTaskContext task = {.id=id, .context=f, .cancelled=cancelled};
        PulseTaskState state = f->aux_work(f->aux_user, &task);
        REQUIRE(state == PULSE_TASK_CANCELLED);
        PulseTaskSnapshot snapshot = {.size=sizeof(snapshot), .id=id, .state=state};
        callback(user, &snapshot);
        return PULSE_OK;
    }
    REQUIRE(id && id == f->task && callback);
    observe_worker(f);
    PulseTaskSnapshot snapshot = {.size=sizeof(snapshot), .id=id, .state=f->task_state};
    callback(user, &snapshot);
    return PULSE_OK;
}
static PulseStatus PULSE_CALL release_task(void *ctx, PulseTaskId id) {
    Fixture *f = ctx;
    if (id && id == f->aux_task) {
        f->aux_task = 0; f->aux_work = NULL; f->aux_user = NULL;
        ++f->aux_released;
        return PULSE_OK;
    }
    REQUIRE(id && id == f->task);
    observe_worker(f);
    if (f->worker) {
        REQUIRE(f->task_state == PULSE_TASK_COMPLETED || f->task_state == PULSE_TASK_CANCELLED || f->task_state == PULSE_TASK_FAILED);
        REQUIRE(WaitForSingleObject(f->worker, 0) == WAIT_OBJECT_0 && CloseHandle(f->worker));
        f->worker = NULL;
    } else {
        REQUIRE(f->task_state == PULSE_TASK_CANCELLED);
    }
    f->task = 0; f->task_work = NULL; f->task_user = NULL;
    ++f->task_released;
    return PULSE_OK;
}
static PulseStatus PULSE_CALL post(void *ctx, PulseDispatchCallback callback, void *user, uint64_t *token) {
    Fixture *f = ctx;
    EnterCriticalSection(&f->dispatch_lock);
    if (f->queued) { LeaveCriticalSection(&f->dispatch_lock); return PULSE_ERROR_STATE; }
    f->queued = callback; f->queued_user = user;
    *token = ++f->dispatch_id;
    LeaveCriticalSection(&f->dispatch_lock);
    return PULSE_OK;
}
static PulseStatus PULSE_CALL cancel_dispatch(void *ctx, uint64_t token) {
    Fixture *f = ctx;
    EnterCriticalSection(&f->dispatch_lock);
    PulseStatus s = PULSE_ERROR_STATE;
    if (f->queued && token == f->dispatch_id) {
        f->queued = NULL; f->queued_user = NULL; s = PULSE_OK;
    }
    LeaveCriticalSection(&f->dispatch_lock);
    return s;
}
static void pump(Fixture *f) {
    EnterCriticalSection(&f->dispatch_lock);
    PulseDispatchCallback cb = f->queued; void *user = f->queued_user;
    f->queued = NULL; f->queued_user = NULL;
    LeaveCriticalSection(&f->dispatch_lock);
    if (cb) cb(user);
}
static PulseStatus PULSE_CALL selection(void *ctx, PulseContextSelectionFn callback, void *user) {
    (void)ctx;
    PulseContextSelectionEntry entry = {.size=sizeof(entry), .flags=PULSE_CONTEXT_ENTRY_DIRECTORY,
        .path=view("C:\\fixture\\cat"), .name=view("cat")};
    PulseContextSelectionSnapshot snapshot = {.size=sizeof(snapshot), .entries=&entry, .entry_count=1};
    REQUIRE(callback && user);
    callback(user, &snapshot);
    return PULSE_OK;
}
static PulseStatus PULSE_CALL show_dialog(void *ctx, const PulseDialogRequest *request,
    PulseDialogStateChanged changed, PulseDialogClosed closed, void *user, uint64_t *id) {
    Fixture *f = ctx;
    (void)changed;
    REQUIRE(!f->dialog && request && closed && user && id);
    REQUIRE(request->button_count == 2 && request->cancel_button == 1 && request->model);
    REQUIRE(request->model->state_count == 2 && request->model->states);
    if (f->dialogs_v2) {
        REQUIRE(request->model->command_count == 1 && request->model->commands);
        REQUIRE(same(request->model->commands[0], "browse"));
    } else {
        REQUIRE(request->model->command_count == 0);
    }
    REQUIRE(same(request->model->states[0].key, "import.path"));
    REQUIRE(same(request->model->states[0].value, "C:\\fixture\\cat"));
    REQUIRE(same(request->model->states[1].value, "cat"));
    f->dialog = ++f->next; *id = f->dialog;
    f->dialog_closed = closed; f->dialog_user = user;
    return PULSE_OK;
}
static PulseStatus PULSE_CALL set_dialog_states(void *ctx, uint64_t dialog, const PulseUiState *states, uint32_t count) {
    Fixture *f = ctx;
    REQUIRE(dialog && dialog == f->dialog && states && count == 2);
    REQUIRE(same(states[0].key, "import.path") && same(states[0].value, "C:\\fixture\\cat"));
    REQUIRE(same(states[1].key, "import.id") && same(states[1].value, "cat"));
    ++f->dialog_states_updated;
    return PULSE_OK;
}
static PulseStatus PULSE_CALL subscribe_dialog_command(void *ctx, uint64_t dialog, PulseStringView command, DialogCommandFn callback, void *user, uint64_t *id) {
    Fixture *f = ctx;
    REQUIRE(f->dialogs_v2 && dialog == f->dialog && same(command, "browse") && callback && user && id && !f->dialog_command);
    f->dialog_command = callback;
    f->dialog_command_user = user;
    f->dialog_command_subscription = ++f->next;
    *id = f->dialog_command_subscription;
    return PULSE_OK;
}
static PulseStatus PULSE_CALL unsubscribe_dialog_command(void *ctx, uint64_t id) {
    Fixture *f = ctx;
    REQUIRE(id && id == f->dialog_command_subscription);
    f->dialog_command = NULL;
    f->dialog_command_user = NULL;
    f->dialog_command_subscription = 0;
    return PULSE_OK;
}
static PulseStatus PULSE_CALL update_dialog_model(void *ctx, uint64_t dialog, const PulseUiModelTree *model) {
    Fixture *f = ctx;
    REQUIRE(dialog && dialog == f->dialog && model);
    return PULSE_OK;
}
static PulseStatus PULSE_CALL get_dialog_state(void *ctx, uint64_t dialog, PulseStringView key, char *buffer, uint32_t capacity, uint32_t *needed) {
    Fixture *f = ctx;
    REQUIRE(dialog && dialog == f->dialog && key.data && buffer && capacity && needed);
    *needed = 0;
    return PULSE_ERROR_UNAVAILABLE;
}
static PulseStatus PULSE_CALL close_dialog(void *ctx, uint64_t dialog) {
    Fixture *f = ctx;
    REQUIRE(dialog && dialog == f->dialog && f->dialog_closed);
    PulseDialogClosed callback = f->dialog_closed;
    void *user = f->dialog_user;
    f->dialog = 0; f->dialog_closed = NULL; f->dialog_user = NULL;
    callback(user, dialog, PULSE_OK, view("cancel"), NULL, 0);
    return PULSE_OK;
}
static PulseStatus PULSE_CALL pick_folders(void *ctx, const FolderRequest *request, FolderCallback callback, void *user, uint64_t *id) {
    Fixture *f = ctx;
    REQUIRE(!f->picker && request && request->size == sizeof(*request) && !request->flags && callback && user && id);
    f->picker = ++f->next; *id = f->picker;
    f->picker_callback = callback; f->picker_user = user;
    return PULSE_OK;
}
static PulseStatus picker_reply(Fixture *f, uint32_t outcome) {
    REQUIRE(f->picker && f->picker_callback);
    PulseStringView path = view("C:\\fixture\\cat");
    FolderResult reply = {.size=sizeof(reply), .outcome=outcome, .request_id=f->picker,
        .path_count=outcome == 0 ? 1u : 0u, .paths=outcome == 0 ? &path : NULL};
    FolderCallback callback = f->picker_callback;
    void *user = f->picker_user;
    f->picker = 0; f->picker_callback = NULL; f->picker_user = NULL;
    callback(user, &reply);
    return PULSE_OK;
}
static PulseStatus PULSE_CALL cancel_picker(void *ctx, uint64_t id) {
    Fixture *f = ctx;
    REQUIRE(id && id == f->picker);
    return picker_reply(f, 1);
}
static PulseStatus PULSE_CALL query(void *ctx, PulseStringView name, uint32_t version, void *out, uint32_t size) {
    Fixture *f = ctx;
    REQUIRE(out);
    if (same(name, PULSE_SETTINGS_PAGES_INTERFACE_NAME)) {
        if (f->fallback) return PULSE_ERROR_UNAVAILABLE;
        REQUIRE(size >= sizeof(PulseSettingsPagesV1));
        PulseSettingsPagesV1 t = {.size=sizeof(t), .version=1, .context=f,
            .create=create, .query=query_page, .remove=remove_page};
        memcpy(out, &t, sizeof(t)); return PULSE_OK;
    }
    if (same(name, PULSE_UI_MODEL_INTERFACE) && f->fallback) return model(f, out, size);
    if (same(name, PULSE_DISPATCH_INTERFACE) && f->auto_dispatch) {
        REQUIRE(size >= sizeof(PulseDispatchV1));
        PulseDispatchV1 t = {.size=sizeof(t), .version=1, .context=f, .post=post, .cancel=cancel_dispatch};
        memcpy(out, &t, sizeof(t)); return PULSE_OK;
    }
    if (f->bundled && same(name, "pulse.pickers")) {
        REQUIRE(size >= sizeof(FolderTable));
        FolderTable t = {.size=sizeof(t), .version=1, .context=f, .pick_folders=pick_folders, .cancel=cancel_picker};
        memcpy(out, &t, sizeof(t)); return PULSE_OK;
    }
    if (same(name, PULSE_DIALOGS_INTERFACE_NAME)) {
        if (version == 2) {
            if (!f->bundled || !f->dialogs_v2) return PULSE_ERROR_UNAVAILABLE;
            REQUIRE(size >= sizeof(DialogsV2Compat));
            DialogsV2Compat t = {.size=sizeof(t), .version=2, .context=f, .show=show_dialog, .set_states=set_dialog_states, .close=close_dialog, .subscribe_command=subscribe_dialog_command, .unsubscribe_command=unsubscribe_dialog_command, .update_model=update_dialog_model, .get_state=get_dialog_state};
            memcpy(out, &t, sizeof(t)); return PULSE_OK;
        }
        if (version == 1) {
            if (!f->bundled) return PULSE_ERROR_UNAVAILABLE;
            REQUIRE(size >= sizeof(PulseDialogsV1));
            PulseDialogsV1 t = {.size=sizeof(t), .version=1, .context=f, .show=show_dialog, .close=close_dialog};
            memcpy(out, &t, sizeof(t)); return PULSE_OK;
        }
        return PULSE_ERROR_UNAVAILABLE;
    }
    REQUIRE(version == 1);
    if (f->bundled && same(name, PULSE_CONTEXT_INTERFACE_NAME)) {
        REQUIRE(size >= sizeof(PulseContextV1));
        PulseContextV1 t = {.size=sizeof(t), .version=1, .context=f, .get_selection=selection};
        memcpy(out, &t, sizeof(t)); return PULSE_OK;
    }
    if (same(name, PULSE_TASKS_INTERFACE_NAME)) {
        REQUIRE(size >= sizeof(PulseTasksV1));
        PulseTasksV1 t = {.size=sizeof(t), .version=1, .context=f,
            .create=create_task, .cancel=cancel_task, .get=get_task, .release=release_task};
        memcpy(out, &t, sizeof(t)); return PULSE_OK;
    }
    if (same(name, PULSE_RESOURCES_INTERFACE_NAME)) {
        REQUIRE(size >= sizeof(PulseResourcesV1));
        PulseResourcesV1 t = {.size=sizeof(t), .version=1, .context=f,
            .settings_get=get, .settings_set=set, .cancel_request=cancel};
        memcpy(out, &t, sizeof(t)); return PULSE_OK;
    }
    return PULSE_ERROR_UNAVAILABLE;
}

static int deliver(Fixture *f, PulseStatus status, int wrong_operation) {
    CHECK(f->pending && f->completion);
    if (status == PULSE_OK && f->operation == PULSE_RESOURCES_SETTINGS_SET && !wrong_operation) {
        f->saved = f->requested; f->saved_present = 1; ++f->version;
    }
    PulseSetting setting = {.key=view("market.downloadConcurrency"), .value={&f->saved, 1}};
    PulseResourcesReply reply = {.size=sizeof(reply), .operation=wrong_operation ? PULSE_RESOURCES_STAT : f->operation,
        .request_id=f->pending, .status=status,
        .settings={.version=f->version, .values=f->saved_present ? &setting : NULL, .count=f->saved_present ? 1u : 0u}};
    PulseResourcesCompletionFn callback = f->completion;
    void *user = f->reply_user;
    f->pending = 0; f->completion = NULL; f->reply_user = NULL;
    callback(user, &reply);
    return 0;
}
static int click(Fixture *f, unsigned i) {
    CHECK(i < COMMAND_COUNT && f->click[i] && f->page);
    f->click[i](f->users[i], f->page, view(commands[i]));
    return 0;
}

static int cycle(PulsePluginEntryV1Fn entry, int fallback) {
    Fixture f = {.fallback=fallback, .version=3};
    PulseHostV1 host = {.size=sizeof(host), .version=1, .context=&f, .query_interface=query};
    PulsePluginV1 out = {.size=sizeof(out), .version=1};
    CHECK(entry(&host, &out) == PULSE_OK && out.instance && out.activate && out.deactivate && out.destroy);
    CHECK(out.activate(out.instance) == PULSE_OK && f.created == 1 && f.subscribed == COMMAND_COUNT && f.pending && f.task);
    CHECK(click(&f, 3) == 0 && f.global && !f.enabled_more);
    CHECK(deliver(&f, PULSE_OK, 0) == 0 && f.enabled_more && f.enabled_less);
    CHECK(click(&f, 6) == 0 && f.pending && f.requested == '5' && !f.enabled_more);
    CHECK(click(&f, 6) == 0 && f.requested == '5');
    CHECK(deliver(&f, PULSE_OK, 0) == 0 && f.saved == '5' && f.version == 4 && f.enabled_more);
    CHECK(click(&f, 0) == 0 && !f.global);
    CHECK(click(&f, 7) == 0 && f.task);
    CHECK(click(&f, 8) == 0 && f.task && !f.task_released);
    CHECK(click(&f, 6) == 0 && !f.pending);
    CHECK(click(&f, 3) == 0 && click(&f, 6) == 0 && f.requested == '6');
    CHECK(deliver(&f, PULSE_ERROR_STATE, 0) == 0 && !f.enabled_more && f.saved == '5');
    CHECK(click(&f, 4) == 0 && deliver(&f, PULSE_OK, 1) == 0 && !f.enabled_more);
    CHECK(click(&f, 4) == 0 && deliver(&f, PULSE_OK, 0) == 0 && f.enabled_more);
    CHECK(click(&f, 4) == 0 && f.pending);
    f.fail_remove = 1;
    out.deactivate(out.instance);
    CHECK(!f.pending && f.canceled == 1 && f.page && f.subscribed == COMMAND_COUNT);
    CHECK(f.task_canceled == 1 && f.task_state == PULSE_TASK_CANCELLED);
    CHECK(click(&f, 6) == 0 && !f.pending); /* inactive callbacks cannot save */
    f.fail_remove = 0;
    out.deactivate(out.instance);
    CHECK(!f.page && !f.subscribed && f.removed == 1);
    CHECK(out.activate(out.instance) == PULSE_OK && deliver(&f, PULSE_OK, 0) == 0);
    CHECK(!f.task && f.task_released == 1);
    CHECK(click(&f, 3) == 0 && click(&f, 5) == 0 && f.requested == '4');
    CHECK(deliver(&f, PULSE_OK, 0) == 0 && f.saved == '4');
    out.destroy(out.instance);
    CHECK(!f.page && !f.pending && !f.subscribed && f.removed == 2);
    return 0;
}

static int automatic(PulsePluginEntryV1Fn entry) {
    Fixture f = {.auto_dispatch=1};
    InitializeCriticalSection(&f.dispatch_lock);
    PulseHostV1 host = {.size=sizeof(host), .version=1, .context=&f, .query_interface=query};
    PulsePluginV1 out = {.size=sizeof(out), .version=1};
    CHECK(entry(&host, &out) == PULSE_OK);
    CHECK(out.activate(out.instance) == PULSE_OK && f.task);
    /* Simulate terminal cancellation without reading real user files. The
       timer must collect automatically, without invoking the poll command. */
    CHECK(cancel_task(&f, f.task) == PULSE_OK);
    for (unsigned i = 0; i < 100 && f.task; ++i) { Sleep(20); pump(&f); }
    CHECK(!f.task && f.task_released == 1);
    CHECK(click(&f, 7) == 0 && f.task);
    out.deactivate(out.instance);
    out.destroy(out.instance);
    pump(&f);
    CHECK(!f.queued);
    DeleteCriticalSection(&f.dispatch_lock);
    return 0;
}
static int partial(PulsePluginEntryV1Fn entry) {
    Fixture f = {.fail_subscribe=1};
    PulseHostV1 host = {.size=sizeof(host), .version=1, .context=&f, .query_interface=query};
    PulsePluginV1 out = {.size=sizeof(out), .version=1};
    CHECK(entry(&host, &out) == PULSE_OK);
    CHECK(out.activate(out.instance) != PULSE_OK && f.created == 1 && f.removed == 1);
    CHECK(!f.page && !f.pending && !f.subscribed);
    out.deactivate(out.instance); out.destroy(out.instance);
    return 0;
}
static int picker_compat_session(PulsePluginEntryV1Fn entry, int use_v2) {
    Fixture f = {.auto_dispatch=1, .bundled=1, .dialogs_v2=use_v2};
    InitializeCriticalSection(&f.dispatch_lock);
    PulseHostV1 host = {.size=sizeof(host), .version=1, .context=&f, .query_interface=query};
    PulsePluginV1 out = {.size=sizeof(out), .version=1};
    CHECK(entry(&host, &out) == PULSE_OK);
    CHECK(out.activate(out.instance) == PULSE_OK && f.task);
    CHECK(cancel_task(&f, f.task) == PULSE_OK);
    for (unsigned i = 0; i < 100 && f.task; ++i) { Sleep(20); pump(&f); }
    CHECK(!f.task);
    if (use_v2) {
        CHECK(click(&f, 19) == 0 && f.dialog && f.dialog_command && f.dialog_command_subscription);
        f.dialog_command(f.dialog_command_user, f.dialog, view("browse"));
        CHECK(f.picker && f.dialog);
        CHECK(picker_reply(&f, 1) == PULSE_OK && !f.picker && f.dialog && f.dialog_states_updated == 0);
        f.dialog_command(f.dialog_command_user, f.dialog, view("browse"));
        CHECK(f.picker && f.dialog);
        CHECK(picker_reply(&f, 0) == PULSE_OK && !f.picker && f.dialog && f.dialog_states_updated == 1);
    } else {
        CHECK(click(&f, 21) == 0 && f.picker && !f.dialog);
        CHECK(picker_reply(&f, 1) == PULSE_OK && !f.picker && !f.dialog);
        CHECK(click(&f, 21) == 0 && f.picker);
        CHECK(picker_reply(&f, 0) == PULSE_OK && !f.picker && f.dialog);
    }
    CHECK(close_dialog(&f, f.dialog) == PULSE_OK && !f.dialog && !f.dialog_command_subscription);
    out.deactivate(out.instance);
    out.destroy(out.instance);
    CHECK(!f.page && !f.pending && !f.worker && !f.queued && !f.picker);
    DeleteCriticalSection(&f.dispatch_lock);
    return 0;
}

static int bundled_session(PulsePluginEntryV1Fn entry) {
    Fixture f = {.auto_dispatch=1, .bundled=1};
    InitializeCriticalSection(&f.dispatch_lock);
    PulseHostV1 host = {.size=sizeof(host), .version=1, .context=&f, .query_interface=query};
    PulsePluginV1 out = {.size=sizeof(out), .version=1};
    CHECK(entry(&host, &out) == PULSE_OK);
    CHECK(out.activate(out.instance) == PULSE_OK && f.task);
    CHECK(cancel_task(&f, f.task) == PULSE_OK);
    for (unsigned i = 0; i < 100 && f.task; ++i) { Sleep(20); pump(&f); }
    CHECK(!f.task);
    CHECK(click(&f, 19) == 0 && f.dialog && !f.task);
    CHECK(close_dialog(&f, f.dialog) == PULSE_OK && !f.dialog && !f.task);
    CHECK(click(&f, 21) == 0 && f.picker && !f.dialog && !f.task);
    CHECK(picker_reply(&f, 1) == PULSE_OK && !f.picker && !f.dialog && !f.task);
    CHECK(click(&f, 21) == 0 && f.picker);
    CHECK(picker_reply(&f, 0) == PULSE_OK && !f.picker && f.dialog && !f.task);
    CHECK(close_dialog(&f, f.dialog) == PULSE_OK && !f.dialog && !f.task);
    CHECK(click(&f, 1) == 0 && f.task && f.worker);
    for (unsigned i = 0; i < 750 && f.task; ++i) { Sleep(20); pump(&f); }
    CHECK(!f.task && f.task_state == PULSE_TASK_COMPLETED && f.start_enabled);
    for (unsigned cycle = 0; cycle < 2; ++cycle) {
        CHECK(click(&f, 12) == 0 && f.task && f.worker && !f.start_enabled);
        for (unsigned i = 0; i < 900 && f.task && !f.first_frame; ++i) { Sleep(20); pump(&f); }
        CHECK(f.task && f.first_frame && f.stop_enabled && f.start_enabled);
        if (!cycle) {
            CHECK(click(&f, 12) == 0 && f.task && !f.start_enabled);
            for (unsigned i = 0; i < 900 && f.task && !f.two_ready; ++i) { Sleep(20); pump(&f); }
            CHECK(f.task && f.two_ready && f.stop_enabled);
            const uint64_t session = f.task;
            CHECK(click(&f, 0) == 0 && f.aux_task && f.task == session);
            for (unsigned i = 0; i < 100 && f.aux_task; ++i) { Sleep(20); pump(&f); }
            CHECK(!f.aux_task && f.aux_released == 1 && f.task == session);
            CHECK(click(&f, 1) == 0 && f.first_frame && f.stop_enabled);
            CHECK(f.running_rows == 2 && click(&f, 14) == 0);
            for (unsigned i = 0; i < 400 && f.task && !f.only_second; ++i) { Sleep(20); pump(&f); }
            CHECK(f.task && f.only_second && f.stop_enabled);
            CHECK(click(&f, 13) == 0 && !f.stop_enabled);
            for (unsigned i = 0; i < 400 && f.task; ++i) { Sleep(20); pump(&f); }
            CHECK(!f.task && f.task_state == PULSE_TASK_CANCELLED && f.start_enabled);
        } else {
            // Match the SDK destroy contract: cancellation first, wait for
            // the host-owned worker to return, then destroy plugin userdata.
            out.deactivate(out.instance);
            CHECK(f.worker && WaitForSingleObject(f.worker, 8000) == WAIT_OBJECT_0);
            observe_worker(&f);
            CHECK(f.task_state == PULSE_TASK_CANCELLED);
        }
    }
    out.destroy(out.instance);
    CHECK(release_task(&f, f.task) == PULSE_OK);
    pump(&f);
    CHECK(!f.page && !f.pending && !f.worker && !f.queued);
    DeleteCriticalSection(&f.dispatch_lock);
    return 0;
}
int main(int argc, char **argv) {
    CHECK(argc == 2 || (argc == 3 && !strcmp(argv[2], "--bundled")));
    if (argc == 3) {
        HMODULE lib = LoadLibraryExA(argv[1], NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        CHECK(lib);
        PulsePluginEntryV1Fn entry = (PulsePluginEntryV1Fn)GetProcAddress(lib, "PulsePluginEntryV1");
        CHECK(entry && picker_compat_session(entry, 1) == 0 && picker_compat_session(entry, 0) == 0 && bundled_session(entry) == 0);
        CHECK(FreeLibrary(lib));
        puts("Bundled Companion ABI: actual first-frame, stop, restart, deactivate verified");
        return 0;
    }
    for (unsigned i = 0; i < 8; ++i) {
        HMODULE lib = LoadLibraryExA(argv[1], NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        CHECK(lib);
        PulsePluginSdkPreviewFn preview = (PulsePluginSdkPreviewFn)GetProcAddress(lib, "PulsePluginSdkPreview");
        PulsePluginEntryV1Fn entry = (PulsePluginEntryV1Fn)GetProcAddress(lib, "PulsePluginEntryV1");
        CHECK(preview && entry && preview() == PULSE_SDK_PREVIEW);
        CHECK(cycle(entry, 0) == 0 && cycle(entry, 1) == 0 && partial(entry) == 0 && automatic(entry) == 0);
        CHECK(FreeLibrary(lib));
    }
    puts("Companion C ABI: 16 complete lifecycle scenarios, 8 partial activations and 8 automatic polling scenarios passed");
    return 0;
}
