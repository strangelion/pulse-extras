#ifndef PULSE_PET_MENU_STRINGS_WIN32_H
#define PULSE_PET_MENU_STRINGS_WIN32_H
#include "pet_surface_win32.h"
#include <wchar.h>

typedef enum {
    PET_LANGUAGE_SYSTEM, PET_LANGUAGE_ZH_CN, PET_LANGUAGE_ZH_TW, PET_LANGUAGE_EN_US
} pet_language;

typedef struct {
    const wchar_t *size, *topmost, *reduced, *reset, *interact, *exit, *activities, *automatic, *outfit, *default_outfit, *auto_outfit, *gaze;
} pet_menu_strings;

static inline BOOL pet_language_parse(const wchar_t *text, pet_language *language) {
    if (!text || !language) return FALSE;
    if (wcscmp(text, L"system") == 0) *language = PET_LANGUAGE_SYSTEM;
    else if (wcscmp(text, L"zh-CN") == 0) *language = PET_LANGUAGE_ZH_CN;
    else if (wcscmp(text, L"zh-TW") == 0) *language = PET_LANGUAGE_ZH_TW;
    else if (wcscmp(text, L"en-US") == 0) *language = PET_LANGUAGE_EN_US;
    else return FALSE;
    return TRUE;
}

static inline pet_language pet_language_resolve(pet_language requested, LANGID system_ui) {
    if (requested != PET_LANGUAGE_SYSTEM) return requested;
    if (PRIMARYLANGID(system_ui) != LANG_CHINESE) return PET_LANGUAGE_EN_US;
    /* Traditional Chinese: Taiwan, Hong Kong and Macau. Simplified:
     * mainland China and Singapore. Unknown Chinese sublanguage uses CN. */
    unsigned sub = SUBLANGID(system_ui);
    return sub == 1 || sub == 3 || sub == 5 ? PET_LANGUAGE_ZH_TW : PET_LANGUAGE_ZH_CN;
}

/* Wide strings are independent from the process ANSI code page. */
static inline pet_menu_strings pet_menu_labels(pet_language requested, LANGID system_ui) {
    switch (pet_language_resolve(requested, system_ui)) {
    case PET_LANGUAGE_ZH_CN:
        return (pet_menu_strings){L"大小", L"窗口置顶", L"减少动态效果", L"重置位置", L"播放互动动画", L"退出桌宠", L"自定义活动", L"自动活动", L"服装", L"默认服装", L"按时间表自动换装", L"鼠标视线追踪"};
    case PET_LANGUAGE_ZH_TW:
        return (pet_menu_strings){L"大小", L"視窗置頂", L"減少動態效果", L"重設位置", L"播放互動動畫", L"結束桌寵", L"自訂活動", L"自動活動", L"服裝", L"預設服裝", L"依時間表自動換裝", L"滑鼠視線追蹤"};
    default:
        return (pet_menu_strings){L"Size", L"Always on top", L"Reduce motion", L"Reset position", L"Play animation", L"Exit pet", L"Idle activities", L"Automatic activities", L"Outfit", L"Default", L"Automatic (schedule)", L"Idle cursor gaze"};
    }
}
#endif
