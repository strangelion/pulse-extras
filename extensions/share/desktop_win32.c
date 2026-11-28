
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <winsock2.h>
#include <windows.h>
#include <bcrypt.h>
#include <iphlpapi.h>
#include <windowsx.h>
#include <commctrl.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <stdint.h>
#include <limits.h>
#include <stdio.h>
#include <wchar.h>

enum { STACK, GRID, GROUP_BOX, TEXT, BUTTON, EDIT_FIELD, SELECT, PROGRESS, TABS, TAB, HEADING };
enum { FIRST_CONTROL = 100, MAX_NODES = 288, TIMER = 1, MOTION_TIMER = 2, NOTICE_TIMER = 3, FULL = 1000 };
enum { WHEEL_MS = 135, SECTION_MS = 200, BUTTON_MS = 110, TAB_MS = 160 };
static const int page_width[] = { 850, 552, 696, 568, 632, 760 };

typedef struct {
    ULONGLONG since;
    int value, from, to;
} Motion;
typedef struct {
    int kind, parent, appearance, pane;
    Motion hover;
    char id[64], key[64], enabled[64];
    HWND hwnd;
    RECT bounds;
    BOOL shown;
} Node;

static Node nodes[MAX_NODES];
static int count, tab, scroll, content_height, body_x, body_width, dpi = 96;
static int hot_tab = -1;
static HWND window, viewport, page, pair_popup;
static Motion scroll_motion, notice_motion;
static HWND notice, notice_text, notice_close;
static BOOL notice_severe;
static Motion tab_selection[ARRAYSIZE(page_width)] = {{ .value = FULL, .from = FULL, .to = FULL }};
static Motion tab_hover[ARRAYSIZE(page_width)];
static HWND popup_address, popup_code, popup_copy, popup_copy_addr, popup_notice, popup_close;
static DWORD copied_pair_sequence;
static BOOL pair_popup_ready, copy_address_ready;
static HFONT font, heading, caption, code_font;
static HBRUSH canvas_brush, card_brush, drop_brush;
static HDWP window_batch;
static HWND batch_parent;
static BOOL in_layout, busy, showing_code, confirming, has_bytes, contrast, long_status;
static BOOL motion_enabled, motion_timer;
static struct {
    const char *id, *key;
    HWND hwnd;
    int node;
    POINT origin;
    Motion reveal;
} sections[] = {
    { .id = "routed-pair-card", .key = "show-routed-pair" },
    { .id = "send-extras", .key = "show-send-options" },
    { .id = "receive-extras", .key = "show-receive-options" },
    { .id = "network-options", .key = "show-network-options" },
    { .id = "storage-options", .key = "show-storage-options" },
    { .id = "send-address-field", .key = "show-address-field" },
    { .id = "lan-join-form", .key = "show-lan-join" },
    { .id = "found-receivers", .key = "show-found-receivers" },
    { .id = "found-pairing", .key = "show-found-pairing" },
    { .id = "listed-peers", .key = "show-listed-peers" },
};
extern void share_desktop_command(const char *);
extern void share_desktop_tick(void);
extern int share_desktop_close(void);
extern void share_desktop_changed(const char *);
extern void share_desktop_drop(const char *, size_t, uint32_t, int);
static void layout(void);
static void layout_page(void);
static void animate(void);
static void place_notice(void);
static void dismiss_notice(void);
static LRESULT CALLBACK notice_proc(HWND, UINT, WPARAM, LPARAM);
static void select_tab(int selected);
static void set_scroll(int requested, BOOL smooth);
static LRESULT CALLBACK tabs_proc(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);
static void popup_fonts(void);
int share_desktop_clear_pair_clipboard(void);

static int scale(int value) { return MulDiv(value, dpi, 96); }
static BOOL prefer_motion(void) {
    BOOL enabled = FALSE;
    return !contrast && SystemParametersInfoW(SPI_GETCLIENTAREAANIMATION, 0, &enabled, 0) && enabled;
}

static BOOL advance(Motion *motion, ULONGLONG now, unsigned duration) {
    if (!motion->since) return FALSE;
    int old = motion->value;
    ULONGLONG elapsed = now - motion->since;
    if (!motion_enabled || elapsed >= duration) {
        motion->since = 0;
        motion->value = motion->to;
    } else {
        int remaining = FULL - (int)(elapsed * FULL / duration);
        int progress = FULL - remaining * remaining * remaining / (FULL * FULL);
        motion->value = motion->from + MulDiv(motion->to - motion->from, progress, FULL);
    }
    return old != motion->value;
}

static void retarget(Motion *motion, int goal) {
    if (motion->to == goal) return;
    motion->from = motion->value;
    motion->to = goal;
    if (motion_enabled && IsWindowVisible(window) && motion->value != goal) {
        if (!motion_timer) motion_timer = SetTimer(window, MOTION_TIMER, 16, NULL) != 0;
        if (motion_timer) {
            motion->since = GetTickCount64();
            return;
        }
    }
    motion->since = 0;
    motion->value = goal;
}

static COLORREF blend(COLORREF a, COLORREF b, int share) {
    return RGB((GetRValue(a) * (FULL - share) + GetRValue(b) * share) / FULL,
        (GetGValue(a) * (FULL - share) + GetGValue(b) * share) / FULL,
        (GetBValue(a) * (FULL - share) + GetBValue(b) * share) / FULL);
}

static COLORREF canvas(void) { return contrast ? GetSysColor(COLOR_WINDOW) : RGB(244, 246, 249); }
static COLORREF card(void) { return contrast ? GetSysColor(COLOR_WINDOW) : RGB(255, 255, 255); }
static COLORREF ink(void) { return contrast ? GetSysColor(COLOR_WINDOWTEXT) : RGB(27, 35, 49); }
static COLORREF drop_color(void) { return contrast ? GetSysColor(COLOR_WINDOW) : RGB(234, 239, 250); }
static COLORREF border(void) { return contrast ? GetSysColor(COLOR_WINDOWTEXT) : RGB(216, 222, 233); }

static void surface(HDC dc, RECT box, COLORREF fill, COLORREF line, int radius) {
    HBRUSH brush = CreateSolidBrush(fill);
    HPEN pen = CreatePen(PS_SOLID, 1, line);
    HGDIOBJ old_brush = SelectObject(dc, brush), old_pen = SelectObject(dc, pen);
    RoundRect(dc, box.left, box.top, box.right, box.bottom, scale(radius), scale(radius));
    SelectObject(dc, old_pen);
    SelectObject(dc, old_brush);
    DeleteObject(pen);
    DeleteObject(brush);
}

static void wide(const char *input, int length, wchar_t *out, int capacity) {
    int size = length && length < 8192 ?
        MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, input, length, out, capacity - 1) : 0;
    out[size > 0 ? size : 0] = 0;
}

static const char *canonical(const char *key) {
    return strncmp(key, "state.", 6) == 0 ? key + 6 : key;
}

static int find(const char *id) {
    for (int i = 0; i < count; i++) if (!strcmp(nodes[i].id, id)) return i;
    return -1;
}

static int find_kind(int kind) {
    for (int i = 0; i < count; i++) if (nodes[i].kind == kind) return i;
    return -1;
}

static int section_for(const char *id) {
    for (size_t i = 0; i < ARRAYSIZE(sections); i++)
        if (!strcmp(id, sections[i].id)) return (int)i;
    return -1;
}

static HWND pane_window(int pane) {
    return pane < 0 ? page : sections[pane].hwnd;
}

static BOOL in_task(int i) {
    for (; i >= 0; i = nodes[i].parent)
        if (!strcmp(nodes[i].id, "task-group")) return TRUE;
    return FALSE;
}

static void set_text(HWND hwnd, const wchar_t *text) {
    wchar_t before[8192];
    GetWindowTextW(hwnd, before, ARRAYSIZE(before));
    if (wcscmp(before, text)) SetWindowTextW(hwnd, text);
    SecureZeroMemory(before, sizeof(before));
}

static BOOL inside_card(int i) {
    for (; i >= 0; i = nodes[i].parent)
        if (nodes[i].kind == GROUP_BOX) return TRUE;
    return FALSE;
}

static HFONT node_font(const Node *node) {
    if (!strcmp(node->id, "pair-code")) return code_font;
    if (node->kind == HEADING) return heading;
    if (node->kind == GROUP_BOX) return caption;
    return font;
}

static void fonts(void) {
    HFONT previous[] = {font, heading, caption, code_font};
    font = CreateFontW(-scale(15), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    heading = CreateFontW(-scale(25), 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    caption = CreateFontW(-scale(16), 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    code_font = CreateFontW(-scale(28), 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
        0, 0, CLEARTYPE_QUALITY, 0, L"Consolas");
    for (int i = 0; i < count; i++)
        if (nodes[i].hwnd) SendMessageW(nodes[i].hwnd, WM_SETFONT, (WPARAM)node_font(&nodes[i]), TRUE);
    popup_fonts();
    if (notice_text) SendMessageW(notice_text, WM_SETFONT, (WPARAM)font, TRUE);
    if (notice_close) SendMessageW(notice_close, WM_SETFONT, (WPARAM)font, TRUE);
    for (size_t i = 0; i < ARRAYSIZE(previous); i++) DeleteObject(previous[i]);
}

static LRESULT CALLBACK button_proc(HWND hwnd, UINT msg, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR data) {
    (void)id;
    Node *node = (Node *)data;
    if (msg == WM_MOUSEMOVE && node->hover.to != FULL && IsWindowEnabled(hwnd)) {
        TRACKMOUSEEVENT mouse = {sizeof(mouse), TME_LEAVE, hwnd, 0};
        if (TrackMouseEvent(&mouse)) {
            retarget(&node->hover, FULL);
            InvalidateRect(hwnd, NULL, FALSE);
        }
    } else if (msg == WM_MOUSELEAVE || (msg == WM_ENABLE && !w)) {
        retarget(&node->hover, 0);
        InvalidateRect(hwnd, NULL, FALSE);
    }
    return DefSubclassProc(hwnd, msg, w, l);
}

int share_desktop_node(int parent, int kind, const char *id, const char *key,
                       const char *enabled, const char *text, int length, int appearance) {
    int index = find(id);
    if (index >= 0) return nodes[index].parent == parent && nodes[index].kind == kind ? index : -1;
    if (count == MAX_NODES || strlen(id) >= sizeof(nodes[0].id) ||
        strlen(key) >= sizeof(nodes[0].key) || strlen(enabled) >= sizeof(nodes[0].enabled)) return -1;
    index = count++;
    Node *node = &nodes[index];
    node->kind = kind;
    node->appearance = appearance;
    node->parent = parent;
    strcpy(node->id, id);
    strcpy(node->key, canonical(key));
    strcpy(node->enabled, canonical(enabled));
    const wchar_t *class_name = NULL;
    DWORD style = WS_CHILD | WS_CLIPSIBLINGS, ex = 0;
    int section = section_for(id);
    node->pane = parent >= 0 ? nodes[parent].pane : -1;
    if (section >= 0) {
        HWND clip = CreateWindowExW(WS_EX_CONTROLPARENT, L"PulseSharePage", NULL,
            WS_CHILD | WS_CLIPSIBLINGS | WS_CLIPCHILDREN, 0, 0, 0, 0, pane_window(node->pane),
            NULL, GetModuleHandleW(NULL), NULL);
        if (!clip) return -1;
        SetWindowLongPtrW(clip, GWLP_USERDATA, section + 1);
        sections[section].hwnd = clip;
        sections[section].node = index;
        node->pane = section;
    }
    HWND owner = in_task(index) || kind == TABS ? window : pane_window(node->pane);
    switch (kind) {
    case HEADING: class_name = L"Static"; style |= SS_CENTER; break;
    case GROUP_BOX: class_name = L"Static"; break;
    case TEXT:
        if (key[0] && strcmp(id, "pair-code") && strcmp(id, "byte-count") &&
            strcmp(id, "current-peer") && strcmp(id, "receive-peer") && strcmp(id, "pair-help") &&
            strcmp(id, "save-location") && strcmp(id, "current-network") && strcmp(id, "send-endpoint-label")) {
            class_name = L"Edit";
            style |= WS_TABSTOP | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY;
            if (!strcmp(id, "source")) style |= ES_CENTER;
            else if (strcmp(id, "discovery-text")) style |= WS_VSCROLL;
        } else class_name = L"Static";
        break;
    case BUTTON: class_name = L"Button"; style |= WS_TABSTOP | BS_NOTIFY | (contrast ? BS_PUSHBUTTON : BS_OWNERDRAW); break;
    case EDIT_FIELD:
        class_name = L"Edit";
        style |= WS_TABSTOP | ES_AUTOHSCROLL | (appearance == 1 ? ES_PASSWORD : 0);
        ex = WS_EX_CLIENTEDGE;
        break;
    case SELECT: class_name = L"ComboBox"; style |= WS_TABSTOP | CBS_DROPDOWNLIST | WS_VSCROLL; break;
    case PROGRESS: class_name = PROGRESS_CLASSW; break;
    case TABS:
        class_name = WC_TABCONTROLW;
        style |= WS_TABSTOP | TCS_BUTTONS | TCS_FIXEDWIDTH;
        break;
    case TAB: {
        wchar_t caption[64];
        wide(text, length, caption, ARRAYSIZE(caption));
        TCITEMW item = { .mask = TCIF_TEXT, .pszText = caption };
        HWND tabs = nodes[parent].hwnd;
        if (SendMessageW(tabs, TCM_INSERTITEMW, TabCtrl_GetItemCount(tabs), (LPARAM)&item) < 0) return -1;
        break;
    }
    default: break;
    }
    if (class_name) {
        wchar_t caption[8192];
        wide(text, length, caption, ARRAYSIZE(caption));
        node->hwnd = CreateWindowExW(ex, class_name, kind == EDIT_FIELD ? L"" : caption, style, 0, 0, 0, 0,
            owner, (HMENU)(INT_PTR)(FIRST_CONTROL + index), GetModuleHandleW(NULL), NULL);
        if (!node->hwnd) return -1;
        SendMessageW(node->hwnd, WM_SETFONT, (WPARAM)node_font(node), TRUE);
        if (!strcmp(id, "status-line")) ShowScrollBar(node->hwnd, SB_VERT, FALSE);
        if (kind == BUTTON && !contrast) SetWindowSubclass(node->hwnd, button_proc, 1, (DWORD_PTR)node);
        if (kind == TABS && !contrast) SetWindowSubclass(node->hwnd, tabs_proc, 1, 0);
        if (kind == EDIT_FIELD) {
            SendMessageW(node->hwnd, EM_SETLIMITTEXT, appearance == 1 ? 8 : 2047, 0);
            if (caption[0]) SendMessageW(node->hwnd, EM_SETCUEBANNER, TRUE, (LPARAM)caption);
        }
    }
    return index;
}

void share_desktop_options(int i, int reset, const char *value, int length) {
    HWND hwnd = nodes[i].hwnd;
    if (reset) SendMessageW(hwnd, CB_RESETCONTENT, 0, 0);
    wchar_t item[256];
    wide(value, length, item, ARRAYSIZE(item));
    if (length) SendMessageW(hwnd, CB_ADDSTRING, 0, (LPARAM)item);
    if (reset) SendMessageW(hwnd, CB_SETCURSEL, 0, 0);
}

void share_desktop_set(const char *key, const char *value, int length) {
    wchar_t text[8192];
    wide(value, length, text, ARRAYSIZE(text));
    BOOL relayout = FALSE, on = !wcscmp(text, L"true");
    if (!strcmp(key, "busy") && busy != on) { busy = on; relayout = TRUE; }
    if (!strcmp(key, "pair-popup-ready") && pair_popup_ready != on) { pair_popup_ready = on; relayout = TRUE; }
    if (!strcmp(key, "copy-address-ready") && copy_address_ready != on) { copy_address_ready = on; relayout = TRUE; }
    if (!strcmp(key, "confirm") && confirming != on) { confirming = on; relayout = TRUE; }
    BOOL reflow = FALSE;
    for (size_t i = 0; i < ARRAYSIZE(sections); i++) {
        Motion *reveal = &sections[i].reveal;
        int goal = on ? FULL : 0;
        if (!strcmp(key, sections[i].key) && reveal->to != goal) {
            HWND clip = sections[i].hwnd;
            HWND focus = GetFocus();
            if (clip && !on && focus && IsChild(clip, focus)) {
                int nav = find_kind(TABS);
                if (nav >= 0) SetFocus(nodes[nav].hwnd);
            }
            if (clip) EnableWindow(clip, on);
            retarget(reveal, goal);
            reflow = TRUE;
        }
    }
    if (!strcmp(key, "pair-code") && showing_code != (length != 0)) { showing_code = length != 0; relayout = TRUE; }
    if (!strcmp(key, "bytes") && has_bytes != (length != 0)) { has_bytes = length != 0; relayout = TRUE; }
    if (!strcmp(key, "status")) {
        BOOL large = wcschr(text, L'\n') != NULL || wcslen(text) > 42;
        if (long_status != large) { long_status = large; relayout = TRUE; }
    }
    for (int i = 0; i < count; i++) {
        Node *n = &nodes[i];
        if (!n->hwnd) continue;
        if (n->enabled[0] && !strcmp(n->enabled, key) && IsWindowEnabled(n->hwnd) != on)
            EnableWindow(n->hwnd, on);
        if (!n->key[0] || strcmp(n->key, key)) continue;
        if (n->kind == SELECT) SendMessageW(n->hwnd, CB_SETCURSEL, (WPARAM)wcstol(text, NULL, 10), 0);
        else if (n->kind == PROGRESS) SendMessageW(n->hwnd, PBM_SETPOS, (WPARAM)wcstol(text, NULL, 10), 0);
        else if (n->kind == TABS) {
            int selected = (int)wcstol(text, NULL, 10);
            select_tab(selected);
        }
        else if (n->kind == TEXT || n->kind == EDIT_FIELD || n->kind == BUTTON) {
            set_text(n->hwnd, text);
            if (relayout && !strcmp(n->id, "status-line")) ShowScrollBar(n->hwnd, SB_VERT, long_status);
        }
    }
    SecureZeroMemory(text, sizeof(text));
    if (relayout) layout();
    else if (reflow) layout_page();
}

int share_desktop_get(const char *key, char *out, int capacity) {
    for (int i = 0; i < count; i++) {
        Node *n = &nodes[i];
        if (!n->key[0] || strcmp(n->key, key)) continue;
        if (n->kind == SELECT) {
            int cur = (int)SendMessageW(n->hwnd, CB_GETCURSEL, 0, 0);
            return snprintf(out, capacity, "%d", cur < 0 ? 0 : cur);
        }
        if (n->kind == EDIT_FIELD) {
            wchar_t text[2048];
            int length = GetWindowTextW(n->hwnd, text, ARRAYSIZE(text));
            if (!length) return 0;
            int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, length, out, capacity, NULL, NULL);
            SecureZeroMemory(text, sizeof(text));
            return size ? size : -1;
        }
    }
    return -1;
}

static int text_height(HWND hwnd, int width) {
    wchar_t text[2048];
    GetWindowTextW(hwnd, text, ARRAYSIZE(text));
    HDC dc = GetDC(hwnd);
    HGDIOBJ before = SelectObject(dc, font);
    RECT box = {0, 0, width, 0};
    int height = DrawTextW(dc, text, -1, &box, DT_CALCRECT | DT_WORDBREAK | DT_NOPREFIX);
    SelectObject(dc, before);
    ReleaseDC(hwnd, dc);
    return max(height, scale(20));
}

static void position(HWND hwnd, int x, int y, int width, int height, UINT visibility) {
    const UINT flags = SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOREDRAW | visibility;
    if (window_batch && GetParent(hwnd) == batch_parent) {
        window_batch = DeferWindowPos(window_batch, hwnd, NULL, x, y, width, height, flags);
        if (window_batch) return;
    }
    SetWindowPos(hwnd, NULL, x, y, width, height, flags);
}

static void position_child(HWND hwnd, int pane, int x, int y, int width, int height, UINT flags) {
    POINT origin = pane >= 0 ? sections[pane].origin : (POINT){0, 0};
    position(hwnd, x - origin.x, y - origin.y, width, height, flags);
}

static BOOL omitted_from_layout(const Node *n) {
    int section = section_for(n->id);
    if (section >= 0 && !sections[section].reveal.value && !sections[section].reveal.to) return TRUE;
    return (!strcmp(n->id, "share-open-pair-popup") && !pair_popup_ready) ||
        (!strcmp(n->id, "share-copy-address") && !copy_address_ready) ||
        (!strcmp(n->id, "pair-code") && !showing_code) ||
        ((!strcmp(n->id, "byte-count") || n->kind == PROGRESS) && !has_bytes) ||
        (!strcmp(n->id, "share-cancel") && !busy) ||
        ((!strcmp(n->id, "share-approve") || !strcmp(n->id, "share-decline")) && !confirming);
}

static int place(int i, int x, int y, int width, BOOL visible) {
    Node *n = &nodes[i];
    BOOL omitted = omitted_from_layout(n);
    int section = section_for(n->id);
    if (section >= 0) {
        sections[section].origin = (POINT){ x, y };
        if ((!visible || omitted) && (GetWindowLongPtrW(sections[section].hwnd, GWL_STYLE) & WS_VISIBLE))
            position(sections[section].hwnd, 0, 0, 0, 0, SWP_HIDEWINDOW | SWP_NOMOVE | SWP_NOSIZE);
    }
    if ((!visible || omitted) && n->hwnd && n->kind != TABS &&
        (GetWindowLongPtrW(n->hwnd, GWL_STYLE) & WS_VISIBLE))
        position(n->hwnd, 0, 0, 0, 0, SWP_HIDEWINDOW | SWP_NOMOVE | SWP_NOSIZE);
    n->shown = visible && !omitted;
    if (!visible || omitted) {
        for (int j = i + 1; j < count; j++)
            if (nodes[j].parent == i && nodes[j].shown) place(j, x, y, width, FALSE);
        return 0;
    }
    if (n->kind == TABS) {
        int ordinal = 0;
        for (int j = i + 1; j < count; j++) if (nodes[j].parent == i) {
            int height = place(j, x, y, width, ordinal++ == tab);
            if (ordinal - 1 == tab) content_height = height + scale(16);
        }
        return 0;
    }
    int height = 0;
    if (n->kind == GRID || n->kind == STACK || n->kind == TAB || n->kind == GROUP_BOX) {
        BOOL cards = !strcmp(n->id, "send-cards");
        BOOL grouping = n->kind == GROUP_BOX && !in_task(i);
        int pad = grouping ? scale(18) : 0;
        int gap = scale(cards ? 16 : 9);
        int title = n->kind == GROUP_BOX && (grouping || busy || long_status) ? scale(27) : 0;
        BOOL columns = n->kind == GRID && width >= scale(cards ? 680 : 290);
        int inside = max(80, width - 2 * pad);
        int cell = columns ? (inside - gap) / 2 : inside;
        int row = 0, slot = 0, remaining = 0;
        for (int j = i + 1; j < count; j++)
            if (nodes[j].parent == i && !omitted_from_layout(&nodes[j])) remaining++;
        if (n->kind == GRID && !cards) cell = min(cell, scale(columns ? 268 : 330));
        height = title + pad;
        for (int j = i + 1; j < count; j++) if (nodes[j].parent == i) {
            BOOL pair = columns && (slot == 1 || remaining > 1);
            int span = pair ? 2 * cell + gap : cell;
            int start = x + pad + (inside - span) / 2;
            int h = place(j, start + slot * (cell + gap), y + height, cell, visible);
            if (h == 0) continue;
            remaining--;
            row = max(row, h);
            if (!pair || slot == 1) {
                height += row + gap;
                slot = row = 0;
            } else slot = 1;
        }
        if (slot) height += row + gap;
        if (height > title + pad) height -= gap;
        height += pad;
        if (grouping && (!strcmp(n->id, "source-card") || !strcmp(n->id, "target-card")))
            height = max(height, scale(218));
        SetRect(&n->bounds, x, y, x + width, y + height);
        if (n->hwnd && visible) position_child(n->hwnd, n->pane, x + pad, y + pad, width - 2 * pad, title,
            title ? SWP_SHOWWINDOW : SWP_HIDEWINDOW);
        if (section >= 0) {
            height = MulDiv(height, sections[section].reveal.value, FULL);
            if (visible) position_child(sections[section].hwnd, n->parent >= 0 ? nodes[n->parent].pane : -1,
                x, y, width, height, SWP_SHOWWINDOW);
        }
        return height;
    }
    switch (n->kind) {
    case TEXT:
        height = !strcmp(n->id, "pair-code") ? scale(34) :
            !strcmp(n->id, "status-line") ? scale(long_status ? 51 : 24) :
            !strcmp(n->id, "source") ? scale(76) :
            !strcmp(n->id, "discovery-text") ? scale(43) :
            !strcmp(n->id, "history-text") || !strcmp(n->id, "diagnostic-text") || strstr(n->id, "-inventory") ? scale(68) :
            text_height(n->hwnd, width);
        break;
    case HEADING: height = scale(39); break;
    case PROGRESS: height = scale(7); break;
    case BUTTON: {
        height = scale(36);
        int button_width = min(width, scale(316));
        x += (width - button_width) / 2;
        width = button_width;
        break;
    }
    default: height = scale(36); break;
    }
    SetRect(&n->bounds, x, y, x + width, y + height);
    if (visible) {
        position_child(n->hwnd, n->pane, x, y, width, n->kind == SELECT ? scale(280) : height, SWP_SHOWWINDOW);
    }
    return height;
}

static int scroll_limit(void) {
    RECT inner;
    GetClientRect(viewport, &inner);
    return max(0, content_height - inner.bottom);
}

static void move_page(int requested) {
    int next = max(0, min(requested, scroll_limit()));
    if (scroll == next) return;
    if (SetWindowPos(page, NULL, 0, -next, 0, 0, SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOSIZE)) {
        scroll = next;
        SetScrollPos(viewport, SB_VERT, scroll, TRUE);
    }
}

static void set_scroll(int requested, BOOL smooth) {
    requested = max(0, requested);
    if (smooth) {
        if (scroll_motion.to == requested) return;
        // Rebase an interrupted gesture on the actual visible offset.
        scroll_motion.value = scroll;
        retarget(&scroll_motion, requested);
        move_page(scroll_motion.value);
    } else {
        scroll_motion = (Motion){ .value = requested, .to = requested };
        move_page(requested);
    }
}

static void place_page(int tabs) {
    batch_parent = page;
    window_batch = BeginDeferWindowPos(count);
    place(tabs, body_x, scale(4), body_width, TRUE);
    BOOL committed = window_batch && EndDeferWindowPos(window_batch);
    window_batch = NULL;
    if (!committed) place(tabs, body_x, scale(4), body_width, TRUE);

    RECT inner;
    GetClientRect(viewport, &inner);
    BOOL overflow = content_height > inner.bottom;
    BOOL has_scrollbar = (GetWindowLongPtrW(viewport, GWL_STYLE) & WS_VSCROLL) != 0;
    if (overflow != has_scrollbar) {
        ShowScrollBar(viewport, SB_VERT, overflow);
        GetClientRect(viewport, &inner);
    }
    scroll = max(0, min(scroll, content_height - inner.bottom));
    if (!scroll_motion.since) scroll_motion.value = scroll_motion.to = scroll;
    position(page, 0, -scroll, inner.right, max(content_height, inner.bottom), SWP_SHOWWINDOW);
    SCROLLINFO info = { .cbSize = sizeof(info), .fMask = SIF_RANGE | SIF_PAGE | SIF_POS,
        .nMax = max(0, content_height - 1), .nPage = (UINT)inner.bottom, .nPos = scroll };
    SetScrollInfo(viewport, SB_VERT, &info, TRUE);
    int source = find("source");
    if (source >= 0 && nodes[source].shown) {
        RECT edit;
        GetClientRect(nodes[source].hwnd, &edit);
        edit.left += scale(15);
        edit.right -= scale(15);
        edit.top += scale(17);
        edit.bottom -= scale(8);
        SendMessageW(nodes[source].hwnd, EM_SETRECTNP, 0, (LPARAM)&edit);
    }
    RedrawWindow(viewport, NULL, NULL, RDW_INVALIDATE | RDW_NOERASE | RDW_ALLCHILDREN);
}

static void layout_page(void) {
    if (!page || in_layout || !body_width) return;
    const int tabs = find_kind(TABS);
    if (tabs < 0) return;
    in_layout = TRUE;
    place_page(tabs);
    in_layout = FALSE;
}

static void layout(void) {
    if (!page || in_layout) return;
    in_layout = TRUE;
    RECT box;
    GetClientRect(window, &box);
    int inset = scale(box.right >= scale(700) ? 28 : 16);
    int width = max(scale(140), min(box.right - 2 * inset, scale(850)));
    int x = (box.right - width) / 2;
    int task = find("task-group"), tabs = find_kind(TABS);
    int rows = confirming ? (width >= scale(290) ? 2 : 3) : busy ? 1 : 0;
    int task_height = scale((busy || long_status ? 87 : 40) + 45 * rows +
        (showing_code ? 43 : 0) + (has_bytes ? 45 : 0));
    int top = scale(64), bottom = box.bottom - task_height;
    position(viewport, x, top, width, max(bottom - top, 0), 0);
    if (tabs >= 0) {
        HWND nav = nodes[tabs].hwnd;
        int item_width = max(scale(50), min((width - scale(42)) / max(1, TabCtrl_GetItemCount(nav)), scale(96)));
        TabCtrl_SetItemSize(nav, item_width, scale(34));
        int nav_width = min(width, TabCtrl_GetItemCount(nav) * (item_width + scale(3)) + scale(6));
        position(nav, (box.right - nav_width) / 2, scale(14), nav_width, scale(42), SWP_SHOWWINDOW);
        // Reserve the gutter even when the vertical scrollbar is hidden.
        int gutter = GetSystemMetricsForDpi(SM_CXVSCROLL, dpi) + scale(6);
        int usable_width = max(scale(110), width - 2 * gutter);
        body_width = min(usable_width, scale(page_width[tab]));
        body_x = (width - body_width) / 2;
        place_page(tabs);
        InvalidateRect(nav, NULL, FALSE);
    }
    if (task >= 0) {
        batch_parent = window;
        window_batch = BeginDeferWindowPos(10);
        place(task, x + body_x, bottom + scale(8), body_width, TRUE);
        BOOL committed = window_batch && EndDeferWindowPos(window_batch);
        window_batch = NULL;
        if (!committed) place(task, x + body_x, bottom + scale(8), body_width, TRUE);
        for (int i = 0; i < count; i++)
            if (nodes[i].hwnd && GetParent(nodes[i].hwnd) == window && in_task(i)) InvalidateRect(nodes[i].hwnd, NULL, FALSE);
    }
    RedrawWindow(window, NULL, NULL, RDW_INVALIDATE | RDW_NOERASE | RDW_NOCHILDREN);
    place_notice();
    in_layout = FALSE;
}

static void select_tab(int selected) {
    if (selected < 0 || selected >= (int)ARRAYSIZE(page_width) || selected == tab) return;
    int tabs = find_kind(TABS);
    if (tabs < 0) return;
    HWND nav = nodes[tabs].hwnd;
    HWND focus = GetFocus();
    if (focus && IsChild(page, focus)) SetFocus(nav);
    retarget(&tab_selection[tab], 0);
    retarget(&tab_selection[selected], FULL);
    tab = selected;
    TabCtrl_SetCurSel(nav, tab);
    set_scroll(0, FALSE);
    layout();
}

void share_desktop_layout(void) { layout(); }

void share_desktop_show_section(const char *id) {
    int i = find(id);
    if (i < 0 || !nodes[i].shown) return;
    RECT inner;
    GetClientRect(viewport, &inner);
    int top = nodes[i].bounds.top - scroll;
    int margin = scale(10);
    if (top < margin) set_scroll(nodes[i].bounds.top - margin, TRUE);
    else if (top > inner.bottom - scale(100)) set_scroll(nodes[i].bounds.top - max(margin, inner.bottom / 3), TRUE);
}

static LRESULT CALLBACK view_proc(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
    switch (msg) {
    case WM_ERASEBKGND: return 1;
    case WM_PAINT: {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(hwnd, &paint);
        int pane = (int)GetWindowLongPtrW(hwnd, GWLP_USERDATA) - 1;
        HBRUSH background = pane >= 0 && inside_card(nodes[sections[pane].node].parent) ? card_brush : canvas_brush;
        FillRect(dc, &paint.rcPaint, background);
        if (hwnd != viewport) {
            POINT origin = pane >= 0 ? sections[pane].origin : (POINT){0, 0};
            for (int i = 0; i < count; i++) {
                const Node *n = &nodes[i];
                if (n->kind != GROUP_BOX || !n->shown || n->pane != pane || in_task(i)) continue;
                RECT card_box = n->bounds, changed;
                OffsetRect(&card_box, -origin.x, -origin.y);
                if (IntersectRect(&changed, &card_box, &paint.rcPaint))
                    surface(dc, card_box, card(), border(), 20);
            }
        }
        EndPaint(hwnd, &paint);
        return 0;
    }
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLOREDIT:
    case WM_DRAWITEM:
    case WM_COMMAND:
    case WM_MOUSEWHEEL:
        return SendMessageW(window, msg, w, l);
    case WM_VSCROLL: {
        if (hwnd != viewport || l) return DefWindowProcW(hwnd, msg, w, l);
        SCROLLINFO info = { .cbSize = sizeof(info), .fMask = SIF_TRACKPOS };
        GetScrollInfo(hwnd, SB_VERT, &info);
        switch (LOWORD(w)) {
        case SB_THUMBPOSITION:
        case SB_THUMBTRACK: set_scroll(info.nTrackPos, FALSE); break;
        case SB_LINEUP: set_scroll(scroll - scale(28), FALSE); break;
        case SB_LINEDOWN: set_scroll(scroll + scale(28), FALSE); break;
        case SB_PAGEUP: set_scroll(scroll - scale(160), FALSE); break;
        case SB_PAGEDOWN: set_scroll(scroll + scale(160), FALSE); break;
        case SB_TOP: set_scroll(0, FALSE); break;
        case SB_BOTTOM: set_scroll(scroll_limit(), FALSE); break;
        }
        return 0;
    }
    default: return DefWindowProcW(hwnd, msg, w, l);
    }
}

static void drop(HDROP request) {
    UINT count = DragQueryFileW(request, 0xffffffff, NULL, 0);
    char paths[2048] = {0};
    size_t length = 0;
    int single_file = 0;
    if (count > 0 && count <= 64) for (UINT i = 0; i < count; i++) {
        wchar_t path[2048];
        UINT n = DragQueryFileW(request, i, NULL, 0);
        if (n == 0 || n >= ARRAYSIZE(path) || DragQueryFileW(request, i, path, ARRAYSIZE(path)) != n) {
            length = 0;
            break;
        }
        if (i) paths[length++] = '|';
        int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, (int)n,
            paths + length, (int)(sizeof(paths) - length - 1), NULL, NULL);
        if (!size) { length = 0; break; }
        if (!i && count == 1) {
            DWORD attrs = GetFileAttributesW(path);
            if (attrs == INVALID_FILE_ATTRIBUTES) { length = 0; break; }
            single_file = !(attrs & FILE_ATTRIBUTE_DIRECTORY);
        }
        length += (size_t)size;
        if (length >= sizeof(paths) - 1 && i + 1 != count) { length = 0; break; }
    }
    DragFinish(request);
    share_desktop_drop(paths, length, count, single_file);
}

static BOOL draw_control(const DRAWITEMSTRUCT *item) {
    HDC dc = item->hDC;
    RECT area = item->rcItem;
    wchar_t text[160] = {0};
    COLORREF fill, line, fg;
    if (item->CtlType == ODT_TAB) {
        TCITEMW tab_item = { .mask = TCIF_TEXT, .pszText = text, .cchTextMax = ARRAYSIZE(text) };
        SendMessageW(item->hwndItem, TCM_GETITEMW, item->itemID, (LPARAM)&tab_item);
        FillRect(dc, &area, canvas_brush);
        int selected = item->itemID < ARRAYSIZE(tab_selection) ? tab_selection[item->itemID].value : 0;
        InflateRect(&area, -scale(3), -scale(2));
        int hover = item->itemID < ARRAYSIZE(tab_hover) ? tab_hover[item->itemID].value : 0;
        COLORREF idle = blend(canvas(), RGB(233, 238, 248), hover);
        fill = blend(idle, RGB(221, 229, 247), selected);
        line = fill;
        fg = blend(ink(), RGB(48, 68, 141), selected);
    } else if (item->CtlType == ODT_BUTTON) {
        int i = (int)item->CtlID - FIRST_CONTROL;
        const Node *n = i >= 0 && i < count ? &nodes[i] : NULL;
        if (!n && item->hwndItem != notice_close) return FALSE;
        BOOL disabled = (item->itemState & ODS_DISABLED) != 0;
        BOOL down = (item->itemState & ODS_SELECTED) != 0;
        BOOL primary = n && n->appearance == 2 && !disabled;
        FillRect(dc, &area, !n || (inside_card(i) && !in_task(i)) ? card_brush : canvas_brush);
        COLORREF idle = primary ? RGB(52, 72, 155) : card();
        COLORREF hovered = primary ? RGB(68, 90, 181) : RGB(232, 237, 248);
        COLORREF pressed = primary ? RGB(35, 49, 107) : RGB(214, 222, 239);
        fill = disabled ? RGB(239, 241, 246) : down ? pressed : blend(idle, hovered, n ? n->hover.value : 0);
        if (down && motion_enabled) {
            area.top += scale(1);
            InflateRect(&area, -scale(1), 0);
        }
        line = primary ? fill : border();
        fg = primary ? RGB(255, 255, 255) : disabled ? RGB(104, 112, 129) : ink();
        GetWindowTextW(item->hwndItem, text, ARRAYSIZE(text));
    } else return FALSE;
    surface(dc, area, fill, line, 12);
    HGDIOBJ old_font = SelectObject(dc, item->CtlType == ODT_TAB ? caption : font);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, fg);
    InflateRect(&area, -scale(7), -scale(2));
    DrawTextW(dc, text, -1, &area, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    if ((item->itemState & ODS_FOCUS) && !(item->itemState & ODS_NOFOCUSRECT)) DrawFocusRect(dc, &area);
    SelectObject(dc, old_font);
    return TRUE;
}

static void draw_tabs(HWND hwnd, HDC dc) {
    RECT client;
    GetClientRect(hwnd, &client);
    FillRect(dc, &client, canvas_brush);
    int focus = TabCtrl_GetCurFocus(hwnd);
    for (int i = 0; i < TabCtrl_GetItemCount(hwnd); i++) {
        DRAWITEMSTRUCT item = { .CtlType = ODT_TAB, .itemID = (UINT)i,
            .itemState = i == focus && GetFocus() == hwnd ? ODS_FOCUS : 0, .hwndItem = hwnd, .hDC = dc };
        if (TabCtrl_GetItemRect(hwnd, i, &item.rcItem)) draw_control(&item);
    }
}

static void hover_tab(HWND hwnd, int next) {
    if (next < 0 || next >= (int)ARRAYSIZE(tab_hover)) next = -1;
    if (hot_tab == next) return;
    if (hot_tab >= 0) retarget(&tab_hover[hot_tab], 0);
    if (next >= 0) retarget(&tab_hover[next], FULL);
    hot_tab = next;
    InvalidateRect(hwnd, NULL, FALSE);
}

static LRESULT CALLBACK tabs_proc(HWND hwnd, UINT msg, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR data) {
    (void)id; (void)data;
    switch (msg) {
    case WM_MOUSEMOVE: {
        TCHITTESTINFO hit = { .pt = { GET_X_LPARAM(l), GET_Y_LPARAM(l) } };
        int next = TabCtrl_HitTest(hwnd, &hit);
        if (hot_tab != next) {
            TRACKMOUSEEVENT mouse = {sizeof(mouse), TME_LEAVE, hwnd, 0};
            if (TrackMouseEvent(&mouse)) hover_tab(hwnd, next);
        }
        break;
    }
    case WM_MOUSELEAVE:
        hover_tab(hwnd, -1);
        break;
    case WM_ERASEBKGND: return 1;
    case WM_PRINTCLIENT: draw_tabs(hwnd, (HDC)w); return 0;
    case WM_PAINT: {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(hwnd, &paint);
        draw_tabs(hwnd, dc);
        EndPaint(hwnd, &paint);
        return 0;
    }
    }
    return DefSubclassProc(hwnd, msg, w, l);
}

static HBRUSH control_background(HWND hwnd, HDC dc, BOOL editable) {
    int id = GetDlgCtrlID(hwnd) - FIRST_CONTROL;
    const Node *n = id >= 0 && id < count ? &nodes[id] : NULL;
    BOOL drop_target = n && !strcmp(n->id, "source");
    BOOL in_card = n && inside_card(id) && !in_task(id);
    SetTextColor(dc, ink());
    SetBkColor(dc, drop_target ? drop_color() : editable || in_card ? card() : canvas());
    return drop_target ? drop_brush : editable || in_card ? card_brush : canvas_brush;
}

static void reveal(int id) {
    const Node *n = &nodes[id];
    if (in_layout || !n->shown || !IsChild(page, n->hwnd)) return;
    RECT inner;
    GetClientRect(viewport, &inner);
    if (n->bounds.top < scroll) set_scroll(n->bounds.top - scale(4), FALSE);
    else if (n->bounds.bottom > scroll + inner.bottom) set_scroll(n->bounds.bottom - inner.bottom + scale(4), FALSE);
}

static void place_notice(void) {
    if (!notice) return;
    if (!notice_motion.to && !notice_motion.value) {
        if (IsWindowVisible(notice)) ShowWindow(notice, SW_HIDE);
        return;
    }
    RECT client;
    GetClientRect(window, &client);
    int w = min(scale(440), client.right - scale(32));
    if (w <= scale(180) || client.bottom <= scale(150)) return;
    int action = scale(56), pad = scale(14);
    int text_width = w - action - 3 * pad;
    int h = max(scale(54), min(scale(104), text_height(notice_text, text_width) + 2 * pad));
    int drift = MulDiv(FULL - notice_motion.value, scale(9), FULL);
    MoveWindow(notice_text, pad + scale(3), pad, text_width, h - 2 * pad, FALSE);
    MoveWindow(notice_close, w - action - pad, (h - scale(28)) / 2, action, scale(28), FALSE);
    SetWindowPos(notice, HWND_TOP, (client.right - w) / 2, scale(78) - drift, w, h,
        SWP_NOACTIVATE | SWP_SHOWWINDOW);
    RedrawWindow(notice, NULL, NULL, RDW_INVALIDATE | RDW_NOERASE | RDW_ALLCHILDREN);
}

static void dismiss_notice(void) {
    KillTimer(window, NOTICE_TIMER);
    if (!notice || !notice_motion.to) return;
    if (GetFocus() == notice_close) {
        int nav = find_kind(TABS);
        if (nav >= 0) SetFocus(nodes[nav].hwnd);
    }
    EnableWindow(notice_close, FALSE);
    retarget(&notice_motion, 0);
    place_notice();
}

static LRESULT CALLBACK notice_proc(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
    switch (msg) {
    case WM_ERASEBKGND: return 1;
    case WM_CTLCOLORSTATIC:
        SetTextColor((HDC)w, ink());
        SetBkColor((HDC)w, card());
        return (LRESULT)card_brush;
    case WM_DRAWITEM: return draw_control((const DRAWITEMSTRUCT *)l);
    case WM_COMMAND:
        if ((HWND)l == notice_close && HIWORD(w) == BN_CLICKED) dismiss_notice();
        return 0;
    case WM_PAINT: {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(hwnd, &paint);
        RECT area;
        GetClientRect(hwnd, &area);
        FillRect(dc, &paint.rcPaint, card_brush);
        HBRUSH accent = CreateSolidBrush(contrast ? ink() : notice_severe ? RGB(174, 75, 41) : RGB(69, 92, 171));
        if (accent) {
            RECT stripe = {0, 0, scale(4), area.bottom};
            FillRect(dc, &stripe, accent);
            DeleteObject(accent);
        }
        EndPaint(hwnd, &paint);
        return 0;
    }
    }
    return DefWindowProcW(hwnd, msg, w, l);
}

void share_desktop_notice(const char *message, int length, int severe) {
    if (!notice || length <= 0 || length > 768) return;
    wchar_t text[768];
    wide(message, length, text, ARRAYSIZE(text));
    if (!text[0]) return;
    notice_severe = severe != 0;
    set_text(notice, text);
    set_text(notice_text, text);
    EnableWindow(notice_close, TRUE);
    retarget(&notice_motion, FULL);
    place_notice();
    SetTimer(window, NOTICE_TIMER, notice_severe ? 7500 : 4300, NULL);
}

static void animate(void) {
    ULONGLONG now = GetTickCount64();
    BOOL again = FALSE, reflow = FALSE, nav_changed = FALSE;
    for (size_t i = 0; i < ARRAYSIZE(sections); i++) {
        Motion *reveal = &sections[i].reveal;
        reflow |= advance(reveal, now, SECTION_MS);
        again |= reveal->since != 0;
    }
    if (reflow) layout_page();
    if (advance(&notice_motion, now, TAB_MS)) place_notice();
    again |= notice_motion.since != 0;
    if (advance(&scroll_motion, now, WHEEL_MS)) move_page(scroll_motion.value);
    again |= scroll_motion.since != 0;
    for (size_t i = 0; i < ARRAYSIZE(tab_selection); i++) {
        nav_changed |= advance(&tab_selection[i], now, TAB_MS);
        nav_changed |= advance(&tab_hover[i], now, BUTTON_MS);
        again |= tab_selection[i].since != 0 || tab_hover[i].since != 0;
    }
    if (nav_changed) {
        int nav = find_kind(TABS);
        if (nav >= 0) InvalidateRect(nodes[nav].hwnd, NULL, FALSE);
    }
    for (int i = 0; i < count; i++) {
        Motion *hover = &nodes[i].hover;
        if (advance(hover, now, BUTTON_MS)) InvalidateRect(nodes[i].hwnd, NULL, FALSE);
        again |= hover->since != 0;
    }
    if (!again && motion_timer) {
        KillTimer(window, MOTION_TIMER);
        motion_timer = FALSE;
    }
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
    switch (msg) {
    case WM_GETMINMAXINFO: {
        MINMAXINFO *info = (MINMAXINFO *)l;
        info->ptMinTrackSize.x = scale(470);
        info->ptMinTrackSize.y = scale(480);
        return 0;
    }
    case WM_SIZE: layout(); return 0;
    case WM_DPICHANGED: {
        dpi = HIWORD(w);
        fonts();
        const RECT *area = (const RECT *)l;
        SetWindowPos(hwnd, NULL, area->left, area->top, area->right-area->left, area->bottom-area->top,
            SWP_NOZORDER | SWP_NOACTIVATE);
        layout();
        return 0;
    }
    case WM_MOUSEWHEEL: {
        if (!page) return 0;
        int limit = scroll_limit();
        int base = scroll_motion.since ? min(scroll_motion.to, limit) : scroll;
        int step = MulDiv(GET_WHEEL_DELTA_WPARAM(w), scale(44), WHEEL_DELTA);
        set_scroll(max(0, min(base - step, limit)), TRUE);
        return 0;
    }
    case WM_SETTINGCHANGE:
        motion_enabled = prefer_motion();
        if (motion_timer && !motion_enabled) animate();
        return 0;
    case WM_DRAWITEM: return draw_control((const DRAWITEMSTRUCT *)l);
    case WM_CTLCOLORSTATIC: return (LRESULT)control_background((HWND)l, (HDC)w, FALSE);
    case WM_CTLCOLOREDIT: return (LRESULT)control_background((HWND)l, (HDC)w, TRUE);
    case WM_DROPFILES: drop((HDROP)w); return 0;
    case WM_COMMAND: {
        int id = LOWORD(w) - FIRST_CONTROL;
        if (id >= 0 && id < count && (HWND)l == nodes[id].hwnd) {
            HWND owner = GetParent(nodes[id].hwnd);
            if (HIWORD(w) == BN_CLICKED && nodes[id].kind == BUTTON &&
                IsWindowEnabled(nodes[id].hwnd) && IsWindowEnabled(owner))
                share_desktop_command(nodes[id].id);
            if (HIWORD(w) == EN_CHANGE && nodes[id].kind == EDIT_FIELD) share_desktop_changed(nodes[id].id);
            if ((nodes[id].kind == BUTTON && HIWORD(w) == BN_SETFOCUS) ||
                (nodes[id].kind == EDIT_FIELD && HIWORD(w) == EN_SETFOCUS) ||
                (nodes[id].kind == SELECT && HIWORD(w) == CBN_SETFOCUS)) reveal(id);
        }
        return 0;
    }
    case WM_NOTIFY:
        if (((const NMHDR *)l)->code == TCN_SELCHANGE)
            select_tab(TabCtrl_GetCurSel(((const NMHDR *)l)->hwndFrom));
        return 0;
    case WM_TIMER:
        if (w == TIMER) share_desktop_tick();
        else if (w == MOTION_TIMER) animate();
        else if (w == NOTICE_TIMER) dismiss_notice();
        return 0;
    case WM_CLOSE:
        if (share_desktop_close()) DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        share_desktop_clear_pair_clipboard();
        KillTimer(hwnd, TIMER);
        KillTimer(hwnd, MOTION_TIMER);
        KillTimer(hwnd, NOTICE_TIMER);
        PostQuitMessage(0);
        return 0;
    default: return DefWindowProcW(hwnd, msg, w, l);
    }
}

int share_desktop_create(void) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    INITCOMMONCONTROLSEX controls = {sizeof(controls), ICC_TAB_CLASSES | ICC_PROGRESS_CLASS};
    if (!InitCommonControlsEx(&controls)) return 0;
    HIGHCONTRASTW hc = { .cbSize = sizeof(hc) };
    contrast = SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(hc), &hc, 0) && (hc.dwFlags & HCF_HIGHCONTRASTON);
    motion_enabled = prefer_motion();
    canvas_brush = CreateSolidBrush(canvas());
    card_brush = CreateSolidBrush(card());
    drop_brush = CreateSolidBrush(drop_color());
    if (!canvas_brush || !card_brush || !drop_brush) return 0;
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW wc = { .lpfnWndProc = window_proc, .hInstance = instance,
        .hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512)), .hbrBackground = canvas_brush,
        .hIcon = LoadIconW(instance, MAKEINTRESOURCEW(101)), .lpszClassName = L"PulseShareDesktop" };
    if (!RegisterClassW(&wc)) return 0;
    wc.lpfnWndProc = view_proc;
    wc.lpszClassName = L"PulseShareViewport";
    if (!RegisterClassW(&wc)) return 0;
    wc.lpszClassName = L"PulseSharePage";
    if (!RegisterClassW(&wc)) return 0;
    wc.lpfnWndProc = notice_proc;
    wc.lpszClassName = L"PulseShareNotice";
    BOOL notice_registered = RegisterClassW(&wc) != 0;
    RECT work;
    if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0)) return 0;
    dpi = (int)GetDpiForSystem();
    int work_width = work.right - work.left, work_height = work.bottom - work.top;
    int w = min(scale(920), min(work_width, MulDiv(work_height, 4, 3)));
    int h = MulDiv(w, 3, 4);
    window = CreateWindowExW(WS_EX_CONTROLPARENT, L"PulseShareDesktop", L"Pulse Share · 文件共享",
        WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, work.left + (work.right - work.left - w) / 2,
        work.top + (work.bottom - work.top - h) / 2, w, h, NULL, NULL, instance, NULL);
    if (!window) return 0;
    HICON small_icon = (HICON)LoadImageW(instance, MAKEINTRESOURCEW(101), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_SHARED);
    if (small_icon) SendMessageW(window, WM_SETICON, ICON_SMALL, (LPARAM)small_icon);
    viewport = CreateWindowExW(WS_EX_CONTROLPARENT | WS_EX_COMPOSITED, L"PulseShareViewport", NULL,
        WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_CLIPCHILDREN, 0, 0, 0, 0, window, NULL, instance, NULL);
    if (!viewport) return 0;
    page = CreateWindowExW(WS_EX_CONTROLPARENT, L"PulseSharePage", NULL,
        WS_CHILD | WS_CLIPCHILDREN, 0, 0, 0, 0, viewport, NULL, instance, NULL);
    if (!page || !SetTimer(window, TIMER, 100, NULL)) return 0;
    if (notice_registered) {
        notice = CreateWindowExW(WS_EX_CONTROLPARENT, L"PulseShareNotice", NULL,
            WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS | WS_BORDER, 0, 0, 0, 0, window, NULL, instance, NULL);
        if (notice) {
            notice_text = CreateWindowExW(0, L"Static", NULL, WS_CHILD | WS_VISIBLE | SS_NOPREFIX,
                0, 0, 0, 0, notice, NULL, instance, NULL);
            notice_close = CreateWindowExW(0, L"Button", L"关闭",
                WS_CHILD | WS_VISIBLE | WS_TABSTOP | (contrast ? BS_PUSHBUTTON : BS_OWNERDRAW),
                0, 0, 0, 0, notice, NULL, instance, NULL);
            if (!notice_text || !notice_close) {
                DestroyWindow(notice);
                notice = notice_text = notice_close = NULL;
            }
        }
    }
    fonts();
    DragAcceptFiles(window, TRUE);
    return 1;
}

void share_desktop_finish(void) { PostMessageW(window, WM_CLOSE, 0, 0); }

void share_desktop_run(void) {
    layout();
    ShowWindow(window, SW_SHOWNORMAL);
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        HWND target = pair_popup && (msg.hwnd == pair_popup || IsChild(pair_popup, msg.hwnd)) ? pair_popup : window;
        if (!IsDialogMessageW(target, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    DeleteObject(font);
    DeleteObject(heading);
    DeleteObject(caption);
    DeleteObject(code_font);
    DeleteObject(canvas_brush);
    DeleteObject(card_brush);
    DeleteObject(drop_brush);
}

int share_desktop_pick(int directory, char *out, int capacity) {
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (FAILED(hr)) return -1;
    IFileOpenDialog *dialog = NULL;
    int size = -1;
    hr = CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileOpenDialog, (void **)&dialog);
    if (SUCCEEDED(hr)) {
        DWORD options = FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR;
        options |= directory ? FOS_PICKFOLDERS : FOS_FILEMUSTEXIST;
        hr = IFileOpenDialog_SetOptions(dialog, options);
        if (SUCCEEDED(hr)) hr = IFileOpenDialog_Show(dialog, window);
        if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) size = 0;
        if (SUCCEEDED(hr)) {
            IShellItem *item = NULL;
            if (SUCCEEDED(IFileOpenDialog_GetResult(dialog, &item))) {
                PWSTR path = NULL;
                if (SUCCEEDED(IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &path))) {
                    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, -1, out, capacity, NULL, NULL);
                    if (n > 1) size = n - 1;
                    CoTaskMemFree(path);
                }
                IShellItem_Release(item);
            }
        }
        IFileOpenDialog_Release(dialog);
    }
    CoUninitialize();
    return size;
}

static BOOL app_directory(wchar_t directory[MAX_PATH], BOOL create) {
    PWSTR known = NULL;
    if (FAILED(SHGetKnownFolderPath(&FOLDERID_LocalAppData, KF_FLAG_DEFAULT, NULL, &known))) return FALSE;
    int n = swprintf(directory, MAX_PATH, L"%ls\\PulseShare", known);
    CoTaskMemFree(known);
    if (n <= 0 || n >= MAX_PATH) return FALSE;
    if (create && !CreateDirectoryW(directory, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return FALSE;
    DWORD attrs = GetFileAttributesW(directory);
    if (attrs == INVALID_FILE_ATTRIBUTES) {
        DWORD error = GetLastError();
        return !create && (error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND);
    }
    return (attrs & FILE_ATTRIBUTE_DIRECTORY) && !(attrs & FILE_ATTRIBUTE_REPARSE_POINT);
}

static BOOL preferences_path(wchar_t out[MAX_PATH], wchar_t directory[MAX_PATH], BOOL create) {
    if (!app_directory(directory, create)) return FALSE;
    int n = swprintf(out, MAX_PATH, L"%ls\\preferences.dat", directory);
    return n > 0 && n < MAX_PATH;
}

int share_desktop_default_path(int kind, char *out, int capacity) {
    wchar_t directory[MAX_PATH], result[MAX_PATH];
    PWSTR known = NULL;
    const wchar_t *path = result;
    if (kind == 2) {
        if (FAILED(SHGetKnownFolderPath(&FOLDERID_Downloads, KF_FLAG_DEFAULT, NULL, &known))) return 0;
        path = known;
    } else {
        if (!app_directory(directory, FALSE)) return 0;
        int n = swprintf(result, MAX_PATH, L"%ls\\%ls", directory, kind == 0 ? L"identity" : L"spool");
        if (n <= 0 || n >= MAX_PATH) return 0;
    }
    int n = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, -1, out, capacity, NULL, NULL);
    CoTaskMemFree(known);
    return n > 1 ? n - 1 : 0;
}

int share_desktop_prepare_default_parent(void) {
    wchar_t directory[MAX_PATH];
    return app_directory(directory, TRUE);
}

int share_desktop_preferences_read(char *out, int capacity) {
    wchar_t path[MAX_PATH], directory[MAX_PATH];
    if (!preferences_path(path, directory, FALSE)) return -1;
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (file == INVALID_HANDLE_VALUE) {
        DWORD error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ? 0 : -1;
    }
    BY_HANDLE_FILE_INFORMATION details;
    DWORD read = 0;
    BOOL ok = GetFileType(file) == FILE_TYPE_DISK && GetFileInformationByHandle(file, &details) &&
        !(details.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) &&
        details.nNumberOfLinks == 1 && !details.nFileSizeHigh &&
        details.nFileSizeLow > 0 && details.nFileSizeLow <= (DWORD)capacity &&
        ReadFile(file, out, details.nFileSizeLow, &read, NULL) && read == details.nFileSizeLow;
    CloseHandle(file);
    return ok ? (int)read : -1;
}

int share_desktop_preferences_write(const char *bytes, int length) {
    wchar_t path[MAX_PATH], directory[MAX_PATH], temporary[MAX_PATH];
    if (!preferences_path(path, directory, TRUE) || !GetTempFileNameW(directory, L"psh", 0, temporary))
        return FALSE;
    HANDLE file = CreateFileW(temporary, GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    BY_HANDLE_FILE_INFORMATION details;
    DWORD written = 0;
    BOOL ok = file != INVALID_HANDLE_VALUE && GetFileInformationByHandle(file, &details) &&
        !(details.dwFileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) &&
        details.nNumberOfLinks == 1 && !details.nFileSizeHigh && !details.nFileSizeLow &&
        WriteFile(file, bytes, (DWORD)length, &written, NULL) && written == (DWORD)length && FlushFileBuffers(file);
    if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
    if (ok) ok = MoveFileExW(temporary, path, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    if (!ok) DeleteFileW(temporary);
    return ok;
}

uint64_t share_desktop_label_nonce(void) {
    uint64_t random;
    if (BCryptGenRandom(NULL, (PUCHAR)&random, sizeof(random), BCRYPT_USE_SYSTEM_PREFERRED_RNG) == 0) return random;
    FILETIME now;
    GetSystemTimePreciseAsFileTime(&now);
    return ((uint64_t)now.dwHighDateTime << 32 | now.dwLowDateTime) ^ GetCurrentProcessId();
}

int share_desktop_default_network(char *out, int capacity) {
    ULONG size = 15 * 1024;
    ULONG flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER | GAA_FLAG_INCLUDE_GATEWAYS;
    HANDLE heap = GetProcessHeap();
    IP_ADAPTER_ADDRESSES *list = HeapAlloc(heap, 0, size);
    if (!list) return 0;
    ULONG status = GetAdaptersAddresses(AF_INET, flags, NULL, list, &size);
    if (status == ERROR_BUFFER_OVERFLOW && size <= 128 * 1024) {
        IP_ADAPTER_ADDRESSES *larger = HeapReAlloc(heap, 0, list, size);
        if (larger) {
            list = larger;
            status = GetAdaptersAddresses(AF_INET, flags, NULL, list, &size);
        }
    }
    const unsigned char *best = NULL, *fallback = NULL;
    ULONG best_metric = ULONG_MAX;
    BOOL tie = FALSE;
    int candidates = 0;
    if (status == NO_ERROR) for (const IP_ADAPTER_ADDRESSES *nic = list; nic; nic = nic->Next) {
        if (nic->OperStatus != IfOperStatusUp ||
            (nic->IfType != IF_TYPE_ETHERNET_CSMACD && nic->IfType != IF_TYPE_IEEE80211) ||
            (nic->Flags & IP_ADAPTER_NO_MULTICAST)) continue;
        for (const IP_ADAPTER_UNICAST_ADDRESS *a = nic->FirstUnicastAddress; a; a = a->Next) {
            if (a->DadState != IpDadStatePreferred || a->Address.iSockaddrLength < (int)sizeof(SOCKADDR_IN)) continue;
            const SOCKADDR_IN *address = (const SOCKADDR_IN *)a->Address.lpSockaddr;
            if (!address || address->sin_family != AF_INET) continue;
            const unsigned char *ip = (const unsigned char *)&address->sin_addr;
            if (ip[0] == 0 || ip[0] == 127 || (ip[0] == 169 && ip[1] == 254)) continue;
            candidates++;
            fallback = ip;
            if (!nic->FirstGatewayAddress) continue;
            if (!best || nic->Ipv4Metric < best_metric) {
                best = ip;
                best_metric = nic->Ipv4Metric;
                tie = FALSE;
            } else if (nic->Ipv4Metric == best_metric) tie = TRUE;
        }
    }
    if (tie) best = NULL;
    if (!best && candidates == 1) best = fallback;
    int result = best ? snprintf(out, capacity, "%u.%u.%u.%u", best[0], best[1], best[2], best[3]) : 0;
    HeapFree(heap, 0, list);
    return result > 0 && result < capacity ? result : 0;
}


int share_desktop_clear_pair_clipboard(void) {
    if (!copied_pair_sequence) return 1;
    if (!OpenClipboard(window)) return 0;
    BOOL cleared = GetClipboardOwner() != window || GetClipboardSequenceNumber() != copied_pair_sequence ||
        EmptyClipboard();
    CloseClipboard();
    if (cleared) copied_pair_sequence = 0;
    return cleared;
}

int share_desktop_copy(const char *text, int length, int contains_code) {
    wchar_t value[260];
    wide(text, length, value, ARRAYSIZE(value));
    int result = 0;
    HGLOBAL data = NULL, marker = NULL;
    if (!value[0]) goto done;
    size_t bytes = (wcslen(value) + 1) * sizeof(wchar_t);
    data = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!data) goto done;
    void *lock = GlobalLock(data);
    if (!lock) goto done;
    memcpy(lock, value, bytes);
    GlobalUnlock(data);
    UINT format = 0;
    if (contains_code) {
        format = RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing");
        if (!format || !(marker = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, 1))) goto done;
    }
    if (!OpenClipboard(window)) goto done;
    if (EmptyClipboard()) {
        BOOL admitted = !marker || SetClipboardData(format, marker);
        if (admitted) {
            marker = NULL;
            if (SetClipboardData(CF_UNICODETEXT, data)) {
                data = NULL;
                copied_pair_sequence = contains_code ? GetClipboardSequenceNumber() : 0;
                result = 1;
            } else EmptyClipboard();
        }
    }
    CloseClipboard();
done:
    if (data) {
        void *remaining = GlobalLock(data);
        if (remaining) {
            SecureZeroMemory(remaining, GlobalSize(data));
            GlobalUnlock(data);
        }
        GlobalFree(data);
    }
    if (marker) GlobalFree(marker);
    SecureZeroMemory(value, sizeof(value));
    return result;
}

int share_desktop_paste(char *out, int capacity) {
    if (!OpenClipboard(window)) return -1;
    HGLOBAL data = GetClipboardData(CF_UNICODETEXT);
    int result = 0;
    const wchar_t *value = data ? GlobalLock(data) : NULL;
    if (value) {
        size_t count = min(GlobalSize(data) / sizeof(wchar_t), (size_t)256);
        const wchar_t *end = wmemchr(value, 0, count);
        if (!end) result = -1;
        else if (end > value) {
            result = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, (int)(end - value),
                out, capacity, NULL, NULL);
            if (!result) result = -1;
        }
        GlobalUnlock(data);
    }
    CloseClipboard();
    return result;
}

enum { POPUP_COPY = 1, POPUP_COPY_ADDRESS, POPUP_CLOSE };

static void popup_fonts(void) {
    if (!pair_popup) return;
    SendMessageW(popup_code, WM_SETFONT, (WPARAM)code_font, TRUE);
    HWND controls[] = {popup_address, popup_copy, popup_copy_addr, popup_notice, popup_close};
    for (size_t i = 0; i < ARRAYSIZE(controls); i++)
        SendMessageW(controls[i], WM_SETFONT, (WPARAM)font, TRUE);
}

static LRESULT CALLBACK popup_proc(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
    switch (msg) {
    case WM_CLOSE:
        ShowWindow(hwnd, SW_HIDE);
        SetActiveWindow(window);
        return 0;
    case WM_COMMAND:
        switch (LOWORD(w)) {
        case POPUP_COPY: share_desktop_command("share-copy-pair"); return 0;
        case POPUP_COPY_ADDRESS: share_desktop_command("share-copy-address"); return 0;
        case POPUP_CLOSE: return SendMessageW(hwnd, WM_CLOSE, 0, 0);
        default: return 0;
        }
    case WM_CTLCOLORSTATIC:
        SetTextColor((HDC)w, ink());
        SetBkColor((HDC)w, canvas());
        return (LRESULT)canvas_brush;
    case WM_NCDESTROY:
        pair_popup = NULL;
        break;
    }
    return DefWindowProcW(hwnd, msg, w, l);
}

static HWND popup_control(const wchar_t *kind, const wchar_t *caption, DWORD style, int id) {
    return CreateWindowExW(0, kind, caption, WS_CHILD | WS_VISIBLE | style, 0, 0, 0, 0,
        pair_popup, (HMENU)(INT_PTR)id, GetModuleHandleW(NULL), NULL);
}

static BOOL create_pair_popup(void) {
    HINSTANCE module = GetModuleHandleW(NULL);
    WNDCLASSW wc = { .lpfnWndProc = popup_proc, .hInstance = module,
        .lpszClassName = L"PulseSharePairing", .hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512)),
        .hbrBackground = canvas_brush };
    if (!RegisterClassW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return FALSE;
    pair_popup = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_CONTROLPARENT, wc.lpszClassName, L"Pulse Share · 配对信息",
        WS_CAPTION | WS_SYSMENU | WS_CLIPCHILDREN, 0, 0, 0, 0, window, NULL, module, NULL);
    if (!pair_popup) return FALSE;
    popup_address = popup_control(L"Static", L"", SS_CENTER, 0);
    popup_code = popup_control(L"Static", L"", SS_CENTER, 0);
    popup_notice = popup_control(L"Static", L"", SS_CENTER, 0);
    popup_copy = popup_control(L"Button", L"复制地址和连接码", WS_TABSTOP, POPUP_COPY);
    popup_copy_addr = popup_control(L"Button", L"只复制地址", WS_TABSTOP, POPUP_COPY_ADDRESS);
    popup_close = popup_control(L"Button", L"返回主窗口", WS_TABSTOP, POPUP_CLOSE);
    if (!popup_address || !popup_code || !popup_notice || !popup_copy || !popup_copy_addr || !popup_close) {
        DestroyWindow(pair_popup);
        return FALSE;
    }
    popup_fonts();
    return TRUE;
}

static void center_pair_popup(void) {
    const int client_w = scale(432), client_h = scale(225);
    RECT area = {0, 0, client_w, client_h}, parent;
    AdjustWindowRectExForDpi(&area, WS_CAPTION | WS_SYSMENU, FALSE, WS_EX_TOOLWINDOW, dpi);
    GetWindowRect(window, &parent);
    int width = area.right - area.left, height = area.bottom - area.top;
    int x = (parent.left + parent.right - width) / 2;
    int y = (parent.top + parent.bottom - height) / 2;
    MONITORINFO monitor = { .cbSize = sizeof(monitor) };
    if (GetMonitorInfoW(MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST), &monitor)) {
        x = max(monitor.rcWork.left, min(x, monitor.rcWork.right - width));
        y = max(monitor.rcWork.top, min(y, monitor.rcWork.bottom - height));
    }
    const int margin = scale(18), gap = scale(8), full = client_w - 2 * margin;
    SetWindowPos(pair_popup, HWND_TOP, x, y, width, height, SWP_NOACTIVATE);
    MoveWindow(popup_address, margin, scale(20), full, scale(24), TRUE);
    MoveWindow(popup_code, margin, scale(52), full, scale(40), TRUE);
    MoveWindow(popup_notice, margin, scale(99), full, scale(44), TRUE);
    MoveWindow(popup_copy, margin, scale(150), (full - gap) / 2, scale(34), TRUE);
    MoveWindow(popup_copy_addr, margin + (full + gap) / 2, scale(150), (full - gap) / 2, scale(34), TRUE);
    MoveWindow(popup_close, (client_w - scale(144)) / 2, scale(190), scale(144), scale(28), TRUE);
}

int share_desktop_pair_popup(const char *address, int address_len, const char *code, int code_len, int show) {
    if (!pair_popup && (!show || !create_pair_popup())) return 0;
    wchar_t number[16], endpoint[100], old_code[16];
    wide(address, address_len, endpoint, ARRAYSIZE(endpoint));
    wide(code, code_len, number, ARRAYSIZE(number));
    GetWindowTextW(popup_code, old_code, ARRAYSIZE(old_code));
    if (wcscmp(number, old_code)) set_text(popup_notice, L"将配对信息发给对方。两边都需核对指纹。");
    set_text(popup_address, endpoint);
    set_text(popup_code, number);
    EnableWindow(popup_copy, TRUE);
    EnableWindow(popup_copy_addr, TRUE);
    if (show && !IsWindowVisible(pair_popup)) {
        center_pair_popup();
        ShowWindow(pair_popup, SW_SHOWNORMAL);
        SetFocus(popup_copy);
    }
    SecureZeroMemory(number, sizeof(number));
    SecureZeroMemory(old_code, sizeof(old_code));
    return 1;
}

void share_desktop_pair_clear(int hide) {
    if (!pair_popup) return;
    set_text(popup_address, L"");
    set_text(popup_code, L"");
    set_text(popup_notice, L"等待新连接码");
    EnableWindow(popup_copy, FALSE);
    EnableWindow(popup_copy_addr, FALSE);
    if (hide) ShowWindow(pair_popup, SW_HIDE);
}

void share_desktop_pair_copied(int contains_code) {
    if (pair_popup) set_text(popup_notice, contains_code ?
        L"已复制，可粘贴到聊天。连接码轮换后需重新复制。" : L"已复制此设备的配对地址。");
}


int share_desktop_stamp(char *out, int capacity) {
    SYSTEMTIME local;
    GetLocalTime(&local);
    return snprintf(out, capacity, "%04u-%02u-%02u %02u:%02u:%02u",
        local.wYear, local.wMonth, local.wDay, local.wHour, local.wMinute, local.wSecond);
}

int share_desktop_export_diagnostics(const char *bytes, int length) {
    if (length <= 0 || length > 8192) return -1;
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (FAILED(hr)) return -1;
    IFileSaveDialog *dialog = NULL;
    int result = -1;
    hr = CoCreateInstance(&CLSID_FileSaveDialog, NULL, CLSCTX_INPROC_SERVER, &IID_IFileSaveDialog, (void **)&dialog);
    if (SUCCEEDED(hr)) {
        const COMDLG_FILTERSPEC types[] = {{L"诊断文本 (*.txt)", L"*.txt"}};
        DWORD options = FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR | FOS_NOREADONLYRETURN;
        hr = IFileSaveDialog_SetOptions(dialog, options);
        if (SUCCEEDED(hr)) hr = IFileSaveDialog_SetFileTypes(dialog, ARRAYSIZE(types), types);
        if (SUCCEEDED(hr)) hr = IFileSaveDialog_SetDefaultExtension(dialog, L"txt");
        if (SUCCEEDED(hr)) hr = IFileSaveDialog_SetFileName(dialog, L"Pulse-Share-诊断.txt");
        if (SUCCEEDED(hr)) hr = IFileSaveDialog_SetTitle(dialog, L"导出 Share 诊断");
        if (SUCCEEDED(hr)) hr = IFileSaveDialog_Show(dialog, window);
        if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) result = 0;
        if (SUCCEEDED(hr)) {
            IShellItem *item = NULL;
            if (SUCCEEDED(IFileSaveDialog_GetResult(dialog, &item))) {
                PWSTR path = NULL;
                if (SUCCEEDED(IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &path))) {
                    HANDLE file = CreateFileW(path, GENERIC_WRITE | DELETE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
                    if (file != INVALID_HANDLE_VALUE) {
                        DWORD written;
                        if (WriteFile(file, bytes, (DWORD)length, &written, NULL) && written == (DWORD)length && FlushFileBuffers(file)) result = 1;
                        else {
                            FILE_DISPOSITION_INFO discard = { .DeleteFile = TRUE };
                            SetFileInformationByHandle(file, FileDispositionInfo, &discard, sizeof(discard));
                        }
                        CloseHandle(file);
                    }
                    CoTaskMemFree(path);
                }
                IShellItem_Release(item);
            }
        }
        IFileSaveDialog_Release(dialog);
    }
    CoUninitialize();
    return result;
}
