/* Independent pinned C ABI fixture; loads the actual production-built DLL.
 * Not a renderer or real Pulse host. Replies arrive only after API return. */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include "pulse/settings_pages.h"
#include "pulse/resources.h"
#include "pulse/tasks.h"

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "ABI fixture line %d: %s\n", __LINE__, #x); return PULSE_ERROR_ARGUMENT; } } while (0)

static const char *commands[] = {
    "companion.library", "companion.running", "companion.market", "companion.global",
    "companion.settings.refresh", "companion.download.less", "companion.download.more",
    "companion.library.reload", "companion.library.poll", "companion.library.previous", "companion.library.next", "companion.library.favorites"
};
typedef struct {
    uint64_t page, next, pending, version;
    unsigned created, removed, canceled, updates, subscribed, fail_subscribe;
    int fallback, fail_remove, enabled_more, enabled_less, global, saved_present;
    char saved, requested;
    uint32_t operation;
    PulseUiClickFn click[12];
    void *users[12];
    uint64_t task;
    unsigned task_released, task_canceled;
    PulseTaskState task_state;
    PulseTaskWorkFn task_work;
    void *task_user;
    PulseResourcesCompletionFn completion;
    void *reply_user;
} Fixture;

static PulseStringView view(const char *s) { return (PulseStringView){s, (uint32_t)strlen(s)}; }
static int same(PulseStringView s, const char *text) {
    size_t n = strlen(text);
    return s.data && s.length == n && memcmp(s.data, text, n) == 0;
}

static PulseStatus inspect(Fixture *f, const PulseUiModelTree *t) {
    REQUIRE(t && t->size == sizeof(*t) && t->root && t->command_count == 12 && t->commands);
    for (unsigned i = 0; i < 12; ++i) REQUIRE(same(t->commands[i], commands[i]));
    const PulseUiModelNode *root = t->root;
    REQUIRE(root->size == sizeof(*root) && root->type == PULSE_UI_MODEL_STACK);
    REQUIRE(root->children.present && root->children.data && (root->children.count == 3 || root->children.count == 5 || root->children.count == 7));
    const PulseUiModelNode *nav = root->children.data;
    REQUIRE(nav->children.present && nav->children.count == 4 && nav->children.data);
    for (unsigned i = 0; i < 4; ++i) {
        const PulseUiModelNode *n = nav->children.data + i;
        REQUIRE(n->size == sizeof(*n) && n->type == PULSE_UI_MODEL_BUTTON && n->command.present && same(n->command.value, commands[i]));
    }
    f->global = root->children.count == 7 && same(root->children.data[4].command.value, commands[4]);
    f->enabled_less = f->enabled_more = 0;
    if (f->global) {
        const PulseUiModelNode *less = root->children.data + 5, *more = less + 1;
        REQUIRE(less->enabled.present && more->enabled.present);
        REQUIRE(same(less->command.value, commands[5]) && same(more->command.value, commands[6]));
        f->enabled_less = (int)less->enabled.value;
        f->enabled_more = (int)more->enabled.value;
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
    for (unsigned i = 0; i < 12; ++i) {
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
    REQUIRE(page == f->page && same(key, "library.query") && needed && buffer && capacity >= 5);
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
static PulseStatus PULSE_CALL create_task(void *ctx, const PulseTaskDescriptor *desc, PulseTaskId *id) {
    Fixture *f = ctx;
    REQUIRE(!f->task && desc && desc->size == sizeof(*desc) && desc->work && desc->user && id);
    REQUIRE(same(desc->type, "companion.library"));
    f->task = ++f->next; f->task_state = PULSE_TASK_RUNNING;
    f->task_work = desc->work; f->task_user = desc->user;
    *id = f->task;
    return PULSE_OK;
}
static uint32_t PULSE_CALL cancelled(void *ctx) {
    (void)ctx;
    return 1;
}
static PulseStatus PULSE_CALL cancel_task(void *ctx, PulseTaskId id) {
    Fixture *f = ctx;
    REQUIRE(id && id == f->task && f->task_work);
    if (f->task_state != PULSE_TASK_RUNNING) return PULSE_ERROR_STATE;
    PulseTaskContext task = {.id=id, .context=f, .cancelled=cancelled};
    f->task_state = f->task_work(f->task_user, &task);
    REQUIRE(f->task_state == PULSE_TASK_CANCELLED);
    ++f->task_canceled;
    return PULSE_OK;
}
static PulseStatus PULSE_CALL get_task(void *ctx, PulseTaskId id, PulseTaskSnapshotFn callback, void *user) {
    Fixture *f = ctx;
    REQUIRE(id && id == f->task && callback);
    PulseTaskSnapshot snapshot = {.size=sizeof(snapshot), .id=id, .state=f->task_state};
    callback(user, &snapshot);
    return PULSE_OK;
}
static PulseStatus PULSE_CALL release_task(void *ctx, PulseTaskId id) {
    Fixture *f = ctx;
    REQUIRE(id && id == f->task && f->task_state == PULSE_TASK_CANCELLED);
    f->task = 0; f->task_work = NULL; f->task_user = NULL;
    ++f->task_released;
    return PULSE_OK;
}
static PulseStatus PULSE_CALL query(void *ctx, PulseStringView name, uint32_t version, void *out, uint32_t size) {
    Fixture *f = ctx;
    REQUIRE(version == 1 && out);
    if (same(name, PULSE_SETTINGS_PAGES_INTERFACE_NAME)) {
        if (f->fallback) return PULSE_ERROR_UNAVAILABLE;
        REQUIRE(size >= sizeof(PulseSettingsPagesV1));
        PulseSettingsPagesV1 t = {.size=sizeof(t), .version=1, .context=f,
            .create=create, .query=query_page, .remove=remove_page};
        memcpy(out, &t, sizeof(t)); return PULSE_OK;
    }
    if (same(name, PULSE_UI_MODEL_INTERFACE) && f->fallback) return model(f, out, size);
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
    CHECK(i < 12 && f->click[i] && f->page);
    f->click[i](f->users[i], f->page, view(commands[i]));
    return 0;
}

static int cycle(PulsePluginEntryV1Fn entry, int fallback) {
    Fixture f = {.fallback=fallback, .version=3};
    PulseHostV1 host = {.size=sizeof(host), .version=1, .context=&f, .query_interface=query};
    PulsePluginV1 out = {.size=sizeof(out), .version=1};
    CHECK(entry(&host, &out) == PULSE_OK && out.instance && out.activate && out.deactivate && out.destroy);
    CHECK(out.activate(out.instance) == PULSE_OK && f.created == 1 && f.subscribed == 12 && f.pending);
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
    CHECK(!f.pending && f.canceled == 1 && f.page && f.subscribed == 12);
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
int main(int argc, char **argv) {
    CHECK(argc == 2);
    for (unsigned i = 0; i < 8; ++i) {
        HMODULE lib = LoadLibraryExA(argv[1], NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        CHECK(lib);
        PulsePluginSdkPreviewFn preview = (PulsePluginSdkPreviewFn)GetProcAddress(lib, "PulsePluginSdkPreview");
        PulsePluginEntryV1Fn entry = (PulsePluginEntryV1Fn)GetProcAddress(lib, "PulsePluginEntryV1");
        CHECK(preview && entry && preview() == PULSE_SDK_PREVIEW);
        CHECK(cycle(entry, 0) == 0 && cycle(entry, 1) == 0 && partial(entry) == 0);
        CHECK(FreeLibrary(lib));
    }
    puts("Companion C ABI: 16 complete lifecycle scenarios and 8 partial activation scenarios passed");
    return 0;
}
