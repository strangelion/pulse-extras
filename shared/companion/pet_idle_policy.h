#ifndef PULSE_PET_IDLE_POLICY_H
#define PULSE_PET_IDLE_POLICY_H
#include <stdint.h>

/* Single-carrier, session-local policy matching the pinned OpenPets
 * pet-activity-policy.ts timing and selection. Caller owns admission,
 * synchronous playback, presentation and cleanup. No timers or I/O. */
#define PET_IDLE_MAX 16u
#define PET_IDLE_NONE PET_IDLE_MAX
#define PET_IDLE_COOLDOWN UINT64_C(300000)

typedef struct {
    uint32_t enabled, failed, played;
    uint64_t played_at[PET_IDLE_MAX];
    unsigned last; /* index + 1, zero = no history */
    uint64_t opportunity; /* zero = unscheduled */
} pet_idle_policy;

static inline uint32_t pet_idle_bit(unsigned index) {
    return index < PET_IDLE_MAX ? UINT32_C(1) << index : 0;
}

static inline uint32_t pet_idle_mask(unsigned count) {
    return count <= PET_IDLE_MAX ? (UINT32_C(1) << count) - 1 : 0;
}

static inline void pet_idle_interrupt(pet_idle_policy *p) {
    p->opportunity = 0;
}

static inline void pet_idle_toggle(pet_idle_policy *p, unsigned index) {
    p->enabled ^= pet_idle_bit(index);
    pet_idle_interrupt(p);
}

static inline void pet_idle_started(pet_idle_policy *p, unsigned index, uint64_t now) {
    if (index >= PET_IDLE_MAX) return;
    p->played_at[index] = now;
    p->played |= pet_idle_bit(index);
    p->last = index + 1;
    pet_idle_interrupt(p);
}

static inline void pet_idle_failed(pet_idle_policy *p, unsigned index) {
    p->failed |= pet_idle_bit(index);
    pet_idle_interrupt(p);
}

static inline uint64_t pet_idle_delay(uint32_t random) {
    return UINT64_C(120000) + ((uint64_t)random * UINT64_C(120000) / UINT32_MAX);
}

/* No fixed polling; only the caller's existing animation/message/deadline
 * wake. A delayed wake admits at most one action, never a catch-up burst. */
static inline unsigned pet_idle_choose(pet_idle_policy *p, unsigned count,
    int available, uint64_t now, uint32_t delay_random, uint32_t choice_random) {
    uint32_t enabled = p->enabled & ~p->failed & pet_idle_mask(count);
    if (!available || !enabled) {
        pet_idle_interrupt(p);
        return PET_IDLE_NONE;
    }
    if (!p->opportunity) {
        uint64_t delay = pet_idle_delay(delay_random);
        p->opportunity = now > UINT64_MAX - delay ? UINT64_MAX : now + delay;
        return PET_IDLE_NONE;
    }
    if (now < p->opportunity) return PET_IDLE_NONE;
    unsigned candidates[PET_IDLE_MAX], n = 0;
    int multiple = (enabled & (enabled - 1)) != 0;
    for (unsigned i = 0; i < count; ++i) {
        uint32_t bit = pet_idle_bit(i);
        if (!(enabled & bit) || (multiple && p->last == i + 1)) continue;
        if ((p->played & bit) && (now < p->played_at[i] || now - p->played_at[i] < PET_IDLE_COOLDOWN)) continue;
        candidates[n++] = i;
    }
    pet_idle_interrupt(p);
    if (!n) {
        uint64_t delay = pet_idle_delay(delay_random);
        p->opportunity = now > UINT64_MAX - delay ? UINT64_MAX : now + delay;
        return PET_IDLE_NONE;
    }
    return candidates[((uint64_t)choice_random * n) >> 32];
}
#endif
