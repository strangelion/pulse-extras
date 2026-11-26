/* Independent C-side layout and real DLL lifecycle check, not the Pulse host. */
#include <stddef.h>
#include <stdio.h>
#include <windows.h>
#include "pulse/abi.h"
#include "pulse/context.h"
#include "pulse/commands.h"
#include "pulse/tasks.h"
#include "pulse/ui_model.h"
#include <string.h>

_Static_assert(PULSE_SDK_PREVIEW == 3, "preview");
_Static_assert(sizeof(PulseStringView) == 16, "string size");
_Static_assert(_Alignof(PulseStringView) == 8, "string alignment");
_Static_assert(offsetof(PulseStringView, length) == 8, "string length");
_Static_assert(sizeof(PulseHostV1) == 24, "host size");
_Static_assert(_Alignof(PulseHostV1) == 8, "host alignment");
_Static_assert(offsetof(PulseHostV1, context) == 8, "host context");
_Static_assert(offsetof(PulseHostV1, query_interface) == 16, "host query");
_Static_assert(sizeof(PulsePluginV1) == 40, "plugin size");
_Static_assert(_Alignof(PulsePluginV1) == 8, "plugin alignment");
_Static_assert(offsetof(PulsePluginV1, instance) == 8, "instance");
_Static_assert(offsetof(PulsePluginV1, activate) == 16, "activate");
_Static_assert(offsetof(PulsePluginV1, deactivate) == 24, "deactivate");
_Static_assert(offsetof(PulsePluginV1, destroy) == 32, "destroy");

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)

static PulseStatus unavailable(void *context, PulseStringView name, uint32_t version, void *out, uint32_t size) {
    (void)context; (void)name; (void)version; (void)out; (void)size;
    return PULSE_ERROR_UNAVAILABLE;
}

/* Independent public-header mock of the host's owner-thread lifecycle.
   This is not the actual Pulse process or a proof of its newer binary. */
typedef struct {
    unsigned panel_open, stopped, fail_get, fail_close, unexpected_tasks;
    unsigned created, closed, updates, subscribed, unsubscribed;
    PulseUiClickFn clicks[3];
    void *click_users[3];
    PulseContextChangeFn navigation;
    void *navigation_user;
    uint64_t next_panel, next_subscription, panel, navigation_id;
    unsigned close_attempts;
    unsigned menu_registered, menu_unregistered;
    PulseCommandId menu_id;
    PulseCommandFn menu;
    void *menu_user;
} LockedHost;

static PulseStringView sv(const char *value) {
    PulseStringView result = { value, (uint32_t)strlen(value) };
    return result;
}

static int equals(PulseStringView value, const char *text) {
    return value.data && value.length == strlen(text) &&
        memcmp(value.data, text, value.length) == 0;
}

static const char *const commands[] = { "vcs.refresh", "vcs.cancel", "vcs.check" };

static int tree_valid(const PulseUiModelTree *tree) {
    if (!tree || tree->size != sizeof(*tree) || !tree->root ||
        tree->command_count != 3 || !tree->commands)
        return 0;
    for (unsigned i = 0; i < 3; ++i)
        if (!equals(tree->commands[i], commands[i])) return 0;
    const PulseUiModelNode *root = tree->root;
    if (!root->children.present || !root->children.data) return 0;
    int locked = 0, check = 0;
    for (uint32_t i = 0; i < root->children.count; ++i) {
        const PulseUiModelNode *node = &root->children.data[i];
        if (equals(node->id, "vcs.approval") && node->text.present &&
            equals(node->text.value, "Execution locked: production approval unavailable"))
            locked = 1;
        if (node->command.present) {
            if (!equals(node->command.value, "vcs.check")) return 0;
            check = 1;
        }
    }
    return locked && check;
}

static PulseStatus PULSE_CALL panel_create(void *context, PulseStringView title,
    const PulseUiModelTree *tree, uint64_t *panel) {
    LockedHost *host = context;
    if (host->stopped || host->panel_open) return PULSE_ERROR_STATE;
    if (!panel || !equals(title, "VCS") || !tree_valid(tree)) return PULSE_ERROR_ARGUMENT;
    host->panel_open = 1;
    host->panel = ++host->next_panel;
    ++host->created;
    *panel = host->panel;
    return PULSE_OK;
}

static PulseStatus PULSE_CALL panel_update(void *context, uint64_t panel, const PulseUiModelTree *tree) {
    LockedHost *host = context;
    if (host->stopped || !host->panel_open || host->panel != panel) return PULSE_ERROR_STATE;
    if (!tree_valid(tree)) return PULSE_ERROR_ARGUMENT;
    ++host->updates;
    return PULSE_OK;
}

static PulseStatus PULSE_CALL panel_subscribe(void *context, uint64_t panel, PulseStringView command,
    PulseUiClickFn callback, void *user, uint64_t *subscription) {
    LockedHost *host = context;
    if (host->stopped || !host->panel_open || panel != host->panel) return PULSE_ERROR_STATE;
    if (!callback || !user || !subscription) return PULSE_ERROR_ARGUMENT;
    for (unsigned i = 0; i < 3; ++i) {
        if (!equals(command, commands[i])) continue;
        if (host->clicks[i]) return PULSE_ERROR_STATE;
        host->clicks[i] = callback;
        host->click_users[i] = user;
        *subscription = ++host->next_subscription;
        ++host->subscribed;
        return PULSE_OK;
    }
    return PULSE_ERROR_ARGUMENT;
}

static void forget_panel(LockedHost *host) {
    if (host->panel_open) ++host->closed;
    host->panel_open = 0;
    memset(host->clicks, 0, sizeof(host->clicks));
    memset(host->click_users, 0, sizeof(host->click_users));
}

static PulseStatus PULSE_CALL panel_close(void *context, uint64_t panel) {
    LockedHost *host = context;
    ++host->close_attempts;
    if (host->stopped || !host->panel_open || panel != host->panel) return PULSE_ERROR_STATE;
    if (host->fail_close) return PULSE_ERROR_PERMISSION;
    forget_panel(host);
    return PULSE_OK;
}

static PulseStatus PULSE_CALL panel_unsubscribe(void *context, uint64_t token) {
    (void)context; (void)token;
    return PULSE_ERROR_STATE; /* close synchronously invalidates every command */
}

static void emit_navigation(PulseContextChangeFn callback, void *user, const char *path, unsigned loading) {
    PulseContextSnapshot snapshot = {0};
    snapshot.size = sizeof(snapshot);
    snapshot.directory = sv(path);
    snapshot.loading = loading;
    callback(user, &snapshot);
}

static PulseStatus PULSE_CALL context_get(void *context, PulseContextChangeFn callback, void *user) {
    LockedHost *host = context;
    if (host->stopped) return PULSE_ERROR_STATE;
    if (host->fail_get) return PULSE_ERROR_PERMISSION;
    if (!callback || !user) return PULSE_ERROR_ARGUMENT;
    emit_navigation(callback, user, "C:\\fixture", 0);
    return PULSE_OK;
}

static PulseStatus PULSE_CALL context_subscribe(void *context, PulseContextChangeFn callback,
    void *user, PulseContextSubscriptionId *id) {
    LockedHost *host = context;
    if (host->stopped || host->navigation) return PULSE_ERROR_STATE;
    if (!callback || !user || !id) return PULSE_ERROR_ARGUMENT;
    host->navigation = callback;
    host->navigation_user = user;
    host->navigation_id = ++host->next_subscription;
    *id = host->navigation_id;
    return PULSE_OK;
}

static void forget_navigation(LockedHost *host) {
    if (host->navigation) ++host->unsubscribed;
    host->navigation = NULL;
    host->navigation_user = NULL;
}

static PulseStatus PULSE_CALL context_unsubscribe(void *context, PulseContextSubscriptionId id) {
    LockedHost *host = context;
    if (host->stopped || !host->navigation || id != host->navigation_id) return PULSE_ERROR_STATE;
    forget_navigation(host);
    return PULSE_OK;
}

static PulseStatus PULSE_CALL task_create(void *context, const PulseTaskDescriptor *descriptor, PulseTaskId *id) {
    (void)descriptor; (void)id;
    ++((LockedHost *)context)->unexpected_tasks;
    return PULSE_ERROR_PERMISSION;
}

static PulseStatus PULSE_CALL task_cancel(void *context, PulseTaskId id) {
    (void)id;
    ++((LockedHost *)context)->unexpected_tasks;
    return PULSE_ERROR_STATE;
}

static PulseStatus PULSE_CALL task_get(void *context, PulseTaskId id, PulseTaskSnapshotFn callback, void *user) {
    (void)id; (void)callback; (void)user;
    ++((LockedHost *)context)->unexpected_tasks;
    return PULSE_ERROR_STATE;
}

static PulseStatus PULSE_CALL register_menu(void *context, const PulseCommandDescriptor *descriptor, PulseCommandId *id) {
    LockedHost *host = context;
    if (host->stopped || host->menu || !descriptor || !id) return PULSE_ERROR_STATE;
    if (descriptor->size != sizeof(*descriptor) || !equals(descriptor->id, "vcs.open-current") ||
        !descriptor->title.data || !descriptor->title.length ||
        descriptor->kinds != (PULSE_COMMAND_FILES | PULSE_COMMAND_DIRECTORIES) ||
        descriptor->min_selection != 0 || descriptor->max_selection != 4096 ||
        descriptor->virtual_key || descriptor->modifiers || !descriptor->invoke || !descriptor->user)
        return PULSE_ERROR_ARGUMENT;
    host->menu = descriptor->invoke;
    host->menu_user = descriptor->user;
    host->menu_id = 1234;
    *id = host->menu_id;
    ++host->menu_registered;
    return PULSE_OK;
}
static PulseStatus PULSE_CALL unregister_menu(void *context, PulseCommandId id) {
    LockedHost *host = context;
    if (host->stopped || !host->menu || id != host->menu_id) return PULSE_ERROR_STATE;
    host->menu = NULL;
    host->menu_user = NULL;
    ++host->menu_unregistered;
    return PULSE_OK;
}

static PulseStatus PULSE_CALL query_locked(void *context, PulseStringView name, uint32_t version, void *out, uint32_t size) {
    LockedHost *host = context;
    if (host->stopped) return PULSE_ERROR_STATE;
    if (!out || version != 1) return PULSE_ERROR_ABI;
    if (equals(name, PULSE_COMMANDS_INTERFACE_NAME)) {
        const PulseCommandsV1 table = { sizeof(table), 1, host, register_menu, unregister_menu };
        if (size < sizeof(table)) return PULSE_ERROR_ABI;
        memcpy(out, &table, sizeof(table));
        return PULSE_OK;
    }
    if (equals(name, PULSE_TASKS_INTERFACE_NAME)) {
        const PulseTasksV1 table = { sizeof(table), 1, host, task_create, task_cancel, task_get, task_cancel };
        if (size < sizeof(table)) return PULSE_ERROR_ABI;
        memcpy(out, &table, sizeof(table));
        return PULSE_OK;
    }
    if (equals(name, PULSE_CONTEXT_INTERFACE_NAME)) {
        const PulseContextV1 table = { sizeof(table), 1, host, context_get, context_subscribe, context_unsubscribe, NULL };
        if (size < sizeof(table)) return PULSE_ERROR_ABI;
        memcpy(out, &table, sizeof(table));
        return PULSE_OK;
    }
    if (equals(name, PULSE_UI_MODEL_INTERFACE)) {
        const PulseUiModelV1 table = { sizeof(table), 1, host, panel_create, panel_update, panel_subscribe,
            NULL, NULL, panel_unsubscribe, panel_close };
        if (size < sizeof(table)) return PULSE_ERROR_ABI;
        memcpy(out, &table, sizeof(table));
        return PULSE_OK;
    }
    return PULSE_ERROR_UNAVAILABLE;
}

static int exercise_locked(PulsePluginEntryV1Fn entry) {
    LockedHost state = {0};
    PulseHostV1 host = { sizeof(host), PULSE_ABI_VERSION_1, &state, query_locked };
    PulsePluginV1 out = { .size = sizeof(out), .version = PULSE_ABI_VERSION_1 };
    CHECK(entry(&host, &out) == PULSE_OK);
    CHECK(out.instance && out.activate && out.deactivate && out.destroy);

    /* Menu discovery must not activate the panel or execute tools. */
    CHECK(state.menu_registered == 1 && state.menu && !state.panel_open && !state.navigation && !state.unexpected_tasks);
    PulseContextSelectionSnapshot selection = {0};
    selection.size = sizeof(selection);
    selection.directory = sv("C:\\fixture");
    state.menu(state.menu_user, state.menu_id, NULL);
    state.menu(state.menu_user, state.menu_id + 1, &selection);
    CHECK(!state.panel_open);
    state.menu(state.menu_user, state.menu_id, &selection);
    CHECK(state.panel_open && state.navigation && !state.unexpected_tasks);
    unsigned menu_created = state.created;
    state.menu(state.menu_user, state.menu_id, &selection);
    CHECK(state.created == menu_created && state.panel_open);
    /* User closes the panel: the next command may reopen only after drain. */
    forget_panel(&state);
    state.menu(state.menu_user, state.menu_id, &selection);
    CHECK(state.panel_open && state.navigation && state.created == menu_created + 1);
    out.deactivate(out.instance);
    CHECK(!state.panel_open && !state.navigation);
    /* Roll back a partially activated panel/context; a retry must work. */
    state.fail_get = 1;
    CHECK(out.activate(out.instance) == PULSE_ERROR_PERMISSION);
    CHECK(!state.panel_open && !state.navigation);
    state.fail_get = 0;
    CHECK(out.activate(out.instance) == PULSE_OK);
    CHECK(state.panel_open && state.navigation && state.clicks[2]);
    unsigned created = state.created;
    CHECK(out.activate(out.instance) == PULSE_OK && state.created == created);
    emit_navigation(state.navigation, state.navigation_user, "C:\\fixture\\second", 1);
    emit_navigation(state.navigation, state.navigation_user, "C:\\fixture\\third", 0);
    unsigned updates = state.updates;
    state.clicks[0](state.click_users[0], state.panel, sv(commands[0]));
    state.clicks[1](state.click_users[1], state.panel, sv(commands[1]));
    CHECK(state.updates == updates);
    state.clicks[2](state.click_users[2], state.panel, sv(commands[2]));
    CHECK(state.updates > updates && !state.unexpected_tasks);

    /* Explicit close refusal retains the binding; no reactivation until retry. */
    state.fail_close = 1;
    out.deactivate(out.instance);
    CHECK(state.panel_open && !state.navigation);
    CHECK(out.activate(out.instance) == PULSE_ERROR_STATE);
    state.fail_close = 0;
    out.deactivate(out.instance);
    CHECK(!state.panel_open && !state.navigation);
    CHECK(out.activate(out.instance) == PULSE_OK);

    /* User closes the panel; context cleanup is still required. */
    forget_panel(&state);
    out.deactivate(out.instance);
    CHECK(!state.navigation);
    CHECK(out.activate(out.instance) == PULSE_OK);

    /* Pinned host Session::Stop closes interfaces before Module::Close.
       STATE here means the mock already invalidated the registrations. */
    forget_panel(&state);
    forget_navigation(&state);
    /* Host stop invalidates command callbacks before final destroy. */
    state.menu = NULL;
    state.menu_user = NULL;
    state.stopped = 1;
    out.deactivate(out.instance);
    unsigned attempts = state.close_attempts;
    out.destroy(out.instance);
    CHECK(state.close_attempts == attempts); /* stop already drained */
    CHECK(state.created == state.closed && !state.unexpected_tasks);
    return 0;
}

int main(int argc, char **argv) {
    CHECK(argc == 2 || argc == 3);
    int locked_candidate = argc == 3;
    for (int cycle = 0; cycle < 16; ++cycle) {
        HMODULE lib = LoadLibraryExA(argv[1], NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        CHECK(lib);
        PulsePluginSdkPreviewFn preview = (PulsePluginSdkPreviewFn)GetProcAddress(lib, "PulsePluginSdkPreview");
        PulsePluginEntryV1Fn entry = (PulsePluginEntryV1Fn)GetProcAddress(lib, "PulsePluginEntryV1");
        CHECK(preview && entry && preview() == PULSE_SDK_PREVIEW);
        PulseHostV1 host = { sizeof(host), PULSE_ABI_VERSION_1, NULL, NULL };
        PulsePluginV1 out = { .size = sizeof(out), .version = PULSE_ABI_VERSION_1 };
        CHECK(entry(NULL, &out) == PULSE_ERROR_ABI);
        CHECK(entry(&host, NULL) == PULSE_ERROR_ABI);
        out.version = 99;
        CHECK(entry(&host, &out) == PULSE_ERROR_ABI && !out.instance);
        out.version = PULSE_ABI_VERSION_1;
        if (locked_candidate) {
            CHECK(entry(&host, &out) == PULSE_ERROR_UNAVAILABLE && !out.instance);
            host.query_interface = unavailable;
        }
        CHECK(entry(&host, &out) == PULSE_OK);
        CHECK(out.instance && out.activate && out.deactivate && out.destroy);
        CHECK(out.activate(out.instance) == (locked_candidate ? PULSE_ERROR_UNAVAILABLE : PULSE_OK));
        out.deactivate(out.instance);
        CHECK(out.activate(out.instance) == (locked_candidate ? PULSE_ERROR_UNAVAILABLE : PULSE_OK));
        out.deactivate(out.instance);
        out.destroy(out.instance);
        if (locked_candidate) CHECK(exercise_locked(entry) == 0);
        CHECK(FreeLibrary(lib));
    }
    puts(locked_candidate ? "C ABI VCS loader: 16 locked lifecycle and rollback cycles passed" : "C ABI DLL loader: 16 lifecycle cycles passed");
    return 0;
}
