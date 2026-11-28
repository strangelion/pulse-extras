/* Independent pinned C ABI fixture; loads the actual production-built DLL.
 * Not a renderer or real Pulse host. Replies arrive only after API return. */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stddef.h>

/* Verified against local Preview 3 ABI measurements, without replacing
 * the public pinned build header. The host may still reject enum 44. */

#include "pulse/settings_pages.h"
#include "pulse/resources.h"
#include "pulse/tasks.h"
#include "pulse/dispatch.h"
#include "pulse/ui_events.h"
#include "pulse/dialogs.h"
#include "pulse/context.h"

typedef char preview3_node_size[(sizeof(PulseUiModelNode) == 1296) ? 1 : -1];
typedef char preview3_node_type[(offsetof(PulseUiModelNode, type) == 4) ? 1 : -1];
typedef char preview3_node_text[(offsetof(PulseUiModelNode, text) == 24) ? 1 : -1];
typedef char preview3_node_glyph[(offsetof(PulseUiModelNode, glyph) == 168) ? 1 : -1];
typedef char preview3_node_kind[(offsetof(PulseUiModelNode, kind) == 768) ? 1 : -1];
typedef char preview3_node_height[(offsetof(PulseUiModelNode, min_height) == 952) ? 1 : -1];
typedef char preview3_table_size[(sizeof(PulseUiModelV1) == 72) ? 1 : -1];

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "ABI fixture line %d: %s\n", __LINE__, #x); return PULSE_ERROR_ARGUMENT; } } while (0)

static const char *commands[] = {
    "companion.library", "companion.running", "companion.market", "companion.global",
    "companion.settings.refresh", "companion.download.less", "companion.download.more",
    "companion.library.reload", "companion.library.poll", "companion.library.previous", "companion.library.next", "companion.library.favorites", "companion.running.start", "companion.running.stop", "companion.running.stop-one", "companion.library.start", "companion.library.favorite-toggle", "companion.library.tag-add", "companion.library.tag-remove", "companion.library.import", "companion.library.import-cancel", "companion.library.browse", "companion.library.recovery-scan", "companion.library.remove", "companion.library.restore", "companion.quarantine.previous", "companion.quarantine.next", "companion.quarantine.purge", "companion.library.search-clear", "companion.running.search", "companion.running.search-clear", "companion.market.search", "companion.market.offline", "companion.market.previous", "companion.market.next", "companion.market.install-base", "companion.market.install-full", "companion.market.cancel", "companion.market.poll", "companion.market.search-clear", "companion.market.select-1", "companion.market.select-2", "companion.market.select-3", "companion.market.select-4", "companion.market.select-5", "companion.market.select-6", "companion.market.select-7", "companion.market.select-8", "companion.market.select-9", "companion.market.select-10", "companion.market.select-11", "companion.market.select-12", "companion.runtime.limits-save", "companion.running.previous", "companion.running.next", "companion.market.filter-mode", "companion.market.filter-category", "companion.market.filter-version", "companion.market.queue-base", "companion.market.queue-full", "companion.market.queue-start", "companion.market.queue-clear", "companion.market.queue-item-1", "companion.market.queue-item-2", "companion.market.queue-item-3", "companion.market.queue-item-4", "companion.market.queue-item-5", "companion.market.queue-item-6", "companion.market.queue-item-7", "companion.market.queue-item-8", "companion.library.profile-default", "companion.library.profile-alternate", "companion.library.profile-reset", "companion.library.profile-clear", "companion.library.start-alternate", "companion.library.start-custom", "companion.library.detail", "companion.market.image-test", "companion.market.open-gallery", "companion.market.image-fallback", "companion.runtime.policy-save", "companion.runtime.plan-start", "companion.runtime.plan-cancel", "companion.running.hide", "companion.running.show", "companion.running.hide-all", "companion.running.show-all", "companion.runtime.diagnostics",
    "companion.library.select", "companion.library.advanced", "companion.library.load-alternate", "companion.library.pick-1", "companion.library.pick-2", "companion.library.pick-3", "companion.library.pick-4", "companion.library.pick-5", "companion.library.pick-6", "companion.library.pick-7", "companion.library.pick-8", "companion.library.pick-9", "companion.library.pick-10", "companion.library.pick-11", "companion.library.pick-12", "companion.library.pick-13", "companion.library.pick-14", "companion.library.pick-15", "companion.library.pick-16", "companion.library.import-file"
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
    unsigned image_seen, reject_image, image_rejected;
    HANDLE worker;
    volatile LONG cancel_flag;
    CRITICAL_SECTION dispatch_lock;
    PulseDispatchCallback queued;
    void *queued_user;
    uint64_t dispatch_id;
    char saved, requested;
    char runtime_saved[32], runtime_requested[32];
    int runtime_write;
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
    uint64_t search_token, running_search_token, library_selection_token;
    PulseUiStateChangedFn library_selection_changed;
    void *library_selection_user;
    unsigned advanced_visible;
    PulseUiStateChangedFn running_search_changed;
    void *running_search_user;
    PulseUiStateChangedFn search_changed;
    void *search_user;
    char search_value[257];
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

/* Mirror the upstream textInput label rule on every tree create/update,
 * not just the default view. A placeholder is insufficient. */
static PulseStatus check_input_labels(const PulseUiModelNode *node, unsigned depth) {
    REQUIRE(node && depth <= 32);
    if (node->type == PULSE_UI_MODEL_BUTTON) REQUIRE(!node->selected.present);
    if (node->type == PULSE_UI_MODEL_TEXT_INPUT) {
        REQUIRE(node->text.present && node->text.value.data && node->text.value.length);
        if (same(node->id, "library.query") || same(node->id, "running.query") ||
            same(node->id, "market.query")) {
            REQUIRE(node->placeholder.present && node->placeholder.value.length);
            REQUIRE(!node->glyph.present && !node->flex.present);
        }
    }
    if (node->children.present) {
        REQUIRE(!node->children.count || node->children.data);
        for (unsigned i = 0; i < node->children.count; ++i) {
            PulseStatus status = check_input_labels(node->children.data + i, depth + 1);
            if (status != PULSE_OK) return status;
        }
    }
    return PULSE_OK;
}
static PulseStatus inspect(Fixture *f, const PulseUiModelTree *t) {
    REQUIRE(t && t->size == sizeof(*t) && t->root && t->command_count == COMMAND_COUNT && t->commands);
    for (unsigned i = 0; i < COMMAND_COUNT; ++i) REQUIRE(same(t->commands[i], commands[i]));
    const PulseUiModelNode *viewport = t->root;
    REQUIRE(check_input_labels(viewport, 0) == PULSE_OK);
    REQUIRE(viewport->size == sizeof(*viewport) && viewport->type == PULSE_UI_MODEL_STACK);
    REQUIRE(viewport->orientation.present && same(viewport->orientation.value, "horizontal"));
    REQUIRE(viewport->children.present && viewport->children.data && viewport->children.count == 3);
    const PulseUiModelNode *root = viewport->children.data + 1;
    REQUIRE(root->type == PULSE_UI_MODEL_STACK && root->flex.present && root->flex.value == 16);
    REQUIRE(root->children.present && root->children.data && (root->children.count >= 3 && root->children.count <= 36));
    REQUIRE(viewport->children.data[0].flex.value == 1 && viewport->children.data[2].flex.value == 1);
    REQUIRE(root->max_width.present);
    if (same(root->children.data[1].id, "market")) REQUIRE(root->max_width.value == 1440);
    else if (same(root->children.data[1].id, "global")) REQUIRE(root->max_width.value == 1100);
    else REQUIRE(root->max_width.value == 1160);
    const PulseUiModelNode *nav_frame = root->children.data;
    REQUIRE(nav_frame->children.present && nav_frame->children.data && nav_frame->children.count == 3);
    const PulseUiModelNode *nav = nav_frame->children.data + 1;
    REQUIRE(nav->type == PULSE_UI_MODEL_GRID && nav->columns.present && nav->columns.value == 4);
    REQUIRE(nav->children.present && nav->children.count == 4 && nav->children.data);
    unsigned primary_count = 0;
    for (unsigned i = 0; i < 4; ++i) {
        const PulseUiModelNode *n = nav->children.data + i;
        REQUIRE(n->size == sizeof(*n) && n->type == PULSE_UI_MODEL_BUTTON && n->command.present && same(n->command.value, commands[i]));
        REQUIRE(same(n->id, commands[i]));
        REQUIRE(n->enabled.present && n->enabled.value && n->kind.present);
        REQUIRE(same(n->kind.value, "primary") || same(n->kind.value, "transparent"));
        primary_count += same(n->kind.value, "primary");
    }
    REQUIRE(primary_count == 1);
    f->global = same(root->children.data[1].id, "global");
    f->enabled_less = f->enabled_more = 0;
    if (f->global) {
        REQUIRE(root->children.count == 5);
        const PulseUiModelNode *overview = root->children.data + 2;
        REQUIRE(overview->type == PULSE_UI_MODEL_GRID && overview->columns.present && overview->columns.value == 2);
        REQUIRE(overview->children.present && overview->children.data && overview->children.count == 2);
        const PulseUiModelNode *groups[] = { overview->children.data, overview->children.data + 1,
                                            root->children.data + 3, root->children.data + 4 };
        static const char *group_ids[] = { "settings.download", "settings.runtime", "settings.policy", "settings.diagnostics-group" };
        for (unsigned i = 0; i < 4; ++i) {
            const PulseUiModelNode *group = groups[i];
            REQUIRE(group->type == PULSE_UI_MODEL_GROUP && group->bordered.present && group->bordered.value);
            REQUIRE(same(group->id, group_ids[i]));
            REQUIRE(group->children.present && group->children.data);
            REQUIRE(group->children.count == (i == 3 ? 2u : 3u));
        }
        REQUIRE(same(groups[1]->children.data[2].command.value, commands[52]));
        REQUIRE(t->state_count == 30);
        REQUIRE(same(t->states[27].key, "library.scale"));
        REQUIRE(same(t->states[28].key, "library.topmost"));
        REQUIRE(same(t->states[29].key, "library.reduced"));
        REQUIRE(same(t->states[11].key, "policy.automatic"));
        REQUIRE(same(t->states[23].key, "policy.entry.8"));
        REQUIRE(same(t->states[24].key, "policy.hide-on-minimize"));
        REQUIRE(same(t->states[25].key, "policy.retain-history"));
        REQUIRE(same(t->states[26].key, "policy.capture-crashes"));
        /* The fixture intentionally omits set_states: retain the old
         * editable text field on older hosts. */
        const PulseUiModelNode *policy = groups[2]->children.data;
        REQUIRE(policy[1].type == PULSE_UI_MODEL_TEXT_INPUT);
        REQUIRE(same(policy[1].state.value, "settings.runtime-policy"));
        REQUIRE(policy[2].children.data && policy[2].children.count == 3);
        REQUIRE(same(policy[2].children.data[0].command.value, commands[80]));
        REQUIRE(same(groups[3]->children.data[0].command.value, commands[87]));
        const PulseUiModelNode *toolbar = groups[0]->children.data + 2;
        REQUIRE(toolbar->children.present && toolbar->children.count == 3 && toolbar->children.data);
        const PulseUiModelNode *less = toolbar->children.data + 1, *more = less + 1;
        REQUIRE(less->enabled.present && more->enabled.present);
        REQUIRE(same(less->command.value, commands[5]) && same(more->command.value, commands[6]));
        f->enabled_less = (int)less->enabled.value;
        f->enabled_more = (int)more->enabled.value;
    }
    if (same(root->children.data[1].id, "running")) {
        REQUIRE(root->children.count >= 6 && root->children.count <= 25);
        const PulseUiModelNode *search = root->children.data + 4;
        REQUIRE(search->type == PULSE_UI_MODEL_TEXT_INPUT && same(search->state.value, "running.query"));
        const PulseUiModelNode *toolbar = root->children.data + 3;
        REQUIRE(toolbar->children.present && toolbar->children.count == 2);
        f->start_enabled = (int)toolbar->children.data[0].enabled.value;
        f->stop_enabled = (int)toolbar->children.data[1].enabled.value;
        f->first_frame = 0;
        f->two_ready = 0;
        f->running_rows = 0;
        f->only_second = 0;
        for (unsigned n = 9; n < root->children.count; ++n) {
            const PulseUiModelNode *row = root->children.data + n;
            if (!row->id.data || row->id.length < 9 || memcmp(row->id.data, "instance-", 9)) continue;
            ++f->running_rows;
            const PulseStringView text = row->text.value;
            static const char second_instance[] = "实例 #2 · ";
            const size_t prefix_length = sizeof(second_instance) - 1;
            if (text.data && text.length >= prefix_length && memcmp(text.data, second_instance, prefix_length) == 0)
                f->only_second = 1;
        }
        f->only_second = f->only_second && f->running_rows == 1;
        if (root->children.count >= 7) {
            const PulseStringView text = root->children.data[6].text.value;
            const char *prefix = "首帧已确认";
            const char *two = "首帧已确认 · 运行 2/2";
            f->first_frame = text.data && text.length >= strlen(prefix) &&
                memcmp(text.data, prefix, strlen(prefix)) == 0;
            f->two_ready = text.data && text.length >= strlen(two) &&
                memcmp(text.data, two, strlen(two)) == 0;
        }
    }
    if (same(root->children.data[1].id, "market")) {
        REQUIRE(root->children.count >= 7);
        REQUIRE(same(root->children.data[6].command.value, commands[77]));
        f->image_seen = 0;
        for (unsigned n = 7; n < root->children.count; ++n) {
            const PulseUiModelNode *image = root->children.data + n;
            if (image->type != 44) continue;
            REQUIRE(same(image->id, "market.image-fixture"));
            REQUIRE(image->glyph.present && same(image->glyph.value, "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAABgAAAAYCAIAAABvFaqvAAAASElEQVR42mN88fkPAzUACwMDg37pAfyKrBzX4Fcw3WsKEwOVwKhBowYNKoNYGBgYsh8SyG75T0/hV/B9NLBHDRquBjFSqzoCAFBxDz4y6Mz0AAAAAElFTkSuQmCC"));
            REQUIRE(image->kind.present && same(image->kind.value, "contain"));
            REQUIRE(image->text.present && same(image->text.value, "SDK 测试图：蓝绿紫橙四格"));
            REQUIRE(image->min_height.present && image->min_height.value == 64);
            REQUIRE(image->max_width.present && image->max_width.value == 144);
            ++f->image_seen;
            if (f->reject_image) {
                ++f->image_rejected;
                return PULSE_ERROR_ARGUMENT;
            }
        }
        const PulseUiModelNode *search = root->children.data + 3;
        REQUIRE(search->type == PULSE_UI_MODEL_TEXT_INPUT && same(search->state.value, "market.query"));
        REQUIRE(!search->glyph.present && !search->flex.present);
        const PulseUiModelNode *toolbar = root->children.data + 4;
        REQUIRE(same(toolbar->id, "market.toolbar") && toolbar->children.present &&
                toolbar->children.data && toolbar->children.count == 3);
        REQUIRE(toolbar->children.data[1].flex.present && toolbar->children.data[1].flex.value == 1);
        const PulseUiModelNode *actions = toolbar->children.data;
        REQUIRE(actions->children.present && actions->children.data && actions->children.count == 5);
        REQUIRE(same(actions->children.data[3].command.value, commands[39]));
        REQUIRE(same(actions->children.data[4].command.value, commands[78]));
        const PulseUiModelNode *filters = toolbar->children.data + 2;
        REQUIRE(filters->children.present && filters->children.data && filters->children.count == 3);
        for (unsigned n = 0; n < 3; ++n)
            REQUIRE(same(filters->children.data[n].command.value, commands[55 + n]));
        for (unsigned n = 0; n < t->state_count; ++n)
            REQUIRE(!same(t->states[n].key, "market.id"));
    }
    if (same(root->children.data[1].id, "library")) {
        REQUIRE(root->children.count >= 5);
        const PulseUiModelNode *toolbar = root->children.data + 4;
        if (same(toolbar->id, "library.actions")) {
            REQUIRE(toolbar->children.present && toolbar->children.data && toolbar->children.count == 3);
            const PulseUiModelNode *actions = toolbar->children.data;
            REQUIRE(actions[1].flex.present && actions[1].flex.value == 1);
            REQUIRE(same(actions[2].id, "library.import-toolbar") && actions[2].children.present &&
                    actions[2].children.data && actions[2].children.count >= 1);
            REQUIRE(same(actions[2].children.data[0].command.value, commands[19]));
            toolbar = actions;
        }
        REQUIRE(toolbar->children.present && toolbar->children.data &&
                (toolbar->children.count == 3 || toolbar->children.count == 4));
        const PulseUiModelNode *search = root->children.data + 3;
        REQUIRE(search->type == PULSE_UI_MODEL_TEXT_INPUT && search->placeholder.present);
        REQUIRE(!search->glyph.present && !search->flex.present && same(search->text.value, "搜索素材"));
        REQUIRE(same(search->state.value, "library.query"));
        REQUIRE(same(toolbar->children.data[0].command.value, commands[7]));
        REQUIRE(same(toolbar->children.data[1].command.value, commands[11]));
        REQUIRE(same(toolbar->children.data[2].command.value, commands[28]));
        REQUIRE(t->state_count && t->states && same(t->states[0].key, "library.query"));
        REQUIRE(t->states[0].value.length < sizeof(f->search_value));
        if (t->states[0].value.length)
            memcpy(f->search_value, t->states[0].value.data, t->states[0].value.length);
        f->search_value[t->states[0].value.length] = 0;
        if (toolbar->children.count == 4)
            REQUIRE(same(toolbar->children.data[3].command.value, commands[8]));
        unsigned profile_groups = 0;
        for (unsigned i = 0; i < root->children.count; ++i) {
            const PulseUiModelNode *node = root->children.data + i;
            if (!same(node->id, "library.profile.group")) continue;
            REQUIRE(node->children.present && node->children.count == 5);
            const PulseUiModelNode *fields = node->children.data + 1;
            REQUIRE(fields->children.present && fields->children.data && fields->children.count == 3);
            REQUIRE(fields->children.data[0].type == PULSE_UI_MODEL_TEXT_INPUT);
            REQUIRE(same(fields->children.data[0].state.value, "library.scale"));
            REQUIRE(fields->children.data[1].type == PULSE_UI_MODEL_CHECKBOX);
            REQUIRE(same(fields->children.data[1].state.value, "library.topmost"));
            REQUIRE(fields->children.data[2].type == PULSE_UI_MODEL_CHECKBOX);
            REQUIRE(same(fields->children.data[2].state.value, "library.reduced"));
            REQUIRE(same(node->children.data[4].command.value, commands[76]));
            ++profile_groups;
        }
        REQUIRE(profile_groups <= 1);
        unsigned recovery_buttons = 0, advanced_buttons = 0, advanced_open = 0;
        unsigned tables = 0;
        for (unsigned i = 0; i < root->children.count; ++i) {
            const PulseUiModelNode *node = root->children.data + i;
            if (same(node->id, "library.advanced.open") || same(node->id, "library.advanced.closed")) {
                REQUIRE(node->type == PULSE_UI_MODEL_BUTTON && node->command.present && same(node->command.value, commands[89]));
                ++advanced_buttons;
                advanced_open += same(node->id, "library.advanced.open");
            }
            if (!same(node->id, "library.table")) continue;
            ++tables;
            REQUIRE(node->type == PULSE_UI_MODEL_DATA_TABLE && node->state.present && same(node->state.value, "library.asset-id"));
            REQUIRE(node->data_columns.present && node->data_columns.data && node->data_columns.count == 5);
            REQUIRE(node->rows.present && node->rows.data && node->rows.count > 0 && node->rows.count <= 16);
            for (unsigned n = 0; n < node->rows.count; ++n) {
                const PulseUiModelRow *row = node->rows.data + n;
                REQUIRE(row->size == sizeof(*row) && row->id.data && row->id.length);
                REQUIRE(row->command.present && same(row->command.value, commands[88]));
                REQUIRE(row->cells.present && row->cells.data && row->cells.count == 5);
            }
        }
        REQUIRE(tables <= 1);
        REQUIRE(advanced_buttons == (f->bundled ? 1u : 0u));
        f->advanced_visible = advanced_open;
        for (unsigned i = 0; i < root->children.count; ++i) {
            const PulseUiModelNode *node = root->children.data + i;
            if (!same(node->id, "library.recovery-scan")) continue;
            REQUIRE(node->type == PULSE_UI_MODEL_BUTTON && node->command.present && same(node->command.value, commands[22]));
            ++recovery_buttons;
        }
        REQUIRE(recovery_buttons == advanced_open);
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
    if (same(key, "settings.instances")) {
        memcpy(buffer, "1024", 5); *needed = 4; return PULSE_OK;
    }
    if (same(key, "settings.commit-mib")) {
        memcpy(buffer, "512", 4); *needed = 3; return PULSE_OK;
    }
    if (same(key, "library.asset-id")) {
        buffer[0] = 0; *needed = 0; return PULSE_OK;
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
static PulseStatus PULSE_CALL subscribe_search(void *ctx, uint64_t page, PulseStringView key, uint32_t sources, PulseUiStateChangedFn cb, void *user, uint64_t *token) {
    Fixture *f = ctx;
    REQUIRE(page == f->page && sources == PULSE_UI_STATE_USER && cb && token);
    if (same(key, "running.query")) {
        REQUIRE(!f->running_search_token);
        f->running_search_token = ++f->next; f->running_search_changed = cb; f->running_search_user = user;
        *token = f->running_search_token;
        return PULSE_OK;
    }
    if (same(key, "library.asset-id")) {
        REQUIRE(!f->library_selection_token);
        f->library_selection_token = ++f->next;
        f->library_selection_changed = cb;
        f->library_selection_user = user;
        *token = f->library_selection_token;
        return PULSE_OK;
    }
    REQUIRE(!f->search_token && same(key, "library.query"));
    f->search_token = ++f->next; f->search_changed = cb; f->search_user = user;
    *token = f->search_token;
    return PULSE_OK;
}
static PulseStatus PULSE_CALL unsubscribe_search(void *ctx, uint64_t token) {
    Fixture *f = ctx;
    if (token && token == f->running_search_token) {
        f->running_search_token = 0; f->running_search_changed = NULL; f->running_search_user = NULL;
        return PULSE_OK;
    }
    if (token && token == f->library_selection_token) {
        f->library_selection_token = 0;
        f->library_selection_changed = NULL;
        f->library_selection_user = NULL;
        return PULSE_OK;
    }
    REQUIRE(token && token == f->search_token);
    f->search_token = 0; f->search_changed = NULL; f->search_user = NULL;
    return PULSE_OK;
}
static PulseStatus events(Fixture *f, void *out, uint32_t size) {
    if (!f->auto_dispatch) return PULSE_ERROR_UNAVAILABLE;
    REQUIRE(size >= sizeof(PulseUiEventsV1));
    PulseUiEventsV1 t = {.size=sizeof(t), .version=1, .context=f, .subscribe_state=subscribe_search, .unsubscribe=unsubscribe_search};
    memcpy(out, &t, sizeof(t));
    return PULSE_OK;
}
static PulseStatus PULSE_CALL query_page(void *ctx, uint64_t page, PulseStringView name, uint32_t version, void *out, uint32_t size) {
    Fixture *f = ctx;
    REQUIRE(page && page == f->page && version == 1);
    if (same(name, PULSE_UI_EVENTS_INTERFACE_NAME)) return events(f, out, size);
    if (same(name, PULSE_UI_MODEL_INTERFACE)) return model(f, out, size);
    return PULSE_ERROR_UNAVAILABLE;
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
    REQUIRE(!del && version == f->version);
    f->runtime_write = same(key, "runtime.limits");
    if (f->runtime_write) {
        REQUIRE(same(value, "1024:512"));
        memcpy(f->runtime_requested, value.data, value.length);
        f->runtime_requested[value.length] = 0;
    } else {
        REQUIRE(same(key, "market.downloadConcurrency"));
        REQUIRE(value.data && value.length == 1 && value.data[0] >= '1' && value.data[0] <= '8');
        f->requested = value.data[0];
    }
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
static PulseStatus PULSE_CALL worker_report(void *ctx, const PulseTaskProgress *progress) {
    (void)ctx;
    REQUIRE(progress && progress->size >= sizeof(*progress));
    if (progress->size == 192) {
        uint32_t step = 0;
        memcpy(&step, (const char *)progress + 72, sizeof(step));
        REQUIRE(step >= 1 && step <= 3 && progress->percent == UINT32_MAX);
    } else {
        REQUIRE(progress->size == sizeof(*progress));
    }
    return PULSE_OK;
}
static DWORD WINAPI work_thread(void *ctx) {
    Fixture *f = ctx;
    PulseTaskContext task = {.id=f->task, .context=f, .report=worker_report, .cancelled=worker_cancelled};
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
    REQUIRE(desc && desc->size >= sizeof(*desc) && desc->work && desc->user && id);
    /* Long-lived sessions must not allocate a Pulse progress task. */
    REQUIRE(!same(desc->type, "companion.session"));
    if (f->bundled && f->worker && same(desc->type, "companion.library")) {
        REQUIRE(!f->aux_task);
        f->aux_task = ++f->next; f->aux_work = desc->work; f->aux_user = desc->user;
        *id = f->aux_task;
        return PULSE_OK;
    }
    REQUIRE(!f->task);
    int runtime = same(desc->type, "companion.runtime");
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
    if (same(name, PULSE_UI_EVENTS_INTERFACE_NAME) && f->fallback) return events(f, out, size);
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
        if (f->runtime_write) memcpy(f->runtime_saved, f->runtime_requested, sizeof(f->runtime_saved));
        else { f->saved = f->requested; f->saved_present = 1; }
        ++f->version;
    }
    PulseSetting settings[2];
    unsigned count = 0;
    if (f->saved_present) settings[count++] = (PulseSetting){.key=view("market.downloadConcurrency"), .value={&f->saved, 1}};
    if (f->runtime_saved[0]) settings[count++] = (PulseSetting){.key=view("runtime.limits"), .value=view(f->runtime_saved)};
    PulseResourcesReply reply = {.size=sizeof(reply), .operation=wrong_operation ? PULSE_RESOURCES_STAT : f->operation,
        .request_id=f->pending, .status=status,
        .settings={.version=f->version, .values=count ? settings : NULL, .count=count}};
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
    CHECK(click(&f, 2) == 0 && !f.global && !f.image_seen);
    CHECK(click(&f, 78) == 0 && f.task); /* Existing task blocks browser dispatch. Never open a real browser in CI. */
    CHECK(click(&f, 77) == 0 && f.image_seen == 1);
    CHECK(click(&f, 77) == 0 && !f.image_seen);
    f.reject_image = 1;
    CHECK(click(&f, 77) == 0 && f.image_rejected == 1 && !f.image_seen);
    CHECK(click(&f, 77) == 0 && f.image_rejected == 1 && !f.image_seen);
    f.reject_image = 0;
    CHECK(click(&f, 40) == 0 && f.task); /* no market row: no new task */
    CHECK(click(&f, 35) == 0 && f.task);
    CHECK(click(&f, 58) == 0 && f.task); /* no selection: cannot queue */
    CHECK(click(&f, 60) == 0 && f.task); /* empty queue: cannot start */
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
    CHECK(click(&f, 52) == 0 && f.pending && !f.runtime_saved[0]);
    CHECK(deliver(&f, PULSE_OK, 0) == 0 && !strcmp(f.runtime_saved, "1024:512") && f.saved == '4');
    CHECK(click(&f, 4) == 0 && deliver(&f, PULSE_OK, 0) == 0);
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
    CHECK(f.search_token && f.search_changed && f.library_selection_token && f.library_selection_changed);
    PulseUiStateChange change = {.key=view("library.query"), .value=view("c"), .revision=1, .source_mask=PULSE_UI_STATE_USER};
    PulseUiStateBatch batch = {.revision=1, .changes=&change, .count=1};
    f.search_changed(f.search_user, f.page, &batch);
    change.value = view("cat"); change.revision = 2; batch.revision = 2;
    f.search_changed(f.search_user, f.page, &batch);
    CHECK(!f.task);
    for (unsigned i = 0; i < 100 && !f.task; ++i) { Sleep(20); pump(&f); }
    CHECK(f.task && strcmp(f.search_value, "cat") == 0);
    out.deactivate(out.instance);
    out.destroy(out.instance);
    pump(&f);
    CHECK(!f.queued && !f.search_token && !f.running_search_token && !f.library_selection_token);
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
    CHECK(!f.advanced_visible);
    CHECK(click(&f, 89) == 0 && f.advanced_visible && !f.task);
    CHECK(click(&f, 89) == 0 && !f.advanced_visible && !f.task);
    /* No diagnostic snapshot/selection: direct mutation commands must do nothing. */
    CHECK(click(&f, 23) == 0 && !f.dialog && !f.task);
    CHECK(click(&f, 24) == 0 && !f.dialog && !f.task);
    CHECK(click(&f, 27) == 0 && !f.dialog && !f.task);
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
        CHECK(click(&f, 12) == 0 && !f.task && !f.worker && !f.start_enabled);
        for (unsigned i = 0; i < 900 && !f.first_frame; ++i) { Sleep(20); pump(&f); }
        CHECK(!f.task && f.first_frame && f.stop_enabled && f.start_enabled);
        if (!cycle) {
            CHECK(click(&f, 12) == 0 && !f.task && !f.start_enabled);
            for (unsigned i = 0; i < 900 && !f.two_ready; ++i) { Sleep(20); pump(&f); }
            CHECK(!f.task && f.two_ready && f.stop_enabled);
            CHECK(click(&f, 0) == 0 && f.task && !f.worker);
            CHECK(cancel_task(&f, f.task) == PULSE_OK);
            for (unsigned i = 0; i < 100 && f.task; ++i) { Sleep(20); pump(&f); }
            CHECK(!f.task && !f.aux_task);
            CHECK(click(&f, 1) == 0 && f.first_frame && f.stop_enabled);
            CHECK(f.running_rows == 2 && f.running_search_token && f.running_search_changed);
            PulseUiStateChange change = {.key=view("running.query"), .value=view("#2"), .revision=1, .source_mask=PULSE_UI_STATE_USER};
            PulseUiStateBatch batch = {.revision=1, .changes=&change, .count=1};
            f.running_search_changed(f.running_search_user, f.page, &batch);
            CHECK(f.running_rows == 1 && f.only_second);
            change.value = view(""); change.revision = 2; batch.revision = 2;
            f.running_search_changed(f.running_search_user, f.page, &batch);
            CHECK(f.running_rows == 2 && click(&f, 14) == 0);
            for (unsigned i = 0; i < 400 && !f.only_second; ++i) { Sleep(20); pump(&f); }
            CHECK(!f.task && f.only_second && f.stop_enabled);
            CHECK(click(&f, 13) == 0 && !f.stop_enabled);
            for (unsigned i = 0; i < 400 && !f.start_enabled; ++i) { Sleep(20); pump(&f); }
            CHECK(!f.task && f.start_enabled && !f.first_frame);
        } else {
            /* Deactivate must join the extension-owned worker itself, not
             * rely on the host's finite task drain. */
            out.deactivate(out.instance);
            CHECK(!f.worker && !f.task && !f.page);
        }
    }
    out.destroy(out.instance);
    pump(&f);
    CHECK(!f.page && !f.pending && !f.worker && !f.queued);
    DeleteCriticalSection(&f.dispatch_lock);
    return 0;
}
typedef struct {
    PulsePluginEntryV1Fn entry;
    int bundled;
} OwnerRun;

static DWORD WINAPI companion_owner(LPVOID user) {
    const OwnerRun *run = user;
    PulsePluginEntryV1Fn entry = run->entry;
    if (run->bundled)
        return (DWORD)(picker_compat_session(entry, 1) != 0 ||
            picker_compat_session(entry, 0) != 0 || bundled_session(entry) != 0);
    return (DWORD)(cycle(entry, 0) != 0 || cycle(entry, 1) != 0 ||
        partial(entry) != 0 || automatic(entry) != 0);
}

static int run_on_owner(PulsePluginEntryV1Fn entry, int bundled) {
    OwnerRun run = {entry, bundled};
    HANDLE owner = CreateThread(NULL, 512 * 1024, companion_owner, &run,
        STACK_SIZE_PARAM_IS_A_RESERVATION, NULL);
    CHECK(owner);
    DWORD wait = WaitForSingleObject(owner, 180000), result = 1;
    /* A timeout must end the entire fixture, not return a borrowed pointer
       or unload a DLL while its owner thread is still executing. */
    if (wait != WAIT_OBJECT_0) {
        fprintf(stderr, "Companion owner wait failed: 0x%08lx\n", (unsigned long)wait);
        ExitProcess(1);
    }
    BOOL completed = GetExitCodeThread(owner, &result);
    CHECK(CloseHandle(owner));
    if (!completed || result != 0)
        fprintf(stderr, "Companion 512 KiB owner exit=0x%08lx\n", (unsigned long)result);
    CHECK(completed && result == 0);
    return 0;
}

int main(int argc, char **argv) {
    SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX);
    CHECK(argc == 2 || (argc == 3 && !strcmp(argv[2], "--bundled")));
    if (argc == 3) {
        HMODULE lib = LoadLibraryExA(argv[1], NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        CHECK(lib);
        PulsePluginEntryV1Fn entry = (PulsePluginEntryV1Fn)GetProcAddress(lib, "PulsePluginEntryV1");
        CHECK(entry && run_on_owner(entry, 1) == 0);
        CHECK(FreeLibrary(lib));
        puts("Bundled Companion ABI: actual first-frame, stop, restart, deactivate verified on a 512 KiB owner thread");
        return 0;
    }
    for (unsigned i = 0; i < 8; ++i) {
        HMODULE lib = LoadLibraryExA(argv[1], NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        CHECK(lib);
        PulsePluginSdkPreviewFn preview = (PulsePluginSdkPreviewFn)GetProcAddress(lib, "PulsePluginSdkPreview");
        PulsePluginEntryV1Fn entry = (PulsePluginEntryV1Fn)GetProcAddress(lib, "PulsePluginEntryV1");
        CHECK(preview && entry && preview() == PULSE_SDK_PREVIEW);
        CHECK(run_on_owner(entry, 0) == 0);
        CHECK(FreeLibrary(lib));
    }
    puts("Companion C ABI: 16 complete lifecycle scenarios, 8 partial activations and 8 automatic polling scenarios passed on 512 KiB owner threads");
    return 0;
}
