
#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <winsock2.h>
#include <windows.h>
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
enum { FIRST_CONTROL = 100, MAX_NODES = 288, TIMER = 1 };
typedef struct {
    int kind, parent, appearance;
    char id[64], key[64], enabled[64];
    HWND hwnd;
    RECT bounds;
    BOOL shown;
} Node;

static Node nodes[MAX_NODES];
static int count, tab, scroll, content_height, dpi = 96;
static HWND window, viewport;
static HFONT font, heading, caption, code_font;
static HBRUSH canvas_brush, card_brush, drop_brush;
static HDWP window_batch;
static HWND hot_button;
static BOOL in_layout, measure_only, busy, showing_code, confirming, has_bytes, contrast, long_status;
static struct {
    const char *id, *key;
    BOOL visible;
} sections[] = {
    {"routed-pair-card", "show-routed-pair", FALSE},
    {"send-extras", "show-send-options", FALSE},
    {"receive-extras", "show-receive-options", FALSE},
    {"network-options", "show-network-options", FALSE},
    {"storage-options", "show-storage-options", FALSE},
    {"send-address-field", "show-address-field", FALSE},
    {"lan-join-form", "show-lan-join", FALSE},
    {"found-receivers", "show-found-receivers", FALSE},
    {"found-pairing", "show-found-pairing", FALSE},
    {"listed-peers", "show-listed-peers", FALSE},
};
extern void share_desktop_command(const char *);
extern void share_desktop_tick(void);
extern int share_desktop_close(void);
extern void share_desktop_changed(const char *);
extern void share_desktop_drop(const char *, size_t, uint32_t, int);
static void layout(void);
static LRESULT CALLBACK tabs_proc(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);

static int scale(int value) { return MulDiv(value, dpi, 96); }
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
    for (size_t i = 0; i < ARRAYSIZE(previous); i++) DeleteObject(previous[i]);
}

static LRESULT CALLBACK button_proc(HWND hwnd, UINT msg, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR data) {
    (void)id; (void)data;
    if (msg == WM_MOUSEMOVE && hot_button != hwnd) {
        hot_button = hwnd;
        TRACKMOUSEEVENT mouse = {sizeof(mouse), TME_LEAVE, hwnd, 0};
        TrackMouseEvent(&mouse);
        InvalidateRect(hwnd, NULL, FALSE);
    } else if (msg == WM_MOUSELEAVE && hot_button == hwnd) {
        hot_button = NULL;
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
    HWND owner = viewport;
    if (in_task(index) || kind == TABS) owner = window;
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
        if (kind == BUTTON && !contrast) SetWindowSubclass(node->hwnd, button_proc, 1, 0);
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
    if (!strcmp(key, "confirm") && confirming != on) { confirming = on; relayout = TRUE; }
    for (size_t i = 0; i < ARRAYSIZE(sections); i++) {
        if (!strcmp(key, sections[i].key) && sections[i].visible != on) {
            sections[i].visible = on;
            relayout = TRUE;
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
        if (n->enabled[0] && !strcmp(n->enabled, key)) EnableWindow(n->hwnd, !wcscmp(text, L"true"));
        if (!n->key[0] || strcmp(n->key, key)) continue;
        if (n->kind == SELECT) SendMessageW(n->hwnd, CB_SETCURSEL, (WPARAM)wcstol(text, NULL, 10), 0);
        else if (n->kind == PROGRESS) SendMessageW(n->hwnd, PBM_SETPOS, (WPARAM)wcstol(text, NULL, 10), 0);
        else if (n->kind == TABS) {
            int selected = (int)wcstol(text, NULL, 10);
            if (tab != selected) {
                tab = selected;
                scroll = 0;
                TabCtrl_SetCurSel(n->hwnd, tab);
                relayout = TRUE;
            }
        }
        else if (n->kind == TEXT || n->kind == EDIT_FIELD) {
            set_text(n->hwnd, text);
            if (relayout && !strcmp(n->id, "status-line")) ShowScrollBar(n->hwnd, SB_VERT, long_status);
        }
    }
    SecureZeroMemory(text, sizeof(text));
    if (relayout) layout();
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
    if (measure_only) return;
    const UINT flags = SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOCOPYBITS | SWP_NOREDRAW | visibility;
    if (window_batch) {
        window_batch = DeferWindowPos(window_batch, hwnd, NULL, x, y, width, height, flags);
        if (window_batch) return;
    }
    SetWindowPos(hwnd, NULL, x, y, width, height, flags);
}

static BOOL omitted_from_layout(const Node *n) {
    for (size_t i = 0; i < ARRAYSIZE(sections); i++)
        if (!sections[i].visible && !strcmp(n->id, sections[i].id)) return TRUE;
    return (!strcmp(n->id, "pair-code") && !showing_code) ||
        ((!strcmp(n->id, "byte-count") || n->kind == PROGRESS) && !has_bytes) ||
        (!strcmp(n->id, "share-cancel") && !busy) ||
        ((!strcmp(n->id, "share-approve") || !strcmp(n->id, "share-decline")) && !confirming);
}

static int place(int i, int x, int y, int width, BOOL visible) {
    Node *n = &nodes[i];
    BOOL omitted = omitted_from_layout(n);
    if ((!visible || omitted) && n->hwnd && n->kind != TABS &&
        (GetWindowLongPtrW(n->hwnd, GWL_STYLE) & WS_VISIBLE))
        position(n->hwnd, 0, 0, 0, 0, SWP_HIDEWINDOW | SWP_NOMOVE | SWP_NOSIZE);
    n->shown = visible && !omitted;
    if (omitted) {
        for (int j = i + 1; j < count; j++)
            if (nodes[j].parent == i) place(j, x, y, width, FALSE);
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
        if (n->hwnd && visible) position(n->hwnd, x + pad, y + pad, width - 2 * pad, title,
            title ? SWP_SHOWWINDOW : SWP_HIDEWINDOW);
        return height;
    }
    switch (n->kind) {
    case TEXT:
        height = !strcmp(n->id, "pair-code") ? scale(34) :
            !strcmp(n->id, "status-line") ? scale(long_status ? 51 : 24) :
            !strcmp(n->id, "source") ? scale(76) :
            !strcmp(n->id, "discovery-text") ? scale(43) :
            !strcmp(n->id, "history-text") || strstr(n->id, "-inventory") ? scale(68) :
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
        position(n->hwnd, x, y, width, n->kind == SELECT ? scale(280) : height, SWP_SHOWWINDOW);
    }
    return height;
}

static void layout(void) {
    if (!window || !viewport || in_layout) return;
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
    RECT inner;
    GetClientRect(viewport, &inner);
    int status_x = x, status_width = width;
    if (tabs >= 0) {
        HWND nav = nodes[tabs].hwnd;
        int item_width = max(scale(50), min((width - scale(42)) / max(1, TabCtrl_GetItemCount(nav)), scale(96)));
        TabCtrl_SetItemSize(nav, item_width, scale(34));
        int nav_width = min(width, TabCtrl_GetItemCount(nav) * (item_width + scale(3)) + scale(6));
        position(nav, (box.right - nav_width) / 2, scale(14), nav_width, scale(42), SWP_SHOWWINDOW);
        static const int page_width[] = { 850, 552, 696, 568, 632, 760 };
        // Reserve the same gutter with or without a scrollbar so cards do not
        // jump when a section is expanded or a different tab is selected.
        int gutter = GetSystemMetricsForDpi(SM_CXVSCROLL, dpi) + scale(6);
        int usable_width = max(scale(110), width - 2 * gutter);
        int body_width = min(usable_width, scale(page_width[tab >= 0 && tab < (int)ARRAYSIZE(page_width) ? tab : 0]));
        int body_x = (width - body_width) / 2;
        status_x = x + body_x;
        status_width = body_width;
        // Measure and clamp first, then move all siblings in one batch.
        measure_only = TRUE;
        place(tabs, body_x, 0, body_width, TRUE);
        measure_only = FALSE;
        scroll = max(0, min(scroll, content_height - inner.bottom));
        window_batch = BeginDeferWindowPos(count);
        place(tabs, body_x, scale(4) - scroll, body_width, TRUE);
        BOOL committed = window_batch && EndDeferWindowPos(window_batch);
        window_batch = NULL;
        if (!committed) place(tabs, body_x, scale(4) - scroll, body_width, TRUE);
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
        SCROLLINFO info = { .cbSize = sizeof(info), .fMask = SIF_ALL,
            .nMax = max(0, content_height - 1), .nPage = (UINT)inner.bottom, .nPos = scroll };
        SetScrollInfo(viewport, SB_VERT, &info, TRUE);
        ShowScrollBar(viewport, SB_VERT, content_height > inner.bottom);
    }
    if (task >= 0) {
        window_batch = BeginDeferWindowPos(10);
        place(task, status_x, bottom + scale(8), status_width, TRUE);
        BOOL committed = window_batch && EndDeferWindowPos(window_batch);
        window_batch = NULL;
        if (!committed) place(task, status_x, bottom + scale(8), status_width, TRUE);
    }
    RedrawWindow(window, NULL, NULL, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN);
    in_layout = FALSE;
}

void share_desktop_layout(void) { layout(); }

void share_desktop_show_section(const char *id) {
    int i = find(id);
    if (i < 0 || !nodes[i].shown) return;
    scroll += nodes[i].bounds.top - scale(4);
    layout();
}

static LRESULT CALLBACK view_proc(HWND hwnd, UINT msg, WPARAM w, LPARAM l) {
    switch (msg) {
    case WM_PAINT: {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(hwnd, &paint);
        FillRect(dc, &paint.rcPaint, canvas_brush);
        for (int i = 0; i < count; i++) {
            const Node *n = &nodes[i];
            RECT changed;
            if (n->kind == GROUP_BOX && n->shown && !in_task(i) && IntersectRect(&changed, &n->bounds, &paint.rcPaint))
                surface(dc, n->bounds, card(), border(), 20);
        }
        EndPaint(hwnd, &paint);
        return 0;
    }
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLOREDIT:
    case WM_DRAWITEM:
    case WM_COMMAND: return SendMessageW(window, msg, w, l);
    case WM_MOUSEWHEEL: return SendMessageW(window, msg, w, l);
    case WM_VSCROLL: {
        SCROLLINFO info = { .cbSize = sizeof(info), .fMask = SIF_TRACKPOS };
        GetScrollInfo(hwnd, SB_VERT, &info);
        switch (LOWORD(w)) {
        case SB_THUMBPOSITION:
        case SB_THUMBTRACK: scroll = info.nTrackPos; break;
        case SB_LINEUP: scroll -= scale(28); break;
        case SB_LINEDOWN: scroll += scale(28); break;
        case SB_PAGEUP: scroll -= scale(160); break;
        case SB_PAGEDOWN: scroll += scale(160); break;
        case SB_TOP: scroll = 0; break;
        case SB_BOTTOM: scroll = content_height; break;
        default: return 0;
        }
        layout();
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
        BOOL active = item->itemID == (UINT)tab;
        InflateRect(&area, -scale(3), -scale(2));
        fill = active ? RGB(221, 229, 247) : canvas();
        line = fill;
        fg = active ? RGB(48, 68, 141) : ink();
    } else if (item->CtlType == ODT_BUTTON) {
        int i = (int)item->CtlID - FIRST_CONTROL;
        if (i < 0 || i >= count) return FALSE;
        const Node *n = &nodes[i];
        BOOL disabled = (item->itemState & ODS_DISABLED) != 0;
        BOOL down = (item->itemState & ODS_SELECTED) != 0;
        BOOL hover = hot_button == item->hwndItem;
        BOOL primary = n->appearance == 2 && !disabled;
        FillRect(dc, &area, inside_card(i) && !in_task(i) ? card_brush : canvas_brush);
        fill = primary ? (down ? RGB(35, 49, 107) : hover ? RGB(68, 90, 181) : RGB(52, 72, 155)) :
            (disabled ? RGB(239, 241, 246) : down ? RGB(214, 222, 239) : hover ? RGB(232, 237, 248) : card());
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

static LRESULT CALLBACK tabs_proc(HWND hwnd, UINT msg, WPARAM w, LPARAM l, UINT_PTR id, DWORD_PTR data) {
    (void)id; (void)data;
    switch (msg) {
    case WM_ERASEBKGND: return 1;
    case WM_PRINTCLIENT: draw_tabs(hwnd, (HDC)w); return 0;
    case WM_PAINT: {
        PAINTSTRUCT paint;
        HDC dc = BeginPaint(hwnd, &paint);
        draw_tabs(hwnd, dc);
        EndPaint(hwnd, &paint);
        return 0;
    }
    default: return DefSubclassProc(hwnd, msg, w, l);
    }
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
    if (in_layout || !n->shown || GetParent(n->hwnd) != viewport) return;
    RECT inner;
    GetClientRect(viewport, &inner);
    if (n->bounds.top < 0) scroll += n->bounds.top - scale(4);
    else if (n->bounds.bottom > inner.bottom) scroll += n->bounds.bottom - inner.bottom + scale(4);
    else return;
    layout();
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
    case WM_MOUSEWHEEL:
        scroll -= GET_WHEEL_DELTA_WPARAM(w) * scale(44) / WHEEL_DELTA;
        layout();
        return 0;
    case WM_DRAWITEM: return draw_control((const DRAWITEMSTRUCT *)l);
    case WM_CTLCOLORSTATIC: return (LRESULT)control_background((HWND)l, (HDC)w, FALSE);
    case WM_CTLCOLOREDIT: return (LRESULT)control_background((HWND)l, (HDC)w, TRUE);
    case WM_DROPFILES: drop((HDROP)w); return 0;
    case WM_COMMAND: {
        int id = LOWORD(w) - FIRST_CONTROL;
        if (id >= 0 && id < count && (HWND)l == nodes[id].hwnd) {
            if (HIWORD(w) == BN_CLICKED && nodes[id].kind == BUTTON && IsWindowEnabled(nodes[id].hwnd))
                share_desktop_command(nodes[id].id);
            if (HIWORD(w) == EN_CHANGE && nodes[id].kind == EDIT_FIELD) share_desktop_changed(nodes[id].id);
            if ((nodes[id].kind == BUTTON && HIWORD(w) == BN_SETFOCUS) ||
                (nodes[id].kind == EDIT_FIELD && HIWORD(w) == EN_SETFOCUS) ||
                (nodes[id].kind == SELECT && HIWORD(w) == CBN_SETFOCUS)) reveal(id);
        }
        return 0;
    }
    case WM_NOTIFY:
        if (((const NMHDR *)l)->code == TCN_SELCHANGE) {
            HWND nav = ((const NMHDR *)l)->hwndFrom;
            tab = TabCtrl_GetCurSel(nav);
            InvalidateRect(nav, NULL, TRUE);
            scroll = 0;
            layout();
        }
        return 0;
    case WM_TIMER:
        if (w == TIMER) share_desktop_tick();
        return 0;
    case WM_CLOSE:
        if (share_desktop_close()) DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        KillTimer(hwnd, TIMER);
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
    RECT work;
    if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0)) return 0;
    dpi = (int)GetDpiForSystem();
    int w = min(scale(780), work.right - work.left), h = min(scale(820), work.bottom - work.top);
    window = CreateWindowExW(WS_EX_CONTROLPARENT, L"PulseShareDesktop", L"Pulse Share · 文件共享",
        WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN, work.left + (work.right - work.left - w) / 2,
        work.top + (work.bottom - work.top - h) / 2, w, h, NULL, NULL, instance, NULL);
    if (!window) return 0;
    HICON small_icon = (HICON)LoadImageW(instance, MAKEINTRESOURCEW(101), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_SHARED);
    if (small_icon) SendMessageW(window, WM_SETICON, ICON_SMALL, (LPARAM)small_icon);
    viewport = CreateWindowExW(WS_EX_CONTROLPARENT, L"PulseShareViewport", NULL,
        WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_CLIPCHILDREN, 0, 0, 0, 0, window, NULL, instance, NULL);
    if (!viewport || !SetTimer(window, TIMER, 100, NULL)) return 0;
    fonts();
    DragAcceptFiles(window, TRUE);
    return 1;
}

void share_desktop_finish(void) { PostMessageW(window, WM_CLOSE, 0, 0); }

void share_desktop_run(void) {
    layout();
    ShowWindow(window, SW_SHOWNORMAL);
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0)
        if (!IsDialogMessageW(window, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
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
