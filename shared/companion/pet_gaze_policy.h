#ifndef PULSE_PET_GAZE_POLICY_H
#define PULSE_PET_GAZE_POLICY_H
#include <stdint.h>
#include <math.h>

/* OpenPetsHQ/openpets@2f02bb04d872dec6923a47572343305235c63482:
 * codex-pets-core.ts and pet-window-gaze.ts. Native physical pixels,
 * no CSS flip or carrier inset in this standalone surface. */
#define PET_GAZE_INTERVAL 100u
#define PET_GAZE_IDLE_RESET 1200u
#define PET_GAZE_MOVEMENT_PAUSE 180u
#define PET_GAZE_NONE (-1)

typedef struct {
    uint64_t next, moved_at, suspended_until;
    int32_t x, y;
    int seeded, moved, direction;
} pet_gaze;

static inline int pet_gaze_direction(double dx, double dy) {
    if (!isfinite(dx) || !isfinite(dy) || dx * dx + dy * dy <= 576.0)
        return PET_GAZE_NONE;
    const double sector_angle = 0.39269908169872415481; /* pi/8 */
    int sector = (int)floor((atan2(dx, -dy) + sector_angle / 2.0) / sector_angle);
    return (sector + 16) % 16;
}

static inline void pet_gaze_reset(pet_gaze *g) {
    *g = (pet_gaze){.direction = PET_GAZE_NONE};
}

static inline void pet_gaze_suspend(pet_gaze *g, uint64_t now) {
    pet_gaze_reset(g);
    g->suspended_until = now + PET_GAZE_MOVEMENT_PAUSE;
    g->next = g->suspended_until;
}

/* Called only after the owner's deadline. The first sample is a baseline,
 * not movement. No catch-up samples after suspension. */
static inline int pet_gaze_observe(pet_gaze *g, uint64_t now,
    int32_t x, int32_t y, double anchor_x, double anchor_y) {
    if (now < g->suspended_until) return PET_GAZE_NONE;
    g->next = now + PET_GAZE_INTERVAL;
    if (g->seeded && (g->x != x || g->y != y)) {
        g->moved = 1;
        g->moved_at = now;
    }
    g->seeded = 1;
    g->x = x; g->y = y;
    g->direction = g->moved && now >= g->moved_at &&
        now - g->moved_at < PET_GAZE_IDLE_RESET ?
        pet_gaze_direction((double)x - anchor_x, (double)y - anchor_y) : PET_GAZE_NONE;
    return g->direction;
}

static inline int pet_gaze_eligible(unsigned version, int enabled, int visible,
    int reduced, int pressed, int activity, unsigned row) {
    return version == 2 && enabled && visible && !reduced && !pressed && !activity && row == 0;
}
#endif
