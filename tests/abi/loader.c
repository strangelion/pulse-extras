/* Independent C-side layout and real DLL lifecycle check, not the Pulse host. */
#include <stddef.h>
#include <stdio.h>
#include <windows.h>
#include "pulse/abi.h"
#include "pulse/context.h"
#include "pulse/commands.h"
#include "pulse/resources.h"
#include "pulse/settings_pages.h"
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
    uint64_t settings_page, settings_request;
    unsigned settings_updates, settings_syncs;
    PulseResourcesCompletionFn settings_reply;
    void *settings_user;
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

/* Card/grid wrappers are presentation only. Validate the entire bounded tree,
 * including nested actions, so a locked view cannot hide an executable action. */
static int inspect_locked_node(const PulseUiModelNode *node, unsigned depth,
    unsigned *remaining, unsigned *locked, unsigned *check) {
    if (!node || depth > 32 || !*remaining || node->size != sizeof(*node)) return 0;
    --*remaining;
    if (equals(node->id, "vcs.approval")) {
        if (!node->text.present ||
            !(equals(node->text.value, "Execution locked: production approval unavailable") ||
              equals(node->text.value, "执行已锁定：尚未提供生产授权"))) return 0;
        ++*locked;
    }
    if (node->command.present) {
        if (!equals(node->command.value, "vcs.check")) return 0;
        ++*check;
    }
    if (node->children.present) {
        if (node->children.count > *remaining || (node->children.count && !node->children.data)) return 0;
        for (uint32_t i = 0; i < node->children.count; ++i)
            if (!inspect_locked_node(&node->children.data[i], depth + 1, remaining, locked, check)) return 0;
    }
    return 1;
}

static int tree_valid(const PulseUiModelTree *tree) {
    if (!tree || tree->size != sizeof(*tree) || !tree->root ||
        tree->command_count != 3 || !tree->commands)
        return 0;
    for (unsigned i = 0; i < 3; ++i)
        if (!equals(tree->commands[i], commands[i])) return 0;
    unsigned remaining = 512, locked = 0, check = 0;
    return inspect_locked_node(tree->root, 0, &remaining, &locked, &check) &&
        locked == 1 && check == 1;
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

static int settings_tree_valid(const PulseUiModelTree *tree) {
    return tree && tree->size == sizeof(*tree) && tree->root &&
        equals(tree->root->id, "vcs.settings.root") &&
        tree->command_count != 0 && tree->commands;
}

static PulseStatus PULSE_CALL settings_create(void *context, PulseStringView title,
    const PulseUiModelTree *tree, uint64_t *page) {
    LockedHost *host = context;
    if (host->settings_page || !page || !title.length || !settings_tree_valid(tree)) return PULSE_ERROR_ARGUMENT;
    *page = host->settings_page = ++host->next_panel;
    return PULSE_OK;
}

static PulseStatus PULSE_CALL settings_update(void *context, uint64_t page, const PulseUiModelTree *tree) {
    LockedHost *host = context;
    if (!host->settings_page || host->settings_page != page || !settings_tree_valid(tree)) return PULSE_ERROR_ARGUMENT;
    ++host->settings_updates;
    return PULSE_OK;
}

static PulseStatus PULSE_CALL settings_subscribe(void *context, uint64_t page,
    PulseStringView command, PulseUiClickFn callback, void *user, uint64_t *id) {
    LockedHost *host = context;
    if (!host->settings_page || host->settings_page != page ||
        !command.length || !callback || !user || !id) return PULSE_ERROR_ARGUMENT;
    *id = ++host->next_subscription;
    return PULSE_OK;
}

static PulseStatus PULSE_CALL settings_set_states(void *context, uint64_t page,
    const PulseUiState *states, uint32_t count) {
    LockedHost *host = context;
    if (!host->settings_page || host->settings_page != page || !states || !count) return PULSE_ERROR_ARGUMENT;
    ++host->settings_syncs;
    return PULSE_OK;
}

static PulseStatus PULSE_CALL settings_get_state(void *context, uint64_t page,
    PulseStringView key, char *buffer, uint32_t capacity, uint32_t *needed) {
    LockedHost *host = context;
    (void)buffer;
    (void)capacity;
    if (!host->settings_page || host->settings_page != page || !key.length || !needed) return PULSE_ERROR_ARGUMENT;
    *needed = 0;
    return PULSE_OK;
}

static PulseStatus PULSE_CALL settings_query(void *context, uint64_t page,
    PulseStringView interface_name, uint32_t version, void *out, uint32_t size) {
    LockedHost *host = context;
    if (!host->settings_page || host->settings_page != page || !out ||
        !equals(interface_name, PULSE_UI_MODEL_INTERFACE) || version != 1 ||
        size < sizeof(PulseUiModelV1)) return PULSE_ERROR_ARGUMENT;
    const PulseUiModelV1 table = {
        .size = sizeof(table), .version = 1, .context = host, .update = settings_update,
        .subscribe_command = settings_subscribe, .set_states = settings_set_states, .get_state = settings_get_state,
    };
    memcpy(out, &table, sizeof(table));
    return PULSE_OK;
}

static PulseStatus PULSE_CALL settings_remove(void *context, uint64_t page) {
    LockedHost *host = context;
    if (!host->settings_page || host->settings_page != page) return PULSE_ERROR_STATE;
    host->settings_page = 0;
    return PULSE_OK;
}

static PulseStatus PULSE_CALL settings_read(void *context, PulseResourcesCompletionFn reply,
    void *user, PulseResourcesRequestId *id) {
    LockedHost *host = context;
    if (!host->settings_page || host->settings_request || !reply || !user || !id) return PULSE_ERROR_STATE;
    *id = host->settings_request = ++host->next_subscription;
    host->settings_reply = reply;
    host->settings_user = user;
    return PULSE_OK;
}

static PulseStatus PULSE_CALL settings_write(void *context, PulseStringView key, PulseStringView value,
    uint32_t delete_value, uint64_t version, PulseResourcesCompletionFn reply, void *user,
    PulseResourcesRequestId *id) {
    (void)context; (void)key; (void)value; (void)delete_value; (void)version;
    (void)reply; (void)user; (void)id;
    return PULSE_ERROR_PERMISSION;
}

static PulseStatus PULSE_CALL settings_cancel(void *context, PulseResourcesRequestId id) {
    LockedHost *host = context;
    if (!id || id != host->settings_request) return PULSE_ERROR_STATE;
    host->settings_request = 0;
    host->settings_reply = NULL;
    host->settings_user = NULL;
    return PULSE_OK;
}

static PulseStatus PULSE_CALL query_locked(void *context, PulseStringView name, uint32_t version, void *out, uint32_t size) {
    LockedHost *host = context;
    if (host->stopped) return PULSE_ERROR_STATE;
    if (!out || version != 1) return PULSE_ERROR_ABI;
    if (equals(name, PULSE_SETTINGS_PAGES_INTERFACE_NAME)) {
        const PulseSettingsPagesV1 table = { sizeof(table), 1, host, settings_create, settings_query, settings_remove };
        if (size < sizeof(table)) return PULSE_ERROR_ABI;
        memcpy(out, &table, sizeof(table));
        return PULSE_OK;
    }
    if (equals(name, PULSE_RESOURCES_INTERFACE_NAME)) {
        const PulseResourcesV1 table = {
            .size = sizeof(table), .version = 1, .context = host,
            .settings_get = settings_read, .settings_set = settings_write, .cancel_request = settings_cancel,
        };
        if (size < sizeof(table)) return PULSE_ERROR_ABI;
        memcpy(out, &table, sizeof(table));
        return PULSE_OK;
    }
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

    fprintf(stderr, "VCS ABI owner: entry returned, testing menu discovery\n");
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
    CHECK(state.settings_page && state.settings_request && state.settings_reply);
    fprintf(stderr, "VCS ABI owner: settings completion\n");
    unsigned settings_updates = state.settings_updates;
    unsigned panel_updates = state.updates;
    PulseResourcesReply reply = {
        .size = sizeof(reply), .operation = PULSE_RESOURCES_SETTINGS_GET,
        .request_id = state.settings_request + 1, .status = PULSE_OK, .settings = { .version = 1 },
    };
    state.settings_reply(state.settings_user, &reply);
    CHECK(state.settings_updates == settings_updates && state.updates == panel_updates);
    reply.request_id = state.settings_request;
    state.settings_request = 0;
    state.settings_reply(state.settings_user, &reply);
    state.settings_reply = NULL;
    state.settings_user = NULL;
    CHECK(state.settings_updates > settings_updates && state.settings_syncs && state.updates > panel_updates);
    unsigned menu_created = state.created;
    state.menu(state.menu_user, state.menu_id, &selection);
    CHECK(state.created == menu_created && state.panel_open);
    /* User closes the panel: the next command may reopen only after drain. */
    forget_panel(&state);
    state.menu(state.menu_user, state.menu_id, &selection);
    CHECK(state.panel_open && state.navigation && state.created == menu_created + 1);
    out.deactivate(out.instance);
    CHECK(!state.panel_open && !state.navigation && !state.settings_page && !state.settings_request);
    fprintf(stderr, "VCS ABI owner: activation rollback\n");
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

    fprintf(stderr, "VCS ABI owner: close refusal and host-first unload\n");
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
    state.settings_page = 0;
    state.settings_request = 0;
    state.settings_reply = NULL;
    state.settings_user = NULL;
    state.stopped = 1;
    out.deactivate(out.instance);
    unsigned attempts = state.close_attempts;
    out.destroy(out.instance);
    CHECK(state.close_attempts == attempts); /* stop already drained */
    CHECK(state.created == state.closed && !state.unexpected_tasks);
    return 0;
}

static DWORD WINAPI exercise_locked_on_host_stack(LPVOID context) {
    PulsePluginEntryV1Fn entry = *(PulsePluginEntryV1Fn *)context;
    return (DWORD)exercise_locked(entry);
}

int main(int argc, char **argv) {
    CHECK(argc == 2 || argc == 3);
    int locked_candidate = argc == 3;
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    /* Keep the last reached phase visible even if the DLL terminates the process. */
    setvbuf(stderr, NULL, _IONBF, 0);
    for (int cycle = 0; cycle < 16; ++cycle) {
        if (locked_candidate) fprintf(stderr, "VCS ABI cycle %d/16: load and basic lifecycle\n", cycle + 1);
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
        if (locked_candidate) {
            fprintf(stderr, "VCS ABI cycle %d/16: 512 KiB owner lifecycle\n", cycle + 1);
            HANDLE owner = CreateThread(NULL, 512 * 1024, exercise_locked_on_host_stack,
                                        &entry, STACK_SIZE_PARAM_IS_A_RESERVATION, NULL);
            CHECK(owner);
            DWORD wait = WaitForSingleObject(owner, 30000);
            DWORD result = 1;
            BOOL completed = wait == WAIT_OBJECT_0 && GetExitCodeThread(owner, &result);
            CHECK(CloseHandle(owner));
            if (!completed || result != 0)
                fprintf(stderr, "VCS ABI owner wait=0x%08lx exit=0x%08lx\n", (unsigned long)wait, (unsigned long)result);
            CHECK(completed && result == 0);
        }
        CHECK(FreeLibrary(lib));
    }
    puts(locked_candidate ? "C ABI VCS loader: 16 locked lifecycle and rollback cycles passed on a 512 KiB owner thread" : "C ABI DLL loader: 16 lifecycle cycles passed");
    return 0;
}
