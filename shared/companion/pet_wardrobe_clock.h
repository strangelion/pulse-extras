#ifndef PULSE_PET_WARDROBE_CLOCK_H
#define PULSE_PET_WARDROBE_CLOCK_H
#include <stdint.h>

/* Civil-time minute boundaries plus a bounded fallback for wall-clock
 * adjustments that do not deliver a window notification. No timer. */
static inline uint32_t pet_wardrobe_wait_ms(unsigned second, unsigned millisecond) {
    if (second >= 60 || millisecond >= 1000) return 15000;
    uint32_t until = 60000u - second * 1000u - millisecond;
    return until < 15000u ? until : 15000u;
}

static inline int pet_wardrobe_switch_due(int automatic, unsigned current,
    unsigned target, uint32_t rejected) {
    return automatic && target <= 16 && target != current &&
        !(rejected & (UINT32_C(1) << target));
}
#endif
